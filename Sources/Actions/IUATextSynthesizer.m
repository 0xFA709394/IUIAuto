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
//  主路径与真实键盘同源（UIKeyInput insertText:），并针对高版本 iOS（16+）
//  真机的时序差异做多层保障：
//    1. becomeFirstResponder 失败自动重试（等待视图 layout/窗口就绪，最多 ~1.5s）
//    2. 成为 responder 后等键盘/输入会话激活（0.1s）再插入
//    3. 插入后回读校验；未生效（delegate 拦截 / 输入法 marked text 干扰）时
//       降级为直赋 text + 补发编辑事件（与系统编辑通知等价）
//    4. 焦点始终拿不到时直接走直赋兜底，不再报"无法成为 firstResponder"
//

#import "IUATextSynthesizer.h"
#import "IUAViewIntrospector.h"
#import "IUALogger.h"

static NSString *const kIUAInputErrorDomain = @"IUATextSynthesizerErrorDomain";

static NSError *IUAError(NSString *text) {
    return [NSError errorWithDomain:kIUAInputErrorDomain code:-1
                           userInfo:@{NSLocalizedDescriptionKey : text}];
}

/// 读输入目标当前全文（UITextField/UITextView；其他返回 nil）
static NSString *IUAReadText(UIResponder<UIKeyInput> *input) {
    if ([input isKindOfClass:[UITextField class]]) {
        return ((UITextField *)input).text ?: @"";
    }
    if ([input isKindOfClass:[UITextView class]]) {
        return ((UITextView *)input).text ?: @"";
    }
    return nil;
}

/// 兜底直赋：设置全文并补发编辑事件（与系统编辑通知等价）。
/// 返回 NO 表示目标不是 UITextField/UITextView（无法直赋）。
static BOOL IUASetTextDirectly(UIResponder<UIKeyInput> *input, NSString *newText) {
    if ([input isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)input;
        field.text = newText;
        [field sendActionsForControlEvents:UIControlEventEditingChanged];
        return YES;
    }
    if ([input isKindOfClass:[UITextView class]]) {
        UITextView *view = (UITextView *)input;
        view.text = newText;
        // delegate 为 nil 时消息发 nil 安全
        [view.delegate textViewDidChange:view];
        return YES;
    }
    return NO;
}

#pragma mark - 当前 firstResponder 探测（sendAction:to:nil 沿响应链路由到 firstResponder）

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

static UIResponder<UIKeyInput> * _Nullable IUAInputForView(UIView *view, NSError **error) {
    if ([view isKindOfClass:[UIResponder class]] && [view conformsToProtocol:@protocol(UIKeyInput)]) {
        return (UIResponder<UIKeyInput> *)view;
    }
    if (error) *error = IUAError([NSString stringWithFormat:@"元素不支持文本输入: %@", view]);
    return nil;
}

