//
//  DemoViewController.h
//  IUIAuto
//

#import <UIKit/UIKit.h>

/// 演示界面：包含可被自动化指令操作的各类控件（每个都设置了 accessibilityIdentifier）
/// 控制服务器可通过 view_tree / element_info 发现这些元素并操作
@interface DemoViewController : UIViewController

@end
