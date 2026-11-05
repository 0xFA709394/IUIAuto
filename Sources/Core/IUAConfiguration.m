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
    // 上限 10s：控制端工具的等待窗口通常 15~20s，
    // 30s 退避会与"server 后启动"场景完美错开（实测漏连）
    return 10.0;
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