static UIResponder<UIKeyInput> * _Nullable IUALocateInput(NSString * _Nullable identifier, NSError **error) {
    if (identifier.length > 0) {
        UIView *view = [IUAViewIntrospector findViewWithIdentifier:identifier];
        if (view) return IUAInputForView(view, error);
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

- (void)typeText:(NSString *)text
    intoViewWithIdentifier:(nullable NSString *)identifier
                completion:(void (^)(NSError * _Nullable))completion {
    NSAssert([NSThread isMainThread], @"typeText 必须在主线程");

    if (text.length == 0) {
        completion(IUAError(@"text 为空"));
        return;
    }
    NSError *locateError = nil;
    UIResponder<UIKeyInput> *input = IUALocateInput(identifier, &locateError);
    if (!input) {
        completion(locateError);
        return;
    }
    [self typeText:text intoInput:input completion:completion];
}

- (void)typeText:(NSString *)text
        intoView:(UIView *)view
      completion:(void (^)(NSError * _Nullable))completion {
    NSAssert([NSThread isMainThread], @"typeText 必须在主线程");
    if (text.length == 0) {
        completion(IUAError(@"text 为空"));
        return;
    }
    NSError *locateError = nil;
    UIResponder<UIKeyInput> *input = IUAInputForView(view, &locateError);
    if (!input) {
        completion(locateError);
        return;
    }
    [self typeText:text intoInput:input completion:completion];
}

- (void)typeText:(NSString *)text
       intoInput:(UIResponder<UIKeyInput> *)input
      completion:(void (^)(NSError * _Nullable))completion {
    NSString *expectedFull = [(IUAReadText(input) ?: @"") stringByAppendingString:text];

    // 焦点就绪（重试等待 layout）→ 键盘激活等待 → 插入 → 回读校验 → 兜底
    [self acquireFocus:input attempt:0 completion:^(BOOL focused) {
        if (focused) {
            // 等键盘/输入会话激活：高版本真机 becomeFirstResponder 成功后立刻
            // insertText 偶发被吞，等一拍后稳定
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                // 主路径：整段 insertText（UIKeyInput 真实键盘路径，delegate 校验
                // 语义一致；长文本整段一次，性能毫秒级）
                [input insertText:text];

                NSString *now = IUAReadText(input);
                if (now != nil && ![now isEqualToString:expectedFull]) {
                    // 高版本真机已知坑：键盘会话未完全激活/输入法 marked text 干扰/
                    // delegate 拦截导致 insertText 未生效 → 直赋兜底并补发编辑事件
                    IUALogWarn(@"insertText 未生效（实际=\"%@\" 期望=\"%@\"），降级直赋", now, expectedFull);
                    if (!IUASetTextDirectly(input, expectedFull)) {
                        completion(IUAError(@"输入未生效且目标不支持直赋兜底"));
                        return;
                    }
                }
                IUALogInfo(@"已输入 %lu 个字符（焦点路径=%@）", (unsigned long)text.length, focused ? @"键盘" : @"直赋");
                completion(nil);
            });   // 结束 dispatch_after block
        } else {
            // 焦点拿不到（视图未就绪/只读态等）：不报错，直接直赋兜底
            IUALogWarn(@"无法获得焦点（%@），使用直赋路径", NSStringFromClass(input.class));
            if (IUASetTextDirectly(input, expectedFull)) {
                completion(nil);
            } else {
                completion(IUAError(@"目标无法获得焦点且不支持直赋（非 UITextField/UITextView）"));
            }
        }
    }];
}

- (void)clearTextInViewWithIdentifier:(nullable NSString *)identifier
                           completion:(void (^)(NSError * _Nullable))completion {
    NSAssert([NSThread isMainThread], @"clearText 必须在主线程");

    NSError *locateError = nil;
    UIResponder<UIKeyInput> *input = IUALocateInput(identifier, &locateError);
    if (!input) {
        completion(locateError);
        return;
    }
    [self clearTextInInput:input completion:completion];
}

- (void)clearTextInView:(UIView *)view
             completion:(void (^)(NSError * _Nullable))completion {
    NSAssert([NSThread isMainThread], @"clearText 必须在主线程");
    NSError *locateError = nil;
    UIResponder<UIKeyInput> *input = IUAInputForView(view, &locateError);
    if (!input) {
        completion(locateError);
        return;
    }
    [self clearTextInInput:input completion:completion];
}

- (void)clearTextInInput:(UIResponder<UIKeyInput> *)input
              completion:(void (^)(NSError * _Nullable))completion {
    NSString *original = IUAReadText(input);
    if (original != nil && original.length == 0) {
        completion(nil);   // 已为空，幂等成功
        return;
    }

    // 快速路径：直赋空串 + 补发编辑事件（与系统编辑等价，无键盘依赖）
    if (IUASetTextDirectly(input, @"")) {
        completion(nil);
        return;
    }

    // 兜底：通用 UIKeyInput 逐字删除（需要焦点）
    [self acquireFocus:input attempt:0 completion:^(BOOL focused) {
        if (!focused) {
            completion(IUAError(@"清空失败：目标无法获得焦点且不支持直赋"));
            return;
        }
        NSUInteger guardCounter = 0;
        while ([input hasText] && guardCounter++ < 20000) {
            [input deleteBackward];
        }
        completion(nil);
    }];
}

#pragma mark - 焦点获取（带重试）

/// becomeFirstResponder 失败自动重试（0.15s × 最多 10 次 ≈ 1.5s）：
/// 高版本真机在视图刚 layout/窗口刚就绪时首次调用常返回 NO，稍后即成功
- (void)acquireFocus:(UIResponder<UIKeyInput> *)input
             attempt:(NSUInteger)attempt
           completion:(void (^)(BOOL focused))completion {
    if ([input isFirstResponder]) {
        completion(YES);
        return;
    }
    if ([input canBecomeFirstResponder] && [input becomeFirstResponder]) {
        completion(YES);
        return;
    }
    if (attempt + 1 < 10) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [self acquireFocus:input attempt:attempt + 1 completion:completion];
        });
        return;
    }
    completion(NO);
}

@end
