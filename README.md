# IUIAuto — iOS UI 自动化 Agent（进程内模拟，不依赖 XCUITest）

iOS 自动化操作项目的 iOS 端：一个纯 Objective-C App，作为常驻 Agent 通过 **WebSocket 长连接**接收控制服务器下发的 JSON 指令，在**本 App 进程内**模拟 UI 操作（点击/长按/滑动/捏合/文本输入/元素查询/截图），并把执行结果实时回传。

- ✅ 不依赖 XCUITest/UITest/XCTest runner
- ✅ 非越狱真机可用（无需私有 entitlement，开发证书即可运行）
- ✅ 零第三方依赖（WebSocket 用系统 `NSURLSessionWebSocketTask`）
- ✅ **录制回放**：真机手工操作一遍，自动生成可读脚本（`Tools/run_script.js --record`）
- ✅ **中文 DSL 脚本 + 断言**：业务测试人员无需手写 JSON（`点击 btn.counter` / `断言文本 label.counter 包含 Count: 2`）
- ⚠️ 合成触控仅作用于**本 App 进程内**（非越狱 iOS 的沙箱限制，无法跨 App）

## 工作原理

```
控制服务器 ⇄ WebSocket(JSON) ⇄ IUAWebSocketClient        通信层：连接/心跳/指数退避重连(1s→30s)
                               ⇅ IUACommandDispatcher      调度层：主线程串行 FIFO + 单条超时
                               ⇅ IUAEngine                 总控：消息路由/动作注册/日志上报
     ┌──────────────┬──────────────┬─────────────────┬──────────────┐
IUATouchSynthesizer IUATextSynthesizer IUAViewIntrospector IUAScreenshotService
(合成 UITouch 派发) (UIKeyInput 输入)  (view 树定位/查询)   (窗口截图 base64)
```

**触控合成**（`IUATouchSynthesizer`）：
1. 通过 `UITouch` 私有 setter（运行时探测 `_setPhase:`/`setPhase:`、`_setLocationInWindow:resetPrevious:`/`setLocationInWindow:` 等候选名，兼容不同 iOS 版本）写入真实的 location/phase/timestamp ivar；
2. 自定义 `UIEvent` 子类包装 touches（实现 `touchesForView:`/`touchesForGestureRecognizer:`/`_firstTouchForView:` 等查询方法）；
3. 对 `hitTest` 命中的 view 及其父链上所有 `UIGestureRecognizer` 派发 `touchesBegan/Moved/Ended`；
4. 时间推进用 `dispatch_after`（主 runloop 保持活动，识别器内部定时器正常工作），因此长按、滚动手势等均能真实触发。

这条路线与 KIF 测试框架同源，已在 iOS 26.5 模拟器上端到端验证（含 UIControl 事件、系统手势识别器完整路径）。

## 快速开始

### 1. 编译（或用 Xcode 打开 `IUIAuto.xcodeproj`）

```bash
brew install xcodegen          # 若未安装
xcodegen generate              # 重新生成工程（改了文件结构后需要）
xcodebuild -project IUIAuto.xcodeproj -scheme IUIAuto \
  -sdk iphonesimulator -destination 'platform=iOS Simulator' build
```

> 本机 `xcode-select` 指向 CommandLineTools 时，给命令加前缀
> `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

### 2. 启动控制服务器（模拟器）

```bash
cd Tools && npm install
node mock_server.js --demo     # 自动演示：连接后自动执行全流程并输出 PASS/FAIL
node mock_server.js            # 或交互模式（help 查看指令，含 rec 录制）
```

### 3. 运行 App

模拟器安装启动后，Agent 自动连接 `ws://127.0.0.1:9800/ws`（模拟器内 127.0.0.1 即 Mac 本机）。
`--demo` 模式会自动执行：tap_view 点击计数按钮 → 坐标点击 → 验证计数 +2 → 中文文本输入 → 提交联动 → 上滑滚动 → 截图 → view_tree，12 项断言全部通过即为链路正常。

### 4. 真机部署

1. Xcode 打开工程，Signing & Capabilities 选择你的开发团队；
2. App 内顶部"控制服务器"卡片填入 Mac 的局域网地址，如 `ws://192.168.1.10:9800/ws`，点"连接"（地址会持久化）；
3. 真机与服务器处于同一网络即可收发指令。

## 面向测试人员：GUI 控制台（推荐入口）

零命令行操作的可视化工作台，覆盖完整的测试工作流：

```bash
cd Tools && node gui_server.js
# 浏览器打开 http://localhost:9900
```

