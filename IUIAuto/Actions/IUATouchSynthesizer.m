//
//  IUATouchSynthesizer.m
//  IUIAuto
//

#import "IUATouchSynthesizer.h"
#import "IUALogger.h"
#import "IUARecorder.h"
#import <objc/message.h>
#import <QuartzCore/QuartzCore.h>

NSString *const IUATouchSynthesizerErrorDomain = @"IUATouchSynthesizerErrorDomain";

#pragma mark - 私有 setter 调用工具（候选方法名逐个探测，兼容 iOS 13+ 各版本）

static BOOL IUASendMsgCGPointBool(id target, NSArray<NSString *> *names, CGPoint point, BOOL flag) {
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if ([target respondsToSelector:sel]) {
            void (*msgSend)(id, SEL, CGPoint, BOOL) = (void (*)(id, SEL, CGPoint, BOOL))objc_msgSend;
            msgSend(target, sel, point, flag);
            return YES;
        }
    }
    return NO;
}

static BOOL IUASendMsgEnum(id target, NSArray<NSString *> *names, NSUInteger value) {
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if ([target respondsToSelector:sel]) {
            void (*msgSend)(id, SEL, NSUInteger) = (void (*)(id, SEL, NSUInteger))objc_msgSend;
            msgSend(target, sel, value);
            return YES;
        }
    }
    return NO;
}

static BOOL IUASendMsgDouble(id target, NSArray<NSString *> *names, double value) {
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if ([target respondsToSelector:sel]) {
            void (*msgSend)(id, SEL, double) = (void (*)(id, SEL, double))objc_msgSend;
            msgSend(target, sel, value);
            return YES;
        }
    }
    return NO;
}

static BOOL IUASendMsgObject(id target, NSArray<NSString *> *names, id object) {
    for (NSString *name in names) {
        SEL sel = NSSelectorFromString(name);
        if ([target respondsToSelector:sel]) {
            void (*msgSend)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
            msgSend(target, sel, object);
            return YES;
        }
    }
    return NO;
}

#pragma mark - UITouch 时间戳设置分类（私有 setter 探测包装）

@interface UITouch (IUASynthetic)
- (void)setTimestampInternal:(NSTimeInterval)timestamp;
@end

@implementation UITouch (IUASynthetic)

- (void)setTimestampInternal:(NSTimeInterval)timestamp {
    IUASendMsgDouble(self, @[@"_setTimestamp:", @"setTimestamp:"], timestamp);
}

@end

#pragma mark - 合成 UIEvent：包装 touches 供手势识别器查询

@interface IUASyntheticEvent : UIEvent {
    NSSet<UITouch *> *_syntheticTouches;
}
- (instancetype)initWithTouches:(NSSet<UITouch *> *)touches;
@end

@implementation IUASyntheticEvent

- (instancetype)initWithTouches:(NSSet<UITouch *> *)touches {
    if (self = [super init]) {
        _syntheticTouches = touches;
    }
    return self;
}

- (NSSet<UITouch *> *)touchesForView:(UIView *)view {
    return _syntheticTouches;
}

- (NSSet<UITouch *> *)touchesForGestureRecognizer:(UIGestureRecognizer *)gestureRecognizer {
    return _syntheticTouches;
}

- (UIEventType)type {
    return UIEventTypeTouches;
}

- (UIEventSubtype)subtype {
    return UIEventSubtypeNone;
}

- (NSTimeInterval)timestamp {
    UITouch *any = _syntheticTouches.anyObject;
    return any.timestamp;
}

- (NSSet<UITouch *> *)allTouches {
    return _syntheticTouches;
}

/// UIControl 的 _firstTouchForEvent: 会调用此私有方法取首个触点
- (UITouch *)_firstTouchForView:(UIView *)view {
    return _syntheticTouches.anyObject;
}

// 兜底：UIKit 内部还可能请求其他未知私有方法。打印名字并按 nil 对象返回
//（OC 对 nil 发消息安全，最坏情况是该控件跳过本次触控处理，不会崩溃）
- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
    IUALogWarn(@"IUASyntheticEvent 被请求未实现的方法: %@", NSStringFromSelector(aSelector));
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}

- (void)forwardInvocation:(NSInvocation *)anInvocation {
    id result = nil;
    [anInvocation setReturnValue:&result];
}

@end

#pragma mark - IUATouchSynthesizer

@interface IUATouchSynthesizer ()
@end

@implementation IUATouchSynthesizer

