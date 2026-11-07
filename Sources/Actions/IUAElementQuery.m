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

#import "IUAElementQuery.h"
#import "IUAViewIntrospector.h"
#import "IUALogger.h"
#import <math.h>
#import <ctype.h>

NSString *const IUAElementQueryErrorDomain = @"IUAElementQueryErrorDomain";
NSString *const IUAElementStrategyAccessibilityId = @"accessibility id";
NSString *const IUAElementStrategyName = @"name";
NSString *const IUAElementStrategyLabel = @"label";
NSString *const IUAElementStrategyText = @"text";
NSString *const IUAElementStrategyClassName = @"class name";
NSString *const IUAElementStrategyXPath = @"xpath";
NSString *const IUAElementStrategyPredicate = @"-ios predicate string";
NSString *const IUAElementStrategyClassChain = @"-ios class chain";

#pragma mark - 基础工具

static NSString *IUATrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static BOOL IUAIsNumericString(NSString *text) {
    if (text.length == 0) return NO;
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    for (NSUInteger i = 0; i < text.length; i++) {
        if (![digits characterIsMember:[text characterAtIndex:i]]) return NO;
    }
    return YES;
}

static BOOL IUAParseNumberString(NSString *text, double *outValue) {
    NSString *trimmed = IUATrim(text);
    if (trimmed.length == 0) return NO;
    const char *cstr = trimmed.UTF8String;
    if (!cstr) return NO;
    char *end = NULL;
    double value = strtod(cstr, &end);
    if (end == cstr || end == NULL) return NO;
    while (*end != '\0' && isspace((unsigned char)*end)) end++;
    if (*end != '\0') return NO;
    if (!isfinite(value)) return NO;
    if (outValue) *outValue = value;
    return YES;
}

static NSString *IUAUnquote(NSString *text) {
    NSString *trimmed = IUATrim(text);
    if (trimmed.length >= 2) {
        unichar first = [trimmed characterAtIndex:0];
        unichar last = [trimmed characterAtIndex:trimmed.length - 1];
        if ((first == '\'' && last == '\'') || (first == '"' && last == '"')) {
            return [trimmed substringWithRange:NSMakeRange(1, trimmed.length - 2)];
        }
    }
    return trimmed;
}

static NSString *IUAXMLEscape(NSString *text) {
    if (text.length == 0) return @"";
    NSMutableString *out = [NSMutableString stringWithString:text];
    [out replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\n" withString:@"&#10;" options:0 range:NSMakeRange(0, out.length)];
    [out replaceOccurrencesOfString:@"\r" withString:@"&#13;" options:0 range:NSMakeRange(0, out.length)];
    return out;
}

static NSString *IUAStringValue(id value) {
    if (value == nil || value == [NSNull null]) return @"";
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        const char *type = number.objCType;
        if (type && (strcmp(type, @encode(BOOL)) == 0 || strcmp(type, @encode(char)) == 0)) {
            return number.boolValue ? @"1" : @"0";
        }
        double d = number.doubleValue;
        if (floor(d) == d) return [NSString stringWithFormat:@"%.0f", d];
        return [NSString stringWithFormat:@"%g", d];
    }
    return [value description] ?: @"";
}

#pragma mark - 视图遍历

static void IUACollectPreorder(UIView *root, NSMutableArray<UIView *> *out) {
    if (!root) return;
    [out addObject:root];
    for (UIView *subview in root.subviews.reverseObjectEnumerator) {
        IUACollectPreorder(subview, out);
    }
}

static void IUACollectDescendants(UIView *root, NSMutableArray<UIView *> *out) {
    for (UIView *subview in root.subviews.reverseObjectEnumerator) {
        [out addObject:subview];
        IUACollectDescendants(subview, out);
    }
}

/// 全部 view（window 逆序 = 上层优先；同一层子视图逆序 = 视觉上层优先）
static NSArray<UIView *> *IUAAllViews(void) {
    NSMutableArray<UIView *> *views = [NSMutableArray array];
    for (UIWindow *window in [IUAViewIntrospector allWindows].reverseObjectEnumerator) {
        IUACollectPreorder(window, views);
    }
    return views;
}

static CGRect IUAFrameInWindow(UIView *view) {
    if ([view isKindOfClass:[UIWindow class]]) return view.bounds;
    UIWindow *window = view.window ?: [IUAViewIntrospector keyWindow];
    if (!window) return view.frame;
    return [view convertRect:view.bounds toView:window];
}

static BOOL IUAVisibleInWindow(UIView *view) {
    if (!view) return NO;
    // 祖先链上任意一层 hidden/透明都会让子视图不可见（XCUITest visible 语义）
    UIView *node = view;
    while (node) {
        if (node.hidden || node.alpha < 0.01) return NO;
        if ([node isKindOfClass:[UIWindow class]]) break;
        node = node.superview;
    }
    if ([view isKindOfClass:[UIWindow class]]) return YES;
    if (view.window == nil) return NO;
    CGRect frame = IUAFrameInWindow(view);
    if (frame.size.width <= 0 || frame.size.height <= 0) return NO;
    return CGRectIntersectsRect(frame, view.window.bounds);
}

#pragma mark - 元素属性提取

static NSString *IUAAttributedString(NSAttributedString *attributed) {
    return attributed.string ?: @"";
}

static NSString *IUATextForView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        return label.text ?: IUAAttributedString(label.attributedText);
    }
    if ([view isKindOfClass:[UITextField class]]) {
        return ((UITextField *)view).text ?: @"";
    }
    if ([view isKindOfClass:[UITextView class]]) {
        UITextView *textView = (UITextView *)view;
        return textView.text ?: IUAAttributedString(textView.attributedText);
    }
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        return [button titleForState:UIControlStateNormal]
            ?: [button titleForState:UIControlStateHighlighted]
            ?: [button titleForState:UIControlStateSelected]
            ?: @"";
    }
    if ([view isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        NSInteger index = segmented.selectedSegmentIndex;
        if (index >= 0 && index < segmented.numberOfSegments) {
            return [segmented titleForSegmentAtIndex:index] ?: @"";
        }
        return @"";
    }
    if (view.accessibilityLabel.length > 0) return view.accessibilityLabel;
    if (view.accessibilityValue.length > 0) return IUAStringValue(view.accessibilityValue);
    return @"";
}

