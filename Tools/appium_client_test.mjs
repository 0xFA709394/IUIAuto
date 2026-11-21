#!/usr/bin/env node
/**
 * WebdriverIO 真实客户端 E2E —— 用标准 Appium 客户端验证桥的协议兼容性
 *
 * 前置：已编译安装 IUIAutoExample，至少一台模拟器 booted，Tools 内已 `npm install`。
 * 运行：node Tools/appium_client_test.mjs [--keep]
 *
 * 与 appium_e2e_test.mjs（裸 HTTP 协议验证）互补：这里走 WebdriverIO 的命令封装
 * （元素链式操作 / W3C Actions 链式手势 / executeScript mobile: 命令），
 * 验证客户端生成的真实请求形状都能被桥正确处理。
 */

import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const execFileAsync = promisify(execFile);
const __dirname = dirname(fileURLToPath(import.meta.url));
const keep = process.argv.includes('--keep');
const BRIDGE_PORT = +(process.env.BRIDGE_PORT || 4725);
const APP_PORT = +(process.env.APP_PORT || 9800);
const BUNDLE_ID = process.env.IUA_BUNDLE_ID || 'com.iuiauto.example';

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function detectBootedSimulator() {
  const { stdout } = await execFileAsync('xcrun', ['simctl', 'list', 'devices', 'booted'], {
    env: { ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer' },
  }).catch(() => ({ stdout: '' }));
  const iosLine = stdout.split('\n').find((line) => /iPhone|iPad/.test(line) && /\([0-9A-F-]{36}\)/.test(line));
  const match = iosLine ? iosLine.match(/\(([0-9A-F-]{36})\)/) : null;
  return match ? match[1] : null;
}

const checks = [];
function check(name, condition, detail = '') {
  checks.push({ name, pass: !!condition });
  console.log(`${condition ? '✓' : '✗'} ${name}${detail ? ` — ${detail}` : ''}`);
}

async function main() {
  let remote;
  try {
    ({ remote } = await import('webdriverio'));
  } catch {
    console.log('⏹ 未安装 webdriverio（cd Tools && npm install），跳过真实客户端 E2E');
    process.exit(0);
  }

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

  let driver = null;
  try {
    // 等桥就绪
    const deadline = Date.now() + 15000;
    while (Date.now() < deadline) {
      const ok = await fetch(`http://127.0.0.1:${BRIDGE_PORT}/status`).then((r) => r.ok).catch(() => false);
      if (ok) break;
      await sleep(300);
    }
    await execFileAsync('xcrun', ['simctl', 'launch', udid, BUNDLE_ID]).catch(() => {});
    // 等 App 真正连上桥（否则建会话会报 "App 未连接"）
    const appDeadline = Date.now() + 30000;
    while (Date.now() < appDeadline) {
      const health = await fetch(`http://127.0.0.1:${BRIDGE_PORT}/`).then((r) => r.json()).catch(() => null);
      if (health?.value?.appConnected) break;
      await sleep(400);
    }

    driver = await remote({
      hostname: '127.0.0.1',
      port: BRIDGE_PORT,
      path: '/',
      capabilities: {
        platformName: 'iOS',
        'appium:automationName': 'IUIAuto',
        'appium:deviceName': 'iPhone Simulator',
      },
      logLevel: 'error',
      connectionRetryTimeout: 30000,
    });
    check('WebdriverIO 建立会话', !!driver.sessionId, `sessionId=${driver.sessionId?.slice(0, 8)}…`);

    // 复位界面
    try { await driver.execute('mobile: scrollToTop'); } catch { /* 无 scroll 容器时忽略 */ }
    await sleep(400);

    // ---- 元素链式操作 ----
    const counter = await driver.$('~btn.counter');
    const label = await driver.$('~label.counter');
    const beforeText = await label.getText();
    const beforeCount = parseInt(String(beforeText).replace(/\D+/g, ''), 10) || 0;
    check('accessibility id 定位 + getText', String(beforeText).includes('Count'), `"${beforeText}"`);

    await counter.click();
    await sleep(400);
    const afterText = await label.getText();
    const afterCount = parseInt(String(afterText).replace(/\D+/g, ''), 10) || 0;
    check('click 真实生效（计数 +1）', afterCount === beforeCount + 1, `${beforeText} → ${afterText}`);

    const field = await driver.$('//XCUIElementTypeTextField[@name="field.input"]');
    await field.clearValue();
    await field.setValue('wdio 你好');
    const value = await field.getValue();
    check('XPath 定位 + setValue/getValue', value === 'wdio 你好', `"${value}"`);

    const attr = await counter.getAttribute('name');
    check('getAttribute', attr === 'btn.counter', `"${attr}"`);
    const rect = await counter.getSize();
    check('getSize / W3C rect', rect.width > 0, `${rect.width}x${rect.height}`);

    const source = await driver.getPageSource();
    check('getPageSource', source.includes('XCUIElementType'), `${source.length} 字节`);
    const shot = await driver.takeScreenshot();
    check('takeScreenshot', typeof shot === 'string' && shot.length > 1000, `${shot?.length ?? 0} base64 字符`);

    // ---- W3C Actions 链式手势（WebdriverIO action() API）----
    await driver.execute('mobile: scrollToTop');
    await sleep(300);
    const gestureBefore = parseInt(String(await label.getText()).replace(/\D+/g, ''), 10) || 0;
    const location = await counter.getLocation();
    const size = await counter.getSize();
    const point = { x: location.x + size.width / 2, y: location.y + size.height / 2 };
    await driver.action('pointer', { parameters: { pointerType: 'touch' } })
      .move({ x: Math.round(point.x), y: Math.round(point.y), origin: 'viewport' })
      .down()
      .pause(80)
      .up()
      .perform();
    await sleep(400);
    const gestureAfter = parseInt(String(await label.getText()).replace(/\D+/g, ''), 10) || 0;
    check('W3C Actions 链式 tap 生效', gestureAfter === gestureBefore + 1, `${gestureBefore} → ${gestureAfter}`);

    // ---- mobile: 命令（executeScript 形状）----
    const strings = await driver.execute('mobile: getAppStrings', { language: 'zh-Hans' });
    check('mobile: getAppStrings', strings?.strings?.['demo.greeting'] === '你好，IUIAuto',
      strings?.language ?? '');

    const appearance = await driver.execute('mobile: setAppearance', { style: 'dark' });
    check('mobile: setAppearance', appearance?.style === 'dark', JSON.stringify(appearance));
    await driver.execute('mobile: setAppearance', { style: 'light' });

    const clip = 'wdio clipboard';
    await driver.execute('mobile: setClipboard', { content: clip });
    const clipBack = await driver.execute('mobile: getClipboard');
    check('mobile: set/getClipboard', clipBack === clip, `"${clipBack}"`);

    const compare = await driver.execute('mobile: compareImages', { firstImage: await driver.takeScreenshot() });
    check('mobile: compareImages', compare?.pass === true, `diff=${compare?.diffPercent}%`);

    const orientation = await driver.getOrientation();
    check('getOrientation', ['PORTRAIT', 'LANDSCAPE'].includes(orientation), orientation);

    const events = await driver.execute('mobile: source');  // 任意 mobile 命令形状冒烟
    check('executeScript 透传', typeof events === 'string' && events.includes('XCUIElementType'));
  } catch (error) {
    console.error('E2E 失败:', error.stack || error.message);
  } finally {
    try { if (driver) await driver.deleteSession(); } catch { /* ignore */ }
    if (!keep) {
      if (child.exitCode === null) {
        child.kill('SIGTERM');
        await Promise.race([new Promise((r) => child.once('exit', r)), sleep(3000)]);
      }
      if (child.exitCode === null) child.kill('SIGKILL');
    }
    const passed = checks.filter((c) => c.pass).length;
    const allPassed = checks.length > 0 && passed === checks.length;
    console.log(`\n结果: ${passed}/${checks.length} 通过 ${allPassed ? '✅ PASS' : '❌ FAIL'}`);
    if (!allPassed) {
      console.log('\n—— bridge 日志（末 40 行）——');
      console.log(childLog.split('\n').slice(-40).join('\n'));
    }
    process.exit(allPassed ? 0 : 1);
  }
}

main().catch((error) => {
  console.error('E2E 失败:', error.stack || error.message);
  process.exit(1);
});