+ (instancetype)shared {
    static IUATouchSynthesizer *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

+ (BOOL)isSupported {
    UITouch *probe = [[UITouch alloc] init];
    return IUASendMsgEnum(probe, @[@"_setPhase:", @"setPhase:"], UITouchPhaseBegan);
}

#pragma mark - 对外动作

- (void)tapAtPoint:(CGPoint)point tapCount:(NSUInteger)tapCount completion:(nullable IUATouchCompletion)completion {
    tapCount = MAX(tapCount, 1);
    [self performTapCycleAtPoint:point tapCount:tapCount completion:^(NSError *error) {
        if (!error && tapCount > 1) {
            // 双击的第二次触摸：tapCount 记为 2（系统语义）
            [self performTapCycleAtPoint:point tapCount:2 completion:^(NSError *err) {
                if (completion) completion(err);
            }];
        } else if (completion) {
            completion(error);
        }
    }];
}

/// 一次完整的按下-抬起
- (void)performTapCycleAtPoint:(CGPoint)point tapCount:(NSUInteger)tapCount completion:(IUATouchCompletion)completion {
    UIWindow *window = [self targetWindow];
    UIView *view = [self hitViewAtPoint:point inWindow:window];
    if (!view) {
        completion([self errorWithText:@"tap: 目标坐标没有可交互的 view"]);
        return;
    }

    UITouch *touch = [self touchInWindow:window view:view point:point tapCount:tapCount];
    NSSet *touches = [NSSet setWithObject:touch];
    IUASyntheticEvent *event = [[IUASyntheticEvent alloc] initWithTouches:touches];
    NSArray<UIGestureRecognizer *> *recognizers = [self collectedRecognizersFromView:view];

    // Began
    [touch setTimestampInternal:CACurrentMediaTime()];
    [self setPhase:touch phase:UITouchPhaseBegan];
    [self deliverTouches:touches event:event selector:@selector(touchesBegan:withEvent:) toView:view recognizers:recognizers];

    // Ended（dispatch_after 保持 runloop 活动，让识别器的 tap 判定正常工作）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setTimestampInternal:CACurrentMediaTime()];
        [self setPhase:touch phase:UITouchPhaseEnded];
        [self deliverTouches:touches event:event selector:@selector(touchesEnded:withEvent:) toView:view recognizers:recognizers];
        completion(nil);
    });
}

- (void)longPressAtPoint:(CGPoint)point duration:(NSTimeInterval)duration completion:(nullable IUATouchCompletion)completion {
    duration = MIN(MAX(duration, 0.1), 30.0);

    UIWindow *window = [self targetWindow];
    UIView *view = [self hitViewAtPoint:point inWindow:window];
    if (!view) {
        completion([self errorWithText:@"long_press: 目标坐标没有可交互的 view"]);
        return;
    }

    UITouch *touch = [self touchInWindow:window view:view point:point tapCount:1];
    NSSet *touches = [NSSet setWithObject:touch];
    IUASyntheticEvent *event = [[IUASyntheticEvent alloc] initWithTouches:touches];
    NSArray<UIGestureRecognizer *> *recognizers = [self collectedRecognizersFromView:view];

    [touch setTimestampInternal:CACurrentMediaTime()];
    [self setPhase:touch phase:UITouchPhaseBegan];
    [self deliverTouches:touches event:event selector:@selector(touchesBegan:withEvent:) toView:view recognizers:recognizers];

    // 保持期间持续派发低频 moved（保持手势识别器“跟踪中”状态）
    NSInteger keepAliveCount = (NSInteger)(duration / 0.25);
    for (NSInteger i = 1; i <= keepAliveCount; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [touch setTimestampInternal:CACurrentMediaTime()];
            [self setPhase:touch phase:UITouchPhaseMoved];
            [self deliverTouches:touches event:event selector:@selector(touchesMoved:withEvent:) toView:view recognizers:recognizers];
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [touch setTimestampInternal:CACurrentMediaTime()];
        [self setPhase:touch phase:UITouchPhaseEnded];
        [self deliverTouches:touches event:event selector:@selector(touchesEnded:withEvent:) toView:view recognizers:recognizers];
        if (completion) completion(nil);
    });
}

