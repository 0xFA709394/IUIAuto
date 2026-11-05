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
//  轻量日志：控制台输出 + 可选转发回调（IUAEngine 用它把日志上报到控制服务器）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, IUALogLevel) {
    IUALogLevelDebug = 0,
    IUALogLevelInfo  = 1,
    IUALogLevelWarn  = 2,
    IUALogLevelError = 3,
};

/// 输出一条日志；format 为 NSString 格式串
void IUALog(IUALogLevel level, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);

/// 注册日志转发回调（传 nil 取消）。回调可能在任意线程触发。
void IUASetLogForwarder(void (^ _Nullable forwarder)(IUALogLevel level, NSString *message));

/// 控制台输出的最低级别，默认 Debug
FOUNDATION_EXPORT IUALogLevel IUALogConsoleLevel;

#define IUALogDebug(fmt, ...) IUALog(IUALogLevelDebug, fmt, ##__VA_ARGS__)
#define IUALogInfo(fmt, ...)  IUALog(IUALogLevelInfo,  fmt, ##__VA_ARGS__)
#define IUALogWarn(fmt, ...)  IUALog(IUALogLevelWarn,  fmt, ##__VA_ARGS__)
#define IUALogError(fmt, ...) IUALog(IUALogLevelError, fmt, ##__VA_ARGS__)

NS_ASSUME_NONNULL_END
