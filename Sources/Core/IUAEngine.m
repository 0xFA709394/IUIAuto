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
#import "IUAElementQuery.h"
#import "IUAFloatingStatusBar.h"
#import "IUAConfigViewController.h"

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

#pragma mark - 设备 / 系统信息辅助

static UIWindowScene *IUAKeyWindowScene(void) {
    UIWindow *window = [IUAViewIntrospector keyWindow];
    if (window.windowScene) return window.windowScene;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

static NSString *IUAOrientationString(void) {
    UIInterfaceOrientation orientation = UIInterfaceOrientationUnknown;
    UIWindowScene *scene = IUAKeyWindowScene();
    if (scene) {
        orientation = scene.interfaceOrientation;
    }
    if (orientation == UIInterfaceOrientationUnknown) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        orientation = UIApplication.sharedApplication.statusBarOrientation;
#pragma clang diagnostic pop
    }
    switch (orientation) {
        case UIInterfaceOrientationLandscapeLeft:
        case UIInterfaceOrientationLandscapeRight:
            return @"LANDSCAPE";
        case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationPortraitUpsideDown:
            return @"PORTRAIT";
        default:
            return @"PORTRAIT";
    }
}

static NSString *IUASetOrientationString(NSString *requested) {
    NSString *upper = (requested ?: @"").uppercaseString;
    UIInterfaceOrientationMask mask = [upper containsString:@"LANDSCAPE"]
        ? UIInterfaceOrientationMaskLandscape
        : UIInterfaceOrientationMaskPortrait;
    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = IUAKeyWindowScene();
        if (scene) {
            UIWindowSceneGeometryPreferencesIOS *preferences =
                [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
            [scene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError * _Nonnull error) {
                IUALogWarn(@"旋转请求失败: %@", error.localizedDescription);
            }];
        }
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        @try {
            UIInterfaceOrientation orientation = (mask == UIInterfaceOrientationMaskLandscape)
                ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
            [UIDevice.currentDevice setValue:@(orientation) forKey:@"orientation"];
            [UIViewController attemptRotationToDeviceOrientation];
        } @catch (NSException *exception) {
            IUALogWarn(@"旋转失败: %@", exception.reason);
        }
#pragma clang diagnostic pop
    }
    return IUAOrientationString();
}

static BOOL IUAKeyboardShown(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            NSString *className = NSStringFromClass(window.class);
            if (([className containsString:@"Keyboard"] || [className containsString:@"TextEffects"]) &&
                !window.hidden && window.alpha > 0.01) {
                return YES;
            }
        }
    }
    // 没有键盘 window（模拟器/硬件键盘）时，有输入焦点仍视为逻辑键盘可见
    UIResponder *first = IUACurrentFirstResponderForInput();
    return [first conformsToProtocol:@protocol(UIKeyInput)];
}

static UIViewController *IUATopPresentedViewController(void) {
    UIWindow *window = [IUAViewIntrospector keyWindow];
    UIViewController *top = window.rootViewController;
    while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
        top = top.presentedViewController;
    }
    return top;
}

static UIView * _Nullable IUAFindViewWithText(UIView *root, NSString *text) {
    if (text.length == 0) return nil;
    if ([root isKindOfClass:[UILabel class]] && [((UILabel *)root).text isEqualToString:text]) return root;
    if ([root isKindOfClass:[UIButton class]] &&
        [[((UIButton *)root) titleForState:UIControlStateNormal] isEqualToString:text]) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = IUAFindViewWithText(subview, text);
        if (found) return found;
    }
    return nil;
}

static UITextField * _Nullable IUAFindTextField(UIView *root) {
    if ([root isKindOfClass:[UITextField class]]) return (UITextField *)root;
    for (UIView *subview in root.subviews) {
        UITextField *found = IUAFindTextField(subview);
        if (found) return found;
    }
    return nil;
}

static UIView * _Nullable IUAControlForAlertAction(UIAlertController *alert, UIAlertAction *action) {
    if (!alert || !action) return nil;
    UIView *label = IUAFindViewWithText(alert.view, action.title ?: @"");
    UIView *node = label;
    // iOS 新版本的 alert 按钮是 _UIAlertControllerActionView（普通 UIView，不是 UIControl），
    // 因此这里返回最近的可点击容器，最终由 tapView: 用 hitTest 校验并派发触控。
    UIView *fallback = label ? label.superview : nil;
    while (node && node != alert.view) {
        if ([node isKindOfClass:[UIControl class]]) return node;
        if ([NSStringFromClass(node.class) containsString:@"ActionView"]) return node;
        if ([NSStringFromClass(node.class) containsString:@"FilledBackgroundView"]) return node;
        node = node.superview;
    }
    if (fallback && fallback != alert.view) return fallback;

    // 兜底：部分系统版本的 action view 不暴露 UILabel，按 accessibilityLabel 查找
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:alert.view];
    while (queue.count > 0) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([current.accessibilityLabel isEqualToString:action.title ?: @""]) return current;
        [queue addObjectsFromArray:current.subviews];
    }
    return nil;
}

static NSString *IUAISO8601Now(void) {
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:[NSDate date]] ?: @"";
}

