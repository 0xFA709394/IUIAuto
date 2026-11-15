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

#import "IUALogger.h"

static void (^gLogForwarder)(IUALogLevel level, NSString *message) = nil;
static NSLock *gLogLock = nil;
IUALogLevel IUALogConsoleLevel = IUALogLevelDebug;

static NSLock *IUALogLock(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ gLogLock = [[NSLock alloc] init]; });
    return gLogLock;
}

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
    [IUALogLock() lock];
    void (^forwarder)(IUALogLevel, NSString *) = [gLogForwarder copy];
    [IUALogLock() unlock];
    if (forwarder) {
        forwarder(level, message);
    }
}

void IUASetLogForwarder(void (^forwarder)(IUALogLevel level, NSString *message)) {
    [IUALogLock() lock];
    gLogForwarder = [forwarder copy];
    [IUALogLock() unlock];
}
