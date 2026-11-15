# IUIAuto × Appium：WebDriver 桥接指南

> 目标：让**标准 Appium 客户端**（WebdriverIO、Appium Python/Java client、CI 平台）直接驱动 IUIAuto，
> 而不需要改造成 IUIAuto 私有协议。
>
> HTTP 侧说 **W3C WebDriver / Appium 协议**，底层翻译为 IUIAuto App 的 WebSocket JSON 指令。
> iOS 端仍然**不依赖 XCUITest / WebDriverAgent**，操作在宿主 App 进程内完成。
>
> 已用 **WebdriverIO 10.2.0** 真实客户端验证：建会话 / `~` 定位 / click / setValue /
> getPageSource / takeScreenshot / performActions / getAlertText / sendAlertText / acceptAlert /
> queryAppState / isAppInstalled / getActiveElement / 链式子元素 / deleteSession 全部通过。

---

## 1. 快速开始

### 方式 A：与 GUI 控制台一起启动（推荐）

```bash
./start.sh
# GUI 控制台:  http://localhost:9900
# Appium 桥:   http://localhost:4723
```

`gui_server.js` 会自动在 4723 启动桥，并与 GUI 共用同一条 App 连接（App 仍连 9800）。

### 方式 B：独立启动桥（无 GUI / CI）

```bash
cd Tools
node appium_bridge.js --takeover
# [appium-bridge] App 连接端口 ws://0.0.0.0:9800/ws
# [appium-bridge] WebDriver 端点: http://127.0.0.1:4723
```

- `--takeover`：端口被本工具旧实例占用时自动接管
- `BRIDGE_PORT=4723 APP_PORT=9800 node appium_bridge.js` 自定义端口
- App 未启动时桥会等待；15 秒后尝试自动拉起模拟器 App

### 能力（Capabilities）

```json
{
  "platformName": "iOS",
  "appium:automationName": "IUIAuto",
  "appium:deviceName": "iPhone",
  "appium:bundleId": "com.iuiauto.example"
}
```

`POST /session` 返回的 capabilities 还会包含 `appium:platformVersion`、`appium:deviceModel`、
`appium:appVersion`、`appium:elementStrategies` 等。`appium:automationName` 固定回写为 `IUIAuto`。

> `appium:udid`（或环境变量 `IUA_UDID`）：指定目标模拟器。宿主侧设备管理（App 生命周期/
> 安装/文件/录屏）只在模拟器上可用；未显式指定 udid 时按 App 上报的机型自动判断，
> 恰好一台模拟器 booted 时自动选中，多台时必须指定。

> 旧式 JSON Wire 的 `desiredCapabilities` 也兼容；W3C 的 `capabilities.alwaysMatch/firstMatch` 优先。

---

## 2. 客户端示例

### WebdriverIO

```js
import { remote } from 'webdriverio';

const driver = await remote({
  hostname: '127.0.0.1',
  port: 4723,
  path: '/',
  capabilities: {
    platformName: 'iOS',
    'appium:automationName': 'IUIAuto',
    'appium:deviceName': 'iPhone Simulator',
    'appium:bundleId': 'com.iuiauto.example',
  },
});

const counter = await driver.$('~btn.counter');       // accessibility id
await counter.click();
console.log(await driver.$('~label.counter').getText()); // Count: 1

const field = await driver.$('//XCUIElementTypeTextField[@name="field.input"]');
await field.setValue('你好 Appium');
console.log(await driver.getPageSource());            // XCUITest 风格 XML
await driver.deleteSession();
```

### Appium Python Client

```python
from appium import webdriver
from appium.options.common.base import AppiumOptions

options = AppiumOptions()
options.set_capability("platformName", "iOS")
options.set_capability("appium:automationName", "IUIAuto")
options.set_capability("appium:bundleId", "com.iuiauto.example")

driver = webdriver.Remote("http://127.0.0.1:4723", options=options)
driver.find_element("accessibility id", "btn.counter").click()
print(driver.find_element("accessibility id", "label.counter").text)

from selenium.webdriver.common.actions.action_builder import ActionBuilder
from selenium.webdriver.common.actions.pointer_input import PointerInput
actions = ActionBuilder(driver, mouse=PointerInput("touch", "finger"))
actions.pointer_action.move_to_location(200, 320)
actions.pointer_action.click()
actions.perform()

driver.quit()
```

### curl（协议调试）

