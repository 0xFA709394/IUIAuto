#!/usr/bin/env node
/**
 * Appium 桥 + 模拟器真机端到端验证
 *
 * 前置：已编译安装 IUIAutoExample，至少一台模拟器 booted。
 * 运行：node Tools/appium_e2e_test.mjs [--keep]
 *   --keep  测试结束后保留 bridge 进程（默认自动关闭）
 *
 * 自动完成：启动独立 appium_bridge（--takeover 接管 9800/4723）→ 拉起 App →
 * W3C session / 元素点击 / 输入 / 页面源码 / 截图 / W3C Actions / Appium 设备端点。
 */

import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const keep = process.argv.includes('--keep');
const BRIDGE_PORT = +(process.env.BRIDGE_PORT || 4724);
const APP_PORT = +(process.env.APP_PORT || 9800);
const BASE = `http://127.0.0.1:${BRIDGE_PORT}`;
const BUNDLE_ID = 'com.iuiauto.example';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function detectBootedSimulator() {
  const { stdout } = await execFileAsync('xcrun', ['simctl', 'list', 'devices', 'booted'], {
    env: { ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer' },
  }).catch(() => ({ stdout: '' }));
  const match = stdout.match(/\(([0-9A-F-]{36})\)/);
  return match ? match[1] : null;
}

async function waitFor(label, fn, timeoutMs = 30000, intervalMs = 300) {
  const deadline = Date.now() + timeoutMs;
  let lastError = null;
  while (Date.now() < deadline) {
    try {
      const value = await fn();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await sleep(intervalMs);
  }
  throw new Error(`${label} 超时${lastError ? `: ${lastError.message}` : ''}`);
}

async function request(method, path, body, timeoutMs = 30000) {
  const response = await fetch(BASE + path, {
    method,
    headers: { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
    signal: AbortSignal.timeout(timeoutMs),
  });
  const text = await response.text();
  let json;
  try { json = JSON.parse(text); } catch { json = text; }
  return { status: response.status, json };
}

const checks = [];
function check(name, condition, detail = '') {
  checks.push({ name, pass: !!condition, detail });
  console.log(`${condition ? '✓' : '✗'} ${name}${detail ? ` — ${detail}` : ''}`);
}

async function main() {
  const udid = await detectBootedSimulator();
  if (!udid) throw new Error('未检测到已启动的模拟器：请先 ./build.sh 或 ./start.sh');
  console.log(`模拟器: ${udid}`);

  const child = spawn(process.execPath, [join(__dirname, 'appium_bridge.js'), '--takeover'], {
    cwd: __dirname,
    env: { ...process.env, BRIDGE_PORT: String(BRIDGE_PORT), APP_PORT: String(APP_PORT), IUA_UDID: udid },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let childLog = '';
  child.stdout.on('data', (data) => { childLog += data.toString(); });
  child.stderr.on('data', (data) => { childLog += data.toString(); });

  try {
    await waitFor('WebDriver 桥启动', async () => {
      const r = await request('GET', '/status', undefined, 2000);
      return r.status === 200;
    }, 15000, 300);
    console.log(`桥已启动: ${BASE}`);

    await execFileAsync('xcrun', ['simctl', 'launch', udid, BUNDLE_ID]).catch(() => {});
    console.log('已请求拉起 App，等待连接…');

    const sessionResponse = await request('POST', '/session', {
      capabilities: {
        alwaysMatch: {
          platformName: 'iOS',
          'appium:automationName': 'IUIAuto',
          'appium:deviceName': 'iPhone Simulator',
        },
        firstMatch: [{}],
      },
    }, 40000);
    check('创建 W3C session', sessionResponse.status === 200 && !!sessionResponse.json?.value?.sessionId,
      JSON.stringify(sessionResponse.json?.value?.capabilities?.['appium:deviceName'] ?? sessionResponse.json));
    const sessionId = sessionResponse.json?.value?.sessionId;
    if (!sessionId) throw new Error('session 创建失败: ' + JSON.stringify(sessionResponse.json));

    const find = async (using, value) => {
      const r = await request('POST', `/session/${sessionId}/element`, { using, value });
      return r.status === 200 ? r.json.value['element-6066-11e4-a52e-4f735466cecf'] : null;
    };

    // 复位界面（残留弹窗/键盘/滚动位置），保证脚本从任意历史状态都可重复运行。
    // 显式指定 scroll.demo，避免误用键盘等系统 UIScrollView。
    await request('POST', `/session/${sessionId}/alert/dismiss`).catch(() => {});
    await sleep(250);
    await request('POST', `/session/${sessionId}/appium/device/hide_keyboard`);
    await sleep(600);
    const demoScroll = await find('accessibility id', 'scroll.demo');
    if (demoScroll) {
      await request('POST', `/session/${sessionId}/execute/sync`, {
        script: 'mobile: scrollToTop',
        args: [{ element: { ELEMENT: demoScroll } }],
      });
    }
    await sleep(800);

    const source = await request('GET', `/session/${sessionId}/source`);
    check('页面源码 XML', source.status === 200 && source.json.value.includes('AppiumAUT') &&
      source.json.value.includes('XCUIElementTypeButton'), `${source.json.value?.length ?? 0} 字节`);

    const button = await find('accessibility id', 'btn.counter');
    const label = await find('accessibility id', 'label.counter');
    check('按 accessibility id 查找元素', !!button && !!label);
    const beforeText = await request('GET', `/session/${sessionId}/element/${label}/text`);
    const beforeCount = parseInt(String(beforeText.json.value).replace(/\D+/g, ''), 10) || 0;
    check('读取元素文本', beforeText.status === 200, `"${beforeText.json.value}"`);

    const buttonRect = await request('GET', `/session/${sessionId}/element/${button}/rect`);
    const click = await request('POST', `/session/${sessionId}/element/${button}/click`);
    check('元素点击', click.status === 200,
      `rect=${JSON.stringify(buttonRect.json?.value ?? {})} ${click.status === 200 ? '' : JSON.stringify(click.json?.value ?? click.json).slice(0, 260)}`);
    const afterText = await request('GET', `/session/${sessionId}/element/${label}/text`);
    const afterCount = parseInt(String(afterText.json.value).replace(/\D+/g, ''), 10) || 0;
    check('点击真实生效（计数 +1）', afterCount === beforeCount + 1, `${beforeText.json.value} → ${afterText.json.value}`);

    const invalidLocator = await request('POST', `/session/${sessionId}/element`, { using: 'xpath', value: '//[' });
    check('无效 XPath 返回 invalid selector', invalidLocator.status === 400 &&
      invalidLocator.json?.value?.error === 'invalid selector', JSON.stringify(invalidLocator.json?.value));
    const unknownAttribute = await request('GET', `/session/${sessionId}/element/${button}/attribute/not-an-attribute`);
    check('未知属性返回 null', unknownAttribute.status === 200 && unknownAttribute.json.value === null);

    const field = await find('xpath', '//XCUIElementTypeTextField[@name="field.input"]');
    check('XPath 定位输入框', !!field);
    await request('POST', `/session/${sessionId}/element/${field}/clear`);
    await request('POST', `/session/${sessionId}/element/${field}/value`, { text: 'Appium E2E 你好' });
    const fieldText = await request('GET', `/session/${sessionId}/element/${field}/text`);
    check('sendKeys / clear', fieldText.json.value === 'Appium E2E 你好', `"${fieldText.json.value}"`);

    // 输入后键盘可能遮挡提交按钮，先收起
    await request('POST', `/session/${sessionId}/appium/device/hide_keyboard`);
    await sleep(600);

    const submit = await find('label', '提交');
    check('label 定位按钮', !!submit);
    await request('POST', `/session/${sessionId}/element/${submit}/click`);
    const output = await find('accessibility id', 'label.output');
    const outputText = output ? await request('GET', `/session/${sessionId}/element/${output}/text`) : null;
    check('提交联动生效', !!outputText && String(outputText.json.value).includes('Appium E2E 你好'),
      outputText?.json?.value ?? '');

    // ---- Appium alert：真实 UIAlertController（Demo 的「弹窗测试」按钮）----
    const alertButton = await find('accessibility id', 'btn.alert');
    check('弹窗触发按钮存在', !!alertButton);
    if (alertButton) {
      await request('POST', `/session/${sessionId}/element/${alertButton}/click`);
      await sleep(400);
      const alertText = await request('GET', `/session/${sessionId}/appium/alert/text`);
      check('读取弹窗文本', alertText.status === 200 && String(alertText.json.value).includes('请输入内容'),
        `"${alertText.json.value}"`);
      const setAlertText = await request('POST', `/session/${sessionId}/appium/alert/text`, { text: 'E2E 弹窗输入' });
      check('设置弹窗文本', setAlertText.status === 200);
      const acceptAlert = await request('POST', `/session/${sessionId}/appium/alert/accept`);
      check('接受弹窗', acceptAlert.status === 200);
      await sleep(350);
      const outputAfterAlert = output ? await request('GET', `/session/${sessionId}/element/${output}/text`) : null;
      check('弹窗按钮回调生效', !!outputAfterAlert && String(outputAfterAlert.json.value).includes('弹窗确认: E2E 弹窗输入'),
        outputAfterAlert?.json?.value ?? '');
      const noAlert = await request('GET', `/session/${sessionId}/appium/alert/text`);
      check('弹窗关闭后返回 no such alert', noAlert.status === 404);
    }

    const screenshot = await request('GET', `/session/${sessionId}/screenshot`);
    check('窗口截图', screenshot.status === 200 && screenshot.json.value.length > 1000,
      `${screenshot.json.value?.length ?? 0} base64 字符`);
    const elementScreenshot = await request('GET', `/session/${sessionId}/element/${button}/screenshot`);
    check('元素截图', elementScreenshot.status === 200 && elementScreenshot.json.value.length > 500,
      `${elementScreenshot.json.value?.length ?? 0} base64 字符`);

    const beforeActionCount = afterCount;
    const actions = await request('POST', `/session/${sessionId}/actions`, {
      actions: [{
        type: 'pointer', id: 'finger1', parameters: { pointerType: 'touch' },
        actions: [
          { type: 'pointerMove', duration: 0, x: 200, y: 320, origin: 'viewport' },
          { type: 'pointerDown', button: 0 },
          { type: 'pause', duration: 80 },
          { type: 'pointerUp', button: 0 },
        ],
      }],
    });
    check('W3C Actions tap', actions.status === 200);
    await sleep(250);
    const afterActionText = await request('GET', `/session/${sessionId}/element/${label}/text`);
    const afterActionCount = parseInt(String(afterActionText.json.value).replace(/\D+/g, ''), 10) || 0;
    check('W3C Actions 真实生效（计数 +1）', afterActionCount === beforeActionCount + 1,
      `${beforeActionCount} → ${afterActionCount}`);

    const orientation = await request('GET', `/session/${sessionId}/orientation`);
    check('方向读取', orientation.status === 200, orientation.json.value);
    const keyboard = await request('GET', `/session/${sessionId}/appium/device/is_keyboard_shown`);
    check('键盘状态', keyboard.status === 200 && typeof keyboard.json.value === 'boolean', String(keyboard.json.value));
    const clipboardSet = await request('POST', `/session/${sessionId}/appium/device/set_clipboard`, { content: 'iuiauto e2e' });
    const clipboardGet = await request('GET', `/session/${sessionId}/appium/device/get_clipboard`);
    check('剪贴板 set/get', clipboardSet.status === 200 && clipboardGet.json.value === 'iuiauto e2e');
    const deviceInfo = await request('POST', `/session/${sessionId}/execute/sync`, { script: 'mobile: deviceInfo', args: [] });
    check('mobile: deviceInfo', deviceInfo.status === 200 && deviceInfo.json.value.bundleId === BUNDLE_ID,
      deviceInfo.json.value?.bundleId ?? '');

    const removed = await request('DELETE', `/session/${sessionId}`);
    check('删除会话', removed.status === 200);
  } finally {
    if (!keep) {
      child.kill('SIGTERM');
      await sleep(500);
      if (!child.killed) child.kill('SIGKILL');
    }
    const passed = checks.filter((c) => c.pass).length;
    console.log(`\n结果: ${passed}/${checks.length} 通过 ${passed === checks.length ? '✅ PASS' : '❌ FAIL'}`);
    if (passed !== checks.length) {
      console.log('\n—— bridge 日志（末 60 行）——');
      console.log(childLog.split('\n').slice(-60).join('\n'));
    }
    process.exit(passed === checks.length ? 0 : 1);
  }
}

main().catch((error) => {
  console.error('E2E 失败:', error.stack || error.message);
  process.exit(1);
});