- (void)swipeFromPoint:(CGPoint)from toPoint:(CGPoint)to duration:(NSTimeInterval)duration completion:(nullable IUATouchCompletion)completion {
    duration = MIN(MAX(duration, 0.05), 10.0);

    UIWindow *window = [self targetWindow];
    UIView *view = [self hitViewAtPoint:from inWindow:window];
    if (!view) {
        completion([self errorWithText:@"swipe: 起点没有可交互的 view"]);
        return;
    }

    UITouch *touch = [self touchInWindow:window view:view point:from tapCount:1];
    NSSet *touches = [NSSet setWithObject:touch];
    IUASyntheticEvent *event = [[IUASyntheticEvent alloc] initWithTouches:touches];
    NSArray<UIGestureRecognizer *> *recognizers = [self collectedRecognizersFromView:view];

    [touch setTimestampInternal:CACurrentMediaTime()];
    [self setPhase:touch phase:UITouchPhaseBegan];
    [self deliverTouches:touches event:event selector:@selector(touchesBegan:withEvent:) toView:view recognizers:recognizers];

    // 以 ~16ms 步长线性插值派发 Moved
    NSUInteger steps = MAX((NSUInteger)(duration / 0.016), 3);
    __block CGFloat lastProgress = 0;
    for (NSUInteger i = 1; i <= steps; i++) {
        CGFloat progress = (CGFloat)i / steps;
        // 注意循环变量捕获：用包装避免 block 直接捕获可变循环量
        NSNumber *progressNumber = @(progress);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * progress * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CGFloat p = progressNumber.doubleValue;
            CGPoint location = CGPointMake(from.x + (to.x - from.x) * p,
                                           from.y + (to.y - from.y) * p);
            [self setLocation:touch location:location resetPrevious:NO];
            [touch setTimestampInternal:CACurrentMediaTime()];
            [self setPhase:touch phase:UITouchPhaseMoved];
            [self deliverTouches:touches event:event selector:@selector(touchesMoved:withEvent:) toView:view recognizers:recognizers];
            lastProgress = p;
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (lastProgress < 1.0) {
            [self setLocation:touch location:to resetPrevious:NO];
        }
        [touch setTimestampInternal:CACurrentMediaTime()];
        [self setPhase:touch phase:UITouchPhaseEnded];
        [self deliverTouches:touches event:event selector:@selector(touchesEnded:withEvent:) toView:view recognizers:recognizers];
        if (completion) completion(nil);
    });
}

- (void)pinchAtCenter:(CGPoint)center fromRadius:(CGFloat)startRadius toRadius:(CGFloat)endRadius duration:(NSTimeInterval)duration completion:(nullable IUATouchCompletion)completion {
    duration = MIN(MAX(duration, 0.1), 10.0);
    startRadius = MAX(startRadius, 1.0);
    endRadius = MAX(endRadius, 0.0);

    UIWindow *window = [self targetWindow];
    UIView *view = [self hitViewAtPoint:center inWindow:window];
    if (!view) {
        completion([self errorWithText:@"pinch: 中心点没有可交互的 view"]);
        return;
    }

    UITouch *touchA = [self touchInWindow:window view:view
                              point:CGPointMake(center.x - startRadius, center.y) tapCount:1];
    UITouch *touchB = [self touchInWindow:window view:view
                              point:CGPointMake(center.x + startRadius, center.y) tapCount:1];
    NSSet *touches = [NSSet setWithArray:@[touchA, touchB]];
    IUASyntheticEvent *event = [[IUASyntheticEvent alloc] initWithTouches:touches];
    NSArray<UIGestureRecognizer *> *recognizers = [self collectedRecognizersFromView:view];

    [touchA setTimestampInternal:CACurrentMediaTime()];
    [touchB setTimestampInternal:CACurrentMediaTime()];
    [self setPhase:touchA phase:UITouchPhaseBegan];
    [self setPhase:touchB phase:UITouchPhaseBegan];
    [self deliverTouches:touches event:event selector:@selector(touchesBegan:withEvent:) toView:view recognizers:recognizers];

    NSUInteger steps = MAX((NSUInteger)(duration / 0.016), 3);
    for (NSUInteger i = 1; i <= steps; i++) {
        NSNumber *progressNumber = @((CGFloat)i / steps);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * progressNumber.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CGFloat p = progressNumber.doubleValue;
            CGFloat r = startRadius + (endRadius - startRadius) * p;
            [self setLocation:touchA location:CGPointMake(center.x - r, center.y) resetPrevious:NO];
            [self setLocation:touchB location:CGPointMake(center.x + r, center.y) resetPrevious:NO];
            [touchA setTimestampInternal:CACurrentMediaTime()];
            [touchB setTimestampInternal:CACurrentMediaTime()];
            [self setPhase:touchA phase:UITouchPhaseMoved];
            [self setPhase:touchB phase:UITouchPhaseMoved];
            [self deliverTouches:touches event:event selector:@selector(touchesMoved:withEvent:) toView:view recognizers:recognizers];
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((duration + 0.05) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setPhase:touchA phase:UITouchPhaseEnded];
        [self setPhase:touchB phase:UITouchPhaseEnded];
        [self deliverTouches:touches event:event selector:@selector(touchesEnded:withEvent:) toView:view recognizers:recognizers];
        if (completion) completion(nil);
    });
}

