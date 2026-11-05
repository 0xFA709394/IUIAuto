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

#import "IUAEngine.h"
#import "IUAWebSocketClient.h"
#import "IUACommandDispatcher.h"
#import "IUACommandResult.h"
#import "IUAConfiguration.h"
#import "IUALogger.h"
#import "IUATouchSynthesizer.h"
#import "IUATextSynthesizer.h"
#import "IUAViewIntrospector.h"
#import "IUAScreenshotService.h"
#import "IUARecorder.h"
#import "IUAPerfSampler.h"

NSString *const IUAEngineConnectionDidChangeNotification = @"IUAEngineConnectionDidChangeNotification";

static NSString *const IUAActionErrorDomain = @"IUAActionErrorDomain";

/// 从 params 中解析点坐标：{"x":..,"y":..} 顶层或 {"from":{"x","y"}} 形式
/// 当前 firstResponder 探测：sendAction:to:nil 会沿响应链路由到 firstResponder
static UIResponder *gIUAEngineCapturedFR = nil;

@interface UIResponder (IUAEngineFRProbe)
- (void)iua_engineCaptureFR:(id)sender;
@end

@implementation UIResponder (IUAEngineFRProbe)
- (void)iua_engineCaptureFR:(id)sender {
    gIUAEngineCapturedFR = self;
}
@end

static UIResponder *IUACurrentFirstResponderForInput(void) {
    gIUAEngineCapturedFR = nil;
    [UIApplication.sharedApplication sendAction:@selector(iua_engineCaptureFR:)
                                             to:nil from:nil forEvent:nil];
    return gIUAEngineCapturedFR;
}

/// NSNumber 直接可用；NSString 必须能完整解析为数值（"12.5" ✓ "abc"/"12x" ✗）
static BOOL IUAIsNumeric(id value) {
    if ([value isKindOfClass:[NSNumber class]]) return YES;
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *trimmed = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (trimmed.length == 0) return NO;
    const char *cstr = trimmed.UTF8String;
    char *end = NULL;
    strtod(cstr, &end);
    return end != cstr && *end == '\0' && end != NULL;
}

static BOOL IUALoadPoint(NSDictionary<NSString *, id> * _Nullable params,
                         NSString *prefix, NSString *xKey, NSString *yKey, CGPoint *outPoint) {
    id x = params[xKey];
    id y = params[yKey];
    if (prefix.length > 0) {
        NSDictionary *sub = [params[prefix] isKindOfClass:[NSDictionary class]] ? params[prefix] : nil;
        if (!x && sub) x = sub[@"x"];
        if (!y && sub) y = sub[@"y"];
    }
    // 数值校验：任意字符串（如 "abc"→0.0）不得混过校验变成点击 (0,0)
    if (!IUAIsNumeric(x) || !IUAIsNumeric(y)) {
        return NO;
    }
    outPoint->x = [x doubleValue];
    outPoint->y = [y doubleValue];
    return YES;
}

/// identifier 定位 → view 中心点（window 坐标）
static BOOL IUALoadPointFromIdentifier(NSString *identifier, CGPoint *outPoint, NSString **errorText) {
    UIView *view = [IUAViewIntrospector findViewWithIdentifier:identifier];
    if (!view || view.hidden || view.alpha < 0.01) {
        *errorText = [NSString stringWithFormat:@"找不到可见的 view: identifier=%@", identifier];
        return NO;
    }
    UIWindow *window = view.window ?: [IUAViewIntrospector keyWindow];
    CGPoint center = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds)) toView:window];
    if (isnan(center.x) || isnan(center.y)) {
        *errorText = @"view 中心点计算失败";
        return NO;
    }
    *outPoint = center;
    return YES;
}

@interface IUAEngine () <IUAWebSocketClientDelegate>
@property (nonatomic, strong, nullable) IUAWebSocketClient *client;
@property (nonatomic, strong) IUACommandDispatcher *dispatcher;
@property (nonatomic, assign) BOOL logForwardingInProgress; // 重入保护
@end

@implementation IUAEngine

+ (instancetype)sharedEngine {
    static IUAEngine *engine = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engine = [[self alloc] init];
    });
    return engine;
}

