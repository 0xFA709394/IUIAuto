Pod::Spec.new do |s|
  s.name             = 'IUIAUTO'
  s.version          = '0.1.1'
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
  s.source_files = 'IUIAUTO.h', 'IUIAuto/Core/**/*.{h,m}', 'IUIAuto/Actions/**/*.{h,m}'
  s.public_header_files =
    'IUIAuto/Core/IUAEngine.h',
    'IUIAuto/Core/IUAConfiguration.h',
    'IUIAuto/Core/IUACommandDispatcher.h',
    'IUIAuto/Actions/IUATouchSynthesizer.h',
    'IUIAuto/Actions/IUARecorder.h',
    'IUIAuto/Actions/IUAPerfSampler.h',
    'IUIAUTO.h'

  s.frameworks = 'UIKit', 'QuartzCore', 'Foundation'

  # UITouch 私有 setter（触控合成核心）：仅可用于开发签名/内部自动化，不可上架 App Store
  s.user_target_xcconfig = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'IUIAUTO_POD=1' }
  s.pod_target_xcconfig  = { 'GCC_PREPROCESSOR_DEFINITIONS' => 'IUIAUTO_POD=1' }
end
