//
//  IUAScreenshotService.h
//  IUIAuto
//
//  截图：对 keyWindow 做 drawViewHierarchy 快照，返回 base64 PNG
//  （App 进程内截自己窗口，公开 API，无需权限）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IUAScreenshotService : NSObject

/// 截取 keyWindow。
/// quality: 0 小（~0.3x 缩放）/ 1 中（~0.6x）/ >=2 原始分辨率。默认 1。
/// 返回 JSON: { image: <base64 PNG>, width, height, scale }
+ (nullable NSDictionary<NSString *, id> *)screenshotWithQuality:(NSUInteger)quality;

@end

NS_ASSUME_NONNULL_END
