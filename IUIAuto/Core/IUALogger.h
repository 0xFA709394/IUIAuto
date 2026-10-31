//
//  IUALogger.h
//  IUIAuto
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
