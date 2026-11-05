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

#import "IUAEngine.h"
#import "IUAConfiguration.h"
#import "IUALogger.h"
#import "IUACommandDispatcher.h"
#import "IUATouchSynthesizer.h"
#import "IUARecorder.h"
#import "IUAPerfSampler.h"
#import "IUIAUTO.h"

FOUNDATION_EXPORT double IUIAUTOVersionNumber;
FOUNDATION_EXPORT const unsigned char IUIAUTOVersionString[];

