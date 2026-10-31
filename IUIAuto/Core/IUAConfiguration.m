//
//  IUAConfiguration.m
//  IUIAuto
//

#import "IUAConfiguration.h"

NSString *const IUAConfigurationServerURLKey = @"IUAConfigurationServerURLKey";

static NSString *const kDefaultServerURL = @"ws://127.0.0.1:9800/ws";

@implementation IUAConfiguration

+ (NSString *)serverURLString {
    NSString *saved = [[NSUserDefaults standardUserDefaults] stringForKey:IUAConfigurationServerURLKey];
    if (saved.length > 0) {
        return saved;
    }
    return kDefaultServerURL;
}

+ (NSURL *)serverURL {
    return [NSURL URLWithString:[self serverURLString]];
}

+ (void)setServerURLString:(NSString *)urlString {
    if (urlString.length == 0) {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:IUAConfigurationServerURLKey];
    } else {
        [[NSUserDefaults standardUserDefaults] setObject:urlString forKey:IUAConfigurationServerURLKey];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSTimeInterval)heartbeatInterval {
    return 20.0;
}

+ (NSTimeInterval)reconnectMinInterval {
    return 1.0;
}

+ (NSTimeInterval)reconnectMaxInterval {
    return 30.0;
}

+ (NSTimeInterval)defaultCommandTimeout {
    return 10.0;
}

+ (NSTimeInterval)maxCommandTimeout {
    return 120.0;
}

+ (NSString *)agentVersion {
    return @"1.0.0";
}

@end