| 区域 | 功能 |
|---|---|
| 顶部状态栏 | App 连接状态、设备/系统/屏幕信息、录制中 ● REC 指示 |
| 左侧 · 实时画面 | App 实时截图（可开 3s 自动刷新）；**直接点击画面任意位置 = 对 App 执行点击**，坐标自动换算并回填 |
| 左侧 · 元素树 | 完整 view 层级（identifier/类型/文本）；点选元素自动填入操作面板 |
| 手动操作 | 点击/双击/长按（标识或坐标）、文本输入/清空、滑动表单，结果即时反馈 |
| 录制 | 一键开始/停止，App 手工操作自动转成可编辑 DSL，保存进脚本库 |
| 脚本 | 脚本库管理（保存/加载/删除）、DSL 编辑器、一键 ▶ 运行 |
| 报告 | 逐步 ✓/✗ 结果、PASS/FAIL 汇总、**失败自动附现场截图** |
| 日志 | App 日志实时流 |

GUI 与 CLI（`mock_server.js`/`run_script.js`）共用 9800 端口，**同一时间只启动一个**。
脚本库存储在 `Tools/scripts/*.txt`，CLI 与 GUI 可共用同一批脚本。

## 录制回放 + DSL 脚本（CLI 方式）

业务测试人员**不需要手写 JSON**。推荐工作流：

### 录制 → 生成脚本（一遍手工操作）

```bash
cd Tools
node run_script.js --record 用例1.txt
# App 连上后开始录制（App 顶部出现 ● REC 徽标）
# 在模拟器/真机上手工点击、滑动、输入……
# 操作完成后回到终端按回车 → DSL 脚本自动保存为 用例1.txt
```

生成的脚本长这样（语义化、可手工编辑）：

```
# IUIAuto 录制脚本（可手工编辑）
点击 btn.counter
点击 btn.counter
输入 field.input 录制内容测试
滑动 200 620 200 340   # slider.demo
```

在脚本里补充断言（点击/输入是录的，"验证"是写的）：

```
断言文本 label.counter 包含 Count: 4
断言存在 btn.submit
```

### 回放 → 出报告

```bash
node run_script.js 用例1.txt
# 逐步输出 ✓/✗，失败自动保存失败现场截图 fail.png
# 全部通过 exit code 0，可接入 CI
```

### DSL 命令速查（中文/英文等价）

| 中文 | 英文 | 示例 |
|---|---|---|
| 探活 | ping | `探活` |
| 点击 id 或 x y | tap | `点击 btn.counter` / `点击 201 314` |
| 双击 x y | dtap | `双击 201 314` |
| 长按 id或x y [秒] | press | `长按 btn.submit 1.0` |
| 输入 id 文本 | type | `输入 field.input 你好 世界` |
| 清空 id | clear | `清空 field.input` |
| 滑动 fx fy tx ty [秒] | swipe | `滑动 200 600 200 300 0.4` |
| 捏合 cx cy r1 r2 | pinch | `捏合 200 400 150 30` |
| 等待 秒 | wait | `等待 1` |
| 截图 [文件] | shot | `截图 demo.png` |
| 断言文本 id 包含/等于 文本 | assert-text | `断言文本 label.counter 包含 Count: 2` |
| 断言存在 id | assert-exists | `断言存在 btn.submit` |
| 断言不存在 id | assert-missing | `断言不存在 btn.deleted` |

### 录制原理（可靠性说明）

录制钩子埋在两条**互斥**的事件路径上，真实操作与合成回放都能录且不会重复：

- 真实手指 → `UIWindow sendEvent:`（method swizzle，所有真实触控必经之路）
- 合成触控（回放指令）→ `IUATouchSynthesizer` 派发点

tap/长按/滑动按位移(≥14pt)与时长(≥0.45s)自动判定；输入通过 `UITextField/UITextView` 变更通知捕获，同一输入框连续按键合并为一步。

## 指令协议（JSON over WebSocket）

### 下行（服务器 → App）：指令

```json
{ "id": "cmd-42", "action": "tap", "params": { "x": 100, "y": 200 }, "timeout": 10 }
```

