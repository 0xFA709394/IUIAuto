# IUIAuto — iOS 端 UI 自动化 Agent（进程内模拟，不依赖 XCUITest）

## Context

构建 iOS 自动化项目的 iOS 端：一个 Objective-C App，作为常驻 Agent 通过 **WebSocket 长连接**接收控制服务器下发的 JSON 指令，在**本 App 进程内**模拟 UI 操作（点击/长按/滑动/文本输入/元素查询/截图），并把执行结果实时回传。

已确认的约束与选型：
- **非越狱真机** + **仅本 App 内部自动化** + **WebSocket 长连接** + **纯 Objective-C**
- 技术原理（无需越狱、无需私有 entitlement）：进程内合成 `UITouch` 并派发到目标 view 及其手势识别器，走完整响应链 —— 这是 KIF 测试框架验证过的成熟路线，Apple 开发签名下可用

## 架构

```
控制服务器 ⇄ WebSocket(JSON) ⇄ IUAWSClient        通信层：连接/心跳/指数退避重连
                               ⇅ IUACommandDispatcher  调度层：主线程串行 FIFO + 超时
                               ⇅ Action Handlers
     ┌──────────────┬──────────────┬─────────────────┬──────────────┐
IUATouchSynthesizer IUATextSynthesizer IUAViewIntrospector IUAScreenshot…
(合成UITouch派发)   (UIKeyInput输入)  (view树定位/查询)   (窗口截图)
```

## 指令协议（JSON over WebSocket）

- 请求：`{"id":"<uuid>","action":"tap","params":{"x":100,"y":200},"timeout":10}`
- 响应：`{"id":"<uuid>","success":true,"data":{…},"error":null,"duration":0.12}`
- 动作集 v1：`tap` / `tap_view`（按 identifier 定位）/ `double_tap` / `long_press` / `swipe`（插值步进）/ `type_text` / `clear_text` / `view_tree`（层级 JSON）/ `element_info` / `screenshot`（base64 PNG）/ `wait` / `ping`

## 关键实现点

1. **IUATouchSynthesizer**：`objc_msgSend` 调 `UITouch` 私有 setter（`setPhase:` / `setLocationInWindow:` / `setTimestamp:` / `setView:` / `setWindow:` / `setTapCount:`，KIF 同款）；运行时探测方法签名，多候选名回退以兼容 iOS 版本差异；对 `hitTest` 命中的 view **及其所有 gestureRecognizers** 派发 touchesBegan/Moved/Ended。tap=began+ended、long_press=中间延迟、swipe=多点插值。
2. **IUATextSynthesizer**：公开的 `UIKeyInput` 协议（`insertText:` / `deleteBackward:`）+ UIControl 事件同步触发。
3. **IUAViewIntrospector**：递归 keyWindow 层级，按 accessibilityIdentifier / label / class / 坐标定位。
4. **IUAWSClient**：`NSURLSessionWebSocketTask`（iOS 13+，零第三方依赖）+ `sendPing` 心跳 + 指数退避重连（1s→30s）。
5. **IUACommandDispatcher**：全部 UI 操作 hop 到主线程串行执行，单条指令超时控制，结果实时回传。
6. **DemoViewController**：内置演示界面（按钮+计数器、输入框、滑块、滚动列表），运行即可直观看到 App 被自动操作的效果。

## 文件结构

```
IUIAuto/
├── project.yml                  # xcodegen 定义（无第三方依赖）
├── README.md                    # 架构说明 + 协议文档 + 部署指南
├── Tools/mock_server.js         # Node 测试服务器：下发指令序列、打印回传结果
└── IUIAuto/
    ├── main.m / AppDelegate / DemoViewController(.h/.m)
    ├── Core/  IUAWSClient / IUACommand / IUACommandDispatcher / IUAConfiguration
    └── Actions/ IUATouchSynthesizer / IUATextSynthesizer / IUAViewIntrospector / IUAScreenshot / 各 action handler
```

## 实施步骤

1. 检查工具链（xcodegen，缺失则 brew 安装）→ 写 `project.yml`
2. 实现 Core 层（WS 客户端、指令模型、调度器）
3. 实现 Actions 层（触控合成、文本、查询、截图）
4. Demo UI + AppDelegate 集成（启动即连 WS，URL 可配置）
5. 编写 `Tools/mock_server.js` 与 README

## 验证

1. `xcodegen generate` + `xcodebuild -sdk iphonesimulator build` 编译通过
2. 端到端闭环：模拟器安装运行 App ↔ Node mock server；服务器下发 `tap`（点 Demo 按钮）→ `element_info`（验证计数变化）→ `screenshot`（回传 base64）→ 服务器收到全部 success 响应
3. 真机部署：用户在 Xcode 中选择自己的开发团队签名即可（README 说明）

## 风险说明（写入 README）

- 合成触控仅作用于本 App 进程（已确认的需求范围，非越狱下无法跨 App）
- 使用了 `UITouch` 私有 setter → 仅适用于开发签名/内部自动化场景，不可上架 App Store
- 私有 setter 名称随 iOS 版本可能变化 → 已用运行时探测 + 候选回退缓解