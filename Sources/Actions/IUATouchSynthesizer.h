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
//  触控合成器：在本 App 进程内合成 UITouch 事件并派发到目标 view 及其手势识别器
//  （KIF 框架验证过的路线，无需 XCUITest、无需私有 entitlement）
//
//  原理：
//  1. 通过 UITouch 私有 setter（运行时探测候选方法名，兼容不同 iOS 版本）写入
//     真实的 location/phase/timestamp/view ivar
//  2. 自定义 UIEvent 子类包装 touches，对 hitTest 命中的 view 及其父链上的
//     所有 gestureRecognizer 派发 touchesBegan/Moved/Ended
//  3. 时间推进用 dispatch_after（主 runloop 保持活动，识别器内部定时器正常工作）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IUATouchCompletion)(NSError * _Nullable error);

FOUNDATION_EXPORT NSString *const IUATouchSynthesizerErrorDomain;

@interface IUATouchSynthesizer : NSObject

+ (instancetype)shared;

/// 单击/连击。tapCount=1 单击，=2 双击（第二次 touch 的 tapCount 记为 2）
- (void)tapAtPoint:(CGPoint)point           // window 逻辑坐标
          tapCount:(NSUInteger)tapCount
        completion:(nullable IUATouchCompletion)completion;

/// 长按（按下 → 保持 duration 秒 → 抬起）
- (void)longPressAtPoint:(CGPoint)point
                 duration:(NSTimeInterval)duration
               completion:(nullable IUATouchCompletion)completion;

/// 滑动（线性插值步进 moved）
- (void)swipeFromPoint:(CGPoint)from
               toPoint:(CGPoint)to
               duration:(NSTimeInterval)duration
             completion:(nullable IUATouchCompletion)completion;

/// 双指捏合（半径收拢/扩张）
- (void)pinchAtCenter:(CGPoint)center
           fromRadius:(CGFloat)startRadius
             toRadius:(CGFloat)endRadius
              duration:(NSTimeInterval)duration
            completion:(nullable IUATouchCompletion)completion;

/// 探测当前运行时是否支持触控合成（所有必需的私有 setter 均可用）
+ (BOOL)isSupported;

@end

NS_ASSUME_NONNULL_END