static NSString *IUAPlaceholderForView(UIView *view) {
    if ([view isKindOfClass:[UITextField class]]) return ((UITextField *)view).placeholder ?: @"";
    if ([view isKindOfClass:[UITextView class]]) return @"";
    return @"";
}

static id IUAValueForView(UIView *view) {
    if ([view isKindOfClass:[UISwitch class]]) return @(((UISwitch *)view).on);
    if ([view isKindOfClass:[UISlider class]]) return @(((UISlider *)view).value);
    if ([view isKindOfClass:[UIStepper class]]) return @(((UIStepper *)view).value);
    if ([view isKindOfClass:[UISegmentedControl class]]) {
        UISegmentedControl *segmented = (UISegmentedControl *)view;
        NSInteger index = segmented.selectedSegmentIndex;
        if (index >= 0 && index < segmented.numberOfSegments) {
            return [segmented titleForSegmentAtIndex:index] ?: @"";
        }
        return @"";
    }
    if ([view isKindOfClass:[UITextField class]]) return ((UITextField *)view).text ?: @"";
    if ([view isKindOfClass:[UITextView class]]) return ((UITextView *)view).text ?: @"";
    if ([view isKindOfClass:[UIDatePicker class]]) {
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss";
        return [formatter stringFromDate:((UIDatePicker *)view).date] ?: @"";
    }
    if (view.accessibilityValue.length > 0) return view.accessibilityValue;
    return nil;
}

static BOOL IUAEnabledForView(UIView *view) {
    if ([view isKindOfClass:[UIControl class]]) return ((UIControl *)view).enabled;
    if (view.hidden || view.alpha < 0.01) return NO;
    // 非控件（UILabel/UIView 等）在 XCUITest 语义下通常仍视为 enabled；
    // 只有控件自身的 enabled 状态才代表“不可交互”。
    return YES;
}

static BOOL IUASelectedForView(UIView *view) {
    if ([view isKindOfClass:[UIControl class]]) return ((UIControl *)view).selected;
    if ([view isKindOfClass:[UITableViewCell class]]) return ((UITableViewCell *)view).selected;
    if ([view isKindOfClass:[UICollectionViewCell class]]) return ((UICollectionViewCell *)view).selected;
    return NO;
}

static NSInteger IUASiblingIndex(UIView *view) {
    UIView *parent = view.superview;
    if (!parent) return 0;
    NSUInteger index = [parent.subviews indexOfObject:view];
    return index == NSNotFound ? 0 : (NSInteger)index;
}

/// 计算控件自身的“可访问标签”（XCUITest label 语义：accessibilityLabel，缺省回退到文本/占位符）
static NSString *IUALabelForView(UIView *view) {
    if (view.accessibilityLabel.length > 0) return view.accessibilityLabel;
    NSString *text = IUATextForView(view);
    if (text.length > 0) return text;
    return IUAPlaceholderForView(view);
}

static NSString *IUANameForView(UIView *view) {
    if (view.accessibilityIdentifier.length > 0) return view.accessibilityIdentifier;
    return IUALabelForView(view);
}

#pragma mark - XCUITest 类型映射

static NSString *IUATypeForView(UIView *view) {
    if ([view isKindOfClass:[UIWindow class]]) return @"XCUIElementTypeWindow";
    if ([view isKindOfClass:[UITableView class]]) return @"XCUIElementTypeTable";
    if ([view isKindOfClass:[UICollectionView class]]) return @"XCUIElementTypeCollectionView";
    if ([view isKindOfClass:[UITableViewCell class]] ||
        [view isKindOfClass:[UICollectionViewCell class]]) return @"XCUIElementTypeCell";
    if ([view isKindOfClass:[UIScrollView class]]) return @"XCUIElementTypeScrollView";
    if ([view isKindOfClass:[UIButton class]]) return @"XCUIElementTypeButton";
    if ([view isKindOfClass:[UISwitch class]]) return @"XCUIElementTypeSwitch";
    if ([view isKindOfClass:[UISlider class]]) return @"XCUIElementTypeSlider";
    if ([view isKindOfClass:[UIStepper class]]) return @"XCUIElementTypeStepper";
    if ([view isKindOfClass:[UISegmentedControl class]]) return @"XCUIElementTypeSegmentedControl";
    if ([view isKindOfClass:[UITextField class]]) return @"XCUIElementTypeTextField";
    if ([view isKindOfClass:[UITextView class]]) return @"XCUIElementTypeTextView";
    if ([view isKindOfClass:[UISearchBar class]]) return @"XCUIElementTypeSearchField";
    if ([view isKindOfClass:[UINavigationBar class]]) return @"XCUIElementTypeNavigationBar";
    if ([view isKindOfClass:[UITabBar class]]) return @"XCUIElementTypeTabBar";
    if ([view isKindOfClass:[UIToolbar class]]) return @"XCUIElementTypeToolbar";
    if ([view isKindOfClass:[UILabel class]]) return @"XCUIElementTypeStaticText";
    if ([view isKindOfClass:[UIImageView class]]) return @"XCUIElementTypeImage";
    if ([view isKindOfClass:[UIPickerView class]]) return @"XCUIElementTypePicker";
    if ([view isKindOfClass:[UIDatePicker class]]) return @"XCUIElementTypeDatePicker";
    if ([view isKindOfClass:[UIProgressView class]]) return @"XCUIElementTypeProgressIndicator";
    if ([view isKindOfClass:[UIActivityIndicatorView class]]) return @"XCUIElementTypeActivityIndicator";
    if ([view isKindOfClass:[UIPageControl class]]) return @"XCUIElementTypePageIndicator";

    UIAccessibilityTraits traits = view.accessibilityTraits;
    if (traits & UIAccessibilityTraitButton) return @"XCUIElementTypeButton";
    if (traits & UIAccessibilityTraitImage) return @"XCUIElementTypeImage";
    if (traits & UIAccessibilityTraitStaticText) return @"XCUIElementTypeStaticText";
    if (traits & UIAccessibilityTraitSearchField) return @"XCUIElementTypeSearchField";
    if (traits & UIAccessibilityTraitSelected) return @"XCUIElementTypeButton";
    return @"XCUIElementTypeOther";
}

#pragma mark - XPath 生成