- (instancetype)init {
    if (self = [super init]) {
        _dispatcher = [[IUACommandDispatcher alloc] init];
        [self registerBuiltinActions];
        [self installLogForwarder];
    }
    return self;
}

#pragma mark - 生命周期

- (void)start {
    [self startWithServerURLString:nil];
}

- (void)startWithServerURLString:(NSString *)urlString {
    if (urlString.length > 0) {
        [IUAConfiguration setServerURLString:urlString];
    }
    [self stop];

    NSURL *url = [IUAConfiguration serverURL];
    if (!url) {
        IUALogError(@"服务器地址无效: %@", [IUAConfiguration serverURLString]);
        return;
    }
    self.client = [[IUAWebSocketClient alloc] initWithURL:url];
    self.client.delegate = self;
    [self.client connect];
    IUALogInfo(@"Agent 已启动，服务器: %@", url.absoluteString);
}

- (void)stop {
    self.client.delegate = nil;
    [self.client disconnect];
    self.client = nil;
}

- (BOOL)isConnected {
    return self.client.isConnected;
}

- (NSString *)currentServerURLString {
    return [IUAConfiguration serverURLString];
}

- (NSArray<NSString *> *)registeredActions {
    return [self.dispatcher registeredActions];
}

#pragma mark - IUAWebSocketClientDelegate

- (void)webSocketDidOpen:(IUAWebSocketClient *)client {
    [self send:@{@"type" : @"hello",
                 @"agent" : @"IUIAuto",
                 @"version" : [IUAConfiguration agentVersion],
                 @"environment" : [IUAViewIntrospector environmentJSON],
                 @"actions" : [self.dispatcher registeredActions],
                 @"timestamp" : @(round(NSDate.date.timeIntervalSince1970 * 1000))}];
    [self notifyConnectionState:YES];
}

- (void)webSocket:(IUAWebSocketClient *)client didReceiveJSON:(NSDictionary<NSString *, id> *)json {
    // 指令：{"id","action",...}
    NSError *error = nil;
    IUACommand *command = [IUACommand commandWithJSONObject:json error:&error];
    if (command) {
        __weak typeof(self) weakSelf = self;
        [self.dispatcher dispatchCommand:command completion:^(IUACommandResult *result) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            [strongSelf send:result.jsonDictionary];
        }];
        return;
    }

    // 轻量探活：{"type":"ping"}
    NSString *type = [json[@"type"] isKindOfClass:[NSString class]] ? json[@"type"] : nil;
    if ([type isEqualToString:@"ping"]) {
        [self send:@{@"type" : @"pong",
                     @"timestamp" : @(round(NSDate.date.timeIntervalSince1970 * 1000))}];
        return;
    }

    IUALogWarn(@"收到无法处理的消息: %@", json);
}

- (void)webSocket:(IUAWebSocketClient *)client didCloseWithError:(nullable NSError *)error reconnectScheduled:(BOOL)reconnectScheduled {
    [self notifyConnectionState:NO];
}

#pragma mark - 内置动作注册

