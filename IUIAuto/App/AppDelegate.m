//
//  AppDelegate.m
//  IUIAuto
//

#import "AppDelegate.h"
#import "DemoViewController.h"
#import "IUAEngine.h"
#import "IUALogger.h"

@interface AppDelegate ()
/// 是否离开过前台（用于区分 launch 时的首次 didBecomeActive 与真正的回前台）
@property (nonatomic, assign) BOOL leftForeground;
/// 启动完成时间（启动初期 active/inactive 抖动不触发重连，避免连接风暴）
@property (nonatomic, assign) CFAbsoluteTime launchTime;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[DemoViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 启动 Agent：连接配置中的服务器（默认 ws://127.0.0.1:9800/ws，可在 Demo 页修改）
    self.launchTime = CFAbsoluteTimeGetCurrent();
    [[IUAEngine sharedEngine] start];
    IUALogInfo(@"IUIAuto Agent 已启动");
    return YES;
}

- (void)applicationWillResignActive:(UIApplication *)application {
    self.leftForeground = YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    self.leftForeground = YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // 启动初期（10s 内）active/inactive 会抖动，此时不重连——
    // 否则 didFinishLaunching 的连接会被立刻断开重建，服务器看到"连接风暴"
    if (CFAbsoluteTimeGetCurrent() - self.launchTime < 10.0) {
        return;
    }
    // 真正回前台时无条件重启：挂起期间 WS 可能早已断开，而 state 可能仍是
    // 陈旧的 Connected（心跳 timer 被挂起暂停来不及标记），按 isConnected 判断会漏重连
    if (self.leftForeground) {
        self.leftForeground = NO;
        IUALogInfo(@"回到前台，重启 Agent 连接");
        [[IUAEngine sharedEngine] start];
    }
}

@end