static NSString *IUAXPathForView(UIView *view) {
    NSMutableArray<NSString *> *components = [NSMutableArray array];
    UIView *node = view;
    NSInteger guard = 0;
    while (node && guard++ < 1000) {
        if ([node isKindOfClass:[UIWindow class]]) {
            NSInteger index = 1;
            for (UIWindow *window in [IUAViewIntrospector allWindows]) {
                if (window == node) break;
                if ([IUATypeForView(window) isEqualToString:IUATypeForView(node)]) index++;
            }
            [components insertObject:[NSString stringWithFormat:@"%@[%ld]", IUATypeForView(node), (long)index] atIndex:0];
            break;
        }
        UIView *parent = node.superview;
        if (!parent) break;
        NSString *type = IUATypeForView(node);
        NSInteger index = 1;
        for (UIView *sibling in parent.subviews) {
            if (sibling == node) break;
            if ([IUATypeForView(sibling) isEqualToString:type]) index++;
        }
        [components insertObject:[NSString stringWithFormat:@"%@[%ld]", type, (long)index] atIndex:0];
        node = parent;
    }
    if (components.count == 0) return @"/";
    return [@"/" stringByAppendingString:[components componentsJoinedByString:@"/"]];
}

#pragma mark - 属性字典

static NSDictionary<NSString *, id> *IUAAttributesForView(UIView *view) {
    CGRect frame = IUAFrameInWindow(view);
    id value = IUAValueForView(view);
    NSString *text = IUATextForView(view) ?: @"";
    NSString *label = IUALabelForView(view) ?: @"";
    NSString *name = IUANameForView(view) ?: @"";

    NSMutableDictionary<NSString *, id> *attrs = [NSMutableDictionary dictionary];
    attrs[@"type"] = IUATypeForView(view);
    attrs[@"name"] = name;
    attrs[@"label"] = label;
    attrs[@"value"] = value ?: @"";
    attrs[@"text"] = text;
    attrs[@"identifier"] = view.accessibilityIdentifier ?: @"";
    attrs[@"class"] = NSStringFromClass(view.class);
    attrs[@"enabled"] = @(IUAEnabledForView(view));
    attrs[@"visible"] = @(IUAVisibleInWindow(view));
    attrs[@"accessible"] = @(view.isAccessibilityElement);
    attrs[@"selected"] = @(IUASelectedForView(view));
    attrs[@"focused"] = @(view.isFirstResponder);
    attrs[@"index"] = @(IUASiblingIndex(view));
    attrs[@"rect"] = @{@"x" : @(round(frame.origin.x * 10) / 10),
                       @"y" : @(round(frame.origin.y * 10) / 10),
                       @"width" : @(round(frame.size.width * 10) / 10),
                       @"height" : @(round(frame.size.height * 10) / 10)};
    attrs[@"x"] = @(round(frame.origin.x * 10) / 10);
    attrs[@"y"] = @(round(frame.origin.y * 10) / 10);
    attrs[@"width"] = @(round(frame.size.width * 10) / 10);
    attrs[@"height"] = @(round(frame.size.height * 10) / 10);
    attrs[@"xpath"] = IUAXPathForView(view);
    attrs[@"placeholder"] = IUAPlaceholderForView(view);
    return attrs;
}

static id IUAAttributeForView(UIView *view, NSString *attribute) {
    NSString *key = IUATrim(attribute).lowercaseString;
    if (key.length == 0) return nil;
    NSDictionary<NSString *, id> *attrs = IUAAttributesForView(view);

    if ([key isEqualToString:@"name"]) return attrs[@"name"];
    if ([key isEqualToString:@"label"]) return attrs[@"label"];
    if ([key isEqualToString:@"value"]) return attrs[@"value"];
    if ([key isEqualToString:@"text"]) return attrs[@"text"];
    if ([key isEqualToString:@"identifier"] || [key isEqualToString:@"accessibilityidentifier"]) return attrs[@"identifier"];
    if ([key isEqualToString:@"type"] || [key isEqualToString:@"class name"] || [key isEqualToString:@"elementtype"]) return attrs[@"type"];
    if ([key isEqualToString:@"class"] || [key isEqualToString:@"classname"]) return attrs[@"class"];
    if ([key isEqualToString:@"enabled"]) return attrs[@"enabled"];
    if ([key isEqualToString:@"visible"] || [key isEqualToString:@"displayed"]) return attrs[@"visible"];
    if ([key isEqualToString:@"accessible"]) return attrs[@"accessible"];
    if ([key isEqualToString:@"selected"]) return attrs[@"selected"];
    if ([key isEqualToString:@"focused"]) return attrs[@"focused"];
    if ([key isEqualToString:@"index"]) return attrs[@"index"];
    if ([key isEqualToString:@"rect"]) return attrs[@"rect"];
    if ([key isEqualToString:@"x"]) return attrs[@"x"];
    if ([key isEqualToString:@"y"]) return attrs[@"y"];
    if ([key isEqualToString:@"width"]) return attrs[@"width"];
    if ([key isEqualToString:@"height"]) return attrs[@"height"];
    if ([key isEqualToString:@"xpath"]) return attrs[@"xpath"];
    if ([key isEqualToString:@"placeholder"] || [key isEqualToString:@"placeholdervalue"]) return attrs[@"placeholder"];

    return nil;
}

#pragma mark - 定位策略匹配

static BOOL IUAClassMatches(UIView *view, NSString *pattern) {
    NSString *value = IUATrim(pattern);
    if (value.length == 0) return NO;
    NSString *className = NSStringFromClass(view.class);
    NSString *type = IUATypeForView(view);
    if ([value isEqualToString:@"*"]) return YES;
    if ([value hasSuffix:@"*"] && value.length > 1) {
        NSString *prefix = [value substringToIndex:value.length - 1];
        return [className hasPrefix:prefix] || [type hasPrefix:prefix];
    }
    if ([value hasPrefix:@"*"] && value.length > 1) {
        NSString *suffix = [value substringFromIndex:1];
        return [className hasSuffix:suffix] || [type hasSuffix:suffix];
    }
    if ([value isEqualToString:className] || [value isEqualToString:type]) return YES;
    // 简写：Button / StaticText / TextField …（XCUIElementType 前缀可省略）
    NSString *shortType = [type hasPrefix:@"XCUIElementType"] ? [type substringFromIndex:@"XCUIElementType".length] : type;
    if ([value caseInsensitiveCompare:shortType] == NSOrderedSame) return YES;
    // UIKit 类型名省略 UI 前缀：Button ↔ UIButton
    if ([className hasPrefix:@"UI"] && [value caseInsensitiveCompare:[className substringFromIndex:2]] == NSOrderedSame) return YES;
    return NO;
}

