//
//  IUAWebSocketClient.h
//  IUIAuto
//
//  通信层：基于 NSURLSessionWebSocketTask（iOS 13+，系统自带，零第三方依赖）
//  - 自动重连（指数退避 1s → 30s）
//  - 心跳 ping（间隔见 IUAConfiguration）
//  - JSON 文本帧收发
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class IUAWebSocketClient;

@protocol IUAWebSocketClientDelegate <NSObject>
/// 连接已建立（握手完成）
- (void)webSocketDidOpen:(IUAWebSocketClient *)client;
/// 收到一条 JSON 消息（无法解析为 JSON 的帧会被忽略并记日志）
- (void)webSocket:(IUAWebSocketClient *)client didReceiveJSON:(NSDictionary<NSString *, id> *)json;
/// 连接断开/失败。reconnectScheduled 表示是否已安排自动重连
- (void)webSocket:(IUAWebSocketClient *)client didCloseWithError:(nullable NSError *)error reconnectScheduled:(BOOL)reconnectScheduled;
@optional
/// 主动断开（调用 disconnect）后触发
- (void)webSocketDidDisconnectManually:(IUAWebSocketClient *)client;
@end

@interface IUAWebSocketClient : NSObject

@property (nonatomic, weak, nullable) id<IUAWebSocketClientDelegate> delegate;
@property (nonatomic, readonly) NSURL *URL;
@property (nonatomic, readonly, getter=isConnected) BOOL connected;

- (instancetype)initWithURL:(NSURL *)URL NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// 开始连接（内部带重连状态机；重复调用安全）
- (void)connect;
/// 主动断开，不再自动重连
- (void)disconnect;

/// 发送 JSON（成功返回 YES；未连接或发送失败返回 NO）
- (BOOL)sendJSON:(NSDictionary<NSString *, id> *)json;

@end

NS_ASSUME_NONNULL_END
