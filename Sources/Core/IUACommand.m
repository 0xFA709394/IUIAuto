//
//  IUACommand.m
//  IUIAuto
//

#import "IUACommand.h"
#import "IUAConfiguration.h"

NSErrorDomain const IUACommandErrorDomain = @"IUACommandErrorDomain";

@implementation IUACommand

+ (nullable instancetype)commandWithJSONObject:(id)jsonObject error:(NSError **)error {
    if (![jsonObject isKindOfClass:[NSDictionary class]]) {
        if (error) {
            *error = [NSError errorWithDomain:IUACommandErrorDomain code:-1
                                     userInfo:@{NSLocalizedDescriptionKey : @"指令必须是 JSON 对象"}];
        }
        return nil;
    }
    NSDictionary *dict = (NSDictionary *)jsonObject;

    NSString *commandId = dict[@"id"];
    NSString *action = dict[@"action"];
    if (![commandId isKindOfClass:[NSString class]] || commandId.length == 0 ||
        ![action isKindOfClass:[NSString class]] || action.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:IUACommandErrorDomain code:-2
                                     userInfo:@{NSLocalizedDescriptionKey : @"指令缺少 id 或 action 字段"}];
        }
        return nil;
    }

    IUACommand *command = [[self alloc] init];
    command.commandId = commandId;
    command.action = action;
    if ([dict[@"params"] isKindOfClass:[NSDictionary class]]) {
        command.params = dict[@"params"];
    }
    if ([dict[@"timeout"] isKindOfClass:[NSNumber class]]) {
        command.timeout = MIN(MAX([(NSNumber *)dict[@"timeout"] doubleValue], 0.1),
                              [IUAConfiguration maxCommandTimeout]);
    } else {
        command.timeout = [IUAConfiguration defaultCommandTimeout];
    }
    return command;
}

- (id)paramForKey:(NSString *)key default:(nullable id)defaultObject {
    id value = self.params[key];
    return (value == nil || value == [NSNull null]) ? defaultObject : value;
}

- (CGFloat)floatParam:(NSString *)key default:(CGFloat)defaultValue {
    id value = [self paramForKey:key default:nil];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value floatValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value floatValue];
    }
    return defaultValue;
}

- (NSInteger)integerParam:(NSString *)key default:(NSInteger)defaultValue {
    id value = [self paramForKey:key default:nil];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)value integerValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value integerValue];
    }
    return defaultValue;
}

- (NSString * _Nullable)stringParam:(NSString *)key {
    id value = [self paramForKey:key default:nil];
    if ([value isKindOfClass:[NSString class]]) {
        return (NSString *)value;
    }
    return nil;
}

@end
