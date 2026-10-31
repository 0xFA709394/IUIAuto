//
//  IUACommandResult.m
//  IUIAuto
//

#import "IUACommandResult.h"
#import "IUALogger.h"

@implementation IUACommandResult

+ (instancetype)resultForCommand:(IUACommand *)command ok:(BOOL)ok
                            data:(nullable NSDictionary *)data
                       errorText:(nullable NSString *)errorText
                          elapsed:(NSTimeInterval)elapsed {
    IUACommandResult *result = [[self alloc] init];
    result.commandId = command.commandId;
    result.ok = ok;
    result.data = data ?: @{};
    result.errorMessage = errorText;
    result.elapsed = elapsed;
    return result;
}

- (NSDictionary<NSString *, id> *)jsonDictionary {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"type"] = @"result";
    dict[@"id"] = self.commandId ?: @"";
    dict[@"ok"] = @(self.ok);
    dict[@"data"] = self.data ?: @{};
    dict[@"error"] = self.errorMessage ?: [NSNull null];
    dict[@"elapsed"] = @(round(self.elapsed * 1000.0) / 1000.0);
    return dict;
}

- (nullable NSData *)JSONData {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.jsonDictionary
                                                   options:0
                                                     error:&error];
    if (!data) {
        IUALogError(@"结果序列化失败: %@", error.localizedDescription);
    }
    return data;
}

@end
