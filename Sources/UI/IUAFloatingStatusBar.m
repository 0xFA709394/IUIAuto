//
//  IUAFloatingStatusBar.m
//  IUIAUTO
//

#import "IUAFloatingStatusBar.h"
#import "IUAEngine.h"
#import "IUAConfiguration.h"
#import "IUACommandDispatcher.h"

static CGFloat const kIUABarHeight = 34.0f;
static CGFloat const kIUABarItemSpacing = 7.0f;
static CGFloat const kIUABarHPadding = 15.0f;

@interface IUAFloatingStatusBar ()
@property (nonatomic, strong, nullable) UIView *barView;       // 容器（毛玻璃）
@property (nonatomic, strong, nullable) UIView *dotView;       // 状态色点
@property (nonatomic, strong, nullable) UILabel *label;        // 文案
@property (nonatomic, strong, nullable) UIVisualEffectView *blurView;   // 毛玻璃（随容器尺寸）
@property (nonatomic, assign) BOOL busy;
@end

@implementation IUAFloatingStatusBar

+ (instancetype)sharedBar {
    static IUAFloatingStatusBar *bar = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bar = [[self alloc] init];
    });
    return bar;
}

- (instancetype)init {
    if (self = [super init]) {
        _enabled = YES;
        _busy = NO;

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onConnectionChange:)
                                                     name:IUAEngineConnectionDidChangeNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(onBusyChange:)
                                                     name:IUACommandDispatcherBusyDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - 状态变化

- (void)onConnectionChange:(NSNotification *)note {
    [self setConnected:[note.userInfo[@"connected"] boolValue]];
}

- (void)onBusyChange:(NSNotification *)note {
    self.busy = [note.userInfo[@"busy"] boolValue];
    [self refresh];
}

- (void)setConnected:(BOOL)connected {
    if (connected) {
        [self showBar];
    } else {
        [self hideBar];
    }
}

- (void)refresh {
    if ([IUAEngine sharedEngine].isConnected) {
        [self showBar];
    } else {
        [self hideBar];
    }
}

#pragma mark - 显示/隐藏

- (void)hideBar {
    [self stopPulse];
    [UIView animateWithDuration:0.25
        animations:^{ self.barView.alpha = 0.0f; }
        completion:^(BOOL finished) {
            if (finished && self.barView.alpha == 0.0f) {
                [self.barView removeFromSuperview];
                self.barView = nil;
                self.blurView = nil;
                self.dotView = nil;
                self.label = nil;
            }
        }];
}

- (void)showBar {
    if (!self.enabled) {
        return;
    }
    UIWindow *window = [self hostWindow];
    if (!window) {
        return;
    }
    if (!self.barView || self.barView.superview != window) {
        [self teardownBar];
        [self buildBarInView:window];
    }

    // 内容
    self.label.text = self.busy ? @"IUIAuto 执行自动化中" : @"IUIAuto 已连接";
    [self.label sizeToFit];
    self.dotView.backgroundColor = self.busy ? [UIColor systemOrangeColor] : [UIColor systemGreenColor];
    if (self.busy) {
        [self startPulse];
    } else {
        [self stopPulse];
    }

    // 布局：动态宽度胶囊，顶部安全区下 8pt 居中
    CGFloat textWidth = ceil(self.label.intrinsicContentSize.width);
    CGFloat barWidth = kIUABarHPadding + 8.0f /*dot*/ + kIUABarItemSpacing + textWidth + kIUABarHPadding;
    CGFloat top = window.safeAreaInsets.top + 8.0f;
    if (top < 8.0f + 20.0f) {
        top = 28.0f;   // 安全区异常时的兜底
    }
    self.barView.frame = CGRectMake(round((window.bounds.size.width - barWidth) / 2.0f),
                                    top,
                                    barWidth,
                                    kIUABarHeight);
    self.blurView.frame = self.barView.bounds;
    self.dotView.frame = CGRectMake(kIUABarHPadding,
                                     (kIUABarHeight - 8.0f) / 2.0f,
                                     8.0f, 8.0f);
    self.label.frame = CGRectMake(CGRectGetMaxX(self.dotView.frame) + kIUABarItemSpacing,
                                   (kIUABarHeight - self.label.intrinsicContentSize.height) / 2.0f,
                                   textWidth,
                                   self.label.intrinsicContentSize.height);

    if (self.barView.alpha < 0.99f) {
        self.barView.alpha = 0.0f;
        self.barView.transform = CGAffineTransformMakeTranslation(0, -6.0f);
        [UIView animateWithDuration:0.3
                              delay:0
             usingSpringWithDamping:0.8
              initialSpringVelocity:0.5
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{
            self.barView.alpha = 0.97f;
            self.barView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }
}

- (void)teardownBar {
    [self.barView removeFromSuperview];
    self.barView = nil;
    self.blurView = nil;
    self.dotView = nil;
    self.label = nil;
}

- (void)buildBarInView:(UIWindow *)window {
    // 毛玻璃胶囊容器
    UIVisualEffectView *bar = [[UIVisualEffectView alloc] initWithEffect:
                               [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
    bar.accessibilityIdentifier = @"bar.floating";
    bar.frame = CGRectZero;   // 由 showBar 完整布局
    bar.layer.cornerRadius = kIUABarHeight / 2.0f;
    bar.layer.masksToBounds = YES;
    // 阴影由外层 shadowHolder 承载（masksToBounds 的圆角视图自身画不了阴影）
    UIView *shadowHolder = [[UIView alloc] init];
    shadowHolder.accessibilityIdentifier = @"bar.floating";
    shadowHolder.backgroundColor = [UIColor clearColor];
    shadowHolder.layer.shadowColor = [UIColor blackColor].CGColor;
    shadowHolder.layer.shadowOpacity = 0.28;
    shadowHolder.layer.shadowRadius = 10.0;
    shadowHolder.layer.shadowOffset = CGSizeMake(0, 4);
    shadowHolder.layer.cornerRadius = kIUABarHeight / 2.0f;

    // 状态点
    UIView *dot = [[UIView alloc] init];
    dot.accessibilityIdentifier = @"dot.floating";
    dot.backgroundColor = [UIColor systemGreenColor];
    dot.layer.cornerRadius = 4.0f;

    // 文案
    UILabel *label = [[UILabel alloc] init];
    label.accessibilityIdentifier = @"label.floating.status";
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentLeft;

    [bar.contentView addSubview:dot];
    [bar.contentView addSubview:label];
    [shadowHolder addSubview:bar];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                          action:@selector(openConfigPage)];
    [shadowHolder addGestureRecognizer:tap];
    shadowHolder.userInteractionEnabled = YES;

    [window addSubview:shadowHolder];

    self.barView = shadowHolder;   // 对外统一操作 shadowHolder（frame/alpha）
    self.blurView = bar;           // 内部毛玻璃随 holder 尺寸
    self.dotView = dot;
    self.label = label;
}

#pragma mark - 执行中脉动动画

- (void)startPulse {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"opacity"];
    pulse.fromValue = @1.0;
    pulse.toValue = @0.25;
    pulse.duration = 0.6;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.removedOnCompletion = NO;
    [self.dotView.layer addAnimation:pulse forKey:@"iua_pulse"];
}

- (void)stopPulse {
    [self.dotView.layer removeAnimationForKey:@"iua_pulse"];
}

#pragma mark - 其他

- (void)openConfigPage {
    [IUAEngine presentConfigPage];
}

- (UIWindow *)hostWindow {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (@available(iOS 15.0, *)) {
            if (ws.keyWindow) {
                return ws.keyWindow;
            }
        }
        // iOS 13/14 回退：取第一个可成为 key 的主窗口
        for (UIWindow *w in ws.windows) {
            if (w.isKeyWindow && ![self isSystemOverlayWindow:w]) {
                return w;
            }
        }
    }
    return nil;
}

- (BOOL)isSystemOverlayWindow:(UIWindow *)window {
    return [window isKindOfClass:NSClassFromString(@"UITextEffectsWindow")] ||
           [window isKindOfClass:NSClassFromString(@"UICallBarWindow")];
}

- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled;
    if (!enabled) {
        [self hideBar];
    } else {
        [self refresh];
    }
}

@end