#pragma mark - 合成与派发

/// 创建合成 touch 并写入真实 ivar（location/phase/timestamp/view）
- (UITouch *)touchInWindow:(UIWindow *)window view:(UIView *)view point:(CGPoint)point tapCount:(NSUInteger)tapCount {
    UITouch *touch = [[UITouch alloc] init];

    IUASendMsgObject(touch, @[@"_setView:", @"setView:"], view);
    IUASendMsgObject(touch, @[@"_setWindow:", @"setWindow:"], window);
    [self setLocation:touch location:point resetPrevious:YES];
    IUASendMsgEnum(touch, @[@"_setTapCount:", @"setTapCount:"], tapCount);
    IUASendMsgDouble(touch, @[@"_setTimestamp:", @"setTimestamp:"], CACurrentMediaTime());
    IUASendMsgEnum(touch, @[@"_setType:"], UITouchTypeDirect); // 部分版本存在
    [touch setTimestampInternal:CACurrentMediaTime()]; // 分类方法，见下

    return touch;
}

- (void)setLocation:(UITouch *)touch location:(CGPoint)location resetPrevious:(BOOL)reset {
    BOOL ok = IUASendMsgCGPointBool(touch, @[@"_setLocationInWindow:resetPrevious:",
                                             @"setLocationInWindow:"], location, reset);
    if (!ok) {
        IUALogError(@"无法设置 touch location（私有 setter 不可用）");
    }
}

- (void)setPhase:(UITouch *)touch phase:(UITouchPhase)phase {
    IUASendMsgEnum(touch, @[@"_setPhase:", @"setPhase:"], (NSUInteger)phase);
}

/// 对 view 及其父链上所有手势识别器 + view 本身派发 touches 回调
- (void)deliverTouches:(NSSet<UITouch *> *)touches
                 event:(IUASyntheticEvent *)event
              selector:(SEL)selector
                toView:(UIView *)view
           recognizers:(NSArray<UIGestureRecognizer *> *)recognizers {
    // 录制钩子：合成事件不经过 UIWindow sendEvent，在此捕获（与真实事件路径互斥，无重复记录）
    [IUARecorder noteEvent:event];

    for (UIGestureRecognizer *recognizer in recognizers) {
        if (!recognizer.enabled || recognizer.state == UIGestureRecognizerStateFailed) {
            continue;
        }
        if ([recognizer respondsToSelector:selector]) {
            void (*msgSend)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
            msgSend(recognizer, selector, touches, event);
        }
    }
    if ([view respondsToSelector:selector]) {
        void (*msgSend)(id, SEL, id, id) = (void (*)(id, SEL, id, id))objc_msgSend;
        msgSend(view, selector, touches, event);
    }
}

/// 收集 view 到 window 链上所有手势识别器（系统 sendEvent 同样会通知整条链）
- (NSArray<UIGestureRecognizer *> *)collectedRecognizersFromView:(UIView *)view {
    NSMutableArray<UIGestureRecognizer *> *result = [NSMutableArray array];
    UIView *current = view;
    while (current) {
        [result addObjectsFromArray:current.gestureRecognizers];
        current = current.superview;
    }
    return result;
}

- (UIView * _Nullable)hitViewAtPoint:(CGPoint)point inWindow:(UIWindow *)window {
    if (!window) {
        return nil;
    }
    return [window hitTest:point withEvent:nil];
}

- (UIWindow *)targetWindow {
    UIWindow *keyWindow = nil;
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                if (windowScene.activationState == UISceneActivationStateForegroundActive &&
                    windowScene.keyWindow != nil) {
                    keyWindow = windowScene.keyWindow;
                    break;
                }
            }
        }
    }
    if (@available(iOS 15.0, *)) {
        if (!keyWindow) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if ([scene isKindOfClass:[UIWindowScene class]]) {
                    UIWindowScene *windowScene = (UIWindowScene *)scene;
                    if (windowScene.keyWindow) {
                        keyWindow = windowScene.keyWindow;
                        break;
                    }
                }
            }
        }
    }
    return keyWindow;
}

- (NSError *)errorWithText:(NSString *)text {
    return [NSError errorWithDomain:IUATouchSynthesizerErrorDomain code:-1
                           userInfo:@{NSLocalizedDescriptionKey : text}];
}

@end
