//
//  IUAWebSocketClient.m
//  IUIAuto
//

#import "IUAWebSocketClient.h"
#import "IUALogger.h"
#import "IUAConfiguration.h"

typedef NS_ENUM(NSUInteger, IUAWSState) {
    IUAWSStateIdle = 0,
    IUAWSStateConnecting,
    IUAWSStateConnected,
};

@interface IUAWebSocketClient () <NSURLSessionWebSocketDelegate>

@property (nonatomic, strong) NSURLSession *session;
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
    }
    return self;
}

- (BOOL)isConnected {
    return self.state == IUAWSStateConnected;
}

- (void)dealloc {
    // 循环引用兜底：session 强引用 self，正常路径靠 disconnect 打破；
    // 若外部未 disconnect 即释放（父对象不再持有时 session 仍持 self），
    // 这里 invalidate 让 session 放开引用
    [_session finishTasksAndInvalidate];
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
    if (self.state != IUAWSStateConnected || !self.task) {
        return NO;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:&error];
    if (!data) {
        IUALogError(@"WS: JSON 序列化失败: %@", error.localizedDescription);
        return NO;
    }
    NSURLSessionWebSocketMessage *message = [[NSURLSessionWebSocketMessage alloc] initWithString:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    __weak typeof(self) weakSelf = self;
    [self.task sendMessage:message completionHandler:^(NSError * _Nullable sendError) {
        if (sendError) {
            IUALogWarn(@"WS: 发送失败: %@", sendError.localizedDescription);
            // 发送失败通常意味着连接已死，走断开流程触发重连
            [weakSelf handleDisconnectWithError:sendError];
        }
    }];
    return YES;
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
    // 内网自签名场景直接信任（工具型 App，风险已知）
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
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
        _session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]
                                                 delegate:self
                                            delegateQueue:delegateQueue];
    }
    return _session;
}

@end
