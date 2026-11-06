//
//  IUAScreenshotService_compare.m
//  IUIAUTO
//
//  screenshot_compare 的像素对比实现（独立文件避免主文件膨胀）
//

#import "IUAScreenshotService.h"
#import "IUAViewIntrospector.h"
#import "IUALogger.h"

@implementation IUAScreenshotService (Compare)

+ (nullable NSDictionary<NSString *, id> *)compareWithBaselineBase64:(NSString *)baselineBase64
                                                    thresholdPercent:(CGFloat)threshold {
    UIWindow *window = [IUAViewIntrospector keyWindow];
    if (!window) {
        return nil;
    }

    // 当前截图（原始分辨率）
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = UIScreen.mainScreen.scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:window.bounds.size format:format];
    UIImage *current = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [window drawViewHierarchyInRect:window.bounds afterScreenUpdates:YES];
    }];

    NSData *baselineData = [[NSData alloc] initWithBase64EncodedString:baselineBase64 options:0];
    UIImage *baseline = baselineData ? [UIImage imageWithData:baselineData] : nil;
    if (!baseline) {
        IUALogError(@"对比失败: 基线图无法解码");
        return nil;
    }

    CGImageRef cgCurrent = current.CGImage;
    CGImageRef cgBaseline = baseline.CGImage;
    if (!cgCurrent || !cgBaseline) {
        return nil;
    }

    size_t cw = CGImageGetWidth(cgCurrent), ch = CGImageGetHeight(cgCurrent);
    size_t bw = CGImageGetWidth(cgBaseline), bh = CGImageGetHeight(cgBaseline);
    if (cw != bw || ch != bh) {
        return @{@"sizeMismatch" : @YES,
                 @"current" : @{@"width" : @(cw), @"height" : @(ch)},
                 @"baseline" : @{@"width" : @(bw), @"height" : @(bh)}};
    }

    // 逐像素对比（RGBA8888；任一通道差 > 24 视为差异像素——抗压缩噪声）
    static const size_t kBytesPerPixel = 4;
    static const uint8_t kChannelTolerance = 24;
    size_t bytesPerRow = cw * kBytesPerPixel;
    NSMutableData *curBuf = [NSMutableData dataWithLength:bytesPerRow * ch];
    NSMutableData *baseBuf = [NSMutableData dataWithLength:bytesPerRow * ch];
    // 两图必须绘制到同一色彩空间（sRGB）的上下文：基线 PNG 可能是 Display P3 等，
    // 各用各的 colorSpace 会导致同一颜色字节完全不同 → 差异虚高（实测同屏 99%+）
    CGColorSpaceRef rgbSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctxC = CGBitmapContextCreate(curBuf.mutableBytes, cw, ch, 8, bytesPerRow,
                            rgbSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGContextRef ctxB = CGBitmapContextCreate(baseBuf.mutableBytes, cw, ch, 8, bytesPerRow,
                            rgbSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(rgbSpace);
    CGContextDrawImage(ctxC, CGRectMake(0, 0, cw, ch), cgCurrent);
    CGContextDrawImage(ctxB, CGRectMake(0, 0, cw, ch), cgBaseline);
    CGContextRelease(ctxC);
    CGContextRelease(ctxB);

    const uint8_t *pCur = curBuf.bytes;
    const uint8_t *pBase = baseBuf.bytes;
    size_t totalPixels = cw * ch;
    size_t diffPixels = 0;
    for (size_t i = 0; i < totalPixels; i++) {
        const uint8_t *c = pCur + i * kBytesPerPixel;
        const uint8_t *b = pBase + i * kBytesPerPixel;
        if (abs((int)c[0] - (int)b[0]) > kChannelTolerance ||
            abs((int)c[1] - (int)b[1]) > kChannelTolerance ||
            abs((int)c[2] - (int)b[2]) > kChannelTolerance) {
            diffPixels++;
        }
    }

    double diffPercent = (double)diffPixels / (double)totalPixels * 100.0;
    BOOL pass = diffPercent <= (double)threshold;
    return @{
        @"pass" : @(pass),
        @"diffPercent" : @(round(diffPercent * 1000) / 1000),
        @"diffPixels" : @(diffPixels),
        @"totalPixels" : @(totalPixels),
        @"thresholdPercent" : @(threshold),
        @"width" : @(cw),
        @"height" : @(ch),
    };
}

@end