static NSDictionary<NSString *, id> *IUADeviceInfoJSON(void) {
    UIDevice *device = UIDevice.currentDevice;
    if (!device.isBatteryMonitoringEnabled) {
        device.batteryMonitoringEnabled = YES;
    }
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSDictionary *environment = [IUAViewIntrospector environmentJSON];
    UIWindow *window = [IUAViewIntrospector keyWindow];
    CGRect screenBounds = UIScreen.mainScreen.bounds;
    CGFloat statusBarHeight = 0;
    UIWindowScene *scene = IUAKeyWindowScene();
    if (@available(iOS 13.0, *)) {
        statusBarHeight = scene.statusBarManager.statusBarFrame.size.height;
    }
    UIEdgeInsets insets = window.safeAreaInsets;

    NSString *applicationStateText = @"unknown";
    switch (UIApplication.sharedApplication.applicationState) {
        case UIApplicationStateActive: applicationStateText = @"active"; break;
        case UIApplicationStateInactive: applicationStateText = @"inactive"; break;
        case UIApplicationStateBackground: applicationStateText = @"background"; break;
        default: break;
    }

    NSString *batteryState = @"unknown";
    switch (device.batteryState) {
        case UIDeviceBatteryStateUnplugged: batteryState = @"unplugged"; break;
        case UIDeviceBatteryStateCharging: batteryState = @"charging"; break;
        case UIDeviceBatteryStateFull: batteryState = @"full"; break;
        default: batteryState = @"unknown"; break;
    }

    return @{
        @"agent" : @"IUIAuto",
        @"version" : [IUAConfiguration agentVersion],
        @"name" : device.name ?: @"",
        @"model" : device.model ?: @"",
        @"deviceModel" : environment[@"deviceModel"] ?: @"unknown",
        @"systemName" : device.systemName ?: @"iOS",
        @"systemVersion" : device.systemVersion ?: @"",
        @"idiom" : @(device.userInterfaceIdiom),
        @"bundleId" : info[@"CFBundleIdentifier"] ?: (NSBundle.mainBundle.bundleIdentifier ?: @""),
        @"appName" : info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"",
        @"appVersion" : info[@"CFBundleShortVersionString"] ?: @"",
        @"build" : info[@"CFBundleVersion"] ?: @"",
        @"locale" : NSLocale.currentLocale.localeIdentifier ?: @"",
        @"language" : NSLocale.preferredLanguages.firstObject ?: @"",
        @"timeZone" : NSTimeZone.localTimeZone.name ?: @"",
        @"time" : IUAISO8601Now(),
        @"timestamp" : @(round(NSDate.date.timeIntervalSince1970 * 1000)),
        @"orientation" : IUAOrientationString(),
        @"screen" : @{@"width" : @(screenBounds.size.width),
                      @"height" : @(screenBounds.size.height),
                      @"scale" : @(UIScreen.mainScreen.scale)},
        @"windowSize" : @{@"width" : @(window.bounds.size.width),
                          @"height" : @(window.bounds.size.height)},
        @"statusBarHeight" : @(statusBarHeight),
        @"safeAreaInsets" : @{@"top" : @(insets.top),
                              @"left" : @(insets.left),
                              @"bottom" : @(insets.bottom),
                              @"right" : @(insets.right)},
        @"batteryLevel" : @(device.batteryLevel),
        @"batteryState" : batteryState,
        @"applicationState" : @(UIApplication.sharedApplication.applicationState),
        @"applicationStateText" : applicationStateText,
        @"keyboardShown" : @(IUAKeyboardShown()),
    };
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

/// 从指令 params 解析元素定位参数（支持 xpath/identifier 简写；index 可负=倒数）
static BOOL IUAResolveLocatorParams(NSDictionary<NSString *, id> *params,
                                    NSString **outUsing,
                                    NSString **outValue,
                                    NSInteger *outIndex) {
    NSString *using = [params[@"using"] isKindOfClass:[NSString class]] ? params[@"using"] : nil;
    NSString *value = [params[@"value"] isKindOfClass:[NSString class]] ? params[@"value"] : nil;
    NSString *xpath = [params[@"xpath"] isKindOfClass:[NSString class]] ? params[@"xpath"] : nil;
    NSString *identifier = [params[@"identifier"] isKindOfClass:[NSString class]] ? params[@"identifier"] : nil;

    if (xpath.length > 0) {
        using = @"xpath";
        value = xpath;
    } else if (using.length == 0 && value.length == 0 && identifier.length > 0) {
        using = @"accessibility id";
        value = identifier;
    }
    if (using.length == 0 && value.length == 0) {
        return NO;
    }
    if (using.length == 0) using = @"accessibility id";
    if (value == nil) value = @"";

    NSInteger index = 0;
    id indexValue = params[@"index"];
    if ([indexValue isKindOfClass:[NSNumber class]]) index = [indexValue integerValue];
    else if ([indexValue isKindOfClass:[NSString class]]) index = [indexValue integerValue];

    if (outUsing) *outUsing = using;
    if (outValue) *outValue = value;
    if (outIndex) *outIndex = index;
    return YES;
}

static BOOL IUAValidateLocator(NSString *using, NSString *value, NSString * __autoreleasing *error) {
    __autoreleasing NSString *validationError = nil;
    BOOL valid = [IUAElementQuery validateUsing:using value:value error:&validationError];
    if (!valid && error) *error = validationError;
    return valid;
}

@interface IUAEngine () <IUAWebSocketClientDelegate>
@property (nonatomic, strong, nullable) IUAWebSocketClient *client;
@property (nonatomic, strong) IUACommandDispatcher *dispatcher;
@property (nonatomic, assign) BOOL logForwardingInProgress; // 重入保护
- (void)tapView:(UIView *)view
    displayName:(NSString *)displayName
       tapCount:(NSUInteger)tapCount
        attempt:(NSUInteger)attempt
       resolver:(nullable UIView *(^)(void))resolver
     completion:(void (^)(BOOL, NSDictionary *, NSString *))finish;
- (void)longPressView:(UIView *)view
          displayName:(NSString *)displayName
             duration:(NSTimeInterval)duration
              attempt:(NSUInteger)attempt
             resolver:(nullable UIView *(^)(void))resolver
           completion:(void (^)(BOOL, NSDictionary *, NSString *))finish;
- (void)waitForElementUsing:(NSString *)using
                      value:(NSString *)value
                      index:(NSInteger)index
                disappearing:(BOOL)disappearing
                    deadline:(NSDate *)deadline
                      waited:(NSTimeInterval)waited
                    interval:(NSTimeInterval)interval
                  completion:(void (^)(BOOL, NSDictionary *, NSString *))finish;
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
    NSString *candidate = urlString.length > 0
        ? [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : [IUAConfiguration serverURLString];
    if (![IUAConfiguration isValidServerURLString:candidate]) {
        // 关键：校验失败时不要保存、也不要断开旧连接，避免一次输入错误让 Agent 彻底失联
        IUALogError(@"服务器地址无效（需要 ws:// 或 wss:// 绝对地址）: %@", candidate ?: @"");
        return;
    }
    if (urlString.length > 0) {
        [IUAConfiguration setServerURLString:candidate];
    }
    [self stop];

    NSURL *url = [IUAConfiguration serverURL];
    if (!url) {
        IUALogError(@"服务器地址无效: %@", candidate);
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
            [[IUAFloatingStatusBar sharedBar] yieldForInteraction];   // 防悬浮条遮挡
            // 遮挡校验（与 tapIdentifier 同款，防止点击落在遮挡层却报成功）
            UIWindow *window = view.window ?: [IUAViewIntrospector keyWindow];
            UIView *hit = [window hitTest:point withEvent:nil];
            BOOL hitIsTargetOrChild = NO;
            for (UIView *probe = hit; probe; probe = probe.superview) {
                if (probe == view) { hitIsTargetOrChild = YES; break; }
            }
            if (!hitIsTargetOrChild) {
                finish(NO, nil, [NSString stringWithFormat:@"目标 %@ 被遮挡（命中 %@），请先关闭覆盖层（如配置页/弹窗）",
                                 identifier, NSStringFromClass(hit.class)]);
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
        // 方向语义：direction=up/down/left/right + distance(pt，默认300) + 可选 originIdentifier（起手元素）
        NSString *direction = [cmd stringParam:@"direction"];
        if (direction.length > 0) {
            UIWindow *window = [IUAViewIntrospector keyWindow];
            if (!window) {
                finish(NO, nil, @"swipe: 没有 keyWindow");
                return;
            }
            CGFloat distance = [cmd floatParam:@"distance" default:300];
            CGPoint origin = CGPointMake(window.bounds.size.width / 2, window.bounds.size.height / 2);
            NSString *originId = [cmd stringParam:@"originIdentifier"];
            if (originId.length > 0) {
                UIView *view = [IUAViewIntrospector findViewWithIdentifier:originId];
                if (!view) {
                    finish(NO, nil, [NSString stringWithFormat:@"swipe: 起点元素不存在: %@", originId]);
                    return;
                }
                origin = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                     toView:window];
            }
            CGPoint target = origin;
            NSString *d = direction.lowercaseString;
            if ([d isEqualToString:@"up"] || [d isEqualToString:@"上"]) {
                target.y = origin.y - distance;
            } else if ([d isEqualToString:@"down"] || [d isEqualToString:@"下"]) {
                target.y = origin.y + distance;
            } else if ([d isEqualToString:@"left"] || [d isEqualToString:@"左"]) {
                target.x = origin.x - distance;
            } else if ([d isEqualToString:@"right"] || [d isEqualToString:@"右"]) {
                target.x = origin.x + distance;
            } else {
                finish(NO, nil, @"swipe: direction 须为 up/down/left/right");
                return;
            }
            [[IUATouchSynthesizer shared] swipeFromPoint:origin toPoint:target
                                                duration:[cmd floatParam:@"duration" default:0.4]
                                              completion:^(NSError * _Nullable error) {
                error ? finish(NO, nil, error.localizedDescription)
                      : finish(YES, @{@"direction" : d, @"distance" : @(distance)}, nil);
            }];
            return;
        }
        CGPoint from = CGPointZero, to = CGPointZero;
        BOOL okFrom = IUALoadPoint(cmd.params, @"from", @"fromX", @"fromY", &from);
        BOOL okTo = IUALoadPoint(cmd.params, @"to", @"toX", @"toY", &to);
        if (!okFrom || !okTo) {
            finish(NO, nil, @"swipe 需要 params.fromX/fromY/toX/toY（或 direction=up/down/left/right）");
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

    // ---- Appium 风格元素模型：定位策略 / 元素句柄 / 页面源码 / 元素级动作 ----
    simple(@"find_elements", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *using = nil, *value = nil;
        NSInteger index = 0;
        if (!IUAResolveLocatorParams(cmd.params, &using, &value, &index)) {
            finish(NO, nil, @"find_elements 需要 params.using + params.value（或 params.xpath/identifier）");
            return;
        }
        NSString *locatorError = nil;
        if (!IUAValidateLocator(using, value, &locatorError)) {
            finish(NO, nil, locatorError);
            return;
        }
        NSArray<UIView *> *views = [IUAElementQuery findViewsUsing:using value:value];
        NSInteger start = index < 0 ? MAX((NSInteger)views.count + index, 0) : index;
        NSInteger limit = MAX([cmd integerParam:@"limit" default:100], 0);
        finish(YES, [IUAElementQuery elementsJSONForViews:views start:start limit:limit using:using value:value], nil);
    });

    simple(@"find_element", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *using = nil, *value = nil;
        NSInteger index = 0;
        if (!IUAResolveLocatorParams(cmd.params, &using, &value, &index)) {
            finish(NO, nil, @"find_element 需要 params.using + params.value（或 params.xpath/identifier）");
            return;
        }
        NSString *locatorError = nil;
        if (!IUAValidateLocator(using, value, &locatorError)) {
            finish(NO, nil, locatorError);
            return;
        }
        UIView *view = [IUAElementQuery findViewUsing:using value:value index:index];
        if (!view) {
            finish(NO, @{@"using" : using, @"value" : value, @"index" : @(index)},
                   [NSString stringWithFormat:@"no such element: %@=%@", using, value]);
            return;
        }
        NSMutableDictionary *info = [[IUAElementQuery attributesForView:view] mutableCopy];
        info[@"using"] = using;
        info[@"locatorValue"] = value;
        info[@"locatorIndex"] = @(index);
        finish(YES, info, nil);
    });

    simple(@"element_action", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *using = nil, *value = nil;
        NSInteger index = 0;
        if (!IUAResolveLocatorParams(cmd.params, &using, &value, &index)) {
            finish(NO, nil, @"element_action 需要元素定位参数（using/value 或 xpath/identifier）");
            return;
        }
        NSString *locatorError = nil;
        if (!IUAValidateLocator(using, value, &locatorError)) {
            finish(NO, nil, locatorError);
            return;
        }
        UIView *view = [IUAElementQuery findViewUsing:using value:value index:index];
        if (!view) {
            finish(NO, @{@"using" : using, @"value" : value, @"index" : @(index)},
                   [NSString stringWithFormat:@"no such element: %@=%@", using, value]);
            return;
        }
        NSString *displayName = [NSString stringWithFormat:@"%@=%@[%ld]", using, value, (long)index];
        NSString *action = [[cmd stringParam:@"action"] lowercaseString] ?: @"click";
        NSDictionary<NSString *, id> *attrs = [IUAElementQuery attributesForView:view];

        if ([action isEqualToString:@"click"] || [action isEqualToString:@"tap"]) {
            UIView *(^resolver)(void) = ^UIView *{
                return [IUAElementQuery findViewUsing:using value:value index:index];
            };
            [self tapView:view displayName:displayName tapCount:1 attempt:0 resolver:resolver completion:^(BOOL ok, NSDictionary *data, NSString *error) {
                NSMutableDictionary *out = [data mutableCopy] ?: [NSMutableDictionary dictionary];
                out[@"element"] = attrs;
                finish(ok, out, error);
            }];
            return;
        }
        if ([action isEqualToString:@"double_click"] || [action isEqualToString:@"double_tap"] ||
            [action isEqualToString:@"doubleclick"]) {
            UIView *(^resolver)(void) = ^UIView *{
                return [IUAElementQuery findViewUsing:using value:value index:index];
            };
            [self tapView:view displayName:displayName tapCount:2 attempt:0 resolver:resolver completion:^(BOOL ok, NSDictionary *data, NSString *error) {
                NSMutableDictionary *out = [data mutableCopy] ?: [NSMutableDictionary dictionary];
                out[@"element"] = attrs;
                out[@"doubleTapped"] = @(ok);
                finish(ok, out, error);
            }];
            return;
        }
        if ([action isEqualToString:@"long_click"] || [action isEqualToString:@"long_press"] ||
            [action isEqualToString:@"longclick"] || [action isEqualToString:@"touch_and_hold"]) {
            double duration = [cmd floatParam:@"duration" default:0.8];
            UIView *(^resolver)(void) = ^UIView *{
                return [IUAElementQuery findViewUsing:using value:value index:index];
            };
            [self longPressView:view displayName:displayName duration:duration attempt:0
                       resolver:resolver completion:^(BOOL ok, NSDictionary *data, NSString *error) {
                NSMutableDictionary *out = [data mutableCopy] ?: [NSMutableDictionary dictionary];
                out[@"element"] = attrs;
                finish(ok, out, error);
            }];
            return;
        }
        if ([action isEqualToString:@"send_keys"] || [action isEqualToString:@"type"] ||
            [action isEqualToString:@"set_text"] || [action isEqualToString:@"set_value"]) {
            NSString *text = [cmd stringParam:@"text"];
            if (text.length == 0) {
                finish(NO, nil, @"send_keys 需要 params.text");
                return;
            }
            IUATextSynthesizer *synthesizer = [[IUATextSynthesizer alloc] init];
            void (^typeBlock)(void) = ^{
                [synthesizer typeText:text intoView:view completion:^(NSError * _Nullable error) {
                    error ? finish(NO, nil, error.localizedDescription)
                          : finish(YES, @{@"typed" : @(text.length), @"text" : text, @"element" : attrs}, nil);
                }];
            };
            if ([action isEqualToString:@"set_text"] || [action isEqualToString:@"set_value"]) {
                [synthesizer clearTextInView:view completion:^(NSError * _Nullable error) {
                    if (error) { finish(NO, nil, error.localizedDescription); return; }
                    typeBlock();
                }];
            } else {
                typeBlock();
            }
            return;
        }
        if ([action isEqualToString:@"clear"] || [action isEqualToString:@"clear_text"]) {
            IUATextSynthesizer *synthesizer = [[IUATextSynthesizer alloc] init];
            [synthesizer clearTextInView:view completion:^(NSError * _Nullable error) {
                error ? finish(NO, nil, error.localizedDescription)
                      : finish(YES, @{@"cleared" : @YES, @"element" : attrs}, nil);
            }];
            return;
        }
        if ([action isEqualToString:@"get_text"]) {
            finish(YES, @{@"text" : attrs[@"text"] ?: @"", @"value" : attrs[@"value"] ?: @"", @"element" : attrs}, nil);
            return;
        }
        if ([action isEqualToString:@"get_attribute"]) {
            NSString *attribute = [cmd stringParam:@"attribute"];
            if (attribute.length == 0) {
                finish(NO, nil, @"get_attribute 需要 params.attribute");
                return;
            }
            id result = [IUAElementQuery attributeForView:view name:attribute];
            if (result == nil) {
                finish(NO, nil, [NSString stringWithFormat:@"unknown attribute: %@", attribute]);
                return;
            }
            finish(YES, @{@"attribute" : attribute, @"value" : result}, nil);
            return;
        }
        if ([action isEqualToString:@"get_rect"]) {
            finish(YES, attrs[@"rect"], nil);
            return;
        }
        if ([action isEqualToString:@"get_attributes"]) {
            finish(YES, attrs, nil);
            return;
        }
        if ([action isEqualToString:@"is_displayed"] || [action isEqualToString:@"displayed"]) {
            finish(YES, @{@"displayed" : attrs[@"visible"]}, nil);
            return;
        }
        if ([action isEqualToString:@"is_enabled"] || [action isEqualToString:@"enabled"]) {
            finish(YES, @{@"enabled" : attrs[@"enabled"]}, nil);
            return;
        }
        if ([action isEqualToString:@"is_selected"] || [action isEqualToString:@"selected"]) {
            finish(YES, @{@"selected" : attrs[@"selected"]}, nil);
            return;
        }
        if ([action isEqualToString:@"is_focused"] || [action isEqualToString:@"focused"]) {
            finish(YES, @{@"focused" : attrs[@"focused"]}, nil);
            return;
        }
        if ([action isEqualToString:@"scroll_to"] || [action isEqualToString:@"scroll_to_visible"]) {
            [self ensureViewVisible:view];
            finish(YES, @{@"scrolledTo" : displayName, @"element" : attrs}, nil);
            return;
        }
        if ([action isEqualToString:@"scroll_to_top"] || [action isEqualToString:@"scroll_to_bottom"]) {
            UIScrollView *scrollView = [view isKindOfClass:[UIScrollView class]] ? (UIScrollView *)view : nil;
            UIView *node = view;
            while (!scrollView && node) {
                if ([node isKindOfClass:[UIScrollView class]]) { scrollView = (UIScrollView *)node; break; }
                node = node.superview;
            }
            if (!scrollView) {
                finish(NO, nil, [NSString stringWithFormat:@"%@ 不在 UIScrollView 内", displayName]);
                return;
            }
            CGFloat top = -scrollView.adjustedContentInset.top;
            CGFloat bottom = MAX(top, scrollView.contentSize.height - scrollView.bounds.size.height + scrollView.adjustedContentInset.bottom);
            CGFloat targetY = [action isEqualToString:@"scroll_to_top"] ? top : bottom;
            [scrollView setContentOffset:CGPointMake(scrollView.contentOffset.x, targetY) animated:NO];
            finish(YES, @{@"offsetY" : @(targetY), @"contentHeight" : @(scrollView.contentSize.height)}, nil);
            return;
        }
        if ([action isEqualToString:@"screenshot"]) {
            NSUInteger quality = (NSUInteger)[cmd integerParam:@"quality" default:1];
            NSDictionary *shot = [IUAScreenshotService screenshotOfView:view quality:quality];
            shot ? finish(YES, shot, nil) : finish(NO, nil, @"元素截图失败");
            return;
        }
        finish(NO, nil, [NSString stringWithFormat:@"unknown element action: %@", action]);
    });

    simple(@"page_source", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSInteger maxDepth = [cmd integerParam:@"maxDepth" default:0];
        NSString *source = [IUAElementQuery pageSourceXMLWithMaxDepth:maxDepth];
        finish(YES, @{@"source" : source, @"format" : @"xml", @"length" : @(source.length)}, nil);
    });

    simple(@"active_element", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        UIView *active = [IUAElementQuery activeElement];
        if (!active) {
            finish(YES, @{@"found" : @NO}, nil);
            return;
        }
        NSMutableDictionary *info = [[IUAElementQuery attributesForView:active] mutableCopy];
        info[@"found"] = @YES;
        finish(YES, info, nil);
    });

    simple(@"element_screenshot", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *using = nil, *value = nil;
        NSInteger index = 0;
        if (!IUAResolveLocatorParams(cmd.params, &using, &value, &index)) {
            finish(NO, nil, @"element_screenshot 需要元素定位参数");
            return;
        }
        NSString *locatorError = nil;
        if (!IUAValidateLocator(using, value, &locatorError)) {
            finish(NO, nil, locatorError);
            return;
        }
        UIView *view = [IUAElementQuery findViewUsing:using value:value index:index];
        if (!view) {
            finish(NO, nil, [NSString stringWithFormat:@"no such element: %@=%@", using, value]);
            return;
        }
        NSUInteger quality = (NSUInteger)[cmd integerParam:@"quality" default:1];
        NSDictionary *shot = [IUAScreenshotService screenshotOfView:view quality:quality];
        shot ? finish(YES, shot, nil) : finish(NO, nil, @"元素截图失败");
    });

    simple(@"wait_for_element", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *using = nil, *value = nil;
        NSInteger index = 0;
        if (!IUAResolveLocatorParams(cmd.params, &using, &value, &index)) {
            finish(NO, nil, @"wait_for_element 需要元素定位参数");
            return;
        }
        NSString *locatorError = nil;
        if (!IUAValidateLocator(using, value, &locatorError)) {
            finish(NO, nil, locatorError);
            return;
        }
        BOOL disappearing = [[cmd stringParam:@"state"] isEqualToString:@"disappear"];
        double timeout = MIN(MAX([cmd floatParam:@"timeout" default:10], 0.5), 60);
        [self waitForElementUsing:using
                            value:value
                            index:index
                      disappearing:disappearing
                          deadline:[NSDate dateWithTimeIntervalSinceNow:timeout]
                            waited:0
                          interval:0.3
                        completion:finish];
    });

    // ---- 视觉回归：与基线图逐像素对比 ----
    simple(@"screenshot_compare", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *baseline = [cmd stringParam:@"baseline"];
        if (baseline.length == 0) {
            finish(NO, nil, @"screenshot_compare 需要 params.baseline（基线 PNG 的 base64）");
            return;
        }
        CGFloat threshold = [cmd floatParam:@"thresholdPercent" default:1.0];
        NSDictionary *result = [IUAScreenshotService compareWithBaselineBase64:baseline thresholdPercent:threshold];
        if (!result) {
            finish(NO, nil, @"对比失败（截图或基线解码失败）");
            return;
        }
        if ([result[@"sizeMismatch"] boolValue]) {
            finish(NO, result, @"当前截图与基线尺寸不一致（需重新生成基线）");
            return;
        }
        BOOL pass = [result[@"pass"] boolValue];
        finish(pass, result, pass ? nil : [NSString stringWithFormat:@"视觉差异 %.3f%% 超过阈值 %.2f%%",
                                           [result[@"diffPercent"] doubleValue], threshold]);
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

    // ---- 等待元素出现/消失（页面流转测试刚需；轮询不阻塞主线程）----
    simple(@"wait_for", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *identifier = [cmd stringParam:@"identifier"];
        if (identifier.length == 0) {
            finish(NO, nil, @"wait_for 需要 params.identifier");
            return;
        }
        BOOL waitForDisappear = [[cmd stringParam:@"state"] isEqualToString:@"disappear"];
        double timeout = MIN(MAX([cmd floatParam:@"timeout" default:10], 0.5), 60);
        [self waitForIdentifier:identifier
                    disappearing:waitForDisappear
                        deadline:[NSDate dateWithTimeIntervalSinceNow:timeout]
                          waited:0
                        interval:0.3
                       completion:finish];
    });

    // ---- 滚动到指定元素可见（显式导航；tap 已内置自动滚动，此指令用于主动定位）----
    simple(@"scroll_to", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *identifier = [cmd stringParam:@"identifier"];
        UIView *view = identifier.length > 0 ? [IUAViewIntrospector findViewWithIdentifier:identifier] : nil;
        if (!view) {
            finish(NO, nil, [NSString stringWithFormat:@"scroll_to: 找不到 view: identifier=%@", identifier]);
            return;
        }
        [self ensureViewVisible:view];
        finish(YES, @{@"scrolledTo" : identifier}, nil);
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
            // 「按键」语义 = 一次一键：只插入首个完整字符簇（emoji 等多字节组合不被截断）
            NSString *raw = [cmd stringParam:@"key"];
            NSRange first = [raw rangeOfComposedCharacterSequencesForRange:NSMakeRange(0, 0)];
            if (first.length == 0) {
                first = NSMakeRange(0, 1);
            }
            [input insertText:[raw substringWithRange:first]];
            finish(YES, @{@"key" : key, @"inserted" : [raw substringWithRange:first]}, nil);
            return;
        }
        finish(NO, nil, @"press_key 需要 params.key（return/delete/回车/删除/任意字符）");
    });

    simple(@"dismiss_keyboard", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        UIWindow *window = [IUAViewIntrospector keyWindow];
        BOOL resigned = [window endEditing:YES];
        finish(YES, @{@"keyboardDismissed" : @(resigned)}, nil);
    });

    // ---- 设备 / 系统能力（Appium 桥接常用端点）----
    simple(@"device_info", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        finish(YES, IUADeviceInfoJSON(), nil);
    });

    simple(@"orientation", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *requested = [cmd stringParam:@"orientation"];
        if (requested.length == 0) {
            finish(YES, @{@"orientation" : IUAOrientationString(),
                          @"requested" : IUAOrientationString()}, nil);
            return;
        }
        NSString *before = IUAOrientationString();
        IUASetOrientationString(requested);
        // requestGeometryUpdate 是异步的，稍等一帧再读实际方向
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            NSString *after = IUAOrientationString();
            finish(YES, @{@"orientation" : after,
                          @"requested" : requested,
                          @"changed" : @(![after isEqualToString:before])}, nil);
        });
    });

    simple(@"keyboard_state", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        finish(YES, @{@"shown" : @(IUAKeyboardShown())}, nil);
    });

    simple(@"clipboard_get", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *text = UIPasteboard.generalPasteboard.string ?: @"";
        finish(YES, @{@"text" : text}, nil);
    });

    simple(@"clipboard_set", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *text = [cmd stringParam:@"text"];
        if (text == nil) {
            finish(NO, nil, @"clipboard_set 需要 params.text");
            return;
        }
        UIPasteboard.generalPasteboard.string = text;
        finish(YES, @{@"text" : text}, nil);
    });

    simple(@"alert", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        UIViewController *top = IUATopPresentedViewController();
        UIAlertController *alert = [top isKindOfClass:[UIAlertController class]] ? (UIAlertController *)top : nil;
        if (!alert) {
            finish(NO, nil, @"no such alert");
            return;
        }
        NSString *action = [[cmd stringParam:@"action"] lowercaseString] ?: @"get";
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (UIAlertAction *item in alert.actions) {
            [titles addObject:item.title ?: @""];
        }
        NSMutableDictionary *base = [@{@"title" : alert.title ?: @"",
                                       @"message" : alert.message ?: @"",
                                       @"text" : alert.message ?: alert.title ?: @"",
                                       @"buttons" : titles} mutableCopy];

        if ([action isEqualToString:@"get"] || [action isEqualToString:@"buttons"] ||
            [action isEqualToString:@"text"]) {
            finish(YES, base, nil);
            return;
        }
        if ([action isEqualToString:@"set_text"]) {
            UITextField *field = IUAFindTextField(alert.view);
            if (!field) {
                finish(NO, nil, @"当前 alert 没有文本输入框");
                return;
            }
            NSString *text = [cmd stringParam:@"text"] ?: @"";
            IUATextSynthesizer *synthesizer = [[IUATextSynthesizer alloc] init];
            [synthesizer clearTextInView:field completion:^(NSError * _Nullable error) {
                if (error) { finish(NO, nil, error.localizedDescription); return; }
                if (text.length == 0) {
                    base[@"setText"] = @"";
                    finish(YES, base, nil);
                    return;
                }
                [synthesizer typeText:text intoView:field completion:^(NSError * _Nullable error2) {
                    if (error2) { finish(NO, nil, error2.localizedDescription); return; }
                    base[@"setText"] = text;
                    finish(YES, base, nil);
                }];
            }];
            return;
        }
        if (![action isEqualToString:@"accept"] && ![action isEqualToString:@"dismiss"]) {
            finish(NO, nil, [NSString stringWithFormat:@"unknown alert action: %@", action]);
            return;
        }

        UIAlertAction *target = nil;
        if ([action isEqualToString:@"accept"]) {
            for (UIAlertAction *item in alert.actions) {
                if (item.style == UIAlertActionStyleDefault) { target = item; break; }
            }
            if (!target) target = alert.actions.firstObject;
        } else {
            for (UIAlertAction *item in alert.actions) {
                if (item.style == UIAlertActionStyleCancel) { target = item; break; }
            }
            if (!target) {
                target = alert.actions.count > 1 ? alert.actions.lastObject : alert.actions.firstObject;
            }
        }
        if (!target) {
            finish(NO, nil, @"alert 没有可点击的按钮");
            return;
        }
        UIView *control = IUAControlForAlertAction(alert, target);
        if (!control) {
            finish(NO, nil, [NSString stringWithFormat:@"无法定位 alert 按钮: %@", target.title ?: @""]);
            return;
        }
        NSString *buttonTitle = target.title ?: @"";
        [self tapView:control displayName:[NSString stringWithFormat:@"alert[%@]", buttonTitle]
             tapCount:1 attempt:0 resolver:nil completion:^(BOOL ok, NSDictionary *data, NSString *error) {
            if (!ok) { finish(NO, nil, error); return; }
            base[@"clickedButton"] = buttonTitle;
            // 等 alert 关闭动画/action handler 执行完，避免脚本紧接着断言时读到旧值
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                finish(YES, base, nil);
            });
        }];
    });

    simple(@"open_url", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        NSString *urlString = [cmd stringParam:@"url"] ?: [cmd stringParam:@"text"];
        NSURL *url = urlString.length > 0 ? [NSURL URLWithString:urlString] : nil;
        if (!url) {
            finish(NO, nil, @"open_url 需要合法的 params.url");
            return;
        }
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
            // 调度器要求完成回调在主线程；openURL 的 completion 队列没有强保证
            dispatch_async(dispatch_get_main_queue(), ^{
                finish(success, @{@"url" : url.absoluteString ?: @""},
                       success ? nil : @"openURL 被系统拒绝");
            });
        }];
    });

    simple(@"shake", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        UIWindow *window = [IUAViewIntrospector keyWindow];
        UIViewController *top = IUATopPresentedViewController();
        if (window) {
            [window motionEnded:UIEventSubtypeMotionShake withEvent:nil];
        }
        if (top) {
            [top motionEnded:UIEventSubtypeMotionShake withEvent:nil];
        }
        finish(YES, @{@"shaken" : @YES}, nil);
    });

    simple(@"app_state", ^(IUACommand *cmd, void (^finish)(BOOL, NSDictionary *, NSString *)) {
        UIApplicationState state = UIApplication.sharedApplication.applicationState;
        NSInteger appiumState = state == UIApplicationStateBackground ? 3 : 4;
        NSString *text = state == UIApplicationStateActive ? @"active"
                        : state == UIApplicationStateInactive ? @"inactive" : @"background";
        finish(YES, @{@"state" : @(appiumState), @"stateText" : text,
                      @"bundleId" : NSBundle.mainBundle.bundleIdentifier ?: @""}, nil);
    });
}

