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

/// 校验服务器地址：必须是绝对 ws:// 或 wss:// URL 且 host 非空
+ (BOOL)isValidServerURLString:(NSString *)urlString;

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
