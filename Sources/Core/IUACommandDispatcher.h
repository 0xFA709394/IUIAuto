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