- (void)registerBuiltinActions {
    IUACommandDispatcher *dispatcher = self.dispatcher;

    void (^simple)(NSString *, void (^)(IUACommand *, void (^)(BOOL, NSDictionary *, NSString *))) =
        ^void(NSString *action, void (^body)(IUACommand *command, void (^finish)(BOOL ok, NSDictionary *data, NSString *error))) {
            [dispatcher registerHandler:action handler:body];
        };

    simple(@"ping", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        finish(YES, @{@"pong" : @YES,
                      @"timestamp" : @(round(NSDate.date.timeIntervalSince1970 * 1000))}, nil);
    });

    simple(@"app_info", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        finish(YES, [IUAViewIntrospector environmentJSON], nil);
    });

    simple(@"wait", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        double seconds = MIN(MAX([cmd floatParam:@"seconds" default:0.5], 0), 60);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            finish(YES, @{@"waited" : @(seconds)}, nil);
        });
    });

    simple(@"tap", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *identifier = [cmd stringParam:@"identifier"];
        if (identifier.length > 0) {
            [self tapIdentifier:identifier completion:finish];
            return;
        }
        CGPoint point = CGPointZero;
        if (!IUALoadPoint(cmd.params, @"", @"x", @"y", &point)) {
            finish(NO, nil, @"tap 需要 params.x/y 或 params.identifier");
            return;
        }
        [[IUATouchSynthesizer shared] tapAtPoint:point tapCount:1 completion:^(NSError * _Nullable error) {
            error ? finish(NO, nil, error.localizedDescription) : finish(YES, @{@"x" : @(point.x), @"y" : @(point.y)}, nil);
        }];
    });

    simple(@"tap_view", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *identifier = [cmd stringParam:@"identifier"];
        if (identifier.length == 0) {
            finish(NO, nil, @"tap_view 需要 params.identifier");
            return;
        }
        [self tapIdentifier:identifier completion:finish];
    });

    simple(@"double_tap", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        // identifier 定位复用 tap 的全套保障（自动滚动到可视区 + 重试）
        NSString *identifier = [cmd stringParam:@"identifier"];
        if (identifier.length > 0) {
            [self tapIdentifier:identifier tapCount:2 attempt:0 completion:^(BOOL ok, NSDictionary *data, NSString *error) {
                finish(ok, ok ? @{@"doubleTapped" : @YES, @"x" : data[@"x"], @"y" : data[@"y"]} : nil, error);
            }];
            return;
        }
        CGPoint point = CGPointZero;
        if (!IUALoadPoint(cmd.params, @"", @"x", @"y", &point)) {
            finish(NO, nil, @"double_tap 需要 params.x/y 或 params.identifier");
            return;
        }
        [[IUATouchSynthesizer shared] tapAtPoint:point tapCount:2 completion:^(NSError * _Nullable error) {
            error ? finish(NO, nil, error.localizedDescription) : finish(YES, @{@"doubleTapped" : @YES, @"x" : @(point.x), @"y" : @(point.y)}, nil);
        }];
    });

    simple(@"long_press", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        CGPoint point = CGPointZero;
        NSString *identifier = [cmd stringParam:@"identifier"];
        if (identifier.length > 0) {
            // 与 tap/double_tap 同款：元素可能滚出可视区，先自动滚动到可见
            UIView *view = [IUAViewIntrospector findViewWithIdentifier:identifier];
            if (!view || view.hidden || view.alpha < 0.01) {
                finish(NO, nil, [NSString stringWithFormat:@"找不到可见的 view: identifier=%@", identifier]);
                return;
            }
            [self ensureViewVisible:view];
            NSString *errorText = nil;
            if (!IUALoadPointFromIdentifier(identifier, &point, &errorText)) {
                finish(NO, nil, errorText);
                return;
            }
        } else if (!IUALoadPoint(cmd.params, @"", @"x", @"y", &point)) {
            finish(NO, nil, @"long_press 需要 params.x/y 或 params.identifier");
            return;
        }
        double duration = [cmd floatParam:@"duration" default:0.8];
        [[IUATouchSynthesizer shared] longPressAtPoint:point duration:duration completion:^(NSError * _Nullable error) {
            error ? finish(NO, nil, error.localizedDescription) : finish(YES, @{@"x" : @(point.x), @"y" : @(point.y), @"duration" : @(duration)}, nil);
        }];
    });

    simple(@"swipe", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        CGPoint from = CGPointZero, to = CGPointZero;
        BOOL okFrom = IUALoadPoint(cmd.params, @"from", @"fromX", @"fromY", &from);
        BOOL okTo = IUALoadPoint(cmd.params, @"to", @"toX", @"toY", &to);
        if (!okFrom || !okTo) {
            finish(NO, nil, @"swipe 需要 params.fromX/fromY/toX/toY（或 from:{x,y}/to:{x,y}）");
            return;
        }
        double duration = [cmd floatParam:@"duration" default:0.3];
        [[IUATouchSynthesizer shared] swipeFromPoint:from toPoint:to duration:duration completion:^(NSError * _Nullable error) {
            error ? finish(NO, nil, error.localizedDescription)
                  : finish(YES, @{@"fromX" : @(from.x), @"fromY" : @(from.y), @"toX" : @(to.x), @"toY" : @(to.y), @"duration" : @(duration)}, nil);
        }];
    });

    simple(@"pinch", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        CGPoint center = CGPointZero;
        if (!IUALoadPoint(cmd.params, @"center", @"x", @"y", &center) &&
            !IUALoadPoint(cmd.params, @"", @"centerX", @"centerY", &center)) {
            finish(NO, nil, @"pinch 需要 params.x/y（中心）+ radiusFrom/radiusTo");
            return;
        }
        CGFloat r0 = [cmd floatParam:@"radiusFrom" default:100];
        CGFloat r1 = [cmd floatParam:@"radiusTo" default:20];
        double duration = [cmd floatParam:@"duration" default:0.5];
        [[IUATouchSynthesizer shared] pinchAtCenter:center fromRadius:r0 toRadius:r1 duration:duration completion:^(NSError * _Nullable error) {
            error ? finish(NO, nil, error.localizedDescription)
                  : finish(YES, @{@"centerX" : @(center.x), @"centerY" : @(center.y), @"radiusFrom" : @(r0), @"radiusTo" : @(r1)}, nil);
        }];
    });

    simple(@"type_text", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *text = [cmd stringParam:@"text"];
        if (text.length == 0) {
            finish(NO, nil, @"type_text 需要 params.text");
            return;
        }
        NSString *identifier = [cmd stringParam:@"identifier"];
        IUATextSynthesizer *synthesizer = [[IUATextSynthesizer alloc] init];
        [synthesizer typeText:text intoViewWithIdentifier:identifier completion:^(NSError * _Nullable error) {
            error ? finish(NO, nil, error.localizedDescription)
                  : finish(YES, @{@"typed" : @(text.length)}, nil);
        }];
    });

    simple(@"clear_text", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *identifier = [cmd stringParam:@"identifier"];
        IUATextSynthesizer *synthesizer = [[IUATextSynthesizer alloc] init];
        [synthesizer clearTextInViewWithIdentifier:identifier completion:^(NSError * _Nullable error) {
            error ? finish(NO, nil, error.localizedDescription) : finish(YES, @{}, nil);
        }];
    });

    simple(@"view_tree", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSInteger maxDepth = [cmd integerParam:@"maxDepth" default:0];
        finish(YES, @{@"windows" : [IUAViewIntrospector viewTreeJSONWithMaxDepth:maxDepth]}, nil);
    });

    simple(@"element_info", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *identifier = [cmd stringParam:@"identifier"];
        if (identifier.length == 0) {
            finish(NO, nil, @"element_info 需要 params.identifier");
            return;
        }
        UIView *view = [IUAViewIntrospector findViewWithIdentifier:identifier];
        if (!view) {
            finish(NO, nil, [NSString stringWithFormat:@"找不到 view: identifier=%@", identifier]);
            return;
        }
        finish(YES, [IUAViewIntrospector infoJSONForView:view maxDepth:2], nil);
    });

    simple(@"screenshot", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSUInteger quality = (NSUInteger)[cmd integerParam:@"quality" default:1];
        NSDictionary *info = [IUAScreenshotService screenshotWithQuality:quality];
        info ? finish(YES, info, nil) : finish(NO, nil, @"截图失败");
    });

    // ---- 录制：真机手工操作一遍，自动生成可回放脚本 ----
    simple(@"record_start", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        [IUARecorder.shared startRecording];
        finish(YES, @{@"recording" : @YES}, nil);
    });

    simple(@"record_stop", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSArray<NSDictionary<NSString *, id> *> *steps = [IUARecorder.shared stopRecording];
        if (!steps) {
            finish(NO, nil, @"当前不在录制中");
            return;
        }
        finish(YES, @{@"steps" : steps, @"count" : @(steps.count)}, nil);
    });

    simple(@"record_cancel", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        [IUARecorder.shared cancelRecording];
        finish(YES, @{}, nil);
    });

    simple(@"record_status", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        finish(YES, @{@"recording" : @(IUARecorder.shared.isRecording),
                      @"steps" : @(IUARecorder.shared.stepCount)}, nil);
    });

    // ---- 性能采样：App 进程内 CPU/内存/FPS（与宿主侧 xctrace 互补，任何环境可用）----
    simple(@"perf_start", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        double interval = [cmd floatParam:@"interval" default:0.5];
        BOOL started = [IUAPerfSampler.shared startSamplingWithInterval:interval];
        finish(started ? YES : NO,
               @{@"sampling" : @YES, @"interval" : @(interval)},
               started ? nil : @"已有采样在进行中");
    });

    simple(@"perf_stop", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSDictionary *stats = [IUAPerfSampler.shared stopSampling];
        if (!stats) {
            finish(NO, nil, @"当前没有采样在进行");
            return;
        }
        // timeline 可能很大，默认剔除（可选 includeTimeline=1 保留）
        BOOL includeTimeline = [cmd integerParam:@"includeTimeline" default:0] == 1;
        if (includeTimeline) {
            finish(YES, stats, nil);
        } else {
            NSMutableDictionary *slim = [stats mutableCopy];
            [slim removeObjectForKey:@"timeline"];
            finish(YES, slim, nil);
        }
    });

    simple(@"perf_sample", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        finish(YES, [IUAPerfSampler instantSample], nil);
    });

    // ---- 按键：回车/删除/退格/任意字符（不依赖系统键盘 UI 是否显示）----
    simple(@"press_key", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *key = [[cmd stringParam:@"key"] lowercaseString];
        NSString *identifier = [cmd stringParam:@"identifier"];
        // 目标输入框：显式 identifier，或当前 firstResponder
        UIResponder<UIKeyInput> *input = nil;
        if (identifier.length > 0) {
            UIView *view = [IUAViewIntrospector findViewWithIdentifier:identifier];
            if ([view isKindOfClass:[UIResponder class]] && [view conformsToProtocol:@protocol(UIKeyInput)]) {
                input = (UIResponder<UIKeyInput> *)view;
                [input becomeFirstResponder];
            }
        } else {
            UIResponder *first = IUACurrentFirstResponderForInput();
            if ([first conformsToProtocol:@protocol(UIKeyInput)]) {
                input = (UIResponder<UIKeyInput> *)first;
            }
        }
        if (!input) {
            finish(NO, nil, @"没有可接收按键的输入框（先用 输入 指令或点击输入框获得焦点，或传 identifier）");
            return;
        }

        if ([key isEqualToString:@"return"] || [key isEqualToString:@"enter"] || [key isEqualToString:@"回车"]) {
            // UITextField 的 didEndOnExit 链路：endEditing 触发 return 回调
            [input insertText:@"\n"];
            if ([input isKindOfClass:[UITextField class]]) {
                UITextField *field = (UITextField *)input;
                [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
            }
            finish(YES, @{@"key" : @"return"}, nil);
            return;
        }
        if ([key isEqualToString:@"delete"] || [key isEqualToString:@"backspace"] || [key isEqualToString:@"删除"] || [key isEqualToString:@"退格"]) {
            if ([input hasText]) {
                [input deleteBackward];
                finish(YES, @{@"key" : @"delete"}, nil);
            } else {
                finish(YES, @{@"key" : @"delete", @"note" : @"输入框已为空"}, nil);
            }
            return;
        }
        if (key.length > 0) {
            [input insertText:[cmd stringParam:@"key"]];   // 原始大小写插入首字符
            finish(YES, @{@"key" : key}, nil);
            return;
        }
        finish(NO, nil, @"press_key 需要 params.key（return/delete/回车/删除/任意字符）");
    });

    simple(@"dismiss_keyboard", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        UIWindow *window = [IUAViewIntrospector keyWindow];
        BOOL resigned = [window endEditing:YES];
        finish(YES, @{@"keyboardDismissed" : @(resigned)}, nil);
    });
}

