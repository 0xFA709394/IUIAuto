# IUIAuto × Appium：WebDriver 桥接指南

> 目标：让**标准 Appium 客户端**（WebdriverIO、Appium Python/Java client、CI 平台）直接驱动 IUIAuto，
> 而不需要改造成 IUIAuto 私有协议。
>
> HTTP 侧说 **W3C WebDriver / Appium 协议**，底层翻译为 IUIAuto App 的 WebSocket JSON 指令。
> iOS 端仍然**不依赖 XCUITest / WebDriverAgent**，操作在宿主 App 进程内完成。
>
> 已用 **WebdriverIO 10.2.0** 真实客户端验证：建会话 / `~` 定位 / click / setValue /
> getPageSource / takeScreenshot / performActions / getAlertText / sendAlertText / acceptAlert /
> deleteSession 全部通过。

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
| POST | `/session/:id/appium/device/activate_app` | 当前 App（no-op） |
| POST | `/session/:id/appium/device/query_app_state` | App 状态（1/3/4） |
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
| `mobile: shake` | — |

**明确不支持**（进程内 Agent 的边界）：
`terminateApp`、`backgroundApp`、`lock`/`unlock`/`isLocked`、`pressKeyCode`（Android）、
`startActivity`（Android）。这些需要宿主/模拟器侧的进程控制，可用 `xcrun simctl` 在测试脚本中完成。

---

## 7. 边界与排错

- **单会话**：一个 App 连接同一时间只允许一个 WebDriver session；先 `DELETE /session/:id` 再建新会话。
- **仅宿主 App**：所有元素/截图/源码来自 IUIAuto 所在 App 进程；无法自动化其他 App。
- **旋转**：设置方向受宿主 App `Info.plist` 支持的方向限制；返回值为实际方向。
- **键盘**：模拟器/硬件键盘下没有键盘 window 时，有输入焦点仍返回 `is_keyboard_shown=true`（逻辑键盘）。
- **截图**：窗口截图来自 keyWindow，元素截图通过视图层级渲染。
- **端口冲突**：GUI 与独立桥不能同时占用 9800；`--takeover` 可接管旧实例。
- **App 未连接**：`POST /session` 返回 500 `session not created`；检查 App 是否启动、地址是否 9800。
- **元素失效**：页面变化后旧句柄会返回 `stale element reference`，重新 find 即可。
