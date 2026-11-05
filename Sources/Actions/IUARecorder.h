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
//  操作录制器：捕获真实手指或合成触控在本 App 内的操作，生成可回放脚本步骤
//
//  原理：
//  1. method swizzle UIView touchesBegan/Ended/Cancelled —— 无论事件来自真实手指
//     还是 IUATouchSynthesizer 的合成派发，view 的 touchesXxx 回调都会经过这里
//  2. 监听 UITextField/UITextView 文本变更通知记录输入
//  3. tap/long_press/swipe 按位移与时长自动判定；控件有 accessibilityIdentifier
//     时步骤语义化（可移植），否则回退坐标
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 录制状态变化通知（start/stop/cancel），userInfo: { @"recording": NSNumber }
extern NSString *const IUARecorderStateDidChangeNotification;

/// 单个录制步骤（字典）：
///   tap:        { action:tap, identifier?, x, y, tapCount }
///   long_press: { action:long_press, identifier?, x, y, duration }
///   swipe:      { action:swipe, identifier?, fromX, fromY, toX, toY }
///   type_text:  { action:type_text|clear_text, identifier, text }

@interface IUARecorder : NSObject

+ (instancetype)shared;

/// 事件捕获入口：真实事件在 UIWindow sendEvent 交换点调用，
/// 合成事件在 IUATouchSynthesizer 派发点调用（两条路径互斥，不会重复记录）
+ (void)noteEvent:(UIEvent *)event;

@property (nonatomic, readonly, getter=isRecording) BOOL recording;
/// 已录制的步骤数
@property (nonatomic, readonly) NSUInteger stepCount;

- (void)startRecording;
/// 停止并返回步骤列表；未在录制时返回 nil
- (nullable NSArray<NSDictionary<NSString *, id> *> *)stopRecording;
/// 丢弃录制内容并停止
- (void)cancelRecording;

@end

NS_ASSUME_NONNULL_END