/// 将属性值转成用于 XPath / 谓词比较的字符串
static NSString *IUAAttributeString(UIView *view, NSString *attribute, BOOL *exists) {
    id value = IUAAttributeForView(view, attribute);
    if (exists) *exists = (value != nil);
    return IUAStringValue(value);
}

/// 在顶层按分隔符切分（忽略引号/括号内部）；用于 " and " / " or " / class chain 的 "/"
static NSArray<NSString *> *IUASplitTopLevel(NSString *text, NSString *separator) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSMutableString *current = [NSMutableString string];
    NSInteger depth = 0;
    unichar quote = 0;
    NSUInteger i = 0;
    NSString *lower = text.lowercaseString;
    NSString *lowerSep = separator.lowercaseString;
    while (i < text.length) {
        unichar c = [text characterAtIndex:i];
        if (quote != 0) {
            [current appendFormat:@"%C", c];
            if (c == quote) quote = 0;
            i++;
            continue;
        }
        if (c == '\'' || c == '"' || c == '`') {
            quote = c;
            [current appendFormat:@"%C", c];
            i++;
            continue;
        }
        if (c == '(' || c == '[' || c == '{') {
            depth++;
            [current appendFormat:@"%C", c];
            i++;
            continue;
        }
        if (c == ')' || c == ']' || c == '}') {
            depth--;
            [current appendFormat:@"%C", c];
            i++;
            continue;
        }
        if (depth == 0 && i + lowerSep.length <= lower.length &&
            [[lower substringWithRange:NSMakeRange(i, lowerSep.length)] isEqualToString:lowerSep]) {
            [parts addObject:[current copy]];
            current = [NSMutableString string];
            i += lowerSep.length;
            continue;
        }
        [current appendFormat:@"%C", c];
        i++;
    }
    [parts addObject:[current copy]];
    return parts;
}

static BOOL IUACompareAttribute(UIView *view, NSString *attribute, NSString *op, NSString *expected) {
    BOOL exists = NO;
    NSString *actual = IUAAttributeString(view, attribute, &exists);
    if (!exists) return NO;
    NSString *lhs = actual ?: @"";
    NSString *rhs = IUAUnquote(expected);
    if ([op isEqualToString:@"="]) {
        if ([lhs isEqualToString:rhs]) return YES;
        // 布尔属性兼容 true/false
        if (([lhs isEqualToString:@"1"] && [rhs.lowercaseString isEqualToString:@"true"]) ||
            ([lhs isEqualToString:@"0"] && [rhs.lowercaseString isEqualToString:@"false"])) return YES;
        if (([rhs isEqualToString:@"1"] && [lhs.lowercaseString isEqualToString:@"true"]) ||
            ([rhs isEqualToString:@"0"] && [lhs.lowercaseString isEqualToString:@"false"])) return YES;
        double lhsNumber = 0, rhsNumber = 0;
        if (IUAParseNumberString(lhs, &lhsNumber) && IUAParseNumberString(rhs, &rhsNumber)) {
            return lhsNumber == rhsNumber;
        }
        return NO;
    }
    if ([op isEqualToString:@"!="]) return !IUACompareAttribute(view, attribute, @"=", expected);
    if ([op isEqualToString:@"contains"]) return [lhs containsString:rhs];
    if ([op isEqualToString:@"starts-with"]) return [lhs hasPrefix:rhs];
    if ([op isEqualToString:@"ends-with"]) return [lhs hasSuffix:rhs];
    double lhsNumber = 0, rhsNumber = 0;
    if (!IUAParseNumberString(lhs, &lhsNumber) || !IUAParseNumberString(rhs, &rhsNumber)) {
        return NO; // XPath 数值比较对非数字操作数返回 false，避免 doubleValue(0) 误匹配
    }
    if ([op isEqualToString:@">"]) return lhsNumber > rhsNumber;
    if ([op isEqualToString:@"<"]) return lhsNumber < rhsNumber;
    if ([op isEqualToString:@">="]) return lhsNumber >= rhsNumber;
    if ([op isEqualToString:@"<="]) return lhsNumber <= rhsNumber;
    return NO;
}

/// XPath 谓词求值（支持 and/or/not、@attr 比较、contains/starts-with/ends-with）
static BOOL IUAEvaluateXPathPredicate(UIView *view, NSString *expression) {
    NSString *expr = IUATrim(expression);
    if (expr.length == 0) return YES;

    NSArray<NSString *> *orParts = IUASplitTopLevel(expr, @" or ");
    if (orParts.count > 1) {
        for (NSString *part in orParts) {
            if (IUAEvaluateXPathPredicate(view, part)) return YES;
        }
        return NO;
    }
    NSArray<NSString *> *andParts = IUASplitTopLevel(expr, @" and ");
    if (andParts.count > 1) {
        for (NSString *part in andParts) {
            if (!IUAEvaluateXPathPredicate(view, part)) return NO;
        }
        return YES;
    }
    if ([expr.lowercaseString hasPrefix:@"not("] && [expr hasSuffix:@")"]) {
        NSString *inner = [expr substringWithRange:NSMakeRange(4, expr.length - 5)];
        return !IUAEvaluateXPathPredicate(view, inner);
    }

    // 函数形式：contains(@name, "x") / starts-with(...) / ends-with(...)
    NSRange paren = [expr rangeOfString:@"("];
    if (paren.location != NSNotFound && [expr hasSuffix:@")"]) {
        NSString *func = IUATrim([expr substringToIndex:paren.location]).lowercaseString;
        NSString *argsText = [expr substringWithRange:NSMakeRange(paren.location + 1, expr.length - paren.location - 2)];
        NSArray<NSString *> *args = IUASplitTopLevel(argsText, @",");
        if (args.count >= 2 &&
            ([func isEqualToString:@"contains"] || [func isEqualToString:@"starts-with"] || [func isEqualToString:@"ends-with"])) {
            NSString *attr = IUATrim(args[0]);
            if ([attr hasPrefix:@"@"]) attr = [attr substringFromIndex:1];
            return IUACompareAttribute(view, attr, func, args[1]);
        }
    }

    // @attr 存在性
    if ([expr hasPrefix:@"@"] && [expr rangeOfString:@"="].location == NSNotFound &&
        [expr rangeOfString:@">"].location == NSNotFound &&
        [expr rangeOfString:@"<"].location == NSNotFound) {
        BOOL exists = NO;
        IUAAttributeString(view, [expr substringFromIndex:1], &exists);
        return exists;
    }

    // 比较运算：@attr op 'value'
    NSArray<NSString *> *operators = @[@"!=", @">=", @"<=", @"=", @">", @"<"];
    for (NSString *op in operators) {
        NSRange range = [expr rangeOfString:op];
        if (range.location == NSNotFound) continue;
        NSString *lhs = IUATrim([expr substringToIndex:range.location]);
        NSString *rhs = IUATrim([expr substringWithRange:NSMakeRange(range.location + op.length,
                                                                     expr.length - range.location - op.length)]);
        if (![lhs hasPrefix:@"@"]) break;
        NSString *attr = [lhs substringFromIndex:1];
        return IUACompareAttribute(view, attr, op, rhs);
    }
    return NO;
}

