//
//  IUAConfigViewController.m
//  IUIAUTO
//

#import "IUAConfigViewController.h"
#import "IUAEngine.h"
#import "IUAConfiguration.h"
#import "IUAFloatingStatusBar.h"

@interface IUAConfigViewController ()
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextField *serverField;
@property (nonatomic, strong) UIButton *actionButton;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UISwitch *floatingSwitch;
@end

@implementation IUAConfigViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"IUIAuto 调试服务端";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self buildUI];
    [self refreshState];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(refreshState)
                                                 name:IUAEngineConnectionDidChangeNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - UI

- (void)buildUI {
    UIScrollView *scroll = [[UIScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.layoutMargins = UIEdgeInsetsMake(20, 16, 20, 16);
    stack.layoutMarginsRelativeArrangement = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];

    [scroll.contentLayoutGuide.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor].active = YES;
    [scroll.contentLayoutGuide.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor].active = YES;
    [scroll.contentLayoutGuide.topAnchor constraintEqualToAnchor:stack.topAnchor].active = YES;
    [scroll.contentLayoutGuide.bottomAnchor constraintEqualToAnchor:stack.bottomAnchor].active = YES;
    [scroll.frameLayoutGuide.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor].active = YES;
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor].active = YES;
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor].active = YES;
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor].active = YES;

    // 状态
    self.statusLabel = [[UILabel alloc] init];
    self.statusLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    [stack addArrangedSubview:self.statusLabel];

    // 地址输入
    self.serverField = [[UITextField alloc] init];
    self.serverField.accessibilityIdentifier = @"field.config.server";
    self.serverField.placeholder = @"ws://<服务器IP>:9800/ws";
    self.serverField.text = [IUAConfiguration serverURLString];
    self.serverField.borderStyle = UITextBorderStyleRoundedRect;
    self.serverField.keyboardType = UIKeyboardTypeURL;
    self.serverField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.serverField.autocorrectionType = UITextAutocorrectionTypeNo;
    self.serverField.font = [UIFont systemFontOfSize:15];
    [stack addArrangedSubview:self.serverField];

    // 连接/断开按钮
    self.actionButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.actionButton.accessibilityIdentifier = @"btn.config.connect";
    self.actionButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    self.actionButton.layer.cornerRadius = 8;
    [self.actionButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [self.actionButton addTarget:self action:@selector(actionTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.actionButton];

    // 悬浮条开关行
    UIStackView *floatRow = [[UIStackView alloc] init];
    floatRow.axis = UILayoutConstraintAxisHorizontal;
    floatRow.spacing = 8;
    floatRow.distribution = UIStackViewDistributionFill;

    UILabel *floatLabel = [[UILabel alloc] init];
    floatLabel.text = @"悬浮状态条（连接后显示）";
    floatLabel.font = [UIFont systemFontOfSize:15];
    [floatRow addArrangedSubview:floatLabel];

    self.floatingSwitch = [[UISwitch alloc] init];
    self.floatingSwitch.accessibilityIdentifier = @"switch.config.floating";
    self.floatingSwitch.on = [IUAFloatingStatusBar sharedBar].isEnabled;
    [self.floatingSwitch addTarget:self action:@selector(floatingSwitchChanged)
                  forControlEvents:UIControlEventValueChanged];
    [floatRow addArrangedSubview:self.floatingSwitch];
    [stack addArrangedSubview:floatRow];

    // Agent 信息
    self.infoLabel = [[UILabel alloc] init];
    self.infoLabel.font = [UIFont fontWithName:@"Menlo" size:12];
    self.infoLabel.textColor = [UIColor secondaryLabelColor];
    self.infoLabel.numberOfLines = 0;
    [stack addArrangedSubview:self.infoLabel];

    // 完成按钮（普通 UIButton，可被 tap_view 定位；UIBarButtonItem 不在 view 树无法自动化）
    UIButton *doneButton = [UIButton buttonWithType:UIButtonTypeSystem];
    doneButton.accessibilityIdentifier = @"btn.config.done";
    [doneButton setTitle:@"完成" forState:UIControlStateNormal];
    doneButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
    doneButton.backgroundColor = [UIColor systemGray5Color];
    doneButton.tintColor = [UIColor labelColor];
    doneButton.layer.cornerRadius = 8;
    [doneButton.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    [doneButton addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:doneButton];

    // 说明
    UILabel *hint = [[UILabel alloc] init];
    hint.font = [UIFont systemFontOfSize:13];
    hint.textColor = [UIColor tertiaryLabelColor];
    hint.numberOfLines = 0;
    hint.text = @"说明：\n· 模拟器默认连接 ws://127.0.0.1:9800/ws\n· 真机填 Mac 的局域网地址（需同网段）\n· 连接成功后顶部出现悬浮状态条，执行自动化时显示进度状态\n· 断开连接悬浮条自动隐藏";
    [stack addArrangedSubview:hint];
}

#pragma mark - 状态刷新

- (void)refreshState {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self refreshState]; });
        return;
    }
    BOOL connected = [IUAEngine sharedEngine].isConnected;
    NSString *url = [IUAConfiguration serverURLString];

    self.statusLabel.text = connected ? @"● 已连接" : @"○ 未连接";
    self.statusLabel.textColor = connected ? [UIColor systemGreenColor] : [UIColor systemRedColor];

    if (connected) {
        [self.actionButton setTitle:@"断开连接" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = [UIColor systemRedColor];
        self.actionButton.tintColor = [UIColor whiteColor];
    } else {
        [self.actionButton setTitle:@"连接" forState:UIControlStateNormal];
        self.actionButton.backgroundColor = [UIColor systemBlueColor];
        self.actionButton.tintColor = [UIColor whiteColor];
    }

    // Agent 信息（连接时来自 hello；未连接展示本地基础信息）
    self.infoLabel.text = [NSString stringWithFormat:@"Agent: %@\n服务器: %@\n状态: %@",
                           [IUAConfiguration agentVersion],
                           url,
                           connected ? @"已连接（指令通道就绪）" : @"未连接"];
}

#pragma mark - 事件

- (void)doneTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionTapped {
    if ([IUAEngine sharedEngine].isConnected) {
        [[IUAEngine sharedEngine] stop];
        [self.view endEditing:YES];
    } else {
        NSString *url = [self.serverField.text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (url.length == 0) {
            self.statusLabel.text = @"请输入服务器地址";
            self.statusLabel.textColor = [UIColor systemOrangeColor];
            return;
        }
        [[IUAEngine sharedEngine] startWithServerURLString:url];
    }
    [self refreshState];
}

- (void)floatingSwitchChanged {
    [IUAFloatingStatusBar sharedBar].enabled = self.floatingSwitch.on;
}

@end
