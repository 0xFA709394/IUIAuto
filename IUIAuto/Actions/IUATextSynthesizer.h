//
//  IUATextSynthesizer.h
//  IUIAuto
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
