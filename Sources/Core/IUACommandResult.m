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
