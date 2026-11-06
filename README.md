# IUIAuto — iOS UI 自动化 Agent（进程内模拟，不依赖 XCUITest）

iOS 自动化操作项目的 iOS 端：一个纯 Objective-C App，作为常驻 Agent 通过 **WebSocket 长连接**接收控制服务器下发的 JSON 指令，在**本 App 进程内**模拟 UI 操作（点击/长按/滑动/捏合/文本输入/元素查询/截图），并把执行结果实时回传。

- ✅ 不依赖 XCUITest/UITest/XCTest runner
- ✅ 非越狱真机可用（无需私有 entitlement，开发证书即可运行）
- ✅ 零第三方依赖（WebSocket 用系统 `NSURLSessionWebSocketTask`）
- ✅ **录制回放**：真机手工操作一遍，自动生成可读脚本（`Tools/run_script.js --record`）
- ✅ **中文 DSL 脚本 + 断言**：业务测试人员无需手写 JSON（`点击 btn.counter` / `断言文本 label.counter 包含 Count: 2`）
- ✅ **性能监测**：脚本运行期间自动采样 App CPU/内存/FPS 并输出报告摘要；可同步调用 **xctrace** 录制 `.trace`（真机全模板可用）
- 📖 **完整操作参考见 [使用手册.md](使用手册.md)**（GUI 详解 / DSL 全表 / 指令协议 / CocoaPods 集成）
- 📦 iOS 库已封装为 CocoaPods pod（`IUIAUTO.podspec`，已通过 lib lint）——宿主 App 三行代码接入
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

### 测试人员（一条命令，浏览器操作）

```bash
./start.sh     # 自动：依赖检查 → 模拟器/App 就绪(缺失自动构建) → GUI 控制台 → 打开浏览器
```

打开后按页面顶部「🚀 快速上手」三步走：**确认连接 → 点画面直接操作 → 录制脚本回放**。
脚本编辑页自带「命令参考」，点击即插入命令模板，不需要背语法。

- 模拟器场景开箱即用（默认连 `ws://127.0.0.1:9800/ws`）
- 真机：App 顶部"控制服务器"卡片填 Mac 局域网地址（如 `ws://192.168.1.10:9800/ws`）→ 点"连接"
- 重启 GUI：再跑一次 `./start.sh`（端口被旧实例占用会自动接管）

### 开发人员

```bash
./build.sh     # 一键：生成工程 → 编译 → 安装到模拟器 → 启动 App
               # 自动处理 xcode-select 指向 CLT / xcodegen 缺失等环境问题
make test      # 端到端验证：demo 12 断言 + 录制回放 + CLI 脚本执行
make gui       # 等价 ./start.sh；其他目标见 Makefile
```

也可用 Xcode 打开 `IUIAuto.xcodeproj` 手动构建；**改动文件结构（新增/删除源文件）后**需 `xcodegen generate`（`./build.sh` 已自动处理）。真机部署：Xcode 选开发团队签名即可。

### 环境要求

macOS + Xcode（含 iOS 模拟器运行时）+ Node.js 18+。首次运行会自动安装 xcodegen（brew）与 ws（npm）。

## 面向测试人员：GUI 控制台（推荐入口）

零命令行操作的可视化工作台（`./start.sh` 即达），也可手动启动：