#pragma mark - identifier 点击（自动滚动到可视区 + 重试）

/// 按 identifier 点击：元素不在可视区时先自动滚动到可见（沿祖先找 UIScrollView），
/// 再执行触控；触控失败自动重试（等待滚动惯性/键盘动画结束）。
- (void)tapIdentifier:(NSString *)identifier completion:(void (^)(BOOL, NSDictionary *, NSString *))finish {
    [self tapIdentifier:identifier tapCount:1 attempt:0 completion:finish];
}

- (void)tapIdentifier:(NSString *)identifier
               tapCount:(NSUInteger)tapCount
                attempt:(NSUInteger)attempt
             completion:(void (^)(BOOL, NSDictionary *, NSString *))finish {
    UIView *view = [IUAViewIntrospector findViewWithIdentifier:identifier];
    if (!view || view.hidden || view.alpha < 0.01) {
        // 系统键盘按键（identifier 形如 UIKeyboardLayout*）需要软件键盘真实显示才存在：
        // 模拟器的键盘渲染进程常驻占位（iOS 17+ 已知限制），此时给出专属指引
        if ([identifier hasPrefix:@"UIKeyboard"]) {
            finish(NO, nil, [NSString stringWithFormat:@"找不到 %@：系统键盘按键要求软件键盘真实显示（模拟器键盘进程常不渲染；真机可用）。若目的是输入内容，请改用 type_text（含 \n 回车）或 press_key 指令，二者均不依赖键盘 UI", identifier]);
            return;
        }
        finish(NO, nil, [NSString stringWithFormat:@"找不到可见的 view: identifier=%@", identifier]);
        return;
    }
    [self ensureViewVisible:view];

    UIWindow *window = view.window ?: [IUAViewIntrospector keyWindow];
    CGPoint point = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                toView:window];
    [[IUATouchSynthesizer shared] tapAtPoint:point tapCount:tapCount completion:^(NSError * _Nullable error) {
        if (!error) {
            finish(YES, @{@"x" : @(point.x), @"y" : @(point.y)}, nil);
            return;
        }
        // 冷启动/布局未完成时元素 frame 可能暂无效（全冷启动实测首启可达 5s+），
        // 最多重试 10 次（约 6s）
        if (attempt + 1 < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self tapIdentifier:identifier tapCount:tapCount attempt:attempt + 1 completion:finish];
            });
            return;
        }
        finish(NO, nil, error.localizedDescription);
    }];
}