```bash
curl -s http://127.0.0.1:4723/status
curl -s -X POST http://127.0.0.1:4723/session \
  -H 'Content-Type: application/json' \
  -d '{"capabilities":{"alwaysMatch":{"platformName":"iOS","appium:automationName":"IUIAuto"}}}'

curl -s -X POST http://127.0.0.1:4723/session/<SID>/element \
  -H 'Content-Type: application/json' \
  -d '{"using":"accessibility id","value":"btn.counter"}'
```

---

## 3. 支持的定位策略

| `using` | 说明 | 示例 value |
|---|---|---|
| `accessibility id` / `id` | accessibilityIdentifier | `btn.counter` |
| `name` | 标识或可访问标签 | `btn.counter` / `提交` |
| `label` | 可访问标签（无标签时回退文本/占位符） | `提交` |
| `text` | 可见文本 | `Count: 1` |
| `class name` | UIKit 类名或 XCUIElementType | `UIButton` / `XCUIElementTypeButton` |
| `xpath` | XCUITest 风格 XPath 子集 | `//XCUIElementTypeButton[@name="btn.counter"]` |
| `-ios predicate string` | NSPredicate 属性过滤 | `type == "XCUIElementTypeButton" AND label CONTAINS "点我"` |
| `-ios class chain` | XCUITest class chain 子集 | `**/XCUIElementTypeButton[\`name == "btn.counter"\`]` |
| `tag name` | 映射为 `class name`（兼容 Selenium 习惯） | `XCUIElementTypeButton` |
| `link text` / `partial link text` | 映射为 label 精确/包含（兼容 Selenium 习惯） | `提交` |

元素属性（`GET .../attribute/:name`）支持：
`name`、`label`、`value`、`text`、`identifier`、`type`、`class`、`enabled`、`visible`、
`displayed`、`accessible`、`selected`、`focused`、`index`、`rect`、`x`、`y`、`width`、`height`、`xpath`、`placeholder`。

---

## 4. 已实现端点

### 会话 / 元素

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/status` | 桥状态 |
| POST | `/session` | 创建会话 |
| DELETE | `/session/:id` | 结束会话 |
| GET | `/session/:id` | 当前 capabilities |
| POST | `/session/:id/element` | 查找单个元素 |
| POST | `/session/:id/elements` | 查找多个元素 |
| GET | `/session/:id/element/active` | 当前焦点元素 |
| POST | `/session/:id/element/:eid/element` | 在父元素下查找子元素 |
| POST | `/session/:id/element/:eid/elements` | 在父元素下查找多个子元素 |
| POST | `/session/:id/element/:eid/click` | 点击 |
| POST | `/session/:id/element/:eid/value` | 输入文本 |
| POST | `/session/:id/element/:eid/clear` | 清空 |
| GET | `/session/:id/element/:eid/text` | 文本 |
| GET | `/session/:id/element/:eid/name` | name |
| GET | `/session/:id/element/:eid/rect` | 矩形 |
| GET | `/session/:id/element/:eid/displayed` | 是否显示 |
| GET | `/session/:id/element/:eid/enabled` | 是否可用 |
| GET | `/session/:id/element/:eid/selected` | 是否选中 |
| GET | `/session/:id/element/:eid/screenshot` | 元素截图（base64） |
| GET | `/session/:id/element/:eid/attribute/:name` | 属性 |
| GET | `/session/:id/element/:eid/property/:name` | 属性（同 attribute） |

### 页面 / 手势 / 会话配置

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/session/:id/source` | 页面源码 XML |
| GET | `/session/:id/screenshot` | 窗口截图（base64） |
| POST | `/session/:id/actions` | W3C Actions（单指/双指/键盘） |
| DELETE | `/session/:id/actions` | 释放手势（no-op） |
| POST | `/session/:id/timeouts` | 隐式/页面/脚本超时 |
| POST | `/session/:id/timeouts/implicit_wait` | 隐式等待 |
| GET | `/session/:id/window/rect` | 窗口尺寸 |
| GET | `/session/:id/window/handles` | 窗口句柄 |
| GET/POST | `/session/:id/window` | 当前窗口 |
| GET/POST | `/session/:id/url` | 读取 bundleId / 打开 URL |
| GET/POST | `/session/:id/orientation` | 方向读取/设置 |
| GET/POST | `/session/:id/context[s]` | `NATIVE_APP` 上下文 |
| POST | `/session/:id/execute/sync` | `mobile:` 命令 |

