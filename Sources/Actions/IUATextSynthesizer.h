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
//  文本输入合成（高版本 iOS 健壮版）
//
//  主路径与真实键盘同源（UIResponder<UIKeyInput> 的 insertText:），
//  并针对高版本 iOS（16+）真机时序做了多层保障：
//    1. becomeFirstResponder 失败自动重试（等待视图 layout 完成，最多 ~1.5s）
//    2. 成为 responder 后等待键盘/输入会话激活再插入
//    3. 插入后回读校验；未生效（delegate 拦截/输入法 marked text 干扰）时
//       降级为直接设置 text 属性 + 补发编辑事件
//    4. 焦点始终拿不到时直接走直赋兜底，不再报"无法成为 firstResponder"
//
//  全部接口异步完成（completion 在主线程回调）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IUATextSynthesizer : NSObject

/// 向指定输入框输入文本。
/// identifier 为空时输入到当前 firstResponder；文本中 \n 表示回车。
- (void)typeText:(NSString *)text
    intoViewWithIdentifier:(nullable NSString *)identifier
                completion:(void (^)(NSError * _Nullable error))completion;

/// 清空指定输入框。
- (void)clearTextInViewWithIdentifier:(nullable NSString *)identifier
                           completion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
