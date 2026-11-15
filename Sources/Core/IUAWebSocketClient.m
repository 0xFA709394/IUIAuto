/*
MIT License

Copyright (c) 2011-Present 0xFA709394

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
 */

#import "IUAWebSocketClient.h"
#import "IUALogger.h"
#import "IUAConfiguration.h"

typedef NS_ENUM(NSUInteger, IUAWSState) {
    IUAWSStateIdle = 0,
    IUAWSStateConnecting,
    IUAWSStateConnected,
};

static void *kIUAWSStateQueueKey = &kIUAWSStateQueueKey;
static const NSUInteger kIUAWSMaxIncomingMessageBytes = 8 * 1024 * 1024;

/// 仅对本机/内网地址放宽自签名证书；公网 wss 仍走系统默认校验，降低 MITM 面
static BOOL IUAIsLocalOrPrivateHost(NSString *host) {
    NSString *lower = host.lowercaseString ?: @"";
    if (lower.length == 0) return NO;
    if ([lower isEqualToString:@"localhost"] || [lower hasSuffix:@".local"]) return YES;
    if ([lower containsString:@":"]) {
        if ([lower isEqualToString:@"::1"] || [lower hasPrefix:@"fe80:"] ||
            [lower hasPrefix:@"fc"] || [lower hasPrefix:@"fd"]) return YES;
    }
    NSArray<NSString *> *parts = [lower componentsSeparatedByString:@"."];
    if (parts.count != 4) return NO;
    NSInteger a = parts[0].integerValue, b = parts[1].integerValue;
    if (a == 127) return YES;
    if (a == 10) return YES;
    if (a == 192 && b == 168) return YES;
    if (a == 172 && b >= 16 && b <= 31) return YES;
    return NO;
}

@class IUAWebSocketClient;

@protocol IUAWSDelegateForwarding <NSObject>
- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(nullable NSString *)protocol;
- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(nullable NSData *)reason;
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable credential))completionHandler;
@end

/// 弱转发代理：避免 NSURLSession 强引用 client delegate 形成 client↔session 循环
@interface IUAWSDelegateProxy : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, weak, nullable) IUAWebSocketClient<IUAWSDelegateForwarding> *client;
@end

@implementation IUAWSDelegateProxy
- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString *)protocol {
    [self.client URLSession:session webSocketTask:webSocketTask didOpenWithProtocol:protocol];
}
- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(NSData *)reason {
    [self.client URLSession:session webSocketTask:webSocketTask didCloseWithCode:closeCode reason:reason];
}
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if (self.client) {
        [self.client URLSession:session didReceiveChallenge:challenge completionHandler:completionHandler];
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}
@end

@interface IUAWebSocketClient () <IUAWSDelegateForwarding>

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) IUAWSDelegateProxy *sessionDelegate;
@property (nonatomic, strong, nullable) NSURLSessionWebSocketTask *task;
@property (nonatomic, strong) dispatch_queue_t stateQueue; // 状态机串行队列
@property (nonatomic, assign) IUAWSState state;
@property (nonatomic, assign) NSUInteger reconnectAttempt;   // 连续失败次数（退避基数）
@property (nonatomic, strong, nullable) dispatch_source_t heartbeatTimer;
@property (nonatomic, assign) BOOL manualDisconnected;

@end

@implementation IUAWebSocketClient

- (instancetype)initWithURL:(NSURL *)URL {
    NSParameterAssert(URL != nil);
    if (self = [super init]) {
        _URL = URL;
        _state = IUAWSStateIdle;
        _manualDisconnected = NO;
        _stateQueue = dispatch_queue_create("IUAWebSocketClient.state", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_stateQueue, kIUAWSStateQueueKey, (__bridge void *)self, NULL);
    }
    return self;
}

- (BOOL)isOnStateQueue {
    return dispatch_get_specific(kIUAWSStateQueueKey) == (__bridge void *)self;
}

/// 状态读写统一走 stateQueue；若调用方已在队列内则直接执行，避免死锁
- (void)performOnStateQueue:(dispatch_block_t)block {
    if ([self isOnStateQueue]) {
        block();
    } else {
        dispatch_sync(self.stateQueue, block);
    }
}

- (BOOL)isConnected {
    __block BOOL connected = NO;
    [self performOnStateQueue:^{
        connected = (self.state == IUAWSStateConnected);
    }];
    return connected;
}

