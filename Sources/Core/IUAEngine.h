//
//  IUAEngine.h
//  IUIAuto
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

@end

NS_ASSUME_NONNULL_END
