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
//  总控：WebSocket 客户端 + 指令调度器 + 动作处理器的组装与消息路由
//
//  上行消息（App → 服务器）：
//    {"type":"hello", ...}      连接建立后的自描述
//    {"type":"result", ...}     指令执行结果（见 IUACommandResult）
//    {"type":"pong"}            应答服务器的 {"type":"ping"}
//    {"type":"log", ...}        日志转发（Info 级以上）
//    {"type":"event", ...}      连接状态事件
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 连接状态变化通知，userInfo: { @"connected": NSNumber }
extern NSString *const IUAEngineConnectionDidChangeNotification;

@interface IUAEngine : NSObject

+ (instancetype)sharedEngine;

/// 使用配置中的服务器地址启动 Agent（重复调用会先停止旧连接）
- (void)start;

/// 以指定服务器地址启动（同时保存到配置）；传 nil 则沿用已保存地址
- (void)startWithServerURLString:(nullable NSString *)urlString;

/// 停止 Agent 并断开连接
- (void)stop;

@property (nonatomic, readonly, getter=isConnected) BOOL connected;
@property (nonatomic, readonly) NSString *currentServerURLString;
/// 已注册的动作列表
@property (nonatomic, readonly) NSArray<NSString *> *registeredActions;

/// 便捷入口：从当前 keyWindow 顶层控制器模态打开「调试服务端配置页」
+ (void)presentConfigPage;

@end

NS_ASSUME_NONNULL_END