#pragma mark - 元素点击（自动滚动到可视区 + 重试）

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
    __weak typeof(self) weakSelf = self;
    UIView *(^resolver)(void) = ^UIView *{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        return strongSelf ? [IUAViewIntrospector findViewWithIdentifier:identifier] : nil;
    };
    [self tapView:view displayName:identifier tapCount:tapCount attempt:attempt
         resolver:resolver completion:finish];
}

/// 通用元素点击：元素级定位（xpath/class chain/predicate…）与 identifier 共用。
/// 自动滚动到可视区、遮挡校验、触控失败重试。
- (void)tapView:(UIView *)view
    displayName:(NSString *)displayName
       tapCount:(NSUInteger)tapCount
        attempt:(NSUInteger)attempt
       resolver:(nullable UIView *(^)(void))resolver
     completion:(void (^)(BOOL, NSDictionary *, NSString *))finish {
    if (attempt == 0) {
        // 悬浮条避让：防止它遮挡点击目标（顶部区域元素）
        [[IUAFloatingStatusBar sharedBar] yieldForInteraction];
    }
    if (view && [view.accessibilityIdentifier isEqualToString:@"bar.floating"] && view.alpha < 0.01) {
        // 悬浮条可能刚被上一条指令 yieldForInteraction 淡出；自动化再次点击它时强制恢复
        [[IUAFloatingStatusBar sharedBar] revealForAutomation];
    }
    if (!view || !view.window || view.hidden || view.alpha < 0.01) {
        NSString *reason = !view ? @"view=nil"
            : !view.window ? @"window=nil"
            : view.hidden ? @"hidden"
            : [NSString stringWithFormat:@"alpha=%.2f", view.alpha];
        finish(NO, nil, [NSString stringWithFormat:@"找不到可见的 view: %@ (%@)", displayName, reason]);
        return;
    }
    [self ensureViewVisible:view];

    UIWindow *window = view.window ?: [IUAViewIntrospector keyWindow];
    CGPoint point = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                toView:window];
    // 遮挡校验：hitTest 命中的必须是目标自身或其子视图（否则点击会落在遮挡层上
    // 却仍报成功——静默点错，比失败更危险）。
    // 滚动/转场动画进行中会瞬时遮挡 → 纳入重试；重试耗尽仍遮挡才报错
    UIView *hit = [window hitTest:point withEvent:nil];
    BOOL hitIsTargetOrChild = NO;
    for (UIView *probe = hit; probe; probe = probe.superview) {
        if (probe == view) { hitIsTargetOrChild = YES; break; }
    }
    if (!hitIsTargetOrChild) {
        if (attempt + 1 < 10) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *nextView = resolver ? resolver() : view;
                if (!nextView) {
                    finish(NO, nil, [NSString stringWithFormat:@"重试时找不到元素: %@", displayName]);
                    return;
                }
                [self tapView:nextView displayName:displayName tapCount:tapCount attempt:attempt + 1
                     resolver:resolver completion:finish];
            });
            return;
        }
        finish(NO, nil, [NSString stringWithFormat:@"目标 %@ 被遮挡（命中 %@），请先关闭覆盖层（如配置页/弹窗）",
                         displayName, NSStringFromClass(hit.class)]);
        return;
    }
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
                UIView *nextView = resolver ? resolver() : view;
                if (!nextView) {
                    finish(NO, nil, [NSString stringWithFormat:@"重试时找不到元素: %@", displayName]);
                    return;
                }
                [self tapView:nextView displayName:displayName tapCount:tapCount attempt:attempt + 1
                     resolver:resolver completion:finish];
            });
            return;
        }
        finish(NO, nil, error.localizedDescription);
    }];
}

