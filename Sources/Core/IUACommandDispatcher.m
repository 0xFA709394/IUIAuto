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

#import "IUACommandDispatcher.h"
#import "IUALogger.h"

@interface IUACommandDispatcher ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, IUAActionHandler> *handlers;
@property (nonatomic, strong) NSMutableArray<IUACommand *> *pendingCommands;
@property (nonatomic, strong) NSMutableArray<void (^)(IUACommandResult *)> *pendingCompletions;
@property (nonatomic, assign) BOOL executing;
@end

@implementation IUACommandDispatcher

- (instancetype)init {
    if (self = [super init]) {
        _handlers = [NSMutableDictionary dictionary];
        _pendingCommands = [NSMutableArray array];
        _pendingCompletions = [NSMutableArray array];
    }
    return self;
}

- (void)registerHandler:(NSString *)action handler:(IUAActionHandler)handler {
    if (action.length == 0 || !handler) {
        return;
    }
    self.handlers[action] = [handler copy];
}

- (NSArray<NSString *> *)registeredActions {
    return [self.handlers.allKeys sortedArrayUsingSelector:@selector(compare:)];
}

NSString *const IUACommandDispatcherBusyDidChangeNotification = @"IUACommandDispatcherBusyDidChangeNotification";

- (void)postBusyChange:(BOOL)busy {
    [[NSNotificationCenter defaultCenter] postNotificationName:IUACommandDispatcherBusyDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"busy" : @(busy)}];
}

- (void)dispatchCommand:(IUACommand *)command completion:(void (^)(IUACommandResult *result))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pendingCommands addObject:command];
        [self.pendingCompletions addObject:completion];
        [self drainOnMainThread];
    });
}

/// 主线程逐条执行；当前指令完成（或超时）后自动取下一条
- (void)drainOnMainThread {
    NSAssert([NSThread isMainThread], @"必须在主线程");

    if (self.executing) {
        return;
    }
    if (self.pendingCommands.count == 0) {
        return;
    }

    IUACommand *command = self.pendingCommands.firstObject;
    void (^completion)(IUACommandResult *) = self.pendingCompletions.firstObject;
    [self.pendingCommands removeObjectAtIndex:0];
    [self.pendingCompletions removeObjectAtIndex:0];

    IUAActionHandler handler = self.handlers[command.action];
    if (!handler) {
        IUALogWarn(@"未注册的动作: %@（可用: %@）", command.action, [self registeredActions]);
        IUACommandResult *result = [IUACommandResult resultForCommand:command ok:NO data:nil
                                                            errorText:[NSString stringWithFormat:@"unknown action: %@", command.action]
                                                               elapsed:0];
        completion(result);
        [self drainOnMainThread];
        return;
    }

    self.executing = YES;
    [self postBusyChange:YES];
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();

    // 先到先得：超时 guard 与真实完成竞争，仅一方生效
    __block BOOL finished = NO;
    __weak typeof(self) weakSelf = self;

    void (^finish)(BOOL, NSDictionary *, NSString *) = ^(BOOL ok, NSDictionary<NSString *, id> * _Nullable data, NSString * _Nullable errorMessage) {
        if (finished) {
            IUALogWarn(@"指令 %@(%@) 迟到结果已丢弃", command.commandId, command.action);
            return;
        }
        finished = YES;

        NSTimeInterval elapsed = CFAbsoluteTimeGetCurrent() - start;
        IUALogInfo(@"指令 %@(%@) %@ 耗时 %.0fms", command.commandId, command.action, ok ? @"成功" : @"失败", elapsed * 1000);

        IUACommandResult *result = [IUACommandResult resultForCommand:command ok:ok data:data
                                                            errorText:errorMessage elapsed:elapsed];
        completion(result);

        __strong typeof(weakSelf) strongSelf = weakSelf;
        strongSelf.executing = NO;
        [strongSelf postBusyChange:NO];
        [strongSelf drainOnMainThread];
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(command.timeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish(NO, nil, [NSString stringWithFormat:@"timeout after %.1fs", command.timeout]);
    });

    IUALogDebug(@"执行指令 %@(%@) params=%@", command.commandId, command.action, command.params);
    handler(command, finish);
}

@end
