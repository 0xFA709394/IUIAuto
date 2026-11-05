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
//  指令模型：控制服务器下发的单条操作指令
//
//  请求格式（JSON）：
//  {
//    "id":      "cmd-42",              // 必填，指令唯一标识，结果原样带回
//    "action":  "tap",                 // 必填，动作名（tap/swipe/type_text/...）
//    "params":  { "x": 100, "y": 200 },// 可选，动作参数
//    "timeout": 10                     // 可选，超时秒数，默认 10s
//  }
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface IUACommand : NSObject

@property (nonatomic, copy) NSString *commandId;
@property (nonatomic, copy) NSString *action;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, id> *params;
@property (nonatomic, assign) NSTimeInterval timeout;

/// 从 JSON 字典解析指令；缺少 id/action 或格式非法时返回 nil 并填充 error
+ (nullable instancetype)commandWithJSONObject:(id)jsonObject error:(NSError **)error;

/// 参数读取便捷方法（缺省时返回 defaultObject）
- (id)paramForKey:(NSString *)key default:(nullable id)defaultObject;
- (CGFloat)floatParam:(NSString *)key default:(CGFloat)defaultValue;
- (NSInteger)integerParam:(NSString *)key default:(NSInteger)defaultValue;
- (NSString * _Nullable)stringParam:(NSString *)key;

@end

/// 指令域错误码
FOUNDATION_EXPORT NSErrorDomain const IUACommandErrorDomain;

NS_ASSUME_NONNULL_END
