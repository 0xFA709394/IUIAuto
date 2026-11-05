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

#import "IUARecorder.h"
#import "IUALogger.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

NSString *const IUARecorderStateDidChangeNotification = @"IUARecorderStateDidChangeNotification";

static NSUInteger const kIUARecorderMaxSteps = 1000;
static CGFloat const kIUARecorderTapMoveTolerance = 14.0;   // 位移阈值(pt)
static NSTimeInterval const kIUARecorderLongPressDuration = 0.45; // 长按时长阈值(s)

#pragma mark - touch 追踪上下文

@interface IUATouchContext : NSObject
@property (nonatomic, assign) CGPoint startLocation; // window 坐标
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, weak) UIView *view;
@end

@implementation IUATouchContext
@end

#pragma mark - UIWindow sendEvent 交换（真实触控事件必经之路）

static void (*gIUAOrigSendEvent)(id, SEL, UIEvent *);

static void IUARec_ReplaceMethod(Class cls, SEL selector, IMP newImp, IMP *origImpSlot) {
    Method method = class_getInstanceMethod(cls, selector);
    NSCAssert(method != NULL, @"方法不存在: %@", NSStringFromSelector(selector));
    *origImpSlot = method_setImplementation(method, newImp);
}

static void IUARec_SendEvent(id receiver, SEL selector, UIEvent *event) {
    [IUARecorder noteEvent:event];
    gIUAOrigSendEvent(receiver, selector, event);
}

#pragma mark - IUARecorder

@interface IUARecorder ()
@property (nonatomic, assign) BOOL recording;
@property (nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *steps;
/// 进行中的 touch（指针作 key，touch 对象生命周期内稳定）
@property (nonatomic, strong) NSMutableDictionary<NSValue *, IUATouchContext *> *activeTouches;
@end

@implementation IUARecorder

+ (instancetype)shared {
    static IUARecorder *recorder = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        recorder = [[self alloc] init];
        [recorder installHooks];
    });
    return recorder;
}

- (instancetype)init {
    if (self = [super init]) {
        _steps = [NSMutableArray array];
        _activeTouches = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)installHooks {
    IUARec_ReplaceMethod([UIWindow class], @selector(sendEvent:),
                         (IMP)IUARec_SendEvent, (IMP *)&gIUAOrigSendEvent);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(textFieldChanged:)
                   name:UITextFieldTextDidChangeNotification object:nil];
    [center addObserver:self selector:@selector(textViewChanged:)
                   name:UITextViewTextDidChangeNotification object:nil];
}

#pragma mark - 录制控制

- (void)startRecording {
    if (self.recording) {
        IUALogWarn(@"录制已在进行中，忽略重复 start");
        return;
    }
    [self.steps removeAllObjects];
    [self.activeTouches removeAllObjects];
    self.recording = YES;
    IUALogInfo(@"录制开始");
    [self postStateChange];
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)stopRecording {
    if (!self.recording) {
        return nil;
    }
    self.recording = NO;
    [self.activeTouches removeAllObjects];
    IUALogInfo(@"录制结束，共 %lu 步", (unsigned long)self.steps.count);
    NSArray *steps = [self.steps copy];
    [self postStateChange];
    return steps;
}

- (void)cancelRecording {
    self.recording = NO;
    [self.steps removeAllObjects];
    [self.activeTouches removeAllObjects];
    IUALogInfo(@"录制已取消");
    [self postStateChange];
}

- (void)postStateChange {
    [[NSNotificationCenter defaultCenter] postNotificationName:IUARecorderStateDidChangeNotification
                                                        object:self
                                                      userInfo:@{@"recording" : @(self.recording)}];
}

- (NSUInteger)stepCount {
    return self.steps.count;
}

#pragma mark - touch 事件处理（UIWindow sendEvent 时同步触发，真实事件必经）

+ (void)noteEvent:(UIEvent *)event {
    IUARecorder *recorder = [IUARecorder shared];
    if (!recorder.recording) {
        return;
    }
    if (event.type != UIEventTypeTouches) {
        return;
    }
    // 必须主线程（steps/activeTouches 非线程安全；sendEvent 本来就在主线程）
    if (![NSThread isMainThread]) {
        return;
    }
    NSSet<UITouch *> *touches = [event allTouches];
    if (!touches) {
        return;
    }
    for (UITouch *touch in touches) {
        NSValue *key = [NSValue valueWithPointer:(__bridge void *)touch];
        switch (touch.phase) {
            case UITouchPhaseBegan:
                [recorder touchDidBegin:touch key:key];
                break;
            case UITouchPhaseEnded:
                [recorder touchDidFinish:touch key:key cancelled:NO];
                break;
            case UITouchPhaseCancelled:
                [recorder touchDidFinish:touch key:key cancelled:YES];
                break;
            default:
                break;
        }
    }
}

