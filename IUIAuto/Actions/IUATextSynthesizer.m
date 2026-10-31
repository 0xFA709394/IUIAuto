//
//  IUATextSynthesizer.m
//  IUIAuto
//

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

    // 逐字符 insertText：与真实键盘同路径，delegate 的 shouldChangeCharactersInRange 正常工作
    for (NSUInteger i = 0; i < text.length; i++) {
        NSString *character = [text substringWithRange:NSMakeRange(i, 1)];
        [input insertText:character];
    }
    IUALogInfo(@"已输入 %lu 个字符", (unsigned long)text.length);
    return nil;
}

+ (nullable NSError *)clearTextInViewWithIdentifier:(nullable NSString *)identifier {
    NSError *error = nil;
    UIResponder<UIKeyInput> *input = IUALocateInput(identifier, &error);
    if (!input) {
        return error;
    }
    NSUInteger guardCounter = 0;
    while ([input hasText] && guardCounter++ < 10000) {
        [input deleteBackward];
    }
    return nil;
}

@end
