//
//  IUIAUTO.h
//  IUIAUTO
//
//  IUIAuto iOS 库伞头文件 —— 集成方只需 #import <IUIAUTO/IUIAUTO.h>
//
//  快速接入（3 行代码启动 Agent）:
//
//      #import <IUIAUTO/IUIAUTO.h>
//
//      - (BOOL)application:(UIApplication *)application
//              didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
//          [[IUAEngine sharedEngine] start];   // 默认连接 ws://127.0.0.1:9800/ws
//          ...
//      }
//
//  服务器地址可通过 [IUAConfiguration setServerURLString:] 修改，或在
//  [IUAEngine startWithServerURLString:] 启动时指定。
//
//  ⚠️ 合成触控使用 UITouch 私有 setter，仅适用于开发签名/内部自动化场景，
//     不可上架 App Store；作用范围仅限宿主 App 进程内（iOS 沙箱限制）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// 总控与配置（绝大多数集成方只需要这两个）
#import "IUAEngine.h"
#import "IUAConfiguration.h"

// 高级用法：直接使用调度器注册自定义指令
#import "IUACommandDispatcher.h"
#import "IUACommand.h"

// 功能模块（一般经由 IUAEngine 自动注册，按需直用）
#import "IUATouchSynthesizer.h"
#import "IUARecorder.h"
#import "IUAPerfSampler.h"

FOUNDATION_EXPORT double IUIAUTOVersionNumber;
FOUNDATION_EXPORT const unsigned char IUIAUTOVersionString[];