static BOOL IUAXPathTextEquals(UIView *view, NSString *tag) {
    if ([tag isEqualToString:@"*"] || [tag isEqualToString:@"XCUIElementTypeAny"]) return YES;
    NSString *type = IUATypeForView(view);
    if ([tag isEqualToString:type]) return YES;
    if ([tag isEqualToString:NSStringFromClass(view.class)]) return YES;
    if ([type hasPrefix:@"XCUIElementType"] && [tag isEqualToString:[type substringFromIndex:@"XCUIElementType".length]]) return YES;
    return NO;
}

#pragma mark - XPath 解析与求值

@interface IUAXPathStep : NSObject
@property (nonatomic, assign) BOOL descendant;
@property (nonatomic, copy) NSString *tag;
@property (nonatomic, strong) NSMutableArray<NSString *> *predicates;
@property (nonatomic, assign) NSInteger index; // 1 起，0 表示无
@end

@implementation IUAXPathStep
@end

static NSArray<IUAXPathStep *> *IUAParseXPath(NSString *path, BOOL *ok) {
    NSString *text = IUATrim(path);
    *ok = NO;
    if (text.length == 0) return nil;

    NSMutableArray<IUAXPathStep *> *steps = [NSMutableArray array];
    NSUInteger i = 0;
    BOOL descendant = YES;
    if ([text hasPrefix:@"//"]) {
        descendant = YES;
        i = 2;
    } else if ([text hasPrefix:@"/"]) {
        descendant = NO;
        i = 1;
    } else {
        descendant = YES;
    }

    while (i < text.length) {
        NSMutableString *tag = [NSMutableString string];
        while (i < text.length) {
            unichar c = [text characterAtIndex:i];
            if (c == '/' || c == '[') break;
            [tag appendFormat:@"%C", c];
            i++;
        }
        NSString *tagText = IUATrim(tag);
        if (tagText.length == 0) return nil;

        NSMutableArray<NSString *> *predicates = [NSMutableArray array];
        NSInteger index = 0;
        while (i < text.length && [text characterAtIndex:i] == '[') {
            NSUInteger start = i + 1;
            NSInteger depth = 1;
            unichar quote = 0;
            i++;
            while (i < text.length && depth > 0) {
                unichar c = [text characterAtIndex:i];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '\'' || c == '"') {
                    quote = c;
                } else if (c == '[') {
                    depth++;
                } else if (c == ']') {
                    depth--;
                    if (depth == 0) break;
                }
                i++;
            }
            if (depth != 0) return nil;
            NSString *content = IUATrim([text substringWithRange:NSMakeRange(start, i - start)]);
            i++; // skip ']'
            if (IUAIsNumericString(content)) {
                index = content.integerValue;
            } else {
                [predicates addObject:content];
            }
        }

        IUAXPathStep *step = [[IUAXPathStep alloc] init];
        step.descendant = descendant;
        step.tag = tagText;
        step.predicates = predicates;
        step.index = index;
        [steps addObject:step];

        if (i < text.length) {
            if ([text characterAtIndex:i] != '/') return nil;
            if (i + 1 < text.length && [text characterAtIndex:i + 1] == '/') {
                descendant = YES;
                i += 2;
            } else {
                descendant = NO;
                i += 1;
            }
        }
    }

    // XCUITest 源里的 Application/AppiumAUT 是虚拟根；去掉后从 window 开始
    while (steps.count > 0 &&
           ([steps.firstObject.tag isEqualToString:@"XCUIElementTypeApplication"] ||
            [steps.firstObject.tag isEqualToString:@"AppiumAUT"])) {
        [steps removeObjectAtIndex:0];
    }
    if (steps.count == 0) {
        *ok = YES;
        return @[];
    }
    steps.firstObject.descendant = YES;
    *ok = YES;
    return steps;
}

static NSArray<UIView *> *IUAEvaluateXPath(NSString *path) {
    BOOL ok = NO;
    NSArray<IUAXPathStep *> *steps = IUAParseXPath(path, &ok);
    if (!ok || steps.count == 0) return @[];

    NSArray<UIView *> *current = nil;
    for (NSUInteger stepIndex = 0; stepIndex < steps.count; stepIndex++) {
        IUAXPathStep *step = steps[stepIndex];
        NSMutableArray<UIView *> *candidates = [NSMutableArray array];
        if (stepIndex == 0) {
            [candidates addObjectsFromArray:IUAAllViews()];
        } else {
            for (UIView *node in current) {
                if (step.descendant) {
                    IUACollectDescendants(node, candidates);
                } else {
                    [candidates addObjectsFromArray:node.subviews];
                }
            }
        }

        NSMutableArray<UIView *> *matched = [NSMutableArray array];
        for (UIView *candidate in candidates) {
            if (!IUAXPathTextEquals(candidate, step.tag)) continue;
            BOOL pass = YES;
            for (NSString *predicate in step.predicates) {
                if (!IUAEvaluateXPathPredicate(candidate, predicate)) { pass = NO; break; }
            }
            if (pass) [matched addObject:candidate];
        }

        // 去重（同一 view 可能被多个父上下文加入）
        NSMutableArray<UIView *> *unique = [NSMutableArray array];
        NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        for (UIView *view in matched) {
            if (![seen containsObject:view]) { [seen addObject:view]; [unique addObject:view]; }
        }
        if (step.index > 0) {
            if ((NSUInteger)step.index <= unique.count) {
                current = @[unique[step.index - 1]];
            } else {
                current = @[];
            }
        } else {
            current = unique;
        }
        if (current.count == 0) break;
    }
    return current ?: @[];
}

