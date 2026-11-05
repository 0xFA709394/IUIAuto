//
//  DemoViewController.m
//  IUIAuto
//

#import "DemoViewController.h"

#import <IUIAUTO/IUAEngine.h>
#import <IUIAUTO/IUAConfiguration.h>
#import <IUIAUTO/IUARecorder.h>
#import <IUIAUTO/IUALogger.h>

@interface DemoViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *serverField;
@property (nonatomic, strong) UIButton *connectButton;
@property (nonatomic, strong) UIButton *counterButton;
@property (nonatomic, strong) UILabel *counterLabel;
@property (nonatomic, strong) UITextField *inputField;
@property (nonatomic, strong) UIButton *submitButton;
@property (nonatomic, strong) UILabel *outputLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UILabel *sliderLabel;
@property (nonatomic, strong) UILabel *lastTouchLabel;
@property (nonatomic, strong) UILabel *recordBadge;
@property (nonatomic, assign) NSInteger tapCount;
@end

@implementation DemoViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.96 green:0.96 blue:0.98 alpha:1.0];
    self.tapCount = 0;
    [self buildUI];
    [self refreshStatus];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(connectionDidChange:)
                                                 name:IUAEngineConnectionDidChangeNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(recorderStateDidChange:)
                                                 name:IUARecorderStateDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI 构建

- (void)buildUI {
    UIScrollView *scrollView = [[UIScrollView alloc] init];
    scrollView.accessibilityIdentifier = @"scroll.demo";
    scrollView.alwaysBounceVertical = YES;
    scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:scrollView];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.layoutMargins = UIEdgeInsetsMake(16, 16, 16, 16);
    stack.layoutMarginsRelativeArrangement = YES;
    [scrollView addSubview:stack];

    NSDictionary *views = @{@"scroll" : scrollView, @"stack" : stack};
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:
        [NSLayoutConstraint constraintsWithVisualFormat:@"H:|[scroll]|"
                                                options:0 metrics:nil views:views]];
    [NSLayoutConstraint activateConstraints:
        [NSLayoutConstraint constraintsWithVisualFormat:@"V:|[scroll]|"
                                                options:0 metrics:nil views:views]];
    // stack 撑满 scroll 内容
    [scrollView.contentLayoutGuide.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor].active = YES;
    [scrollView.contentLayoutGuide.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor].active = YES;
    [scrollView.contentLayoutGuide.topAnchor constraintEqualToAnchor:stack.topAnchor].active = YES;
    [scrollView.contentLayoutGuide.bottomAnchor constraintEqualToAnchor:stack.bottomAnchor].active = YES;
    // 宽度跟随 scroll 本体（垂直滚动）
    [scrollView.frameLayoutGuide.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;

    [stack addArrangedSubview:[self statusSection]];
    [stack addArrangedSubview:[self serverSection]];
    [stack addArrangedSubview:[self counterSection]];
    [stack addArrangedSubview:[self inputSection]];
    [stack addArrangedSubview:[self sliderSection]];
    [stack addArrangedSubview:[self listSection]];
    [stack addArrangedSubview:[self footerSection]];
}

- (UIView *)statusSection {
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    self.statusLabel.numberOfLines = 2;

    self.recordBadge = [[UILabel alloc] init];
    self.recordBadge.accessibilityIdentifier = @"label.record";
    self.recordBadge.text = @"● REC 录制中";
    self.recordBadge.textAlignment = NSTextAlignmentCenter;
    self.recordBadge.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    self.recordBadge.textColor = UIColor.whiteColor;
    self.recordBadge.backgroundColor = [UIColor systemRedColor];
    self.recordBadge.layer.cornerRadius = 4;
    self.recordBadge.hidden = YES;

    return [self cardViewWithTitle:nil subviews:@[self.statusLabel, self.recordBadge]];
}

