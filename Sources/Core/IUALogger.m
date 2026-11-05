//
//  IUALogger.m
//  IUIAuto
//

#import "IUALogger.h"

static void (^gLogForwarder)(IUALogLevel level, NSString *message) = nil;
IUALogLevel IUALogConsoleLevel = IUALogLevelDebug;

static NSString *IUALogLevelName(IUALogLevel level) {
    switch (level) {
        case IUALogLevelDebug: return @"DEBUG";
        case IUALogLevelInfo:  return @"INFO";
        case IUALogLevelWarn:  return @"WARN";
        case IUALogLevelError: return @"ERROR";
    }
}

void IUALog(IUALogLevel level, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (level >= IUALogConsoleLevel) {
        NSLog(@"[IUIAuto][%@] %@", IUALogLevelName(level), message);
    }
    if (gLogForwarder) {
        gLogForwarder(level, message);
    }
}

void IUASetLogForwarder(void (^forwarder)(IUALogLevel level, NSString *message)) {
    gLogForwarder = [forwarder copy];
}