#pragma mark - iOS Predicate String

static NSPredicate * _Nullable IUACompilePredicate(NSString *format) {
    @try {
        return [NSPredicate predicateWithFormat:format];
    } @catch (NSException *exception) {
        IUALogWarn(@"谓词编译失败: %@ (%@)", format, exception.reason);
        return nil;
    }
}

static NSArray<UIView *> *IUAFilterByPredicate(NSArray<UIView *> *views, NSString *predicateFormat) {
    NSPredicate *predicate = nil;
    @try {
        predicate = [NSPredicate predicateWithFormat:predicateFormat];
    } @catch (NSException *exception) {
        IUALogWarn(@"谓词编译失败: %@ (%@)", predicateFormat, exception.reason);
        return @[];
    }
    NSMutableArray<UIView *> *matched = [NSMutableArray array];
    for (UIView *view in views) {
        if ([predicate evaluateWithObject:IUAAttributesForView(view)]) [matched addObject:view];
    }
    return matched;
}

#pragma mark - iOS Class Chain

@interface IUAChainStep : NSObject
@property (nonatomic, assign) BOOL descendant;
@property (nonatomic, copy) NSString *type;
@property (nonatomic, strong) NSMutableArray<NSString *> *predicates;
@property (nonatomic, assign) NSInteger index;
@end

@implementation IUAChainStep
@end

static NSArray<IUAChainStep *> *IUAParseClassChain(NSString *chain, BOOL *ok) {
    *ok = NO;
    NSArray<NSString *> *segments = IUASplitTopLevel(IUATrim(chain), @"/");
    NSMutableArray<IUAChainStep *> *steps = [NSMutableArray array];
    BOOL nextDescendant = YES;
    for (NSString *raw in segments) {
        NSString *segment = IUATrim(raw);
        if (segment.length == 0) continue;
        if ([segment isEqualToString:@"**"] || [segment isEqualToString:@"*"]) {
            nextDescendant = YES;
            continue;
        }
        NSMutableString *typeText = [NSMutableString string];
        NSUInteger i = 0;
        while (i < segment.length && [segment characterAtIndex:i] != '[') {
            [typeText appendFormat:@"%C", [segment characterAtIndex:i]];
            i++;
        }
        NSString *type = IUATrim(typeText);
        if (type.length == 0) type = @"*";

        NSMutableArray<NSString *> *predicates = [NSMutableArray array];
        NSInteger index = 0;
        while (i < segment.length && [segment characterAtIndex:i] == '[') {
            NSUInteger start = i + 1;
            NSInteger depth = 1;
            unichar quote = 0;
            i++;
            while (i < segment.length && depth > 0) {
                unichar c = [segment characterAtIndex:i];
                if (quote != 0) {
                    if (c == quote) quote = 0;
                } else if (c == '\'' || c == '"' || c == '`') {
                    quote = c;
                } else if (c == '[') {
                    depth++;
                } else if (c == ']') {
                    depth--;
                    if (depth == 0) break;
                }
                i++;
            }
            if (depth != 0) return nil;
            NSString *content = IUATrim([segment substringWithRange:NSMakeRange(start, i - start)]);
            i++;
            if (IUAIsNumericString(content)) {
                index = content.integerValue;
            } else if (content.length >= 2 && [content hasPrefix:@"`"] && [content hasSuffix:@"`"]) {
                NSString *predicate = [content substringWithRange:NSMakeRange(1, content.length - 2)];
                if (!IUACompilePredicate(predicate)) return nil;
                [predicates addObject:predicate];
            } else {
                if (!IUACompilePredicate(content)) return nil;
                [predicates addObject:content];
            }
        }

        IUAChainStep *step = [[IUAChainStep alloc] init];
        step.descendant = nextDescendant;
        step.type = type;
        step.predicates = predicates;
        step.index = index;
        [steps addObject:step];
        nextDescendant = NO;
    }
    // XCUITest class chain 有时以 Application/AppiumAUT 虚拟根开头；我们没有对应 view，
    // 去掉后从 Window 开始查询（与 XPath 行为保持一致）。
    while (steps.count > 0 &&
           ([steps.firstObject.type isEqualToString:@"XCUIElementTypeApplication"] ||
            [steps.firstObject.type isEqualToString:@"AppiumAUT"])) {
        [steps removeObjectAtIndex:0];
    }
    if (steps.count == 0) return nil;
    steps.firstObject.descendant = YES;
    *ok = YES;
    return steps;
}

