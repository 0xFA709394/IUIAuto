//
//  IUAFloatingStatusBar.h
//  IUIAUTO
//
//  悬浮状态条：Agent 连接调试服务端成功后悬浮于界面顶部的小状态条。
//    - 已连接：      "● IUIAuto 已连接"
//    - 执行自动化中： "▶ IUIAuto 执行自动化中…"（有指令在执行时自动切换）
//    - 断开连接：    自动隐藏
//  点击悬浮条可打开服务端配置页（IUAConfigViewController）。
//
//  使用：无需手动管理——[IUAEngine sharedEngine] 连接状态变化时自动显示/隐藏；
//  也可通过 enabled 属性整体关闭悬浮条。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface IUAFloatingStatusBar : NSObject

/// 单例（自动跟随连接/执行状态，懒加载并挂接到当前 keyWindow）
+ (instancetype)sharedBar;

/// 总开关（默认 YES）。NO 时即使已连接也不显示。
@property (nonatomic, assign, getter=isEnabled) BOOL enabled;

/// 立即刷新显示状态（一般无需手动调用）
- (void)refresh;

/// 连接状态驱动（由 IUAEngine 自动调用：YES 显示悬浮条 / NO 隐藏）
- (void)setConnected:(BOOL)connected;

@end

NS_ASSUME_NONNULL_END
