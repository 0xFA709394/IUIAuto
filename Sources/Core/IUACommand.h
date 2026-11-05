//
//  IUACommand.h
//  IUIAuto
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