static NSArray<UIView *> *IUAEvaluateClassChain(NSString *chain) {
    BOOL ok = NO;
    NSArray<IUAChainStep *> *steps = IUAParseClassChain(chain, &ok);
    if (!ok || steps.count == 0) return @[];
    NSArray<UIView *> *current = nil;
    for (NSUInteger stepIndex = 0; stepIndex < steps.count; stepIndex++) {
        IUAChainStep *step = steps[stepIndex];
        NSMutableArray<UIView *> *candidates = [NSMutableArray array];
        if (stepIndex == 0) {
            [candidates addObjectsFromArray:IUAAllViews()];
        } else {
            for (UIView *node in current) {
                if (step.descendant) {
                    IUACollectDescendants(node, candidates);
                } else {
                    [candidates addObjectsFromArray:node.subviews];
                }
            }
        }
        NSMutableArray<NSPredicate *> *predicates = [NSMutableArray array];
        BOOL invalidPredicate = NO;
        for (NSString *format in step.predicates) {
            NSPredicate *predicate = IUACompilePredicate(format);
            if (predicate) [predicates addObject:predicate];
            else invalidPredicate = YES;
        }
        if (invalidPredicate) {
            current = @[];
            break;
        }
        NSMutableArray<UIView *> *matched = [NSMutableArray array];
        for (UIView *candidate in candidates) {
            if (!IUAClassMatches(candidate, step.type)) continue;
            NSDictionary<NSString *, id> *attrs = predicates.count > 0 ? IUAAttributesForView(candidate) : nil;
            BOOL pass = YES;
            for (NSPredicate *predicate in predicates) {
                if (![predicate evaluateWithObject:attrs]) { pass = NO; break; }
            }
            if (pass) [matched addObject:candidate];
        }
        // 多层 ** 时同一 view 可能被多个父上下文加入，去重后再应用 index
        NSMutableArray<UIView *> *unique = [NSMutableArray array];
        NSHashTable *seen = [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
        for (UIView *view in matched) {
            if (![seen containsObject:view]) { [seen addObject:view]; [unique addObject:view]; }
        }
        if (step.index > 0) {
            if ((NSUInteger)step.index <= unique.count) {
                current = @[unique[step.index - 1]];
            } else {
                current = @[];
            }
        } else {
            current = unique;
        }
        if (current.count == 0) break;
    }
    return current ?: @[];
}

#pragma mark - Page Source XML

static void IUAAppendNodeXML(NSMutableString *xml, UIView *view, NSInteger remainingDepth, NSInteger indentLevel) {
    NSDictionary<NSString *, id> *attrs = IUAAttributesForView(view);
    NSString *tag = attrs[@"type"] ?: @"XCUIElementTypeOther";
    NSString *padding = [@"" stringByPaddingToLength:(NSUInteger)(indentLevel * 2) withString:@" " startingAtIndex:0];

    [xml appendFormat:@"%@<%@", padding, tag];
    [xml appendFormat:@" type=\"%@\"", IUAXMLEscape(tag)];
    [xml appendFormat:@" name=\"%@\"", IUAXMLEscape(IUAStringValue(attrs[@"name"]))];
    [xml appendFormat:@" label=\"%@\"", IUAXMLEscape(IUAStringValue(attrs[@"label"]))];
    NSString *value = IUAStringValue(attrs[@"value"]);
    if (value.length > 0) [xml appendFormat:@" value=\"%@\"", IUAXMLEscape(value)];
    NSString *identifier = IUAStringValue(attrs[@"identifier"]);
    if (identifier.length > 0) [xml appendFormat:@" identifier=\"%@\"", IUAXMLEscape(identifier)];
    [xml appendFormat:@" enabled=\"%@\"", [attrs[@"enabled"] boolValue] ? @"true" : @"false"];
    [xml appendFormat:@" visible=\"%@\"", [attrs[@"visible"] boolValue] ? @"true" : @"false"];
    [xml appendFormat:@" accessible=\"%@\"", [attrs[@"accessible"] boolValue] ? @"true" : @"false"];
    [xml appendFormat:@" x=\"%@\" y=\"%@\" width=\"%@\" height=\"%@\"",
        IUAStringValue(attrs[@"x"]), IUAStringValue(attrs[@"y"]),
        IUAStringValue(attrs[@"width"]), IUAStringValue(attrs[@"height"])];
    NSString *className = IUAStringValue(attrs[@"class"]);
    if (className.length > 0) [xml appendFormat:@" class=\"%@\"", IUAXMLEscape(className)];

    BOOL hasChildren = view.subviews.count > 0 && remainingDepth != 1;
    if (!hasChildren) {
        [xml appendString:@"/>\n"];
        return;
    }
    [xml appendString:@">\n"];
    NSInteger childDepth = (remainingDepth > 0) ? remainingDepth - 1 : remainingDepth;
    for (UIView *subview in view.subviews) {
        IUAAppendNodeXML(xml, subview, childDepth, indentLevel + 1);
    }
    [xml appendFormat:@"%@</%@>\n", padding, tag];
}

#pragma mark - Active Element 探测

static UIResponder *gIUAActiveElementResponder = nil;

@interface UIResponder (IUAElementQueryCapture)
- (void)iua_elementQueryCapture:(id)sender;
@end

@implementation UIResponder (IUAElementQueryCapture)
- (void)iua_elementQueryCapture:(id)sender {
    gIUAActiveElementResponder = self;
}
@end

#pragma mark - IUAElementQuery

@implementation IUAElementQuery

+ (NSArray<NSString *> *)supportedStrategies {
    return @[IUAElementStrategyAccessibilityId,
             @"id",
             IUAElementStrategyName,
             IUAElementStrategyLabel,
             IUAElementStrategyText,
             IUAElementStrategyClassName,
             @"class",
             IUAElementStrategyXPath,
             IUAElementStrategyPredicate,
             @"predicate",
             IUAElementStrategyClassChain,
             @"class chain"];
}

+ (BOOL)validateUsing:(NSString *)strategy value:(NSString *)value error:(NSString * _Nullable * _Nullable)error {
    NSString *key = IUATrim(strategy ?: @"").lowercaseString;
    if ([key isEqualToString:@"xpath"]) {
        if (value.length == 0) {
            if (error) *error = @"xpath 不能为空";
            return NO;
        }
        BOOL ok = NO;
        IUAParseXPath(value, &ok);
        if (!ok) {
            if (error) *error = [NSString stringWithFormat:@"invalid xpath: %@", value];
            return NO;
        }
        return YES;
    }
    if ([key isEqualToString:@"-ios class chain"] || [key isEqualToString:@"class chain"] ||
        [key isEqualToString:@"classchain"]) {
        if (value.length == 0) {
            if (error) *error = @"class chain 不能为空";
            return NO;
        }
        BOOL ok = NO;
        IUAParseClassChain(value, &ok);
        if (!ok) {
            if (error) *error = [NSString stringWithFormat:@"invalid class chain: %@", value];
            return NO;
        }
        return YES;
    }
    if ([key isEqualToString:@"-ios predicate string"] || [key isEqualToString:@"predicate"] ||
        [key isEqualToString:@"predicate string"] || [key isEqualToString:@"-ios predicate"]) {
        if (value.length == 0) {
            if (error) *error = @"iOS predicate 不能为空";
            return NO;
        }
        @try {
            (void)[NSPredicate predicateWithFormat:value];
        } @catch (NSException *exception) {
            if (error) *error = [NSString stringWithFormat:@"invalid predicate: %@ (%@)", value, exception.reason];
            return NO;
        }
        return YES;
    }
    return YES;
}

+ (NSArray<UIView *> *)findViewsUsing:(NSString *)strategy value:(NSString *)value {
    NSString *key = IUATrim(strategy ?: @"").lowercaseString;
    NSString *target = value ?: @"";
    NSArray<UIView *> *all = IUAAllViews();

    if (key.length == 0 || [key isEqualToString:@"accessibility id"] ||
        [key isEqualToString:@"accessibility_id"] || [key isEqualToString:@"accessibilityid"] ||
        [key isEqualToString:@"id"] || [key isEqualToString:@"identifier"]) {
        NSMutableArray *matched = [NSMutableArray array];
        for (UIView *view in all) {
            if ([view.accessibilityIdentifier isEqualToString:target]) [matched addObject:view];
        }
        return matched;
    }

    if ([key isEqualToString:@"name"]) {
        NSMutableArray *matched = [NSMutableArray array];
        for (UIView *view in all) {
            if ([IUANameForView(view) isEqualToString:target]) [matched addObject:view];
        }
        return matched;
    }

    if ([key isEqualToString:@"label"] || [key isEqualToString:@"accessibility label"] ||
        [key isEqualToString:@"accessibilitylabel"]) {
        NSMutableArray *matched = [NSMutableArray array];
        for (UIView *view in all) {
            if ([IUALabelForView(view) isEqualToString:target]) [matched addObject:view];
        }
        return matched;
    }

    if ([key isEqualToString:@"text"]) {
        NSMutableArray *matched = [NSMutableArray array];
        for (UIView *view in all) {
            if ([IUATextForView(view) isEqualToString:target]) [matched addObject:view];
        }
        return matched;
    }

    if ([key isEqualToString:@"class name"] || [key isEqualToString:@"classname"] ||
        [key isEqualToString:@"class"] || [key isEqualToString:@"type"]) {
        NSMutableArray *matched = [NSMutableArray array];
        for (UIView *view in all) {
            if (IUAClassMatches(view, target)) [matched addObject:view];
        }
        return matched;
    }

    if ([key isEqualToString:@"xpath"]) {
        return IUAEvaluateXPath(target);
    }

    if ([key isEqualToString:@"-ios predicate string"] || [key isEqualToString:@"predicate"] ||
        [key isEqualToString:@"predicate string"] || [key isEqualToString:@"-ios predicate"]) {
        if (target.length == 0) return @[];
        return IUAFilterByPredicate(all, target);
    }

    if ([key isEqualToString:@"-ios class chain"] || [key isEqualToString:@"class chain"] ||
        [key isEqualToString:@"classchain"] || [key isEqualToString:@"-ios classchain"]) {
        return IUAEvaluateClassChain(target);
    }

    return @[];
}

+ (nullable UIView *)findViewUsing:(NSString *)strategy value:(NSString *)value index:(NSInteger)index {
    NSArray<UIView *> *views = [self findViewsUsing:strategy value:value];
    if (views.count == 0) return nil;
    NSInteger resolved = index;
    if (resolved < 0) resolved += (NSInteger)views.count;
    if (resolved < 0 || resolved >= (NSInteger)views.count) return nil;
    return views[(NSUInteger)resolved];
}

+ (NSString *)typeForView:(UIView *)view {
    return IUATypeForView(view);
}

+ (NSString *)xpathForView:(UIView *)view {
    return IUAXPathForView(view);
}

+ (NSDictionary<NSString *, id> *)attributesForView:(UIView *)view {
    return IUAAttributesForView(view);
}

+ (nullable id)attributeForView:(UIView *)view name:(NSString *)name {
    return IUAAttributeForView(view, name);
}

+ (NSDictionary<NSString *, id> *)elementsJSONForViews:(NSArray<UIView *> *)views
                                                 start:(NSInteger)start
                                                 limit:(NSInteger)limit
                                                 using:(NSString *)using
                                                 value:(NSString *)value {
    NSMutableArray<NSDictionary<NSString *, id> *> *elements = [NSMutableArray array];
    NSInteger begin = MAX(start, 0);
    NSInteger maxCount = limit > 0 ? limit : 0;
    if ((NSUInteger)begin < views.count) {
        NSUInteger end = views.count;
        if (maxCount > 0) end = MIN(views.count, (NSUInteger)(begin + maxCount));
        for (NSUInteger i = (NSUInteger)begin; i < end; i++) {
            NSMutableDictionary *info = [[self attributesForView:views[i]] mutableCopy];
            info[@"elementIndex"] = @(i);
            info[@"using"] = using;
            info[@"locatorValue"] = value;
            [elements addObject:info];
        }
    }
    return @{@"elements" : elements,
             @"count" : @(views.count),
             @"using" : using ?: @"",
             @"value" : value ?: @"",
             @"start" : @(begin),
             @"limit" : @(maxCount)};
}

+ (NSString *)pageSourceXML {
    return [self pageSourceXMLWithMaxDepth:0];
}

+ (NSString *)pageSourceXMLWithMaxDepth:(NSInteger)maxDepth {
    NSMutableString *xml = [NSMutableString string];
    [xml appendString:@"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"];
    [xml appendString:@"<AppiumAUT>\n"];

    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};
    NSString *appName = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"Application";
    UIWindow *keyWindow = [IUAViewIntrospector keyWindow];
    CGSize size = keyWindow ? keyWindow.bounds.size : UIScreen.mainScreen.bounds.size;
    [xml appendFormat:@"  <XCUIElementTypeApplication type=\"XCUIElementTypeApplication\" name=\"%@\" label=\"%@\" enabled=\"true\" visible=\"true\" accessible=\"false\" x=\"0\" y=\"0\" width=\"%g\" height=\"%g\">\n",
        IUAXMLEscape(appName), IUAXMLEscape(appName), size.width, size.height];

    for (UIWindow *window in [IUAViewIntrospector allWindows]) {
        IUAAppendNodeXML(xml, window, maxDepth, 2);
    }
    [xml appendString:@"  </XCUIElementTypeApplication>\n"];
    [xml appendString:@"</AppiumAUT>\n"];
    return xml;
}

+ (nullable UIView *)activeElement {
    gIUAActiveElementResponder = nil;
    [UIApplication.sharedApplication sendAction:@selector(iua_elementQueryCapture:)
                                             to:nil from:nil forEvent:nil];
    if ([gIUAActiveElementResponder isKindOfClass:[UIView class]]) {
        return (UIView *)gIUAActiveElementResponder;
    }
    return nil;
}

@end
