//
//  IUAScreenshotService.m
//  IUIAuto
//

#import "IUAScreenshotService.h"
#import "IUAViewIntrospector.h"
#import "IUALogger.h"

@implementation IUAScreenshotService

+ (nullable NSDictionary<NSString *, id> *)screenshotWithQuality:(NSUInteger)quality {
    UIWindow *window = [IUAViewIntrospector keyWindow];
    if (!window) {
        IUALogError(@"截图失败: 没有 keyWindow");
        return nil;
    }

    CGFloat scale = UIScreen.mainScreen.scale;
    if (quality == 0) {
        scale = MAX(scale * 0.3, 0.5);
    } else if (quality == 1) {
        scale = MAX(scale * 0.6, 1.0);
    } // quality >= 2: 原始分辨率

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                                         initWithSize:window.bounds.size format:format];

    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        // afterScreenUpdates:YES 保证拿到最新一帧（含进行中的动画）
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];

    NSData *pngData = UIImagePNGRepresentation(image);
    if (!pngData) {
        IUALogError(@"截图失败: PNG 编码失败");
        return nil;
    }
    NSString *base64 = [pngData base64EncodedStringWithOptions:0];
    return @{
        @"image" : base64,
        @"width" : @(image.size.width),
        @"height" : @(image.size.height),
        @"scale" : @(image.scale),
        @"bytes" : @(pngData.length),
    };
}

@end