/// 通用元素长按（元素级定位使用）。遮挡场景做一次 0.4s 重试。
- (void)longPressView:(UIView *)view
          displayName:(NSString *)displayName
             duration:(NSTimeInterval)duration
              attempt:(NSUInteger)attempt
             resolver:(nullable UIView *(^)(void))resolver
           completion:(void (^)(BOOL, NSDictionary *, NSString *))finish {
    if (attempt == 0) {
        [[IUAFloatingStatusBar sharedBar] yieldForInteraction];
    }
    if (view && [view.accessibilityIdentifier isEqualToString:@"bar.floating"] && view.alpha < 0.01) {
        // 悬浮条可能刚被上一条指令 yieldForInteraction 淡出；自动化再次点击它时强制恢复
        [[IUAFloatingStatusBar sharedBar] revealForAutomation];
    }
    if (!view || !view.window || view.hidden || view.alpha < 0.01) {
        NSString *reason = !view ? @"view=nil"
            : !view.window ? @"window=nil"
            : view.hidden ? @"hidden"
            : [NSString stringWithFormat:@"alpha=%.2f", view.alpha];
        finish(NO, nil, [NSString stringWithFormat:@"找不到可见的 view: %@ (%@)", displayName, reason]);
        return;
    }
    [self ensureViewVisible:view];
    UIWindow *window = view.window ?: [IUAViewIntrospector keyWindow];
    CGPoint point = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds))
                                toView:window];
    UIView *hit = [window hitTest:point withEvent:nil];
    BOOL hitIsTargetOrChild = NO;
    for (UIView *probe = hit; probe; probe = probe.superview) {
        if (probe == view) { hitIsTargetOrChild = YES; break; }
    }
    if (!hitIsTargetOrChild) {
        if (attempt + 1 < 5) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                UIView *nextView = resolver ? resolver() : view;
                if (!nextView) {
                    finish(NO, nil, [NSString stringWithFormat:@"重试时找不到元素: %@", displayName]);
                    return;
                }
                [self longPressView:nextView displayName:displayName duration:duration
                           attempt:attempt + 1 resolver:resolver completion:finish];
            });
            return;
        }
        finish(NO, nil, [NSString stringWithFormat:@"目标 %@ 被遮挡（命中 %@）", displayName, NSStringFromClass(hit.class)]);
        return;
    }
    double clamped = MIN(MAX(duration, 0.1), 30.0);
    [[IUATouchSynthesizer shared] longPressAtPoint:point duration:clamped completion:^(NSError * _Nullable error) {
        error ? finish(NO, nil, error.localizedDescription)
              : finish(YES, @{@"x" : @(point.x), @"y" : @(point.y), @"duration" : @(clamped)}, nil);
    }];
}

