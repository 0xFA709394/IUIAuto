//
//  IUACommandResult.h
//  IUIAuto
//
//  指令执行结果，序列化为 JSON 回传：
//  {
//    "type":    "result",
//    "id":      "cmd-42",
//    "ok":      true,
//    "data":    { ... },
//    "error":   null,
//    "elapsed": 0.18
//  }
//

#import <Foundation/Foundation.h>
#import "IUACommand.h"

NS_ASSUME_NONNULL_BEGIN

@interface IUACommandResult : NSObject

@property (nonatomic, copy) NSString *commandId;
@property (nonatomic, assign) BOOL ok;
@property (nonatomic, strong, nullable) NSDictionary<NSString *, id> *data;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@property (nonatomic, assign) NSTimeInterval elapsed;

+ (instancetype)resultForCommand:(IUACommand *)command ok:(BOOL)ok
                            data:(nullable NSDictionary *)data
                       errorText:(nullable NSString *)errorText
                          elapsed:(NSTimeInterval)elapsed;

- (NSDictionary<NSString *, id> *)jsonDictionary;
- (nullable NSData *)JSONData;

@end

NS_ASSUME_NONNULL_END