### Appium 设备端点

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/session/:id/appium/device/shake` | 摇一摇 |
| POST | `/session/:id/appium/device/hide_keyboard` | 收起键盘 |
| GET/POST | `/session/:id/appium/device/is_keyboard_shown` | 键盘状态 |
| GET/POST | `/session/:id/appium/device/system_time` | 设备时间 |
| GET/POST | `/session/:id/appium/device/battery_info` | 电量 |
| POST | `/session/:id/appium/device/set_clipboard` | 写剪贴板 |
| GET/POST | `/session/:id/appium/device/get_clipboard` | 读剪贴板 |
| POST | `/session/:id/appium/device/delete_clipboard` | 清空剪贴板 |
| POST | `/session/:id/appium/device/activate_app` | 拉起 App 到前台（任意 bundleId） |
| POST | `/session/:id/appium/device/terminate_app` | 结束 App（任意 bundleId） |
| POST | `/session/:id/appium/device/background_app` | 切后台 `{seconds}` 后自动拉回 |
| POST | `/session/:id/appium/device/app_state` | App 状态（1/3/4，WebdriverIO 标准路径） |
| POST | `/session/:id/appium/device/query_app_state` | 同上（别名） |
| POST | `/session/:id/appium/device/app_installed` | 任意 App 是否安装 |
| POST | `/session/:id/appium/device/install_app` | 安装 `{appPath}`（宿主 .app 路径） |
| POST | `/session/:id/appium/device/remove_app` | 卸载 `{appId}` |
| POST | `/session/:id/appium/device/push_file` | 写文件 `{path, payload(base64)}` |
| POST | `/session/:id/appium/device/pull_file` | 读文件 → base64 |
| POST | `/session/:id/appium/device/pull_folder` | 打包目录 → base64 zip |
| POST | `/session/:id/appium/start_recording_screen` | 开始录屏（同一会话一路） |
| POST | `/session/:id/appium/stop_recording_screen` | 停止录屏 → base64 mp4 |
| POST | `/session/:id/alert/accept|dismiss` | W3C 标准弹窗接受/关闭 |
| GET/POST | `/session/:id/alert/text` | W3C 标准弹窗文本/设置文本 |
| POST | `/session/:id/appium/alert/accept|dismiss` | Appium 别名（同上） |
| GET/POST | `/session/:id/appium/alert/text` | Appium 别名（同上） |
| GET/POST | `/session/:id/appium/settings` | Appium settings 存储 |
| POST | `/session/:id/appium/performance_data` | App 内性能单点采样 |

---

## 5. W3C Actions 支持情况

| 手势 | 翻译 |
|---|---|
| 单指 tap | `tap` |
| 双 tap（间隔 <600ms、点位接近） | `double_tap` |
| 按住 ≥450ms 不动 | `long_press` |
| 单指滑动 | `swipe` |
| 双指距离变化 | `pinch` |
| 双指平移 | 用两指中点近似 `swipe`（当前合成触控以单指/双指 pinch 为主） |
| 键盘 keyDown | `press_key`（Enter/Backspace/Tab/Escape/普通字符） |
| `origin` | `viewport` / `pointer` / 元素句柄（元素中心 + offset） |

---

## 6. mobile: 命令

`POST /session/:id/execute/sync`，`script` 形如 `mobile: tap`：

| 命令 | 主要参数 |
|---|---|
| `mobile: tap` / `doubleTap` / `touchAndHold` | `element` 或 `x,y`、`duration` |
| `mobile: swipe` / `scroll` | `element?`、`direction`、`distance` |
| `mobile: pinch` | `element?`、`scale` |
| `mobile: dragFromToForDuration` | `fromX,fromY,toX,toY,duration`（元素内相对坐标） |
| `mobile: scrollToElement` / `scrollToVisible` | `element` |
| `mobile: scrollToTop` / `scrollToBottom` | `element?`（缺省取首个 UIScrollView） |
| `mobile: alert` | `action: accept/dismiss/getText/setText`、`text` |
| `mobile: getPasteboard` / `setPasteboard` / `deletePasteboard` | `text` |
| `mobile: activeElement` / `source` / `deviceInfo` / `keyboardShown` | — |
| `mobile: orientation` / `setOrientation` | `orientation` |
| `mobile: viewportScreenshot` | — |
| `mobile: performanceData` / `startPerfRecord` / `stopPerfRecord` | — |
| `mobile: getDeviceTime` / `batteryInfo` / `queryAppState` | — |
| `mobile: activateApp` / `terminateApp` / `backgroundApp` | `bundleId?`（缺省当前 App）、`seconds` |
| `mobile: installApp` / `removeApp` / `isAppInstalled` | `app`（宿主 .app 路径）、`appId`、`bundleId` |
| `mobile: pushFile` / `pullFile` / `pullFolder` | `path`、`payload|data` |
| `mobile: startRecordingScreen` / `stopRecordingScreen` | —（停止返回 base64 mp4） |
| `mobile: shake` | — |

**明确不支持**（进程内 Agent 的边界）：
`lock`/`unlock`/`isLocked`、`pressKeyCode`（Android）、`startActivity`（Android）。
App 管理 / 文件 / 录屏已通过宿主 `xcrun simctl` 支持（见下节，仅模拟器）。

> `mobile: tap`/`doubleTap`/`touchAndHold` 在同时提供 `element` 时，`x`/`y` 按“相对元素左上角”处理；
> `mobile: dragFromToForDuration` 的四个坐标同样按元素相对坐标平移。

---

## 7. 宿主侧设备管理（仅模拟器）

桥跑在 macOS 宿主上，参考 Appium XCUITest driver 把“进程外”能力通过 `xcrun simctl` 补齐
（实现见 `Tools/iua_simctl.js`）：

| 能力 | 语义 |
|---|---|
| `activateApp` / `terminateApp` | 任意 bundleId；对未运行的 App terminate 也算成功（Appium 语义） |
| `backgroundApp(seconds)` | terminate → 等待 → 重新 launch；当前 App 会自动等 WS 重连 |
| `queryAppState` | 其他 App：`3`（后台运行）/`1`（未运行）；当前 App 走进程内精确值（4 等） |
| `isAppInstalled` / `installApp` / `removeApp` | `listapps` / `install` / `uninstall` |
| `pushFile` / `pullFile` / `pullFolder` | `@bundleId/相对路径` → App 数据容器；或绝对路径；pullFolder 返回 zip base64 |
| `startRecordingScreen` / `stopRecordingScreen` | `simctl io recordVideo`；同一会话一路；stop 返回 mp4 base64；会话结束自动收尾 |

约束：

- **UDID 解析**：`appium:udid` capability / `IUA_UDID` 环境变量显式指定；否则要求恰好一台
  booted 模拟器（0 台报错、多台要求指定）。
- **真机**：App 上报机型为真机（`iPhone17,1` 等）且未显式给 udid 时，上述端点返回
  `unsupported operation`；`activateApp`（当前 App）、`isAppInstalled`/`app_state` 保持
  原降级语义（true / false / 0）。
- **文件安全**：`@bundleId/…` 路径 resolve 后必须仍在数据容器内（防穿越）；单文件/目录
  传输上限 64MB。
- **录屏**：`recordVideo` 需要 SIGINT 优雅结束才有可用的 mp4（内部已处理）；
  `timeLimit`/`remotePath` 等选项暂不支持，静默忽略。

示例（WebdriverIO）：

```js
await driver.execute('mobile: pushFile', [{
  path: '@com.iuiauto.example/Documents/seed.json',
  data: Buffer.from('{"v":1}').toString('base64'),
}]);

