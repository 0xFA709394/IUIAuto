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
import { createAppiumBridge } from './appium_bridge.js';
import { translateActions, ELEMENT_KEY } from './iua_webdriver_actions.js';

const tests = [];
function test(name, fn) {
  tests.push({ name, fn });
}

// ---------------------------------------------------------------------------
// 假 App
// ---------------------------------------------------------------------------
function createFakeApp() {
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
          const isLabel = String(params.value || '').includes('label.counter');
          const value = attribute === 'value' ? state.text
            : attribute === 'name' ? (isLabel ? 'label.counter' : 'btn.counter')
            : attribute === 'label' ? `Count: ${state.counter}`
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
      case 'device_info':
        return { ok: true, data: {
          name: 'iPhone 17 Pro', systemVersion: '26.5', bundleId: 'com.iuiauto.example',
          appVersion: '1.0', deviceModel: 'arm64', locale: 'en_CN', language: 'zh-Hans-CN',
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
// 桥端到端（假 App）
// ---------------------------------------------------------------------------
const fake = createFakeApp();
const hello = {
  type: 'hello',
  agent: 'IUIAuto',
  version: '0.3.0',
  environment: { systemVersion: '26.5', deviceModel: 'arm64' },
  actions: ['find_elements', 'element_action', 'page_source'],
};
const bridge = createAppiumBridge({
  send: fake.send,
  getHello: () => hello,
  sessionWaitMs: 1000,
  log: () => {},
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

test('DELETE /session', async () => {
  const r = await request('DELETE', `/session/${sessionId}`);
  assert.equal(r.status, 200);
  assert.equal(r.json.value, null);
  const after = await request('GET', `/session/${sessionId}/source`);
  assert.equal(after.status, 404);
  assert.equal(after.json.value.error, 'invalid session id');
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