- (void)dealloc {
    [self stopHeartbeat];
    // 正常路径必须由持有方调用 disconnect；session 会强引用 delegate，
    // 未 disconnect 直接释放时 dealloc 实际不会执行（这是 NSURLSession 的约定）。
    // 这里保留 invalidate 兜底，覆盖 session 尚未创建/已被外部置空的情况。
    [_session finishTasksAndInvalidate];
    _sessionDelegate = nil;
}

#pragma mark - 连接管理

- (void)connect {
    dispatch_async(self.stateQueue, ^{
        self.manualDisconnected = NO;
        if (self.state != IUAWSStateIdle) {
            IUALogDebug(@"WS: connect 被调用但当前状态非 Idle(=%ld)，忽略", (long)self.state);
            return;
        }
        [self startTask];
    });
}

- (void)startTask {
    self.state = IUAWSStateConnecting;
    NSURLSessionWebSocketTask *task = [self.session webSocketTaskWithURL:self.URL];
    self.task = task;
    IUALogInfo(@"WS: 正在连接 %@", self.URL.absoluteString);
    [task resume];
    [self receiveLoopOnTask:task];
}

- (void)disconnect {
    dispatch_async(self.stateQueue, ^{
        self.manualDisconnected = YES;
        [self teardownTask];
        self.state = IUAWSStateIdle;
        // NSURLSession 强引用 delegate(self) 且持有系统资源：不 invalidate 会
        // 造成 session↔client 循环引用泄漏（每次 engine 重启泄漏一整个 session）
        if (self->_session) {
            [self->_session finishTasksAndInvalidate];
            self->_session = nil;
        }
        IUALogInfo(@"WS: 已主动断开");
        if ([self.delegate respondsToSelector:@selector(webSocketDidDisconnectManually:)]) {
            [self.delegate webSocketDidDisconnectManually:self];
        }
    });
}

/// 清理当前 task / 心跳，并安排指数退避重连（若非主动断开）
- (void)teardownTask {
    [self stopHeartbeat];
    [self.task cancel];
    self.task = nil;
}

- (void)handleDisconnectWithError:(nullable NSError *)error {
    // 回调来自 session delegate queue / 心跳回调 / send 完成回调，
    // 统一回到 stateQueue，避免与 connect/disconnect 并发修改状态。
    if ([self isOnStateQueue]) {
        [self handleDisconnectOnStateQueue:error];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.stateQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf handleDisconnectOnStateQueue:error];
    });
}

- (void)handleDisconnectOnStateQueue:(nullable NSError *)error {
    if (self.state == IUAWSStateIdle) {
        return; // 已是关闭状态（主动断开路径已处理）
    }
    [self teardownTask];
    self.state = IUAWSStateIdle;

    if (self.manualDisconnected) {
        if ([self.delegate respondsToSelector:@selector(webSocketDidDisconnectManually:)]) {
            [self.delegate webSocketDidDisconnectManually:self];
        }
        return;
    }

    // 指数退避重连
    NSTimeInterval minInt = [IUAConfiguration reconnectMinInterval];
    NSTimeInterval maxInt = [IUAConfiguration reconnectMaxInterval];
    NSTimeInterval delay = MIN(minInt * pow(2, (double)self.reconnectAttempt), maxInt);
    self.reconnectAttempt += 1;
    IUALogWarn(@"WS: 连接断开(%@)，%.1fs 后第 %lu 次重连",
               error.localizedDescription ?: @"-", delay, (unsigned long)self.reconnectAttempt);

    if ([self.delegate respondsToSelector:@selector(webSocket:didCloseWithError:reconnectScheduled:)]) {
        [self.delegate webSocket:self didCloseWithError:error reconnectScheduled:YES];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), self.stateQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.manualDisconnected || strongSelf.state != IUAWSStateIdle) {
            return;
        }
        [strongSelf startTask];
    });
}

#pragma mark - 收发

- (void)receiveLoopOnTask:(NSURLSessionWebSocketTask *)task {
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        // task 已被替换时，丢弃过期回调
        if (strongSelf.task != task) {
            return;
        }
        if (error) {
            [strongSelf handleDisconnectWithError:error];
            return;
        }
        if (message.string.length > 0) {
            [strongSelf handleTextMessage:message.string];
        }
        [strongSelf receiveLoopOnTask:task];
    }];
}

