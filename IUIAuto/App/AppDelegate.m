//
//  AppDelegate.m
//  IUIAuto
//

#import "AppDelegate.h"
#import "DemoViewController.h"
#import "IUAEngine.h"
#import "IUALogger.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application
        didFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey, id> *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[DemoViewController alloc] init];
    [self.window makeKeyAndVisible];

    // 启动 Agent：连接配置中的服务器（默认 ws://127.0.0.1:9800/ws，可在 Demo 页修改）
    [[IUAEngine sharedEngine] start];
    IUALogInfo(@"IUIAuto Agent 已启动");
    return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)application {
    // 回前台时若未连接则重连（后台 WS 会被系统挂起/断开）
    if (![IUAEngine sharedEngine].isConnected) {
        [[IUAEngine sharedEngine] start];
    }
}

@end
