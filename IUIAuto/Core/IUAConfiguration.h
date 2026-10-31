//
//  IUAConfiguration.h
//  IUIAuto
//
//  运行配置：服务器地址（UserDefaults 持久化，Demo 页可改）、心跳/重连参数
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const IUAConfigurationServerURLKey;

@interface IUAConfiguration : NSObject

/// 当前服务器 WebSocket 地址，如 ws://192.168.1.10:9800/ws
/// 优先级：UserDefaults > 默认值 ws://127.0.0.1:9800/ws（模拟器本机调试用）
+ (NSURL *)serverURL;
+ (NSString *)serverURLString;

/// 保存服务器地址到 UserDefaults
+ (void)setServerURLString:(NSString *)urlString;

/// 心跳间隔（秒），0 表示关闭心跳
+ (NSTimeInterval)heartbeatInterval;

/// 重连退避：最小/最大间隔（秒）
+ (NSTimeInterval)reconnectMinInterval;
+ (NSTimeInterval)reconnectMaxInterval;

/// 单条指令默认超时（秒）
+ (NSTimeInterval)defaultCommandTimeout;

/// 指令超时上限（秒）
+ (NSTimeInterval)maxCommandTimeout;

/// 协议/Agent 版本号
+ (NSString *)agentVersion;

@end

NS_ASSUME_NONNULL_END