- (UIView *)serverSection {
    self.serverField = [[UITextField alloc] init];
    self.serverField.accessibilityIdentifier = @"field.server";
    self.serverField.text = [IUAConfiguration serverURLString];
    self.serverField.placeholder = @"ws://<服务器IP>:9800/ws";
    self.serverField.borderStyle = UITextBorderStyleRoundedRect;
    self.serverField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverField.keyboardType = UIKeyboardTypeURL;
    self.serverField.font = [UIFont systemFontOfSize:14];

    self.connectButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.connectButton setTitle:@"连接" forState:UIControlStateNormal];
    self.connectButton.accessibilityIdentifier = @"btn.connect";
    self.connectButton.backgroundColor = [UIColor systemBlueColor];
    self.connectButton.tintColor = UIColor.whiteColor;
    self.connectButton.layer.cornerRadius = 6;
    self.connectButton.contentEdgeInsets = UIEdgeInsetsMake(6, 14, 6, 14);
    self.connectButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.connectButton addTarget:self action:@selector(connectTapped)
                 forControlEvents:UIControlEventTouchUpInside];

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentCenter;
    [row addArrangedSubview:self.serverField];
    [row addArrangedSubview:self.connectButton];
    [self.serverField setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.connectButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.connectButton.widthAnchor constraintEqualToConstant:72].active = YES;

    // 卡片标题行右侧加"连接设置"入口（打开完整配置页）
    UIButton *settingsButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [settingsButton setTitle:@"连接设置 ▸" forState:UIControlStateNormal];
    settingsButton.accessibilityIdentifier = @"btn.settings";
    settingsButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [settingsButton addTarget:self action:@selector(settingsTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *titleRow = [[UIStackView alloc] init];
    titleRow.axis = UILayoutConstraintAxisHorizontal;
    titleRow.distribution = UIStackViewDistributionFill;
    titleRow.spacing = 4;
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"控制服务器";
    titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor tertiaryLabelColor];
    [titleRow addArrangedSubview:titleLabel];
    [titleRow addArrangedSubview:[[UIView alloc] init]];   // 撑开
    [titleRow addArrangedSubview:settingsButton];

    return [self cardViewWithTitle:nil customTitleView:titleRow subviews:@[row]];
}

- (UIView *)counterSection {
    self.counterButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.counterButton setTitle:@"点我 (tap me)" forState:UIControlStateNormal];
    self.counterButton.accessibilityIdentifier = @"btn.counter";
    self.counterButton.backgroundColor = [UIColor systemOrangeColor];
    self.counterButton.tintColor = UIColor.whiteColor;
    self.counterButton.titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    self.counterButton.layer.cornerRadius = 10;
    [self.counterButton.heightAnchor constraintGreaterThanOrEqualToConstant:64].active = YES;
    [self.counterButton addTarget:self action:@selector(counterTapped)
                 forControlEvents:UIControlEventTouchUpInside];
    [self.counterButton addTarget:self action:@selector(counterTouchDown)
                 forControlEvents:UIControlEventTouchDown];

    self.counterLabel = [[UILabel alloc] init];
    self.counterLabel.accessibilityIdentifier = @"label.counter";
    self.counterLabel.textAlignment = NSTextAlignmentCenter;
    self.counterLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.counterLabel.text = @"Count: 0";

    return [self cardViewWithTitle:@"点击计数（tap / tap_view）" subviews:@[self.counterButton, self.counterLabel]];
}

