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

#import "IUAViewIntrospector.h"
#import "IUAConfiguration.h"
#import "IUATouchSynthesizer.h"
#import <sys/utsname.h>

@implementation IUAViewIntrospector

#pragma mark - Window

+ (NSArray<UIWindow *> *)allWindows {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
        }
    }
    if (windows.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [windows addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    }
    return windows;
}

+ (nullable UIWindow *)keyWindow {
    // 排除键盘等系统浮层（动画期间 scene.keyWindow 可能短暂返回 UITextEffectsWindow）
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) {
            if ([window isKindOfClass:NSClassFromString(@"UITextEffectsWindow")] ||
                [window isKindOfClass:NSClassFromString(@"UICallBarWindow")]) {
                continue;
            }
            if (window.isKeyWindow) {
                return window;
            }
            if (!fallback && window.rootViewController != nil) {
                fallback = window;
            }
        }
    }
    if (fallback) {
        return fallback;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
}

#pragma mark - 搜索

+ (nullable UIView *)findViewWithIdentifier:(NSString *)identifier {
    return [self searchWindows:^BOOL(UIView *view) {
        return [view.accessibilityIdentifier isEqualToString:identifier];
    }];
}

+ (nullable UIView *)findViewWithAccessibilityLabel:(NSString *)label {
    return [self searchWindows:^BOOL(UIView *view) {
        return [view.accessibilityLabel isEqualToString:label];
    }];
}

/// 倒序深度优先（数组末尾的子视图在视觉上层，应优先命中）
+ (nullable UIView *)searchWindows:(BOOL (^)(UIView *view))predicate {
    for (UIWindow *window in [self allWindows].reverseObjectEnumerator) {
        UIView *found = [self recursiveSearchIn:window predicate:predicate];
        if (found) {
            return found;
        }
    }
    return nil;
}

+ (nullable UIView *)recursiveSearchIn:(UIView *)root predicate:(BOOL (^)(UIView *view))predicate {
    if (predicate(root)) {
        return root;
    }
    for (UIView *subview in root.subviews.reverseObjectEnumerator) {
        UIView *found = [self recursiveSearchIn:subview predicate:predicate];
        if (found) {
            return found;
        }
    }
    return nil;
}

#pragma mark - JSON 导出

+ (NSArray<NSDictionary<NSString *, id> *> *)viewTreeJSONWithMaxDepth:(NSInteger)maxDepth {
    NSMutableArray *trees = [NSMutableArray array];
    UIWindow *keyWindow = [self keyWindow];
    for (UIWindow *window in [self allWindows]) {
        NSDictionary *info = [self infoJSONForView:window maxDepth:maxDepth];
        NSMutableDictionary *mutable = [info mutableCopy];
        mutable[@"isKeyWindow"] = @(window == keyWindow);
        [trees addObject:mutable];
    }
    return trees;
}

+ (NSDictionary<NSString *, id> *)infoJSONForView:(UIView *)view maxDepth:(NSInteger)maxDepth {
    UIWindow *window = [self keyWindow];
    CGRect frameInWindow = window ? [view convertRect:view.bounds toView:nil] : view.frame;

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"class"] = NSStringFromClass(view.class);
    info[@"identifier"] = view.accessibilityIdentifier ?: @"";
    info[@"label"] = view.accessibilityLabel ?: @"";
    info[@"frame"] = @{@"x" : @(round(frameInWindow.origin.x * 10) / 10),
                       @"y" : @(round(frameInWindow.origin.y * 10) / 10),
                       @"width" : @(round(frameInWindow.size.width * 10) / 10),
                       @"height" : @(round(frameInWindow.size.height * 10) / 10)};
    info[@"alpha"] = @(view.alpha);
    info[@"hidden"] = @(view.hidden);
    info[@"enabled"] = @(view.userInteractionEnabled);
    info[@"window"] = view.window ? NSStringFromClass(view.window.class) : @"(nil)";
    info[@"windowHidden"] = @(view.window.hidden);

    // 常见控件的值
    if ([view isKindOfClass:[UILabel class]]) {
        info[@"text"] = ((UILabel *)view).text ?: @"";
    } else if ([view isKindOfClass:[UITextField class]]) {
        info[@"text"] = ((UITextField *)view).text ?: @"";
    } else if ([view isKindOfClass:[UITextView class]]) {
        info[@"text"] = ((UITextView *)view).text ?: @"";
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSString *title = [button titleForState:UIControlStateNormal] ?: [button titleForState:UIControlStateHighlighted] ?: @"";
        info[@"text"] = title;
    } else if ([view isKindOfClass:[UISwitch class]]) {
        info[@"value"] = @(((UISwitch *)view).on);
    } else if ([view isKindOfClass:[UISlider class]]) {
        info[@"value"] = @(((UISlider *)view).value);
    }

    if (maxDepth != 1) {
        NSInteger childDepth = (maxDepth > 0) ? maxDepth - 1 : maxDepth;
        NSMutableArray *children = [NSMutableArray array];
        for (UIView *subview in view.subviews) {
            [children addObject:[self infoJSONForView:subview maxDepth:childDepth]];
        }
        info[@"children"] = children;
        info[@"childrenCount"] = @(view.subviews.count);
    }
    return info;
}

+ (NSDictionary<NSString *, id> *)environmentJSON {
    UIScreen *screen = UIScreen.mainScreen;
    UIWindow *window = [self keyWindow];
    CGSize size = window ? window.bounds.size : screen.bounds.size;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary ?: @{};

    NSString *orientation = @"PORTRAIT";
    UIInterfaceOrientation orientationValue = UIInterfaceOrientationUnknown;
    if (window.windowScene) {
        orientationValue = window.windowScene.interfaceOrientation;
    } else {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            orientationValue = ((UIWindowScene *)scene).interfaceOrientation;
            break;
        }
    }
    if (orientationValue == UIInterfaceOrientationLandscapeLeft ||
        orientationValue == UIInterfaceOrientationLandscapeRight) {
        orientation = @"LANDSCAPE";
    }

    return @{
        @"agent" : @"IUIAuto",
        @"version" : [IUAConfiguration agentVersion],
        @"systemVersion" : UIDevice.currentDevice.systemVersion,
        @"deviceModel" : [self deviceModelIdentifier],
        @"deviceName" : UIDevice.currentDevice.name ?: @"",
        @"bundleId" : info[@"CFBundleIdentifier"] ?: (NSBundle.mainBundle.bundleIdentifier ?: @""),
        @"appName" : info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"] ?: @"",
        @"appVersion" : info[@"CFBundleShortVersionString"] ?: @"",
        @"build" : info[@"CFBundleVersion"] ?: @"",
        @"orientation" : orientation,
        @"screen" : @{@"width" : @(size.width),
                      @"height" : @(size.height),
                      @"scale" : @(screen.scale)},
        @"touchSynthesisSupported" : @([self touchSynthesisSupported]),
    };
}

+ (NSString *)deviceModelIdentifier {
    struct utsname systemInfo;
    uname(&systemInfo);
    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"unknown";
}

+ (BOOL)touchSynthesisSupported {
    return [IUATouchSynthesizer isSupported];
}

@end
