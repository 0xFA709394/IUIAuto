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
//  元素查询：Appium / XCUITest 风格的元素定位与属性模型
//
//  支持的定位策略（using）：
//    accessibility id / id  → accessibilityIdentifier
//    name                    → accessibilityLabel 或 accessibilityIdentifier
//    label                   → accessibilityLabel
//    text                    → 可见文本（UILabel/UITextField/UIButton/…）
//    class name / class      → UIKit 类名或 XCUIElementType 类型名
//    xpath                   → XCUITest 风格 XPath 子集
//    -ios predicate string   → NSPredicate 属性过滤
//    -ios class chain        → XCUITest class chain 子集
//
//  另外提供：
//    - XCUITest 类型名映射（UIButton → XCUIElementTypeButton）
//    - 元素属性字典（name/label/value/type/rect/enabled/visible/…）
//    - Appium page source 兼容的 XML
//    - 元素稳定 XPath（可回查）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString *const IUAElementQueryErrorDomain;
FOUNDATION_EXPORT NSString *const IUAElementStrategyAccessibilityId;
FOUNDATION_EXPORT NSString *const IUAElementStrategyName;
FOUNDATION_EXPORT NSString *const IUAElementStrategyLabel;
FOUNDATION_EXPORT NSString *const IUAElementStrategyText;
FOUNDATION_EXPORT NSString *const IUAElementStrategyClassName;
FOUNDATION_EXPORT NSString *const IUAElementStrategyXPath;
FOUNDATION_EXPORT NSString *const IUAElementStrategyPredicate;
FOUNDATION_EXPORT NSString *const IUAElementStrategyClassChain;

@interface IUAElementQuery : NSObject

/// 支持的定位策略名（用于 hello 能力上报 / 桥接文档）
+ (NSArray<NSString *> *)supportedStrategies;

/// 校验策略/表达式（xpath/class chain/predicate 语法错误返回 NO 并给出原因）
+ (BOOL)validateUsing:(NSString *)strategy value:(NSString *)value error:(NSString **)error;

/// 按策略返回全部匹配 view（视觉上层优先）；策略非法或表达式错误返回空数组
+ (NSArray<UIView *> *)findViewsUsing:(NSString *)strategy value:(NSString *)value;

/// 按策略返回第 index 个匹配（0 起；负数表示从末尾倒数）；越界返回 nil
+ (nullable UIView *)findViewUsing:(NSString *)strategy value:(NSString *)value index:(NSInteger)index;

/// XCUITest 元素类型名（如 XCUIElementTypeButton）
+ (NSString *)typeForView:(UIView *)view;

/// 元素稳定 XPath（如 /XCUIElementTypeWindow[1]/XCUIElementTypeOther[2]/XCUIElementTypeButton[1]）
+ (NSString *)xpathForView:(UIView *)view;

/// 完整属性字典（Appium 语义）：type/name/label/value/identifier/rect/enabled/visible/accessible/selected/focused/index/class/xpath/text
+ (NSDictionary<NSString *, id> *)attributesForView:(UIView *)view;

/// 单属性读取（get_attribute），未知属性返回 nil
+ (nullable id)attributeForView:(UIView *)view name:(NSString *)name;

/// 元素列表 JSON（find_elements 指令使用）：{ elements, count, using, value, start, limit }
+ (NSDictionary<NSString *, id> *)elementsJSONForViews:(NSArray<UIView *> *)views
                                                 start:(NSInteger)start
                                                 limit:(NSInteger)limit
                                                 using:(NSString *)using
                                                 value:(NSString *)value;

/// Appium page source 兼容 XML（含全部 window，Application → Window → …）
+ (NSString *)pageSourceXML;
+ (NSString *)pageSourceXMLWithMaxDepth:(NSInteger)maxDepth;

/// 当前 firstResponder 对应的 view（无则 nil）
+ (nullable UIView *)activeElement;

@end

NS_ASSUME_NONNULL_END
