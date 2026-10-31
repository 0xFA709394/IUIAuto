//
//  IUAViewIntrospector.h
//  IUIAuto
//
//  视图内省：定位 view（accessibilityIdentifier）、导出 view 树/信息 JSON
//  供控制服务器做元素级定位（tap_view/type_text 等按 identifier 操作）
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IUAViewIntrospector : NSObject

/// 当前 keyWindow（iOS 13+ scene 兼容）
+ (nullable UIWindow *)keyWindow;
/// 所有已连接的 window（含 keyWindow 在内的可用层级）
+ (NSArray<UIWindow *> *)allWindows;

/// 全窗口深度搜索 accessibilityIdentifier 等于 identifier 的 view（上层视图优先）
+ (nullable UIView *)findViewWithIdentifier:(NSString *)identifier;
/// 全窗口搜索 accessibilityLabel 等于 label 的 view
+ (nullable UIView *)findViewWithAccessibilityLabel:(NSString *)label;

/// 单个 view 的信息 JSON（class/identifier/label/frame/状态/文本内容/子节点）
+ (NSDictionary<NSString *, id> *)infoJSONForView:(UIView *)view maxDepth:(NSInteger)maxDepth;

/// 整棵 view 树（含 window 层级），maxDepth<=0 表示不限制
+ (NSArray<NSDictionary<NSString *, id> *> *)viewTreeJSONWithMaxDepth:(NSInteger)maxDepth;

/// 屏幕/设备信息 JSON（app_info 指令用）
+ (NSDictionary<NSString *, id> *)environmentJSON;

@end

NS_ASSUME_NONNULL_END
