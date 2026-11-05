#ifdef __OBJC__
#import <UIKit/UIKit.h>
#else
#ifndef FOUNDATION_EXPORT
#if defined(__cplusplus)
#define FOUNDATION_EXPORT extern "C"
#else
#define FOUNDATION_EXPORT extern
#endif
#endif
#endif

#import "IUAPerfSampler.h"
#import "IUARecorder.h"
#import "IUAScreenshotService.h"
#import "IUATextSynthesizer.h"
#import "IUATouchSynthesizer.h"
#import "IUAViewIntrospector.h"
#import "IUACommand.h"
#import "IUACommandDispatcher.h"
#import "IUACommandResult.h"
#import "IUAConfiguration.h"
#import "IUAEngine.h"
#import "IUALogger.h"
#import "IUAWebSocketClient.h"
#import "IUIAUTO.h"

FOUNDATION_EXPORT double IUIAUTOVersionNumber;
FOUNDATION_EXPORT const unsigned char IUIAUTOVersionString[];

