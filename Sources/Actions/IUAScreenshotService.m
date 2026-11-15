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

+ (nullable NSDictionary<NSString *, id> *)screenshotOfView:(UIView *)view quality:(NSUInteger)quality {
    if (!view || CGRectIsEmpty(view.bounds)) {
        IUALogError(@"元素截图失败: view 为空或尺寸为 0");
        return nil;
    }
    CGFloat scale = UIScreen.mainScreen.scale;
    if (quality == 0) {
        scale = MAX(scale * 0.3, 0.5);
    } else if (quality == 1) {
        scale = MAX(scale * 0.6, 1.0);
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc]
                                         initWithSize:view.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
        // 优先走视图层级快照；部分自定义 layer 不响应时退回 renderInContext
        BOOL drawn = [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
        if (!drawn) {
            [view.layer renderInContext:context.CGContext];
        }
    }];

    NSData *pngData = UIImagePNGRepresentation(image);
    if (!pngData) {
        IUALogError(@"元素截图失败: PNG 编码失败");
        return nil;
    }
    return @{
        @"image" : [pngData base64EncodedStringWithOptions:0],
        @"width" : @(image.size.width),
        @"height" : @(image.size.height),
        @"scale" : @(image.scale),
        @"bytes" : @(pngData.length),
    };
}

@end
