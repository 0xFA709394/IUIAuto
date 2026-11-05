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
//  文本输入合成：走 UIResponder<UIKeyInput> 公开协议（insertText:/deleteBackward:）
//  与真实键盘输入同路径，会正常触发 delegate 校验与 UIControl 编辑事件
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IUATextSynthesizer : NSObject

/// 向指定输入框输入文本。
/// identifier 为空时输入到当前 firstResponder；文本中 \n 表示回车。
/// 返回 nil 表示成功，否则为错误描述。
+ (nullable NSError *)typeText:(NSString *)text
          intoViewWithIdentifier:(nullable NSString *)identifier;

/// 清空指定输入框（deleteBackward 逐字符删除，与真实退格同路径）
+ (nullable NSError *)clearTextInViewWithIdentifier:(nullable NSString *)identifier;

@end

NS_ASSUME_NONNULL_END