await driver.startRecordingScreen();        // 开始录屏
await driver.$('~btn.counter').click();
const mp4 = await driver.stopRecordingScreen();  // base64 mp4
require('fs').writeFileSync('demo.mp4', Buffer.from(mp4, 'base64'));

await driver.backgroundApp(2);              // 切后台 2s 后拉回，自动等重连
```

---

## 8. 边界与排错

- **单会话**：一个 App 连接同一时间只允许一个 WebDriver session；先 `DELETE /session/:id` 再建新会话。
- **仅宿主 App**：所有元素/截图/源码来自 IUIAuto 所在 App 进程；无法自动化其他 App。
- **旋转**：设置方向受宿主 App `Info.plist` 支持的方向限制；返回值为实际方向。
- **键盘**：模拟器/硬件键盘下没有键盘 window 时，有输入焦点仍返回 `is_keyboard_shown=true`（逻辑键盘）。
- **截图**：窗口截图来自 keyWindow，元素截图通过视图层级渲染。
- **端口冲突**：GUI 与独立桥不能同时占用 9800；`--takeover` 可接管旧实例。
- **App 未连接**：`POST /session` 返回 500 `session not created`；检查 App 是否启动、地址是否 9800。
- **元素失效**：页面变化后旧句柄会返回 `stale element reference`，重新 find 即可。
- **XPath/class chain 索引**：`[n]` 当前按全局匹配结果取第 n 个，不是严格的“每个父节点下第 n 个”；复杂层级建议使用唯一 identifier/name 或完整路径。
- **WebDriver 监听地址**：默认只绑定 `127.0.0.1`（`BRIDGE_HOST` 可改）；GUI 默认 `GUI_HOST=127.0.0.1`。
- **App WebSocket**：9800 仍监听所有网卡以支持真机；当前无鉴权，请只在可信网络使用。