| action | params | 说明 |
|---|---|---|
| `ping` | — | 探活，返回时间戳 |
| `app_info` | — | 设备/屏幕/Agent 信息 |
| `wait` | `seconds` (≤60) | 等待 |
| `tap` | `x`,`y` 或 `identifier` | 坐标/元素点击 |
| `tap_view` | `identifier` | 按 accessibilityIdentifier 点击 |
| `double_tap` | `x`,`y` | 双击 |
| `long_press` | `x`,`y`,`duration`(默认 0.8s) | 长按 |
| `swipe` | `fromX`,`fromY`,`toX`,`toY`,`duration`(默认 0.3s) | 滑动（线性插值步进） |
| `pinch` | `x`,`y`,`radiusFrom`,`radiusTo`,`duration` | 双指捏合 |
| `type_text` | `text`,`identifier?` | 输入文本（无 identifier 时输入到当前焦点） |
| `clear_text` | `identifier?` | 清空输入框 |
| `view_tree` | `maxDepth`? | 全窗口 view 树 JSON |
| `element_info` | `identifier` | 单个元素信息（class/frame/text/…） |
| `screenshot` | `quality` 0小/1中/≥2原始 | 截图，返回 base64 PNG |
| `record_start` | — | 开始录制（App 显示 ● REC 徽标） |
| `record_stop` | — | 停止录制，返回 `{steps:[…], count}`（可 `stepsToDSL` 转 DSL） |
| `record_cancel` / `record_status` | — | 取消录制 / 查询录制状态 |

### 上行（App → 服务器）

```json
{"type":"hello","agent":"IUIAuto","version":"1.0.0","environment":{…},"actions":[…]}   // 连接建立
{"type":"result","id":"cmd-42","ok":true,"data":{…},"error":null,"elapsed":0.064}      // 指令结果
{"type":"pong","timestamp":1760000000000}                                              // 应答 {"type":"ping"}
{"type":"log","level":1,"message":"…"}                                                 // 日志转发(Info 以上)
```

坐标均为 window 逻辑点（y 从顶部起算）。`identifier` 即控件的 `accessibilityIdentifier`。

## 项目结构

```
├── project.yml                  # xcodegen 定义（改结构后需 xcodegen generate）
├── IUIAuto/
│   ├── SupportingFiles/main.m / Info.plist(生成)
│   ├── App/AppDelegate          # 启动即连接服务器；回前台自动重连
│   ├── UI/DemoViewController    # 演示界面（计数按钮/输入框/滑块/滚动列表，均带 identifier）
│   ├── Core/
│   │   ├── IUAWebSocketClient   # 通信层：心跳/重连/JSON 收发
│   │   ├── IUACommandDispatcher # 调度层：串行 FIFO + 超时
│   │   ├── IUACommand(Result)   # 指令/结果模型
│   │   ├── IUAEngine            # 总控：路由 + 18 个动作注册
│   │   ├── IUAConfiguration     # 服务器地址等配置(UserDefaults 持久化)
│   │   └── IUALogger            # 日志(可转发到服务器)
│   └── Actions/
│       ├── IUATouchSynthesizer  # 触控合成（核心）
│       ├── IUARecorder          # 操作录制(sendEvent + 派发点双路径钩子)
│       ├── IUATextSynthesizer   # 文本输入(UIKeyInput)
│       ├── IUAViewIntrospector  # view 树查询/定位
│       └── IUAScreenshotService # 截图
└── Tools/                       # 控制端（Node）
    ├── gui_server.js / gui.html # ★ GUI 控制台（浏览器可视化工作台）
    ├── mock_server.js           # 控制服务器模拟器(交互/--demo 自动验证/rec 录制)
    ├── iua_dsl.js               # DSL 解析器 + 录制步骤→DSL 转换
    ├── iua_runner.js            # 脚本执行器共享模块(GUI/CLI 复用)
    ├── run_script.js            # 脚本执行器/录制器(断言+报告+exit code)
    ├── record_test.mjs          # 录制功能端到端自检
    └── scripts/                 # GUI/CLI 共享的脚本库
```

## 约束与风险说明

- **仅本 App 内**：非越狱 iOS 不允许跨进程注入触控（Apple 沙箱）。需要控制系统级界面时，可选方案为越狱设备（IOHIDEvent 注入，如 ZXTouch）或模拟器。
- **私有 API**：`UITouch` 的私有 setter 属私有 API，**不可上架 App Store**；本 App 仅适用于开发签名分发/内部自动化/测试场景。
- **版本兼容**：私有 setter 名称可能随 iOS 版本变化。实现已做"候选方法名运行时探测 + 多名回退"，并对未知方法调用打印告警日志（`IUASyntheticEvent 被请求未实现的方法`）——出现该日志说明需要为新 iOS 版本补充方法。
- **指令超时**：超时后结果丢弃但触控序列可能仍在执行（v1 不中断），避免在同一目标上连发高密度长时指令。

## 已验证环境

- Xcode 26.6 / iOS 26.5 模拟器（iPhone 17 Pro）
- 指令链路端到端断言 12/12 通过：identifier 点击、坐标点击、计数联动、中文输入、提交联动、滑动滚动、截图、view 树导出
- 录制回放闭环 6/6 通过：合成操作录制（tap×2/type_text/swipe 步骤数与内容精确校验）→ DSL 生成 → 回放 + 断言（`Count: 4` 验证录制与回放双向生效）
