Pod::Spec.new do |s|
  s.name             = 'IUIAUTO'
  s.version          = '0.3.0'
  s.summary          = 'IUIAuto — iOS UI 自动化 Agent（进程内触控合成，不依赖 XCUITest）'
  s.description      = <<-DESC
    通过 WebSocket 长连接接收控制服务器下发的 JSON 指令，在宿主 App 进程内
    模拟 UI 操作（点击/双击/长按/滑动/捏合/文本输入/元素查询/截图/录制/性能采样）。
    不依赖 XCUITest/XCTest runner，非越狱真机可用（开发证书即可）。
    合成触控仅作用于宿主 App 进程内（iOS 沙箱限制）。
  DESC

  s.homepage         = 'https://github.com/0xFA709394/IUIAuto'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { '0xFA709394' => 'skyprayer@126.com' }
  # 私有库：宿主通过 :path 本地引用（pod 'IUIAUTO', :path => '…'）；
  # 发布到私有 pod repo 时改为真实 git 地址
  s.source           = { :git => 'https://github.com/0xFA709394/IUIAuto.git', :tag => s.version.to_s }

  s.ios.deployment_target = '13.0'
  s.swift_version    = '5.0'   # 纯 OC，占位声明（部分 lint 工具需要）
  
  # 库源码 = Core（通信/调度/总控）+ Actions（触控合成/录制/文本/查询/截图/性能采样）
  # 不含 demo App 壳（App/UI/SupportingFiles）
  s.source_files = 'Sources/IUIAUTO.h', 'Sources/IUIAUTOVersion.m', 'Sources/Core/**/*.{h,m}', 'Sources/Actions/**/*.{h,m}', 'Sources/UI/**/*.{h,m}'
  # 全部头设为 public：public 头之间存在互引（如 IUACommandDispatcher.h → IUACommand.h），
  # 任何被 public 头 import 的头若不在 public 列表，宿主在 framework 模式下展开伞头链时会报
  # 'xxx.h' file not found。纯 OC 库统一全公开最稳妥。
  s.public_header_files = 'Sources/**/*.h'

  # 显式声明全部依赖框架：pod_target 关闭了 modules（CLANG_ENABLE_MODULES=NO），
  # auto-link 失效，CoreGraphics（CGRectGetMidX/Y 等）等必须显式链接，否则链接期符号未定义
  s.frameworks = 'UIKit', 'QuartzCore', 'Foundation', 'CoreGraphics'

  
  
  # DEFINES_MODULE 保持默认 YES：宿主需要 @import IUIAUTO / #import <IUIAUTO/IUIAUTO.h>
  # （module map 必须生成；早期为绕过非模块化 include 警告曾关闭，会导致 trunk 验证
  #   与宿主 framework 集成时 Module not found，已回退为允许非模块化 include 的方式）
   s.pod_target_xcconfig = {
     'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
   }

   
   # 仅放开非模块化 include 检查；不再覆盖宿主的预处理器定义
   s.user_target_xcconfig = {
     'CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES' => 'YES'
   }
end
