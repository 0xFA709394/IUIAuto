#!/usr/bin/env node
/**
 * Appium / WebDriver 桥单元测试（不依赖模拟器）
 *
 * 运行: node Tools/appium_bridge_test.mjs
 *
 * 用假 App send 函数模拟 IUIAuto 指令层，验证：
 *   - W3C session / element / source / screenshot / actions / timeouts
 *   - Appium 设备端点与 mobile: execute 命令
 *   - 元素句柄、隐式等待、错误映射、会话生命周期
 *   - W3C Actions → 语义手势翻译
 */

import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createAppiumBridge } from './appium_bridge.js';
import { translateActions, ELEMENT_KEY } from './iua_webdriver_actions.js';
import { createSimctl } from './iua_simctl.js';

const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

// ---------------------------------------------------------------------------
// 假 App
// ---------------------------------------------------------------------------
function createFakeApp(deviceModel = 'arm64') {
  const state = {
    counter: 0,
    text: '',
    focused: false,
    waitElement: true,
    clipboard: '',
    orientation: 'PORTRAIT',
    alertVisible: false,
    calls: [],
    lastGesture: null,
  };

  const element = (extra = {}) => ({
    type: 'XCUIElementTypeButton',
    name: 'btn.counter',
    label: '点我',
    value: '',
    text: '点我',
    identifier: 'btn.counter',
    class: 'UIButton',
    enabled: true,
    visible: true,
    selected: false,
    focused: false,
    rect: { x: 10, y: 20, width: 100, height: 40 },
    x: 10,
    y: 20,
    width: 100,
    height: 40,
    xpath: '/XCUIElementTypeWindow[1]/XCUIElementTypeButton[1]',
    elementIndex: 0,
    ...extra,
  });

  function elementsFor(value) {
    if (!state.waitElement && value === 'wait.element') return [];
    // xpath / 其他策略的简化模拟：按 value 中的元素名路由
    if (value && typeof value === 'string') {
      if (value.includes('label.counter')) value = 'label.counter';
      else if (value.includes('field.input')) value = 'field.input';
      else if (value.includes('btn.counter')) value = 'btn.counter';
    }
    if (value === 'btn.counter') return [element()];
    if (value === 'label.counter') {
      return [element({
        type: 'XCUIElementTypeStaticText',
        name: 'label.counter',
        identifier: 'label.counter',
        label: `Count: ${state.counter}`,
        text: `Count: ${state.counter}`,
        class: 'UILabel',
        rect: { x: 10, y: 80, width: 200, height: 20 },
        xpath: '/XCUIElementTypeWindow[1]/XCUIElementTypeStaticText[1]',
      })];
    }
    if (value === 'field.input') {
      return [element({
        type: 'XCUIElementTypeTextField',
        name: 'field.input',
        identifier: 'field.input',
        label: state.text || '请输入',
        text: state.text,
        value: state.text,
        class: 'UITextField',
        focused: state.focused,
        rect: { x: 10, y: 120, width: 200, height: 30 },
        xpath: '/XCUIElementTypeWindow[1]/XCUIElementTypeTextField[1]',
      })];
    }
    if (value === 'wait.element') return [element({ name: 'wait.element', identifier: 'wait.element' })];
    if (value === 'btn.two') {
      return [element({ name: 'btn.two', identifier: 'btn.two' }), element({ name: 'btn.two', identifier: 'btn.two', elementIndex: 1, xpath: '/XCUIElementTypeWindow[1]/XCUIElementTypeButton[2]' })];
    }
    return [];
  }

  async function send(action, params = {}) {
    state.calls.push({ action, params });
    switch (action) {
      case 'find_elements': {
        const elements = elementsFor(params.value);
        return { ok: true, data: { elements, count: elements.length } };
      }
      case 'find_element': {
        const elements = elementsFor(params.value);
        if (!elements.length) return { ok: false, error: 'no such element: ' + params.value };
        return { ok: true, data: elements[0] };
      }
      case 'element_action': {
        const { action: elementAction, attribute, text } = params;
        if (elementAction === 'click') {
          if (params.value === 'btn.counter') state.counter += 1;
          if (params.value === 'field.input') state.focused = true;
          return { ok: true, data: { x: 60, y: 40 } };
        }
        if (elementAction === 'double_click') {
          if (params.value === 'btn.counter') state.counter += 2;
          return { ok: true, data: { doubleTapped: true } };
        }
        if (elementAction === 'long_click') {
          if (params.value === 'btn.counter') state.counter += 10;
          return { ok: true, data: { duration: params.duration } };
        }
        if (elementAction === 'send_keys') {
          state.text += text || '';
          state.focused = true;
          return { ok: true, data: { typed: (text || '').length } };
        }
        if (elementAction === 'clear') {
          state.text = '';
          return { ok: true, data: { cleared: true } };
        }
        if (elementAction === 'get_attributes') {
          const list = elementsFor(params.value);
          return { ok: true, data: list[0] || element() };
        }
        if (elementAction === 'get_text') {
          const isLabel = String(params.value || '').includes('label.counter');
          return { ok: true, data: { text: isLabel ? `Count: ${state.counter}` : state.text } };
        }
        if (elementAction === 'get_rect') {
          return { ok: true, data: { x: 10, y: 20, width: 100, height: 40 } };
        }
        if (elementAction === 'get_attribute') {
          const element = elementsFor(params.value)[0] || element();
          const value = attribute === 'value' ? (element.value ?? '')
            : attribute === 'name' ? element.name
            : attribute === 'label' ? element.label
            : attribute === 'type' ? element.type
            : null;
          if (value === null) return { ok: false, error: 'unknown attribute: ' + attribute };
          return { ok: true, data: { attribute, value } };
        }
        if (elementAction === 'is_displayed') return { ok: true, data: { displayed: true } };
        if (elementAction === 'is_enabled') return { ok: true, data: { enabled: true } };
        if (elementAction === 'is_selected') return { ok: true, data: { selected: false } };
        if (elementAction === 'screenshot') return { ok: true, data: { image: 'iVBORw0KGgo=', width: 100, height: 40 } };
        if (elementAction === 'scroll_to') return { ok: true, data: { scrolledTo: params.value } };
        return { ok: false, error: 'unknown element action: ' + elementAction };
      }
      case 'page_source':
        return { ok: true, data: { source: '<?xml version="1.0" encoding="UTF-8"?>\n<AppiumAUT><XCUIElementTypeButton name="btn.counter"/></AppiumAUT>' } };
      case 'screenshot':
        return { ok: true, data: { image: 'iVBORw0KGgoAAAANSUhEUg==', width: 402, height: 874 } };
      case 'screenshot_compare': {
        if (params.baseline === 'GOOD_BASELINE') {
          return { ok: true, data: { pass: true, diffPercent: 0, matchedPixels: 100 } };
        }
        if (params.baseline === 'BAD_BASELINE') {
          return { ok: false, error: '视觉差异 5.000% 超过阈值 1.00%', data: { pass: false, diffPercent: 5 } };
        }
        return { ok: false, error: '对比失败（截图或基线解码失败）' };
      }
      case 'device_info':
        return { ok: true, data: {
          name: 'iPhone 17 Pro', systemVersion: '26.5', bundleId: 'com.iuiauto.example',
          appVersion: '1.0', deviceModel, locale: 'en_CN', language: 'zh-Hans-CN',
          windowSize: { width: 402, height: 874 }, screen: { width: 402, height: 874, scale: 3 },
          time: '2026-11-07T15:00:00Z', batteryLevel: -1, batteryState: 'unknown',
        } };
      case 'orientation':
        if (params.orientation) state.orientation = params.orientation;
        return { ok: true, data: { orientation: state.orientation } };
      case 'keyboard_state':
        return { ok: true, data: { shown: state.focused } };
      case 'clipboard_get':
        return { ok: true, data: { text: state.clipboard } };
      case 'clipboard_set':
        state.clipboard = params.text || '';
        return { ok: true, data: { text: state.clipboard } };
      case 'alert': {
        if (!state.alertVisible) return { ok: false, error: 'no such alert' };
        if (params.action === 'accept' || params.action === 'dismiss') state.alertVisible = false;
        return { ok: true, data: { title: '提示', message: '弹窗内容', text: '弹窗内容', buttons: ['OK'] } };
      }
      case 'app_state':
        return { ok: true, data: { state: 4, stateText: 'active', bundleId: 'com.iuiauto.example' } };
      case 'perf_sample':
        return { ok: true, data: { cpuPercent: 1.2, memoryMB: 20 } };
      case 'perf_start':
        return { ok: true, data: { sampling: true } };
      case 'perf_stop':
        return { ok: true, data: { duration: 1, sampleCount: 2 } };
      case 'active_element':
        return state.focused
          ? { ok: true, data: { found: true, xpath: '/XCUIElementTypeWindow[1]/XCUIElementTypeTextField[1]' } }
          : { ok: true, data: { found: false } };
      case 'tap':
        state.counter += 1;
        state.lastGesture = { action: 'tap', ...params };
        return { ok: true, data: {} };
      case 'double_tap':
        state.counter += 2;
        state.lastGesture = { action: 'double_tap', ...params };
        return { ok: true, data: {} };
      case 'long_press':
        state.counter += 10;
        state.lastGesture = { action: 'long_press', ...params };
        return { ok: true, data: {} };
      case 'swipe':
      case 'pinch':
        state.lastGesture = { action, ...params };
        return { ok: true, data: {} };
      case 'press_key':
        state.lastGesture = { action: 'press_key', ...params };
        return { ok: true, data: {} };
      case 'shake':
      case 'dismiss_keyboard':
      case 'open_url':
        return { ok: true, data: {} };
      default:
        return { ok: false, error: 'unknown action: ' + action };
    }
  }

  return { state, send };
}

