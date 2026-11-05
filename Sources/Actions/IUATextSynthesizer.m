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

#import "IUATextSynthesizer.h"
#import "IUAViewIntrospector.h"
#import "IUALogger.h"

static NSError *IUAError(NSString *text) {
    return [NSError errorWithDomain:@"IUATextSynthesizerErrorDomain" code:-1
                           userInfo:@{NSLocalizedDescriptionKey : text}];
}

#pragma mark - 当前 firstResponder 探测（sendAction:to:nil 会沿响应链路由到 firstResponder）

static UIResponder *gIUACapturedFirstResponder = nil;

@interface UIResponder (IUAFirstResponderCapture)
- (void)iua_captureFirstResponderViaChain:(id)sender;
@end

@implementation UIResponder (IUAFirstResponderCapture)

- (void)iua_captureFirstResponderViaChain:(id)sender {
    gIUACapturedFirstResponder = self;
}

@end

static UIResponder *IUACurrentFirstResponder(void) {
    gIUACapturedFirstResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(iua_captureFirstResponderViaChain:)
                                             to:nil from:nil forEvent:nil];
    return gIUACapturedFirstResponder;
}

#pragma mark - 定位输入目标

static UIResponder<UIKeyInput> * _Nullable IUALocateInput(NSString * _Nullable identifier, NSError **error) {
    if (identifier.length > 0) {
        UIView *view = [IUAViewIntrospector findViewWithIdentifier:identifier];
        if ([view isKindOfClass:[UIResponder class]] && [view conformsToProtocol:@protocol(UIKeyInput)]) {
            UIResponder<UIKeyInput> *input = (UIResponder<UIKeyInput> *)view;
            if (![input canBecomeFirstResponder]) {
                if (error) *error = IUAError([NSString stringWithFormat:@"view(%@) 无法成为 firstResponder", identifier]);
                return nil;
            }
            [input becomeFirstResponder];
            return input;
        }
        if (error) *error = IUAError([NSString stringWithFormat:@"找不到支持输入的 view: %@", identifier]);
        return nil;
    }

    // 未指定 identifier：要求当前 firstResponder 已支持输入
    UIResponder *first = IUACurrentFirstResponder();
    if ([first conformsToProtocol:@protocol(UIKeyInput)]) {
        return (UIResponder<UIKeyInput> *)first;
    }
    if (error) *error = IUAError(@"当前 firstResponder 不支持文本输入（可改用 identifier 定位输入框）");
    return nil;
}

@implementation IUATextSynthesizer

+ (nullable NSError *)typeText:(NSString *)text intoViewWithIdentifier:(nullable NSString *)identifier {
    if (text.length == 0) {
        return IUAError(@"text 为空");
    }
    NSError *error = nil;
    UIResponder<UIKeyInput> *input = IUALocateInput(identifier, &error);
    if (!input) {
        return error;
    }

    // 整段一次 insertText：仍走 UIKeyInput 真实路径（delegate 的
    // shouldChangeCharactersInRange 以整段 range 调用，语义一致），
    // 长文本从逐字符 O(n) 次 IPC 级开销降为一次（实测 5000 字 34s → 毫秒级）
    [input insertText:text];
    IUALogInfo(@"已输入 %lu 个字符（整段）", (unsigned long)text.length);
    return nil;
}

+ (nullable NSError *)clearTextInViewWithIdentifier:(nullable NSString *)identifier {
    NSError *error = nil;
    UIResponder<UIKeyInput> *input = IUALocateInput(identifier, &error);
    if (!input) {
        return error;
    }

    // 快速路径：UITextField/UITextView 直接置空 + 补发编辑事件（与系统编辑等价）
    if ([input isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)input;
        field.text = @"";
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        return nil;
    }
    if ([input isKindOfClass:[UITextView class]]) {
        UITextView *view = (UITextView *)input;
        view.text = @"";
        [view.delegate textViewDidChange:view];
        return nil;
    }

    // 兜底：通用 UIKeyInput 逐字删除
    NSUInteger guardCounter = 0;
    while ([input hasText] && guardCounter++ < 20000) {
        [input deleteBackward];
    }
    return nil;
}

@end