/// 中心点不在可视 window 内（含状态栏上方）时，滚动最近的 UIScrollView 祖先使其可见
- (void)ensureViewVisible:(UIView *)view {
    UIWindow *window = view.window ?: [IUAViewIntrospector keyWindow];
    if (!window) {
        return;
    }
    CGPoint center = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                 toView:window];
    if (CGRectContainsPoint(window.bounds, center) && center.y >= 44 && center.y <= window.bounds.size.height - 20) {
        return; // 已在可视区（留出状态栏/底部 Home 指示条余量）
    }
    UIView *ancestor = view.superview;
    while (ancestor && ![ancestor isKindOfClass:[UIScrollView class]]) {
        ancestor = ancestor.superview;
    }
    if ([ancestor isKindOfClass:[UIScrollView class]]) {
        UIScrollView *scrollView = (UIScrollView *)ancestor;
        CGRect rectInView = [view convertRect:view.bounds toView:scrollView];
        [scrollView scrollRectToVisible:rectInView animated:NO];
        IUALogInfo(@"元素不在可视区，已滚动 UIScrollView 使其可见（中心 y=%.0f）", center.y);
    }
}

#pragma mark - 上行发送

- (void)send:(NSDictionary<NSString *, id> *)json {
    if (!self.client || !self.client.isConnected) {
        return;
    }
    [self.client sendJSON:json];
}

- (void)notifyConnectionState:(BOOL)connected {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:IUAEngineConnectionDidChangeNotification
                                                            object:self
                                                          userInfo:@{@"connected" : @(connected)}];
    });
}

#pragma mark - 日志转发（带重入保护，防止发送失败日志再次触发转发造成循环）

- (void)installLogForwarder {
    __weak typeof(self) weakSelf = self;
    IUASetLogForwarder(^(IUALogLevel level, NSString *message) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.logForwardingInProgress || level < IUALogLevelInfo) {
            return;
        }
        strongSelf.logForwardingInProgress = YES;
        [strongSelf send:@{@"type" : @"log",
                           @"level" : @((int)level),
                           @"message" : message,
                           @"timestamp" : @(round(NSDate.date.timeIntervalSince1970 * 1000))}];
        strongSelf.logForwardingInProgress = NO;
    });
}

@end