/// wait_for_element 轮询：支持任意定位策略，不阻塞 UI
- (void)waitForElementUsing:(NSString *)using
                      value:(NSString *)value
                      index:(NSInteger)index
                disappearing:(BOOL)disappearing
                    deadline:(NSDate *)deadline
                      waited:(NSTimeInterval)waited
                    interval:(NSTimeInterval)interval
                  completion:(void (^)(BOOL, NSDictionary *, NSString *))finish {
    BOOL exists = ([IUAElementQuery findViewUsing:using value:value index:index] != nil);
    if (disappearing ? !exists : exists) {
        finish(YES, @{@"using" : using,
                      @"value" : value,
                      @"index" : @(index),
                      @"state" : disappearing ? @"disappeared" : @"appeared",
                      @"waited" : @(round(waited * 10) / 10)}, nil);
        return;
    }
    if ([NSDate.date compare:deadline] != NSOrderedAscending) {
        finish(NO, nil, [NSString stringWithFormat:@"wait_for_element: %.1fs 内元素 %@=%@ 未%@",
                         waited, using, value, disappearing ? @"消失" : @"出现"]);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf waitForElementUsing:using value:value index:index
                           disappearing:disappearing deadline:deadline
                                 waited:waited + interval interval:interval
                             completion:finish];
    });
}