- (void)handleTextMessage:(NSString *)text {
    if (text.length > kIUAWSMaxIncomingMessageBytes) {
        IUALogWarn(@"WS: 收到超大消息（%lu 字符），已丢弃", (unsigned long)text.length);
        return;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        IUALogWarn(@"WS: 收到无法解码的消息");
        return;
    }
    NSError *error = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![json isKindOfClass:[NSDictionary class]]) {
        IUALogWarn(@"WS: 收到非 JSON 对象消息: %@", text.length > 80 ? [text substringToIndex:80] : text);
        return;
    }
    [self.delegate webSocket:self didReceiveJSON:(NSDictionary *)json];
}

- (BOOL)sendJSON:(NSDictionary<NSString *, id> *)json {
    __block BOOL sent = NO;
    [self performOnStateQueue:^{
        if (self.state != IUAWSStateConnected || !self.task) {
            return;
        }
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
        if (!data) {
            IUALogError(@"WS: JSON 序列化失败: %@", error.localizedDescription);
            return;
        }
        NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc]
            initWithString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
        __weak typeof(self) weakSelf = self;
        [self.task sendMessage:message completionHandler:^(NSError * _Nullable sendError) {
            if (sendError) {
                IUALogWarn(@"WS: 发送失败: %@", sendError.localizedDescription);
                // 发送失败通常意味着连接已死，走断开流程触发重连
                [weakSelf handleDisconnectWithError:sendError];
            }
        }];
        sent = YES;
    }];
    return sent;
}

#pragma mark - 心跳

- (void)startHeartbeat {
    [self stopHeartbeat];
    NSTimeInterval interval = [IUAConfiguration heartbeatInterval];
    if (interval <= 0) {
        return;
    }
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.stateQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC),
                              (uint64_t)(1.0 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.state != IUAWSStateConnected || !strongSelf.task) {
            return;
        }
        [strongSelf.task sendPingWithPongReceiveHandler:^(NSError * _Nullable error) {
            if (error) {
                IUALogWarn(@"WS: 心跳无响应: %@", error.localizedDescription);
                [weakSelf handleDisconnectWithError:error];
            }
        }];
    });
    dispatch_resume(timer);
    self.heartbeatTimer = timer;
}

- (void)stopHeartbeat {
    if (self.heartbeatTimer) {
        dispatch_source_cancel(self.heartbeatTimer);
        self.heartbeatTimer = nil;
    }
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(NSString * _Nullable)protocol {
    dispatch_async(self.stateQueue, ^{
        if (webSocketTask != self.task) {
            return;
        }
        self.state = IUAWSStateConnected;
        self.reconnectAttempt = 0;
        IUALogInfo(@"WS: 已连接 %@", self.URL.absoluteString);
        [self startHeartbeat];
        [self.delegate webSocketDidOpen:self];
    });
}

- (void)URLSession:(NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(NSData * _Nullable)reason {
    NSString *reasonText = reason ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : nil;
    NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:(NSInteger)closeCode
                                  userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"连接被关闭 (code=%ld, reason=%@)", (long)closeCode, reasonText ?: @"-"]}];
    dispatch_async(self.stateQueue, ^{
        if (webSocketTask != self.task) {
            return;
        }
        [self handleDisconnectWithError:error];
    });
}

- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
                                     completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    // 内网自签名场景放宽；公网地址不走该分支（仍由系统校验证书链）
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
        IUAIsLocalOrPrivateHost(self.URL.host)) {
        SecTrustRef trust = challenge.protectionSpace.serverTrust;
        if (trust) {
            completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
            return;
        }
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

#pragma mark - Lazy

- (NSURLSession *)session {
    if (!_session) {
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1; // 串行队列，保证 delegate 回调有序
        delegateQueue.name = @"IUAWebSocketClient.delegateQueue";
        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
        // 避免服务器不可达时长期停留在 Connecting（否则 state 永远不会进入 Idle，重连逻辑失效）
        configuration.timeoutIntervalForRequest = 15.0;
        configuration.timeoutIntervalForResource = 0; // WebSocket 长连接不应因资源超时被中断
        IUAWSDelegateProxy *proxy = [[IUAWSDelegateProxy alloc] init];
        proxy.client = self;
        _sessionDelegate = proxy;
        _session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:proxy
                                            delegateQueue:delegateQueue];
    }
    return _session;
}

@end