- (void)touchDidBegin:(UITouch *)touch key:(NSValue *)key {
    if (self.activeTouches.count > 10) {
        return; // 指尖风暴保护
    }
    IUATouchContext *context = [[IUATouchContext alloc] init];
    context.startLocation = [touch locationInView:nil];
    context.startTime = CACurrentMediaTime();
    context.view = touch.view;
    self.activeTouches[key] = context;
}

- (void)touchDidFinish:(UITouch *)touch key:(NSValue *)key cancelled:(BOOL)cancelled {
    IUATouchContext *context = self.activeTouches[key];
    if (!context) {
        return;
    }
    [self.activeTouches removeObjectForKey:key];

    if (self.steps.count >= kIUARecorderMaxSteps) {
        return;
    }
    CGPoint endLocation = [touch locationInView:nil];
    CGFloat dx = endLocation.x - context.startLocation.x;
    CGFloat dy = endLocation.y - context.startLocation.y;
    CGFloat distance = sqrtf(dx * dx + dy * dy);
    CFTimeInterval duration = CACurrentMediaTime() - context.startTime;

    NSString *identifier = [self bestIdentifierForView:context.view];

    if (distance >= kIUARecorderTapMoveTolerance) {
        // 滑动（cancelled 也可能是滑出边界/被手势接管，同样记为 swipe）
        [self appendStep:@{
            @"action" : @"swipe",
            @"identifier" : identifier ?: @"",
            @"fromX" : @(round(context.startLocation.x)),
            @"fromY" : @(round(context.startLocation.y)),
            @"toX" : @(round(endLocation.x)),
            @"toY" : @(round(endLocation.y)),
        }];
    } else if (duration >= kIUARecorderLongPressDuration && !cancelled) {
        [self appendStep:@{
            @"action" : @"long_press",
            @"identifier" : identifier ?: @"",
            @"x" : @(round(endLocation.x)),
            @"y" : @(round(endLocation.y)),
            @"duration" : @(MIN(round(duration * 10) / 10, 5.0)),
        }];
    } else if (!cancelled) {
        [self appendStep:@{
            @"action" : @"tap",
            @"identifier" : identifier ?: @"",
            @"x" : @(round(endLocation.x)),
            @"y" : @(round(endLocation.y)),
            @"tapCount" : @(touch.tapCount),
            }];
    }
}

/// 取 view 或其最近祖先的 accessibilityIdentifier（回放语义化用）
- (NSString * _Nullable)bestIdentifierForView:(UIView *)view {
    UIView *current = view;
    NSInteger depth = 0;
    while (current && depth < 8) {
        if (current.accessibilityIdentifier.length > 0) {
            return current.accessibilityIdentifier;
        }
        current = current.superview;
        depth += 1;
    }
    return nil;
}

- (void)appendStep:(NSDictionary<NSString *, id> *)step {
    if (self.steps.count >= kIUARecorderMaxSteps) {
        return;
    }
    [self.steps addObject:step];
    IUALogInfo(@"录制 +%lu: %@", (unsigned long)self.steps.count, step);
}

#pragma mark - 文本输入录制

- (void)textFieldChanged:(NSNotification *)notification {
    UITextField *textField = notification.object;
    if ([textField isKindOfClass:[UITextField class]]) {
        [self recordTextChange:textField.text identifier:textField.accessibilityIdentifier];
    }
}

- (void)textViewChanged:(NSNotification *)notification {
    UITextView *textView = notification.object;
    if ([textView isKindOfClass:[UITextView class]]) {
        [self recordTextChange:textView.text identifier:textView.accessibilityIdentifier];
    }
}

/// 同一输入框的连续变更合并为一步（保存最新全文）
- (void)recordTextChange:(NSString *)text identifier:(NSString *)identifier {
    if (!self.recording || identifier.length == 0 || ![NSThread isMainThread]) {
        return;
    }
    if (self.steps.count > 0) {
        NSDictionary *last = self.steps.lastObject;
        NSString *lastAction = last[@"action"];
        BOOL isTextStep = [lastAction isEqualToString:@"type_text"] || [lastAction isEqualToString:@"clear_text"];
        if (isTextStep && [last[@"identifier"] isEqualToString:identifier]) {
            // 就地更新
            NSMutableDictionary *mutable = [last mutableCopy];
            if (text.length == 0) {
                mutable[@"action"] = @"clear_text";
                [mutable removeObjectForKey:@"text"];
            } else {
                mutable[@"action"] = @"type_text";
                mutable[@"text"] = [text copy];
            }
            self.steps[self.steps.count - 1] = mutable;
            return;
        }
    }
    if (text.length == 0) {
        return; // 全删后的空态不新增步骤（由就地更新覆盖）
    }
    [self appendStep:@{@"action" : @"type_text",
                       @"identifier" : identifier,
                       @"text" : [text copy]}];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

@end