// ---------------------------------------------------------------------------
// W3C Actions 翻译单测
// ---------------------------------------------------------------------------
test('translateActions: tap', async () => {
  const commands = await translateActions([{
    type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: 120, y: 240, origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  assert.deepEqual(commands, [{ action: 'tap', params: { x: 120, y: 240 } }]);
});

test('translateActions: long press', async () => {
  const commands = await translateActions([{
    type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: 10, y: 20, origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pause', duration: 700 },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  assert.equal(commands.length, 1);
  assert.equal(commands[0].action, 'long_press');
  assert.equal(commands[0].params.x, 10);
  assert.equal(commands[0].params.duration, 0.7);
});

test('translateActions: swipe', async () => {
  const commands = await translateActions([{
    type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: 200, y: 600, origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pointerMove', duration: 400, x: 200, y: 300, origin: 'viewport' },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  assert.equal(commands.length, 1);
  assert.equal(commands[0].action, 'swipe');
  assert.equal(commands[0].params.fromY, 600);
  assert.equal(commands[0].params.toY, 300);
  assert.equal(commands[0].params.duration, 0.4);
});

test('translateActions: double tap', async () => {
  const commands = await translateActions([{
    type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: 100, y: 100, origin: 'viewport' },
      { type: 'pointerDown', button: 0 },
      { type: 'pointerUp', button: 0 },
      { type: 'pause', duration: 100 },
      { type: 'pointerDown', button: 0 },
      { type: 'pointerUp', button: 0 },
    ],
  }]);
  assert.equal(commands[0].action, 'double_tap');
});

test('translateActions: pinch', async () => {
  const commands = await translateActions([
    {
      type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x: 150, y: 300, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pointerMove', duration: 300, x: 100, y: 300, origin: 'viewport' },
        { type: 'pointerUp', button: 0 },
      ],
    },
    {
      type: 'pointer', id: 'finger2', parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x: 250, y: 300, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pointerMove', duration: 300, x: 300, y: 300, origin: 'viewport' },
        { type: 'pointerUp', button: 0 },
      ],
    },
  ]);
  assert.equal(commands[0].action, 'pinch');
  assert.equal(commands[0].params.x, 200);
  assert.equal(commands[0].params.y, 300);
  assert.equal(commands[0].params.radiusFrom, 50);
  assert.equal(commands[0].params.radiusTo, 100);
});

test('translateActions: element origin', async () => {
  const commands = await translateActions([{
    type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
    actions: [
      { type: 'pointerMove', duration: 0, x: 5, y: 6, origin: { [ELEMENT_KEY]: 'el-1' } },
      { type: 'pointerDown', button: 0 },
      { type: 'pointerUp', button: 0 },
    ],
  }], async (id) => {
    assert.equal(id, 'el-1');
    return { x: 100, y: 200, width: 40, height: 20 };
  });
  assert.equal(commands[0].params.x, 125);
  assert.equal(commands[0].params.y, 216);
});

test('translateActions: keyboard', async () => {
  const commands = await translateActions([{
    type: 'key', id: 'keyboard1',
    actions: [
      { type: 'keyDown', value: 'a' },
      { type: 'keyUp', value: 'a' },
      { type: 'keyDown', value: '\uE007' },
      { type: 'keyUp', value: '\uE007' },
    ],
  }]);
  assert.deepEqual(commands, [
    { action: 'press_key', params: { key: 'a' } },
    { action: 'press_key', params: { key: 'return' } },
  ]);
});

// ---------------------------------------------------------------------------
// 假 simctl（宿主侧设备管理的离线替身）
// ---------------------------------------------------------------------------
const FAKE_UDID = '11111111-2222-3333-4444-555555555555';

function createFakeSimctl() {
  const calls = [];
  const container = mkdtempSync(join(tmpdir(), 'iua-simctl-test-'));
  // 假 App 安装目录：带真实 Localizable.strings（plutil 真解析）
  const appBundle = mkdtempSync(join(tmpdir(), 'iua-simctl-app-'));
  mkdirSync(join(appBundle, 'zh-Hans.lproj'), { recursive: true });
  mkdirSync(join(appBundle, 'en.lproj'), { recursive: true });
  writeFileSync(join(appBundle, 'zh-Hans.lproj', 'Localizable.strings'),
    '"demo.greeting" = "你好，IUIAuto";\n"demo.submit" = "提交";\n');
  writeFileSync(join(appBundle, 'en.lproj', 'Localizable.strings'),
    '"demo.greeting" = "Hello, IUIAuto";\n"demo.submit" = "Submit";\n');
  let running = new Set(['com.iuiauto.example']);
  let appearance = 'dark';
  let increaseContrast = 'disabled';
  let videoStops = 0;

  const fakeRun = async (args) => {
    calls.push(args.join(' '));
    const [sub, ...rest] = args;
    if (sub === 'list' && rest[0] === 'devices') {
      return JSON.stringify({ devices: { 'iOS 26.5': [
        { udid: FAKE_UDID, name: 'iPhone 17 Pro', state: 'Booted' },
      ] } });
    }
    if (sub === 'privacy') return '';
    if (sub === 'get_app_container') return `${rest[2] === 'app' ? appBundle : container}\n`;
    if (sub === 'ui') {
      if (rest[1] === 'appearance') {
        if (rest[2] === 'light' || rest[2] === 'dark') appearance = rest[2];
        return `${appearance}\n`;
      }
      if (rest[1] === 'increase_contrast') {
        if (rest[2] === 'enabled' || rest[2] === 'disabled') increaseContrast = rest[2];
        return `${increaseContrast}\n`;
      }
      throw new Error('fake simctl 未实现的 ui 子命令: ' + args.join(' '));
    }
    if (sub === 'launch') {
      running.add(rest[1]);
      return `${rest[1]}: 4242\n`;
    }
    if (sub === 'terminate') {
      running.delete(rest[1]);
      return '';
    }
    if (sub === 'listapps') {
      return `<?xml version="1.0"?><plist version="1.0"><dict>` +
        `<key>com.iuiauto.example</key><dict><key>CFBundleIdentifier</key>` +
        `<string>com.iuiauto.example</string></dict></dict></plist>`;
    }
    if (sub === 'get_app_container') return `${container}\n`;
    if (sub === 'spawn') {
      return [...running].map((b) => `-\t0\tUIKitApplication:${b}`).join('\n') + '\n';
    }
    if (sub === 'install' || sub === 'uninstall') return '';
    throw new Error('fake simctl 未实现的子命令: ' + args.join(' '));
  };

  const fakeSpawnVideo = (args) => {
    calls.push(args.join(' '));
    const videoPath = args[args.length - 1];
    // 模拟 recordVideo：启动即产出文件（真实实现是停止时 finalize）
    writeFileSync(videoPath, Buffer.from('fake-mp4-bytes'));
    return { stop: async () => { videoStops += 1; } };
  };

  const simctl = createSimctl({ run: fakeRun, spawnVideo: fakeSpawnVideo, log: () => {} });
  return {
    simctl,
    calls,
    container,
    setRunning: (bundles) => { running = new Set(bundles); },
    get videoStops() { return videoStops; },
  };
}

const simctlFake = createFakeSimctl();

// ---------------------------------------------------------------------------
// 桥端到端（假 App）
// ---------------------------------------------------------------------------
const fake = createFakeApp();
const hello = {
  type: 'hello',
  agent: 'IUIAuto',
  version: '0.4.0',
  environment: { systemVersion: '26.5', deviceModel: 'arm64' },
  actions: ['find_elements', 'element_action', 'page_source'],
};
const bridge = createAppiumBridge({
  send: fake.send,
  getHello: () => hello,
  sessionWaitMs: 1000,
  log: () => {},
  simctl: simctlFake.simctl,
});
await new Promise((resolve) => bridge.server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${bridge.server.address().port}`;
let sessionId = null;
let buttonId = null;
let labelId = null;
let fieldId = null;

async function request(method, path, body) {
  const response = await fetch(base + path, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(10000),
  });
  const text = await response.text();
  let json = null;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: response.status, json, headers: response.headers };
}

test('GET /status', async () => {
  const r = await request('GET', '/status');
  assert.equal(r.status, 200);
  assert.equal(r.json.value.ready, true);
});

test('POST /session (W3C capabilities)', async () => {
  const r = await request('POST', '/session', {
    capabilities: {
      alwaysMatch: { platformName: 'iOS', 'appium:automationName': 'IUIAuto' },
      firstMatch: [{ 'appium:deviceName': 'test' }],
    },
  });
  assert.equal(r.status, 200);
  sessionId = r.json.value.sessionId;
  assert.ok(sessionId);
  assert.equal(r.json.value.capabilities['appium:automationName'], 'IUIAuto');
  assert.equal(r.json.value.capabilities.platformName, 'iOS');
});

test('second session rejected', async () => {
  const r = await request('POST', '/session', { capabilities: { alwaysMatch: {} } });
  assert.equal(r.status, 500);
  assert.equal(r.json.value.error, 'session not created');
});

test('GET /source', async () => {
  const r = await request('GET', `/session/${sessionId}/source`);
  assert.equal(r.status, 200);
  assert.match(r.json.value, /AppiumAUT/);
  assert.match(r.json.value, /btn\.counter/);
});

test('find element (accessibility id)', async () => {
  const r = await request('POST', `/session/${sessionId}/element`, {
    using: 'accessibility id', value: 'btn.counter',
  });
  assert.equal(r.status, 200);
  buttonId = r.json.value[ELEMENT_KEY];
  assert.ok(buttonId);
  assert.equal(r.json.value.ELEMENT, buttonId);
});

test('find elements count', async () => {
  const r = await request('POST', `/session/${sessionId}/elements`, {
    using: 'accessibility id', value: 'btn.two',
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.value.length, 2);
});

test('find label by xpath + label element', async () => {
  const r = await request('POST', `/session/${sessionId}/element`, {
    using: 'xpath', value: '//XCUIElementTypeStaticText[@name="label.counter"]',
  });
  assert.equal(r.status, 200);
  labelId = r.json.value[ELEMENT_KEY];
  const text = await request('GET', `/session/${sessionId}/element/${labelId}/text`);
  assert.equal(text.json.value, 'Count: 0');
});

test('click element updates counter', async () => {
  const r = await request('POST', `/session/${sessionId}/element/${buttonId}/click`);
  assert.equal(r.status, 200);
  assert.equal(r.json.value, null);
  assert.equal(fake.state.counter, 1);
  const text = await request('GET', `/session/${sessionId}/element/${labelId}/text`);
  assert.equal(text.json.value, 'Count: 1');
});

test('element rect / displayed / enabled / selected / attribute / name', async () => {
  assert.deepEqual((await request('GET', `/session/${sessionId}/element/${buttonId}/rect`)).json.value,
    { x: 10, y: 20, width: 100, height: 40 });
  assert.equal((await request('GET', `/session/${sessionId}/element/${buttonId}/displayed`)).json.value, true);
  assert.equal((await request('GET', `/session/${sessionId}/element/${buttonId}/enabled`)).json.value, true);
  assert.equal((await request('GET', `/session/${sessionId}/element/${buttonId}/selected`)).json.value, false);
  assert.equal((await request('GET', `/session/${sessionId}/element/${buttonId}/attribute/name`)).json.value, 'btn.counter');
  assert.equal((await request('GET', `/session/${sessionId}/element/${buttonId}/name`)).json.value, 'btn.counter');
});

test('element screenshot', async () => {
  const r = await request('GET', `/session/${sessionId}/element/${buttonId}/screenshot`);
  assert.equal(r.status, 200);
  assert.match(r.json.value, /^iVBOR/);
});

test('find text field and send keys / clear / value attribute', async () => {
  const find = await request('POST', `/session/${sessionId}/element`, {
    using: 'accessibility id', value: 'field.input',
  });
  fieldId = find.json.value[ELEMENT_KEY];
  assert.ok(fieldId);
  let r = await request('POST', `/session/${sessionId}/element/${fieldId}/value`, { text: 'hello 世界' });
  assert.equal(r.status, 200);
  assert.equal((await request('GET', `/session/${sessionId}/element/${fieldId}/text`)).json.value, 'hello 世界');
  assert.equal((await request('GET', `/session/${sessionId}/element/${fieldId}/attribute/value`)).json.value, 'hello 世界');
  r = await request('POST', `/session/${sessionId}/element/${fieldId}/clear`);
  assert.equal(r.status, 200);
  assert.equal((await request('GET', `/session/${sessionId}/element/${fieldId}/text`)).json.value, '');
});

test('screenshot', async () => {
  const r = await request('GET', `/session/${sessionId}/screenshot`);
  assert.equal(r.status, 200);
  assert.match(r.json.value, /^iVBOR/);
});

test('W3C actions: tap', async () => {
  const before = fake.state.counter;
  const r = await request('POST', `/session/${sessionId}/actions`, {
    actions: [{
      type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x: 200, y: 300, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pointerUp', button: 0 },
      ],
    }],
  });
  assert.equal(r.status, 200);
  assert.equal(fake.state.counter, before + 1);
});

test('W3C actions: long press / swipe / pinch', async () => {
  await request('POST', `/session/${sessionId}/actions`, {
    actions: [{
      type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x: 10, y: 20, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pause', duration: 600 },
        { type: 'pointerUp', button: 0 },
      ],
    }],
  });
  assert.equal(fake.state.lastGesture.action, 'long_press');
  await request('POST', `/session/${sessionId}/actions`, {
    actions: [{
      type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
      actions: [
        { type: 'pointerMove', duration: 0, x: 200, y: 600, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pointerMove', duration: 300, x: 200, y: 300, origin: 'viewport' },
        { type: 'pointerUp', button: 0 },
      ],
    }],
  });
  assert.equal(fake.state.lastGesture.action, 'swipe');
  await request('POST', `/session/${sessionId}/actions`, {
    actions: [
      { type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' }, actions: [
        { type: 'pointerMove', duration: 0, x: 150, y: 300, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pointerMove', duration: 300, x: 100, y: 300, origin: 'viewport' },
        { type: 'pointerUp', button: 0 },
      ] },
      { type: 'pointer', id: 'finger2', parameters: { pointerType: 'touch' }, actions: [
        { type: 'pointerMove', duration: 0, x: 250, y: 300, origin: 'viewport' },
        { type: 'pointerDown', button: 0 },
        { type: 'pointerMove', duration: 300, x: 300, y: 300, origin: 'viewport' },
        { type: 'pointerUp', button: 0 },
      ] },
    ],
  });
  assert.equal(fake.state.lastGesture.action, 'pinch');
});

test('timeouts + implicit wait', async () => {
  let r = await request('POST', `/session/${sessionId}/timeouts`, { implicit: 400 });
  assert.equal(r.status, 200);
  assert.equal((await request('GET', `/session/${sessionId}/timeouts`)).json.value.implicit, 400);

  fake.state.waitElement = false;
  const start = Date.now();
  r = await request('POST', `/session/${sessionId}/element`, { using: 'accessibility id', value: 'wait.element' });
  const elapsed = Date.now() - start;
  assert.equal(r.status, 404);
  assert.ok(elapsed >= 350, `implicit wait elapsed ${elapsed}ms`);

  fake.state.waitElement = true;
  r = await request('POST', `/session/${sessionId}/element`, { using: 'accessibility id', value: 'wait.element' });
  assert.equal(r.status, 200);
  await request('POST', `/session/${sessionId}/timeouts`, { implicit: 0 });
});

test('invalid selector', async () => {
  const r = await request('POST', `/session/${sessionId}/element`, { using: 'css selector', value: 'button' });
  assert.equal(r.status, 400);
  assert.equal(r.json.value.error, 'invalid selector');
});

test('stale / invalid element handle', async () => {
  const r = await request('GET', `/session/${sessionId}/element/no-such-element/text`);
  assert.equal(r.status, 404);
  assert.equal(r.json.value.error, 'stale element reference');
});

test('Appium device endpoints', async () => {
  let r = await request('GET', `/session/${sessionId}/appium/device/is_keyboard_shown`);
  assert.equal(r.json.value, true);
  r = await request('POST', `/session/${sessionId}/appium/device/set_clipboard`, { content: 'clip' });
  assert.equal(r.status, 200);
  assert.equal((await request('GET', `/session/${sessionId}/appium/device/get_clipboard`)).json.value, 'clip');
  assert.equal((await request('GET', `/session/${sessionId}/appium/device/system_time`)).json.value, '2026-11-07T15:00:00Z');
  assert.equal((await request('GET', `/session/${sessionId}/appium/device/battery_info`)).json.value.level, -1);
  assert.equal((await request('GET', `/session/${sessionId}/orientation`)).json.value, 'PORTRAIT');
  assert.equal((await request('POST', `/session/${sessionId}/orientation`, { orientation: 'LANDSCAPE' })).json.value, 'LANDSCAPE');
  assert.equal((await request('GET', `/session/${sessionId}/window/rect`)).json.value.width, 402);
  assert.deepEqual((await request('GET', `/session/${sessionId}/contexts`)).json.value, ['NATIVE_APP']);
});

test('Appium app_state / app_installed endpoints', async () => {
  let r = await request('POST', `/session/${sessionId}/appium/device/app_state`, { bundleId: 'com.iuiauto.example' });
  assert.equal(r.status, 200);
  assert.equal(r.json.value, 4);
  r = await request('POST', `/session/${sessionId}/appium/device/app_installed`, { bundleId: 'com.iuiauto.example' });
  assert.equal(r.json.value, true);
  r = await request('POST', `/session/${sessionId}/appium/device/app_installed`, { bundleId: 'com.other' });
  assert.equal(r.json.value, false);
});

// ---------------------------------------------------------------------------
// 宿主侧设备管理（simctl 假执行器）
// ---------------------------------------------------------------------------
test('simctl: activateApp / terminateApp / backgroundApp', async () => {
  // 未运行的 App terminate 同样成功（Appium 语义），且不实际下发 terminate
  let r = await request('POST', `/session/${sessionId}/appium/device/terminate_app`, { appId: 'com.other.app' });
  assert.equal(r.status, 200);
  assert.equal(simctlFake.calls.includes(`terminate ${FAKE_UDID} com.other.app`), false);
  // activate 其他 App → simctl launch
  r = await request('POST', `/session/${sessionId}/appium/device/activate_app`, { appId: 'com.other.app' });
  assert.equal(r.status, 200);
  assert.ok(simctlFake.calls.includes(`launch ${FAKE_UDID} com.other.app`));
  // 运行中的 App terminate → 实际下发
  r = await request('POST', `/session/${sessionId}/appium/device/terminate_app`, { appId: 'com.other.app' });
  assert.equal(r.status, 200);
  assert.ok(simctlFake.calls.includes(`terminate ${FAKE_UDID} com.other.app`));
  // background 当前 App（seconds=0 → 立即拉回前台）
  r = await request('POST', `/session/${sessionId}/appium/device/background_app`, { seconds: 0 });
  assert.equal(r.status, 200);
  assert.ok(simctlFake.calls.includes(`terminate ${FAKE_UDID} com.iuiauto.example`));
  assert.ok(simctlFake.calls.includes(`launch ${FAKE_UDID} com.iuiauto.example`));
});

test('simctl: app_state / app_installed for other bundles', async () => {
  // com.other.app 已被 terminate → 未运行（1）；未安装 → installed=false
  let r = await request('POST', `/session/${sessionId}/appium/device/app_state`, { bundleId: 'com.other.app' });
  assert.equal(r.status, 200);
  assert.equal(r.json.value, 1);
  r = await request('POST', `/session/${sessionId}/appium/device/app_installed`, { bundleId: 'com.other.app' });
  assert.equal(r.json.value, false);
  // 重新 launch 后 → 后台运行（3）
  await request('POST', `/session/${sessionId}/appium/device/activate_app`, { appId: 'com.other.app' });
  r = await request('POST', `/session/${sessionId}/appium/device/app_state`, { bundleId: 'com.other.app' });
  assert.equal(r.json.value, 3);
  simctlFake.setRunning(['com.iuiauto.example']);
});

test('simctl: push_file / pull_file / pull_folder', async () => {
  const payload = Buffer.from('IUIAuto push/pull 你好', 'utf8').toString('base64');
  let r = await request('POST', `/session/${sessionId}/appium/device/push_file`, {
    path: '@com.iuiauto.example/Documents/e2e.txt',
    payload,
  });
  assert.equal(r.status, 200);
  // 容器内真实落盘
  assert.equal(readFileSync(join(simctlFake.container, 'Documents/e2e.txt'), 'utf8'), 'IUIAuto push/pull 你好');
  r = await request('POST', `/session/${sessionId}/appium/device/pull_file`, {
    path: '@com.iuiauto.example/Documents/e2e.txt',
  });
  assert.equal(r.json.value, payload);
  // 不存在的文件 → no such file 404
  r = await request('POST', `/session/${sessionId}/appium/device/pull_file`, {
    path: '@com.iuiauto.example/Documents/none.txt',
  });
  assert.equal(r.status, 404);
  assert.equal(r.json.value.error, 'no such file');
  // 目录 → zip（PK 头）
  r = await request('POST', `/session/${sessionId}/appium/device/pull_folder`, {
    folderPath: '@com.iuiauto.example/Documents',
  });
  assert.equal(r.status, 200);
  assert.equal(Buffer.from(r.json.value, 'base64').subarray(0, 2).toString(), 'PK');
  // 相对路径 → invalid argument
  r = await request('POST', `/session/${sessionId}/appium/device/push_file`, { path: 'relative/x', payload });
  assert.equal(r.status, 400);
  assert.equal(r.json.value.error, 'invalid argument');
  // 越出容器的路径 → invalid argument
  r = await request('POST', `/session/${sessionId}/appium/device/pull_file`, {
    path: '@com.iuiauto.example/../escape.txt',
  });
  assert.equal(r.status, 400);
});

test('simctl: screen recording lifecycle', async () => {
  let r = await request('POST', `/session/${sessionId}/appium/start_recording_screen`);
  assert.equal(r.status, 200);
  // 同一会话重复开始 → 报错
  r = await request('POST', `/session/${sessionId}/appium/start_recording_screen`);
  assert.equal(r.status, 500);
  assert.match(r.json.value.message, /已在进行中/);
  // 停止 → base64 mp4
  r = await request('POST', `/session/${sessionId}/appium/stop_recording_screen`);
  assert.equal(r.status, 200);
  assert.equal(Buffer.from(r.json.value, 'base64').toString(), 'fake-mp4-bytes');
  // 没有进行中的录屏再停止 → 404
  r = await request('POST', `/session/${sessionId}/appium/stop_recording_screen`);
  assert.equal(r.status, 404);
});

test('mobile: installApp / removeApp / isAppInstalled / pushFile / queryAppState', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: isAppInstalled', args: [{ bundleId: 'com.iuiauto.example' }],
  });
  assert.equal(r.json.value, true);
  // 临时 .app 目录 → installApp
  const appDir = join(simctlFake.container, '..', 'Fake.app');
  mkdirSync(appDir, { recursive: true });
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: installApp', args: [{ app: appDir }],
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.value, true);
  assert.ok(simctlFake.calls.includes(`install ${FAKE_UDID} ${appDir}`));
  // 未安装的 App removeApp → false（不实际卸载）
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: removeApp', args: [{ appId: 'com.not.installed' }],
  });
  assert.equal(r.json.value, false);
  // mobile: pushFile（data 参数名）
  const payload = Buffer.from('mobile push').toString('base64');
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: pushFile', args: [{ path: '@com.iuiauto.example/tmp/m.txt', data: payload }],
  });
  assert.equal(r.status, 200);
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: pullFile', args: [{ path: '@com.iuiauto.example/tmp/m.txt' }],
  });
  assert.equal(r.json.value, payload);
  // mobile: queryAppState 指定其他 bundleId → 走 simctl 探测
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: queryAppState', args: [{ bundleId: 'com.other.app' }],
  });
  assert.equal(r.json.value, 1);
});

test('simctl: mobile setAppearance / getAppearance', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: getAppearance', args: [] });
  assert.equal(r.status, 200);
  assert.equal(r.json.value.style, 'dark');
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: setAppearance', args: [{ style: 'light' }] });
  assert.equal(r.status, 200);
  assert.equal(r.json.value.style, 'light');
  assert.ok(simctlFake.calls.includes(`ui ${FAKE_UDID} appearance light`));
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: setAppearance', args: [{ style: 'blue' }] });
  assert.equal(r.status, 400);
  assert.equal(r.json.value.error, 'invalid argument');
});

test('mobile: hideKeyboard / keys', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: hideKeyboard', args: [{ key: 'return' }],
  });
  assert.equal(r.status, 200);
  const lastKey = [...fake.state.calls].reverse().find((c) => c.action === 'press_key');
  assert.equal(lastKey.params.key, 'return');
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: hideKeyboard', args: [] });
  assert.equal(r.status, 200);
  assert.ok([...fake.state.calls].some((c) => c.action === 'dismiss_keyboard'));
  const keysBefore = fake.state.calls.filter((c) => c.action === 'press_key').length;
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: keys', args: [{ keys: ['ab', '\uE003'] }],
  });
  assert.equal(r.status, 200);
  const keys = fake.state.calls.filter((c) => c.action === 'press_key').slice(keysBefore)
    .map((c) => c.params.key);
  assert.deepEqual(keys, ['a', 'b', 'delete']);
});

test('JSON Wire: element location / location_in_view / size / equals', async () => {
  let r = await request('GET', `/session/${sessionId}/element/${buttonId}/location`);
  assert.deepEqual(r.json.value, { x: 10, y: 20 });
  r = await request('GET', `/session/${sessionId}/element/${buttonId}/location_in_view`);
  assert.deepEqual(r.json.value, { x: 10, y: 20 });
  r = await request('GET', `/session/${sessionId}/element/${buttonId}/size`);
  assert.deepEqual(r.json.value, { width: 100, height: 40 });
  // 重新查找同一元素 → equals true；不同元素 → false
  const again = await request('POST', `/session/${sessionId}/element`, { using: 'accessibility id', value: 'btn.counter' });
  const againId = again.json.value[ELEMENT_KEY];
  r = await request('GET', `/session/${sessionId}/element/${buttonId}/equals/${againId}`);
  assert.equal(r.json.value, true);
  r = await request('GET', `/session/${sessionId}/element/${buttonId}/equals/${labelId}`);
  assert.equal(r.json.value, false);
});

test('JSON Wire: POST /keys sends key sequence', async () => {
  const keysBefore = fake.state.calls.filter((c) => c.action === 'press_key').length;
  const r = await request('POST', `/session/${sessionId}/keys`, { value: ['hi', '\uE007'] });
  assert.equal(r.status, 200);
  const keys = fake.state.calls.filter((c) => c.action === 'press_key').slice(keysBefore)
    .map((c) => c.params.key);
  assert.deepEqual(keys, ['h', 'i', 'return']);
});

test('JSON Wire: touch/perform chains', async () => {
  // tap 链
  let r = await request('POST', `/session/${sessionId}/touch/perform`, {
    actions: [{ action: 'tap', options: { x: 120, y: 240 } }],
  });
  assert.equal(r.status, 200);
  assert.equal(fake.state.lastGesture.action, 'tap');
  assert.equal(fake.state.lastGesture.x, 120);
  // press → wait → moveTo → release ⇒ swipe
  r = await request('POST', `/session/${sessionId}/touch/perform`, {
    actions: [
      { action: 'press', options: { x: 200, y: 600 } },
      { action: 'wait', options: { ms: 100 } },
      { action: 'moveTo', options: { x: 200, y: 300 } },
      { action: 'release' },
    ],
  });
  assert.equal(r.status, 200);
  assert.equal(fake.state.lastGesture.action, 'swipe');
  assert.equal(fake.state.lastGesture.fromY, 600);
  assert.equal(fake.state.lastGesture.toY, 300);
  // longPress 链：元素相对坐标（rect 10,20,100,40 + 偏移 5,6 → 15,26）
  r = await request('POST', `/session/${sessionId}/touch/perform`, {
    actions: [{ action: 'longPress', options: { element: { ELEMENT: buttonId }, x: 5, y: 6 } }],
  });
  assert.equal(r.status, 200);
  assert.equal(fake.state.lastGesture.action, 'long_press');
  assert.equal(fake.state.lastGesture.x, 15);
  assert.equal(fake.state.lastGesture.y, 26);
  // 未知动作 → 400
  r = await request('POST', `/session/${sessionId}/touch/perform`, {
    actions: [{ action: 'explode' }],
  });
  assert.equal(r.status, 400);
});

test('JSON Wire: touch/multi/perform → pinch', async () => {
  const r = await request('POST', `/session/${sessionId}/touch/multi/perform`, {
    actions: [
      [
        { action: 'press', options: { x: 150, y: 300 } },
        { action: 'moveTo', options: { x: 100, y: 300 } },
        { action: 'release' },
      ],
      [
        { action: 'press', options: { x: 250, y: 300 } },
        { action: 'moveTo', options: { x: 300, y: 300 } },
        { action: 'release' },
      ],
    ],
  });
  assert.equal(r.status, 200);
  assert.equal(fake.state.lastGesture.action, 'pinch');
  assert.equal(fake.state.lastGesture.radiusFrom, 50);
  assert.equal(fake.state.lastGesture.radiusTo, 100);
});

test('appium settings: screenshotQuality applies to screenshots', async () => {
  let r = await request('POST', `/session/${sessionId}/appium/settings`, { settings: { screenshotQuality: 0 } });
  assert.equal(r.status, 200);
  assert.equal((await request('GET', `/session/${sessionId}/appium/settings`)).json.value.screenshotQuality, 0);
  r = await request('GET', `/session/${sessionId}/screenshot`);
  assert.equal(r.status, 200);
  const lastShot = [...fake.state.calls].reverse().find((c) => c.action === 'screenshot');
  assert.equal(lastShot.params.quality, 0);
  // 元素截图同样生效
  await request('GET', `/session/${sessionId}/element/${buttonId}/screenshot`);
  const lastElementShot = [...fake.state.calls].reverse()
    .find((c) => c.action === 'element_action' && c.params.action === 'screenshot');
  assert.equal(lastElementShot.params.quality, 0);
  // 恢复默认
  await request('POST', `/session/${sessionId}/appium/settings`, { settings: { screenshotQuality: 2 } });
});

test('mobile: scroll XCUITest semantics (name / predicateString / direction)', async () => {
  // name：找到即返回元素句柄，并滚到可见
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: scroll', args: [{ name: 'field.input' }],
  });
  assert.equal(r.status, 200);
  assert.ok(r.json.value[ELEMENT_KEY], '应返回目标元素句柄');
  assert.ok(fake.state.calls.some((c) => c.action === 'element_action' && c.params.action === 'scroll_to'));
  // 找不到 → 循环滚动后 404
  await request('POST', `/session/${sessionId}/timeouts`, { script: 3000 });
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: scroll', args: [{ predicateString: 'name == "never.found"' }],
  });
  assert.equal(r.status, 404);
  assert.equal(r.json.value.error, 'no such element');
  assert.equal(fake.state.lastGesture.action, 'swipe', '循环过程中应产生滚动');
  // 普通 direction+distance 滚动不受影响
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: scroll', args: [{ direction: 'down', distance: 200 }],
  });
  assert.equal(r.status, 200);
  assert.equal(fake.state.lastGesture.action, 'swipe');
});

test('mobile: compareImages maps screenshot_compare', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: compareImages', args: [{ firstImage: 'GOOD_BASELINE' }],
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.value.pass, true);
  assert.equal(r.json.value.diffPercent, 0);
  const goodCall = fake.state.calls.find((c) => c.action === 'screenshot_compare' && c.params.baseline === 'GOOD_BASELINE');
  assert.ok(goodCall);
  assert.equal(goodCall.params.thresholdPercent, undefined, '未给阈值不应传 thresholdPercent');
  // 差异超阈值 → pass:false 结构化返回（而不是抛错）
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: compareImages', args: [{ firstImage: 'BAD_BASELINE', options: { threshold: 1 } }],
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.value.pass, false);
  assert.equal(r.json.value.diffPercent, 5);
  const badCall = fake.state.calls.find((c) => c.action === 'screenshot_compare' && c.params.baseline === 'BAD_BASELINE');
  assert.equal(badCall.params.thresholdPercent, 1);
  // Appium 风格 0~1 阈值 → 换算为百分比
  await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: compareImages', args: [{ firstImage: 'GOOD_BASELINE', options: { threshold: 0.02 } }],
  });
  const scaled = [...fake.state.calls].reverse().find((c) => c.action === 'screenshot_compare');
  assert.equal(scaled.params.thresholdPercent, 2);
  // 缺参 → 400
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: compareImages', args: [{}] });
  assert.equal(r.status, 400);
});

test('Appium events endpoints', async () => {
  let r = await request('GET', `/session/${sessionId}/appium/events`);
  assert.ok(r.json.value.events.sessionStarted.length >= 1);
  assert.ok(r.json.value.events.serverStarted.length >= 1);
  // POST 按名称过滤
  r = await request('POST', `/session/${sessionId}/appium/events`, { events: ['sessionStarted'] });
  assert.deepEqual(Object.keys(r.json.value.events), ['sessionStarted']);
  // 服务器级 /events
  r = await request('GET', '/events');
  assert.ok(r.json.value.events.sessionRequested.length >= 1);
});

test('mobile: setPermission / resetPermission (simctl privacy)', async () => {
  // 当前 App grant：等重连（假 hello 恒在线，最多 2s 后继续）
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setPermission', args: [{ service: 'photos', state: 'granted' }],
  });
  assert.equal(r.status, 200);
  assert.ok(simctlFake.calls.includes(`privacy ${FAKE_UDID} grant photos com.iuiauto.example`));
  // 其他 App deny / reset：不等待重连
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setPermission', args: [{ service: 'location', state: 'denied', bundleId: 'com.other.app' }],
  });
  assert.equal(r.status, 200);
  assert.ok(simctlFake.calls.includes(`privacy ${FAKE_UDID} revoke location com.other.app`));
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setPermission', args: [{ service: 'photos', state: 'reset', bundleId: 'com.other.app' }],
  });
  assert.ok(simctlFake.calls.includes(`privacy ${FAKE_UDID} reset photos com.other.app`));
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: resetPermission', args: [{ service: 'all', bundleId: 'com.other.app' }],
  });
  assert.equal(r.status, 200);
  assert.ok(simctlFake.calls.includes(`privacy ${FAKE_UDID} reset all com.other.app`));
  // 非法服务（camera 不在本机 simctl 服务表）→ 400；非法状态 → 400
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setPermission', args: [{ service: 'camera', state: 'granted', bundleId: 'com.other.app' }],
  });
  assert.equal(r.status, 400);
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setPermission', args: [{ service: 'photos', state: 'maybe', bundleId: 'com.other.app' }],
  });
  assert.equal(r.status, 400);
});

test('mobile: setReduceTransparency / getReduceTransparency', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setReduceTransparency', args: [{ enabled: true }],
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.value, true);
  assert.ok(simctlFake.calls.includes(`ui ${FAKE_UDID} increase_contrast enabled`));
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: getReduceTransparency', args: [] });
  assert.equal(r.json.value, true);
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setReduceTransparency', args: [{ enabled: false }],
  });
  assert.equal(r.json.value, false);
});

test('W3C computedlabel / computedrole element endpoints', async () => {
  let r = await request('GET', `/session/${sessionId}/element/${buttonId}/computedlabel`);
  assert.equal(r.status, 200);
  assert.equal(r.json.value, '点我');
  r = await request('GET', `/session/${sessionId}/element/${buttonId}/computedrole`);
  assert.equal(r.status, 200);
  assert.equal(r.json.value, 'XCUIElementTypeButton');
});

test('mobile: getAppStrings reads bundle Localizable.strings', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: getAppStrings', args: [{ language: 'zh-Hans' }],
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.value.language, 'zh-Hans');
  assert.equal(r.json.value.strings['demo.greeting'], '你好，IUIAuto');
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: getAppStrings', args: [{ language: 'en' }],
  });
  assert.equal(r.json.value.strings['demo.greeting'], 'Hello, IUIAuto');
  // 未知语言回退 en/Base
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: getAppStrings', args: [{ language: 'fr' }],
  });
  assert.equal(r.status, 200);
  assert.equal(r.json.value.strings['demo.greeting'], 'Hello, IUIAuto');
});

test('mobile: getClipboard / setClipboard aliases', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: setClipboard', args: [{ content: '剪贴板别名' }],
  });
  assert.equal(r.status, 200);
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: getClipboard', args: [] });
  assert.equal(r.status, 200);
  assert.equal(r.json.value, '剪贴板别名');
});

test('real device: host-side management returns unsupported', async () => {
  const realFake = createFakeApp('iPhone17,1');
  const realHello = {
    type: 'hello',
    agent: 'IUIAuto',
    version: '0.5.0',
    environment: { systemVersion: '26.5', deviceModel: 'iPhone17,1' },
    actions: [],
  };
  const realBridge = createAppiumBridge({
    send: realFake.send,
    getHello: () => realHello,
    sessionWaitMs: 500,
    log: () => {},
    simctl: simctlFake.simctl, // 即使注入也不应被调用（真机会话）
  });
  await new Promise((resolve) => realBridge.server.listen(0, '127.0.0.1', resolve));
  const realBase = `http://127.0.0.1:${realBridge.server.address().port}`;
  const post = async (path, body) => {
    const response = await fetch(realBase + path, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(10000),
    });
    return { status: response.status, json: await response.json() };
  };
  // appium:orientation capability：建会话即设置方向
  // appium:newCommandTimeout=3：空闲后自动结束会话
  const created = await post('/session', {
    capabilities: { alwaysMatch: {
      platformName: 'iOS',
      'appium:automationName': 'IUIAuto',
      'appium:orientation': 'LANDSCAPE',
      'appium:newCommandTimeout': 3,
    } },
  });
  const sid = created.json.value.sessionId;
  assert.equal(realFake.state.orientation, 'LANDSCAPE');
  const simctlCallsBefore = simctlFake.calls.length;

  let r = await post(`/session/${sid}/appium/device/terminate_app`, { appId: 'com.any.app' });
  assert.equal(r.status, 500);
  assert.equal(r.json.value.error, 'unsupported operation');
  r = await post(`/session/${sid}/execute/sync`, { script: 'mobile: setAppearance', args: [{ style: 'dark' }] });
  assert.equal(r.status, 500);
  assert.equal(r.json.value.error, 'unsupported operation');
  r = await post(`/session/${sid}/execute/sync`, {
    script: 'mobile: setPermission', args: [{ service: 'photos', state: 'granted' }],
  });
  assert.equal(r.status, 500);
  assert.equal(r.json.value.error, 'unsupported operation');
  // 真机激活"当前 App"仍可用（App 本就在前台）
  r = await post(`/session/${sid}/appium/device/activate_app`, { bundleId: 'com.iuiauto.example' });
  assert.equal(r.status, 200);
  // 其他 App：installed=false / state=0，且不触碰 simctl
  r = await post(`/session/${sid}/appium/device/app_installed`, { bundleId: 'com.other.app' });
  assert.equal(r.json.value, false);
  r = await post(`/session/${sid}/appium/device/app_state`, { bundleId: 'com.other.app' });
  assert.equal(r.json.value, 0);
  assert.equal(simctlFake.calls.length, simctlCallsBefore);

  // appium:newCommandTimeout=3：不再发命令后，会话应自动结束（用根路径轮询，不刷新计时）
  const expired = await (async () => {
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const status = await fetch(`${realBase}/`).then((x) => x.json()).catch(() => null);
      if (status && status.value.session === null) return true;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    return false;
  })();
  assert.equal(expired, true, '会话应在 newCommandTimeout 空闲后自动结束');
  const gone = await fetch(`${realBase}/session/${sid}/source`).then((x) => x.status);
  assert.equal(gone, 404);
  const events = await fetch(`${realBase}/events`).then((x) => x.json());
  assert.ok(events.value.events.unexpectedShutdown?.length >= 1, '应记录 unexpectedShutdown 事件');

  await realBridge.close();
});

test('W3C active element endpoint', async () => {
  // 假 App 的 active_element 返回 xpath；active 端点应返回可用的元素句柄
  const r = await request('GET', `/session/${sessionId}/element/active`);
  assert.equal(r.status, 200);
  assert.ok(r.json.value[ELEMENT_KEY]);
});

test('mobile: execute commands', async () => {
  let r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: deviceInfo', args: [] });
  assert.equal(r.json.value.name, 'iPhone 17 Pro');
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: setPasteboard', args: [{ text: 'xyz' }] });
  assert.equal(r.status, 200);
  assert.equal((await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: getPasteboard', args: [] })).json.value, 'xyz');
  r = await request('POST', `/session/${sessionId}/execute/sync`, {
    script: 'mobile: activeElement', args: [],
  });
  assert.ok(r.json.value === null || r.json.value[ELEMENT_KEY]);
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: orientation', args: [] });
  assert.equal(r.json.value, 'LANDSCAPE');
  r = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: unsupportedThing', args: [] });
  assert.equal(r.status, 404);
});

test('alert endpoints (no alert → error)', async () => {
  const r = await request('POST', `/session/${sessionId}/appium/alert/accept`);
  assert.ok(r.status >= 400);
});

test('unknown endpoint', async () => {
  const r = await request('GET', `/session/${sessionId}/not/a/route`);
  assert.equal(r.status, 404);
  assert.equal(r.json.value.error, 'unknown command');
});

test('invalid session id', async () => {
  const r = await request('GET', '/session/not-a-session/source');
  assert.equal(r.status, 404);
  assert.equal(r.json.value.error, 'invalid session id');
});

test('DELETE /session stops active recording', async () => {
  const stopsBefore = simctlFake.videoStops;
  const started = await request('POST', `/session/${sessionId}/appium/start_recording_screen`);
  assert.equal(started.status, 200);
  const r = await request('DELETE', `/session/${sessionId}`);
  assert.equal(r.status, 200);
  assert.equal(r.json.value, null);
  assert.equal(simctlFake.videoStops, stopsBefore + 1, '会话结束应停止在录的屏');
  const after = await request('GET', `/session/${sessionId}/source`);
  assert.equal(after.status, 404);
  assert.equal(after.json.value.error, 'invalid session id');
});

test('POST /session with appium:forceAppLaunch restarts host app', async () => {
  const r = await request('POST', '/session', {
    capabilities: { alwaysMatch: {
      platformName: 'iOS',
      'appium:automationName': 'IUIAuto',
      'appium:forceAppLaunch': true,
    } },
  });
  assert.equal(r.status, 200);
  assert.ok(r.json.value.sessionId);
  assert.ok(simctlFake.calls.includes(`terminate ${FAKE_UDID} com.iuiauto.example`));
  assert.ok(simctlFake.calls.includes(`launch ${FAKE_UDID} com.iuiauto.example`));
  // 事件流包含两次会话创建
  const events = await request('GET', '/events');
  assert.ok(events.json.value.events.sessionRequested.length >= 2);
  assert.ok(events.json.value.events.sessionStarted.length >= 2);
});

// ---------------------------------------------------------------------------
// 运行
// ---------------------------------------------------------------------------
let passed = 0;
for (const { name, fn } of tests) {
  try {
    await fn();
    passed++;
    console.log(`✓ ${name}`);
  } catch (error) {
    console.error(`✗ ${name}`);
    console.error(`  ${error.stack || error.message}`);
  }
}

await bridge.close();
console.log(`\n${passed}/${tests.length} 通过`);
process.exit(passed === tests.length ? 0 : 1);