/// wait_for 轮询：主线程 dispatch_after 链，不阻塞 UI
- (void)waitForIdentifier:(NSString *)identifier
              disappearing:(BOOL)disappearing
                  deadline:(NSDate *)deadline
                    waited:(NSTimeInterval)waited
                  interval:(NSTimeInterval)interval
                 completion:(void (^)(BOOL, NSDictionary *, NSString *))finish {
    BOOL exists = ([IUAViewIntrospector findViewWithIdentifier:identifier] != nil);
    if (disappearing ? !exists : exists) {
        finish(YES, @{@"identifier" : identifier,
                      @"state" : disappearing ? @"disappeared" : @"appeared",
                      @"waited" : @(round(waited * 10) / 10)}, nil);
        return;
    }
    if ([NSDate.date compare:deadline] != NSOrderedAscending) {
        finish(NO, nil, [NSString stringWithFormat:@"wait_for: %.1fs 内元素 %@ 未%@",
                         waited, identifier, disappearing ? @"消失" : @"出现"]);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        [strongSelf waitForIdentifier:identifier
                          disappearing:disappearing
                              deadline:deadline
                                waited:waited + interval
                              interval:interval
                             completion:finish];
    });
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
        // 悬浮状态条跟随连接状态（连接显示 / 断开隐藏）
        [[IUAFloatingStatusBar sharedBar] setConnected:connected];
    });
}

/// 便捷入口：从当前 keyWindow 的最顶层控制器模态打开服务端配置页
+ (void)presentConfigPage {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) {
                continue;
            }
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (@available(iOS 15.0, *)) {
                if (ws.keyWindow) { window = ws.keyWindow; break; }
            }
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow && ![w isKindOfClass:NSClassFromString(@"UITextEffectsWindow")]) {
                    window = w; break;
                }
            }
            if (window) { break; }
        }
        UIViewController *top = window.rootViewController;
        while (top.presentedViewController && ![top.presentedViewController isBeingDismissed]) {
            top = top.presentedViewController;
        }
        if ([top isKindOfClass:[IUAConfigViewController class]]) {
            return;   // 已打开
        }
        UINavigationController *nav = [[UINavigationController alloc]
                                       initWithRootViewController:[[IUAConfigViewController alloc] init]];
        [top presentViewController:nav animated:YES completion:nil];
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