- (UIView *)inputSection {
    self.inputField = [[UITextField alloc] init];
    self.inputField.accessibilityIdentifier = @"field.input";
    self.inputField.placeholder = @"输入点什么…（type_text）";
    self.inputField.borderStyle = UITextBorderStyleRoundedRect;
    self.inputField.clearButtonMode = UITextFieldViewModeWhileEditing;

    self.submitButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.submitButton setTitle:@"提交" forState:UIControlStateNormal];
    self.submitButton.accessibilityIdentifier = @"btn.submit";
    self.submitButton.backgroundColor = [UIColor systemGreenColor];
    self.submitButton.tintColor = UIColor.whiteColor;
    self.submitButton.layer.cornerRadius = 6;
    self.submitButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [self.submitButton addTarget:self action:@selector(submitTapped)
                forControlEvents:UIControlEventTouchUpInside];

    self.outputLabel = [[UILabel alloc] init];
    self.outputLabel.accessibilityIdentifier = @"label.output";
    self.outputLabel.text = @"提交内容: -";
    self.outputLabel.font = [UIFont systemFontOfSize:14];
    self.outputLabel.textColor = [UIColor secondaryLabelColor];

    UIStackView *row = [[UIStackView alloc] init];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.spacing = 8;
    [row addArrangedSubview:self.inputField];
    [row addArrangedSubview:self.submitButton];
    [self.inputField setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self.submitButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.submitButton.widthAnchor constraintEqualToConstant:72].active = YES;

    return [self cardViewWithTitle:@"文本输入（type_text / clear_text）" subviews:@[row, self.outputLabel]];
}

- (UIView *)sliderSection {
    self.slider = [[UISlider alloc] init];
    self.slider.accessibilityIdentifier = @"slider.demo";
    self.slider.minimumValue = 0;
    self.slider.maximumValue = 100;
    self.slider.value = 50;
    [self.slider addTarget:self action:@selector(sliderChanged:)
              forControlEvents:UIControlEventValueChanged];

    self.sliderLabel = [[UILabel alloc] init];
    self.sliderLabel.accessibilityIdentifier = @"label.slider";
    self.sliderLabel.textAlignment = NSTextAlignmentCenter;
    self.sliderLabel.font = [UIFont systemFontOfSize:15];
    self.sliderLabel.text = @"value: 50";

    return [self cardViewWithTitle:@"滑块（swipe 拖动）" subviews:@[self.slider, self.sliderLabel]];
}

- (UIView *)listSection {
    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 8;
    for (NSInteger i = 1; i <= 12; i++) {
        UILabel *label = [[UILabel alloc] init];
        label.accessibilityIdentifier = [NSString stringWithFormat:@"label.row.%ld", (long)i];
        label.text = [NSString stringWithFormat:@"  第 %ld 行 — 上滑可滚动（swipe）  ", (long)i];
        label.font = [UIFont systemFontOfSize:14];
        label.backgroundColor = [UIColor secondarySystemBackgroundColor];
        label.layer.cornerRadius = 6;
        label.textAlignment = NSTextAlignmentCenter;
        [label.heightAnchor constraintEqualToConstant:44].active = YES;
        [rows addArrangedSubview:label];
    }
    return [self cardViewWithTitle:@"滚动列表（swipe 滚动）" subviews:@[rows]];
}

- (UIView *)footerSection {
    self.lastTouchLabel = [[UILabel alloc] init];
    self.lastTouchLabel.accessibilityIdentifier = @"label.touch";
    self.lastTouchLabel.numberOfLines = 0;
    self.lastTouchLabel.font = [UIFont fontWithName:@"Menlo" size:12];
    self.lastTouchLabel.textColor = [UIColor tertiaryLabelColor];
    self.lastTouchLabel.text = @"等待指令…\n服务器下发 tap/swipe/type_text 等指令后，此页面会被自动操作";
    return [self cardViewWithTitle:@"指令回显" subviews:@[self.lastTouchLabel]];
}

- (UIView *)cardViewWithTitle:(NSString * _Nullable)title subviews:(NSArray<UIView *> *)subviews {
    return [self cardViewWithTitle:title customTitleView:nil subviews:subviews];
}