```bash
cd Tools && node gui_server.js [--takeover]
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
端口被旧实例占用时会给出友好提示（含占用进程 pid 与处理指引），也可以 `--takeover` 自动接管：

```bash
node gui_server.js --takeover     # 自动结束本工具旧实例并接管端口（不会动其他程序）
```
脚本库存储在 `Tools/scripts/*.txt`，CLI 与 GUI 可共用同一批脚本。

## 性能监测（脚本运行期间的 CPU / 内存 / FPS / xctrace）

在 UI 自动化执行的同时观察被测 App 的性能，双数据源设计：

### 1. App 内采样（任何环境可靠，默认开启）

```bash
node run_script.js --perf 用例1.txt          # CLI：运行期间 0.5s 周期采样
```
GUI：脚本页勾选「性能监测」→ 运行结束后报告页直接显示性能摘要表。

报告示例：
```
── 性能摘要（App 内采样）─────────────────────
时长 4.0s / 8 点
CPU%       min 0.2 | avg 21.0 | p95 112.3 | max 112.3
系统CPU%   min 1.0 | avg 7.9 | p95 19.8 | max 19.8
物理内存MB min 24.5 | avg 31.0 | p95 32.0 | max 32.0
FPS        min 48 | avg 56.3 | p95 61 | max 61
```

数据来自 App 端 `IUAPerfSampler`（公开 mach API：`task_threads`+`thread_info` 算 CPU、
`TASK_VM_INFO` 的 `phys_footprint` 算内存、`CADisplayLink` 算 FPS），真机/模拟器均可用。
也可单独调用指令：`perf_start` / `perf_stop` / `perf_sample`（即时单点）。

### 2. xctrace 录制（深度分析，Instruments 可视化）

```bash
node run_script.js --xctrace 用例1.txt              # 默认 Time Profiler
node run_script.js --xctrace="Allocations" 用例1.txt # 指定模板
node run_script.js --perf --xctrace 用例1.txt        # 双数据源同时开启
```

- 测试运行期间自动 `xctrace record --attach`，结束后停止并保存 `.trace` 到 `Tools/traces/`
- trace 文件可直接拖入 Xcode Instruments GUI 做火焰图/内存曲线等深度分析
- 尽力导出摘要（`sysmon-process` 等 schema 的 CPU%/内存序列）
- **环境限制（实测）**：模拟器上 Activity Monitor 等服务不可用（真机专属）、Time Profiler 在部分
  环境 CLI 停止管线挂起——封装对此做了超时保护与**优雅降级**（记录原因、不阻塞测试）；
  真机部署时全模板预期可用
- GUI：脚本页勾选「xctrace 录制」，报告页显示 trace 路径与导出摘要

### 相关新增指令/能力

| 指令/DSL | 说明 |
|---|---|
| `perf_start` / `perf_stop` / `perf_sample` | App 内性能采样控制 |
| `dismiss_keyboard`（DSL：`收起键盘`） | 收起软键盘（避免遮挡点击） |
| `tap_view` 自动滚动 | 元素不在可视区时自动 `scrollRectToVisible` 再点击，并带重试 |

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
| 收起键盘 | dismiss | `收起键盘` |
| 按键 回车/删除/字符 | key | `按键 回车`（不依赖键盘 UI 显示） |
| 点击 id 或 x y | tap | `点击 btn.counter` / `点击 201 314` |
| 双击 x y | dtap | `双击 201 314` |
| 长按 id或x y [秒] | press | `长按 btn.submit 1.0` |
| 输入 id 文本 | type | `输入 field.input 你好 世界` |
| 清空 id | clear | `清空 field.input` |
| 滑动 fx fy tx ty [秒] | swipe | `滑动 200 600 200 300 0.4` |
| 捏合 cx cy r1 r2 | pinch | `捏合 200 400 150 30` |
| 等待 秒 | wait | `等待 1`（队列等待，不卡 App UI） |
| 等待出现 <标识> [秒] | wait_for | `等待出现 btn.submit 8`（轮询至出现，默认 10s） |
| 等待消失 <标识> [秒] | wait_for | `等待消失 loading 5` |
| 上滑/下滑/左滑/右滑 [pt] [起点] | swipe | `上滑 400`、`下滑 300 btn.counter` |
| 滚动到 <标识> | scroll_to | `滚动到 label.row.12` |
| 断言值 <标识> 包含/等于 值 | assert-value | `断言值 slider.demo 等于 50`（slider/switch 值） |
| 循环 N … 结束循环 | loop | `循环 5` / `结束循环`（块内重复 5 次，可嵌套，上限 100） |
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

## Licenses

```
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
```
