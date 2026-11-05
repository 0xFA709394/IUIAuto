//
//  IUACommandDispatcher.h
//  IUIAuto
//
//  调度层：指令 → 动作处理器
//  - 主线程串行 FIFO（UI 操作必须在主线程且有序执行）
//  - 单条指令超时控制，超时/完成先到先得，迟到结果丢弃
//

#import <Foundation/Foundation.h>
#import "IUACommand.h"
#import "IUACommandResult.h"

NS_ASSUME_NONNULL_BEGIN

/// 动作处理器：执行完毕必须调用 complete（恰好一次），否则由超时兜底
typedef void (^IUAActionHandler)(IUACommand *command,
                                 void (^complete)(BOOL ok, NSDictionary<NSString *, id> * _Nullable data,
                                                  NSString * _Nullable errorMessage));

@interface IUACommandDispatcher : NSObject

/// 注册动作处理器（同名覆盖）
- (void)registerHandler:(NSString *)action handler:(IUAActionHandler)handler;
/// 已注册的动作名列表
- (NSArray<NSString *> *)registeredActions;

/// 派发一条指令；completion 恰好回调一次（主线程）
- (void)dispatchCommand:(IUACommand *)command completion:(void (^)(IUACommandResult *result))completion;

@end

NS_ASSUME_NONNULL_END