- (UIView *)cardViewWithTitle:(NSString * _Nullable)title
               customTitleView:(nullable UIView *)customTitle
                    subviews:(NSArray<UIView *> *)subviews {
    UIStackView *container = [[UIStackView alloc] init];
    container.axis = UILayoutConstraintAxisVertical;
    container.spacing = 10;
    container.layoutMargins = UIEdgeInsetsMake(12, 12, 12, 12);
    container.layoutMarginsRelativeArrangement = YES;
    container.backgroundColor = UIColor.whiteColor;
    container.layer.cornerRadius = 12;

    if (customTitle) {
        [container addArrangedSubview:customTitle];
    } else if (title.length > 0) {
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = title;
        titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        titleLabel.textColor = [UIColor tertiaryLabelColor];
        [container addArrangedSubview:titleLabel];
    }
    for (UIView *subview in subviews) {
        [container addArrangedSubview:subview];
    }
    container.layer.shadowColor = [UIColor.blackColor colorWithAlphaComponent:0.05].CGColor;
    container.layer.shadowOpacity = 1.0;
    container.layer.shadowRadius = 6;
    container.layer.shadowOffset = CGSizeMake(0, 2);
    return container;
}

#pragma mark - 事件（真实手指与合成触控走完全相同的路径）

- (void)counterTouchDown {
    self.counterButton.backgroundColor = [UIColor systemYellowColor];
    [self performSelector:@selector(resetCounterColor)
               withObject:nil afterDelay:0.25];
}

- (void)resetCounterColor {
    self.counterButton.backgroundColor = [UIColor systemOrangeColor];
}

- (void)counterTapped {
    self.tapCount += 1;
    self.counterLabel.text = [NSString stringWithFormat:@"Count: %ld", (long)self.tapCount];
    self.lastTouchLabel.text = [NSString stringWithFormat:@"btn.counter 点击 × %ld\n%@",
                                (long)self.tapCount, [NSDate date].description];
    IUALogInfo(@"Demo: btn.counter 被点击（第 %ld 次）", (long)self.tapCount);
}

- (void)submitTapped {
    self.outputLabel.text = [NSString stringWithFormat:@"提交内容: %@", self.inputField.text ?: @""];
    self.lastTouchLabel.text = [NSString stringWithFormat:@"btn.submit 提交: \"%@\"", self.inputField.text ?: @""];
    [self.inputField resignFirstResponder];
}

- (void)sliderChanged:(UISlider *)slider {
    self.sliderLabel.text = [NSString stringWithFormat:@"value: %.0f", slider.value];
}

- (void)settingsTapped {
    [IUAEngine presentConfigPage];
}

- (void)connectTapped {
    NSString *urlString = [self.serverField.text stringByTrimmingCharactersInSet:
                           [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (urlString.length == 0) {
        self.statusLabel.text = @"请输入服务器地址";
        return;
    }
    self.statusLabel.text = @"正在连接…";
    [[IUAEngine sharedEngine] startWithServerURLString:urlString];
}

#pragma mark - 状态

- (void)connectionDidChange:(NSNotification *)notification {
    [self refreshStatus];
}

- (void)recorderStateDidChange:(NSNotification *)notification {
    BOOL recording = [notification.userInfo[@"recording"] boolValue];
    self.recordBadge.hidden = !recording;
}

- (void)refreshStatus {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshStatus]; });
        return;
    }
    BOOL connected = [IUAEngine sharedEngine].isConnected;
    NSString *dot = connected ? @"●" : @"○";
    NSString *text = [NSString stringWithFormat:@"%@ %@\n%@",
                      dot, connected ? @"已连接" : @"未连接",
                      [IUAConfiguration serverURLString]];
    NSAttributedString *attributed = [[NSAttributedString alloc] initWithString:text
                                                                       attributes:@{
        NSForegroundColorAttributeName : connected ? [UIColor systemGreenColor] : [UIColor systemRedColor],
        NSFontAttributeName : [UIFont systemFontOfSize:14 weight:UIFontWeightMedium],
    }];
    self.statusLabel.attributedText = attributed;
}

@end
