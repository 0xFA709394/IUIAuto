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
