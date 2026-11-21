#!/usr/bin/env node
/**
 * IUIAuto Appium / WebDriver 桥
 *
 * 目标：让标准 Appium 客户端（WebdriverIO、Appium Python/Java client 等）可以直接
 * 驱动 IUIAuto —— HTTP 侧说 W3C WebDriver / Appium 协议，底层翻译为 IUIAuto 的
 * WebSocket JSON 指令。
 *
 * 独立运行（App 连接 ws://<host>:9800/ws）：
 *   node appium_bridge.js                 # HTTP :4723 + App WS :9800
 *   node appium_bridge.js --takeover      # 端口占用时自动接管本工具旧实例
 *   BRIDGE_PORT=4723 APP_PORT=9800 node appium_bridge.js
 *
 * 与 GUI 控制台共存：gui_server.js 会自动在 4723 启动本桥（共用同一 App 连接）。
 *
 * 支持的主要端点：
 *   GET  /status
 *   POST /session | DELETE /session/:id
 *   POST /session/:id/element(s)
 *   POST /session/:id/element/:eid/click|value|clear
 *   GET  /session/:id/element/:eid/{text,name,rect,displayed,enabled,selected,screenshot}
 *   GET  /session/:id/element/:eid/attribute/:name | property/:name
 *   GET  /session/:id/source | screenshot | window/rect | orientation | url | contexts
 *   POST /session/:id/actions（W3C 手势）
 *   POST /session/:id/timeouts[/implicit_wait]
 *   POST /session/:id/execute/sync（mobile: 命令）
 *   Appium 设备端点：shake / hide_keyboard / is_keyboard_shown / system_time /
 *     battery_info / clipboard / activate_app / terminate_app / background_app /
 *     query_app_state / app_installed / install_app / remove_app / push_file /
 *     pull_file / pull_folder / start-stop_recording_screen / alert / settings /
 *     performance_data
 *     （App 生命周期 / 安装 / 文件 / 录屏走宿主 xcrun simctl —— 仅模拟器，见 iua_simctl.js）
 */

import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { WebSocketServer } from 'ws';
import { ensurePortFree, handleListenError, tryWakeApp } from './iua_ports.js';
import { translateActions, textToKeyCommands, ELEMENT_KEY, extractElementId } from './iua_webdriver_actions.js';
import { createSimctl, looksLikeSimulatorModel } from './iua_simctl.js';

const DEFAULT_BRIDGE_PORT = +(process.env.BRIDGE_PORT || 4723);
const DEFAULT_APP_PORT = +(process.env.APP_PORT || 9800);
const DEFAULT_BRIDGE_HOST = process.env.BRIDGE_HOST || '127.0.0.1';
const AGENT_VERSION = '0.8.0';

const SUPPORTED_LOCATORS = new Set([
  'accessibility id', 'id', 'identifier', 'name', 'label', 'text',
  'class name', 'classname', 'class', 'type',
  'xpath', '-ios predicate string', 'predicate', 'predicate string',
  '-ios class chain', 'class chain', 'classchain',
  'tag name', 'link text', 'partial link text',
]);

const ELEMENT_STRATEGY_DOC = [
  'accessibility id', 'id', 'name', 'label', 'text', 'class name',
  'xpath', '-ios predicate string', '-ios class chain',
  'tag name', 'link text', 'partial link text',
];

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

function wdError(error, message, status = 500) {
  const err = new Error(message);
  err.webdriver = { error, message, status };
  return err;
}

function number(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function extractKeys(body) {
  if (!body || typeof body !== 'object') return '';
  if (typeof body.text === 'string') return body.text;
  if (Array.isArray(body.text)) return body.text.join('');
  if (typeof body.value === 'string') return body.value;
  if (Array.isArray(body.value)) return body.value.join('');
  return '';
}

function parseCapabilities(body) {
  if (!body || typeof body !== 'object') return {};
  const w3c = body.capabilities;
  if (w3c && typeof w3c === 'object') {
    const always = (w3c.alwaysMatch && typeof w3c.alwaysMatch === 'object') ? w3c.alwaysMatch : {};
    const first = Array.isArray(w3c.firstMatch) && w3c.firstMatch.length > 0 &&
      typeof w3c.firstMatch[0] === 'object' ? w3c.firstMatch[0] : {};
    const merged = { ...always, ...first };
    if (merged['appium:options'] && typeof merged['appium:options'] === 'object') {
      Object.assign(merged, merged['appium:options']);
    }
    return merged;
  }
  return (body.desiredCapabilities && typeof body.desiredCapabilities === 'object')
    ? body.desiredCapabilities : {};
}

function normalizeLocator(using, value) {
  const raw = String(using ?? '').trim();
  const key = raw.toLowerCase();
  const text = String(value ?? '');
  if (!SUPPORTED_LOCATORS.has(key)) {
    throw wdError('invalid selector', `不支持的定位策略: ${raw}（支持: ${ELEMENT_STRATEGY_DOC.join(' / ')}）`, 400);
  }
  if (key === 'tag name') return { using: 'class name', value: text };
  if (key === 'link text') return { using: 'label', value: text };
  if (key === 'partial link text') {
    const escaped = text.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    return { using: '-ios predicate string', value: `label CONTAINS "${escaped}"` };
  }
  return { using: raw, value: text };
}

function escapeXPathLiteral(value) {
  return String(value ?? '').replace(/\\/g, '\\\\').replace(/"/g, '\\"');
}

/// 把子元素查找转换为“父元素 XPath + 后代轴”的 XPath；无法转换时返回 null（调用方用矩形过滤降级）
function scopedChildXPath(parentPath, using, value) {
  if (!parentPath) return null;
  const key = String(using || '').trim().toLowerCase();
  const text = String(value ?? '');
  if (key === 'xpath') {
    if (text.startsWith('//')) return `${parentPath}${text}`;
    if (text.startsWith('/')) return `${parentPath}${text}`;
    if (text.startsWith('.//')) return `${parentPath}${text.slice(1)}`;
    if (text.startsWith('./')) return `${parentPath}${text.slice(1)}`;
    return `${parentPath}//${text}`;
  }
  const attrByStrategy = {
    'accessibility id': 'identifier',
    'id': 'identifier',
    'identifier': 'identifier',
    'name': 'name',
    'label': 'label',
    'text': 'text',
  };
  const attr = attrByStrategy[key];
  if (attr) {
    return `${parentPath}//*[@${attr}="${escapeXPathLiteral(text)}"]`;
  }
  if (key === 'class name' || key === 'class' || key === 'classname' || key === 'tag name') {
    return `${parentPath}//${text}`;
  }
  if (key === '-ios predicate string' || key === 'predicate' || key === 'predicate string') {
    return `${parentPath}//*[${text}]`;
  }
  return null;
}

function rectContains(container, child) {
  if (!container || !child) return true;
  const cx = Number(container.x) || 0;
  const cy = Number(container.y) || 0;
  const cw = Number(container.width) || 0;
  const ch = Number(container.height) || 0;
  const x = Number(child.x) || 0;
  const y = Number(child.y) || 0;
  const w = Number(child.width) || 0;
  const h = Number(child.height) || 0;
  return x + w >= cx && x <= cx + cw && y + h >= cy && y <= cy + ch;
}

function elementHandle(id) {
  return { [ELEMENT_KEY]: id, ELEMENT: id };
}

function attributeValue(value) {
  if (value === null || value === undefined) return null;
  if (typeof value === 'boolean') return value ? 'true' : 'false';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

function readJSON(req, limitBytes = 16 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limitBytes) {
        reject(wdError('invalid argument', `请求体超过 ${Math.round(limitBytes / 1024 / 1024)}MB`, 413));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (chunks.length === 0) return resolve({});
      try {
        const text = Buffer.concat(chunks).toString('utf8').trim();
        resolve(text.length === 0 ? {} : JSON.parse(text));
      } catch (error) {
        reject(wdError('invalid argument', `JSON 解析失败: ${error.message}`, 400));
      }
    });
    req.on('error', reject);
  });
}

function setCommonHeaders(res) {
  res.setHeader('access-control-allow-origin', '*');
  res.setHeader('access-control-allow-methods', 'GET,POST,DELETE,OPTIONS');
  res.setHeader('access-control-allow-headers', 'content-type');
  res.setHeader('cache-control', 'no-store');
}

function sendJSON(res, payload, status = 200) {
  if (res.headersSent) return;
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

function sendError(res, error) {
  const info = error?.webdriver || {
    error: 'unknown error',
    message: error?.message || String(error),
    status: 500,
  };
  sendJSON(res, {
    value: {
      error: info.error,
      message: info.message,
      stacktrace: '',
    },
  }, info.status || 500);
}

/**
 * 创建桥实例（不监听端口，调用方决定）。
 * @param {Object} options
 * @param {(action:string, params:Object, timeoutSec?:number)=>Promise<{ok:boolean,data?:any,error?:string}>} options.send
 * @param {()=>Object|null} [options.getHello] 当前 App hello（含 environment/actions）
 * @param {(msg:string)=>void} [options.log]
 * @param {number} [options.sessionWaitMs] 创建会话时等待 App 连接的最长时间
 * @param {Object} [options.capabilities] 额外能力（合并进 session capabilities）
 * @param {Object} [options.simctl] 宿主侧设备管理（iua_simctl.js；缺省用真实 simctl）
 */
export function createAppiumBridge(options = {}) {
  const {
    send,
    getHello = () => null,
    log = (...args) => console.log('[appium-bridge]', ...args),
    sessionWaitMs = 15000,
    capabilities: extraCapabilities = {},
    simctl: simctlOption = null,
  } = options;

  if (typeof send !== 'function') {
    throw new Error('createAppiumBridge 需要 options.send(action, params, timeoutSec) 函数');
  }

  let session = null;
  let creatingSession = false;
  let lastCommandAt = Date.now();

  // ---- Appium Events API（GET/POST /session/:id/appium/events）----
  const eventLog = new Map(); // 事件名 -> 时间戳数组（Appium 格式）

  function recordEvent(name) {
    const list = eventLog.get(name) || [];
    list.push(Date.now());
    eventLog.set(name, list);
    return list.length;
  }

  function eventsSnapshot(filter) {
    const names = Array.isArray(filter) && filter.length > 0
      ? filter.map(String) : [...eventLog.keys()];
    const result = {};
    for (const name of names) {
      if (eventLog.has(name)) result[name] = eventLog.get(name);
    }
    return result;
  }

  recordEvent('serverStarted');

  // ---- appium:newCommandTimeout：空闲会话自动结束（0 = 禁用）----
  const idleTimer = setInterval(() => {
    const timeoutSec = number(session?.capabilities?.['appium:newCommandTimeout'], 0);
    if (!session || !(timeoutSec > 0)) return;
    if (Date.now() - lastCommandAt <= timeoutSec * 1000) return;
    const ended = session.id;
    session = null;
    recordEvent('unexpectedShutdown');
    cleanupRecording().finally(() => {
      log(`session ${ended} 空闲 ${timeoutSec}s（newCommandTimeout）自动结束`);
    });
  }, 1000);
  idleTimer.unref?.();

  async function appSend(action, params = {}, timeoutSec = 20) {
    const result = await send(action, params, timeoutSec);
    if (!result || result.ok !== true) {
      const message = result?.error || `App 指令失败: ${action}`;
      if (/no such alert/i.test(message)) throw wdError('no such alert', message, 404);
      if (/no such element|找不到/i.test(message)) throw wdError('no such element', message, 404);
      if (/unsupported|不支持/i.test(message)) throw wdError('unsupported operation', message, 500);
      throw wdError('unknown error', message);
    }
    return result.data;
  }

  async function waitForApp(timeoutMs) {
    const start = Date.now();
    while (Date.now() - start <= timeoutMs) {
      const hello = getHello();
      if (hello && (hello.type === 'hello' || hello.agent)) return hello;
      await sleep(100);
    }
    return null;
  }

  /** 等 App 连接断开（hello 变空）。恒定在线的假 hello 超时后返回 false，调用方继续。 */
  async function waitForAppDrop(timeoutMs) {
    const start = Date.now();
    while (Date.now() - start <= timeoutMs) {
      if (!getHello()) return true;
      await sleep(100);
    }
    return false;
  }

  function requireSession(sessionId) {
    if (!session || session.id !== sessionId) {
      throw wdError('invalid session id', `会话不存在或已结束: ${sessionId}`, 404);
    }
    return session;
  }

  function requireElement(currentSession, elementId) {
    const record = currentSession.elements.get(elementId);
    if (!record) {
      throw wdError('stale element reference', '元素句柄已失效（页面可能已变化）', 404);
    }
    return record;
  }

  // ---- 宿主侧设备管理（simctl，仅模拟器）----

  const simctlModule = simctlOption || createSimctl({
    log: (...args) => log('[simctl]', ...args),
  });

  function deviceModelOf(currentSession) {
    return currentSession.deviceInfo?.deviceModel ||
      currentSession.hello?.environment?.deviceModel || '';
  }

  function isSimulatorSession(currentSession) {
    const udid = String(currentSession.capabilities['appium:udid'] || '').trim();
    // 显式给了 udid 视为用户确认走模拟器路径；否则按 App 上报的 machine 架构判定
    return !!udid || looksLikeSimulatorModel(deviceModelOf(currentSession));
  }

  async function requireSimulatorUdid(currentSession) {
    if (!isSimulatorSession(currentSession)) {
      throw wdError('unsupported operation',
        'App 运行在真机上：App 生命周期/安装/文件传输/录屏等宿主侧能力仅支持模拟器（可用 appium:udid 显式指定）', 500);
    }
    if (!currentSession.resolvedUdid) {
      const hint = String(currentSession.capabilities['appium:udid'] || '').trim() || null;
      currentSession.resolvedUdid = await simctlModule.resolveUdid(hint);
    }
    return currentSession.resolvedUdid;
  }

  /** iua_simctl 的 kind 错误 → WebDriver 错误 */
  function simctlFailure(error) {
    if (error?.webdriver) return error;
    const message = error?.message || String(error);
    switch (error?.kind) {
      case 'not-found': return wdError('no such file', message, 404);
      case 'invalid': return wdError('invalid argument', message, 400);
      case 'no-recording': return wdError('unknown error', message, 404);
      case 'busy': return wdError('unknown error', message, 500);
      default: return wdError('unknown error', message, 500);
    }
  }

  /** 会话/桥收尾：停掉还在跑的录屏（丢弃产物） */
  async function cleanupRecording() {
    try {
      await simctlModule.stopRecording({ discard: true });
    } catch { /* 没有进行中的录屏 */ }
  }

  const simctlCall = (promise) => promise.catch((error) => { throw simctlFailure(error); });

  /** privacy 变更可能杀掉运行中的 App（simctl 不会自动拉起）：断开则主动重启并等重连 */
  async function ensureAppAliveAfterPrivacyChange(currentSession, bundleId, udid) {
    if (bundleId !== String(currentSession.capabilities['appium:bundleId'] ||
        currentSession.hello?.environment?.bundleId || '')) {
      return;
    }
    const dropped = await waitForAppDrop(2500);
    if (!dropped) return; // App 未被杀（如 reset 且未运行变更），无需处理
    await simctlCall(simctlModule.launchApp(udid, bundleId));
    await waitForApp(15000);
  }

  /**
   * App 管理 / 文件传输 / 录屏的共用实现。
   * mobile: 命令与 Appium 设备端点共用；模拟器走宿主 simctl，真机按语义降级或报不支持。
   */
  async function appManagement(currentSession, op, options = {}) {
    // capabilities 里的 bundleId 可能为空（旧版 App 无法上报 device_info）：hello 环境兜底
    const currentBundleId = String(currentSession.capabilities['appium:bundleId'] ||
      currentSession.hello?.environment?.bundleId || '');

    switch (op) {
      case 'terminate': {
        const bundleId = String(options.bundleId || options.appId || currentBundleId);
        if (!bundleId) throw wdError('invalid argument', '缺少 bundleId/appId', 400);
        const udid = await requireSimulatorUdid(currentSession);
        const result = await simctlCall(simctlModule.terminateApp(udid, bundleId));
        log(`terminateApp ${bundleId}: ${JSON.stringify(result)}`);
        return true;
      }
      case 'activate': {
        const bundleId = String(options.bundleId || options.appId || currentBundleId);
        if (!bundleId) throw wdError('invalid argument', '缺少 bundleId/appId', 400);
        // 真机上激活"当前 App"：App 本就在前台运行，视为成功
        if (!isSimulatorSession(currentSession) && bundleId === currentBundleId) return true;
        const udid = await requireSimulatorUdid(currentSession);
        const { pid } = await simctlCall(simctlModule.launchApp(udid, bundleId));
        log(`activateApp ${bundleId}: pid=${pid ?? '?'}`);
        return true;
      }
      case 'background': {
        const bundleId = String(options.bundleId || options.appId || currentBundleId);
        if (!bundleId) throw wdError('invalid argument', '缺少 bundleId/appId', 400);
        const seconds = Math.max(0, number(options.seconds ?? options.duration, 3));
        const udid = await requireSimulatorUdid(currentSession);
        await simctlCall(simctlModule.terminateApp(udid, bundleId));
        if (seconds > 0) await sleep(Math.min(seconds, 300) * 1000);
        await simctlCall(simctlModule.launchApp(udid, bundleId));
        // 宿主 App 被切后台会断开 WS：先等断开事件把 hello 清掉，再等重连（不把等待变成失败）
        if (bundleId === currentBundleId) {
          await waitForAppDrop(2000);
          await waitForApp(15000);
        }
        return null;
      }
      case 'state': {
        const bundleId = String(options.bundleId || options.appId || '');
        if (!bundleId || bundleId === currentBundleId) {
          const data = await appSend('app_state');
          return data?.state ?? 4;
        }
        if (!isSimulatorSession(currentSession)) return 0;
        const udid = await requireSimulatorUdid(currentSession);
        return simctlCall(simctlModule.appState(udid, bundleId));
      }
      case 'installed': {
        const bundleId = String(options.bundleId || options.appId || '');
        if (!bundleId || bundleId === currentBundleId) return true;
        if (!isSimulatorSession(currentSession)) return false;
        const udid = await requireSimulatorUdid(currentSession);
        return simctlCall(simctlModule.isAppInstalled(udid, bundleId));
      }
      case 'install': {
        const appPath = String(options.appPath || options.app || '');
        if (!appPath) throw wdError('invalid argument', '缺少 appPath（宿主 .app 路径）', 400);
        const udid = await requireSimulatorUdid(currentSession);
        await simctlCall(simctlModule.installApp(udid, appPath));
        return true;
      }
      case 'remove': {
        const bundleId = String(options.appId || options.bundleId || '');
        if (!bundleId) throw wdError('invalid argument', '缺少 appId/bundleId', 400);
        const udid = await requireSimulatorUdid(currentSession);
        return simctlCall(simctlModule.removeApp(udid, bundleId));
      }
      case 'push': {
        const path = String(options.path || '');
        const payload = options.payload ?? options.data ?? options.content;
        if (!path || typeof payload !== 'string') {
          throw wdError('invalid argument', '缺少 path 或 payload（base64 文本）', 400);
        }
        const udid = await requireSimulatorUdid(currentSession);
        await simctlCall(simctlModule.pushFile(udid, path, payload));
        return null;
      }
      case 'pull': {
        const path = String(options.path || '');
        if (!path) throw wdError('invalid argument', '缺少 path', 400);
        const udid = await requireSimulatorUdid(currentSession);
        return simctlCall(simctlModule.pullFile(udid, path));
      }
      case 'pullFolder': {
        const path = String(options.folderPath || options.path || '');
        if (!path) throw wdError('invalid argument', '缺少 folderPath', 400);
        const udid = await requireSimulatorUdid(currentSession);
        return simctlCall(simctlModule.pullFolder(udid, path));
      }
      case 'startRecording': {
        const udid = await requireSimulatorUdid(currentSession);
        await simctlCall(simctlModule.startRecording(udid));
        return null;
      }
      case 'stopRecording': {
        return simctlCall(simctlModule.stopRecording());
      }
      case 'setAppearance': {
        const style = options.style ?? options.appearance;
        const udid = await requireSimulatorUdid(currentSession);
        const value = await simctlCall(simctlModule.setAppearance(udid, style));
        return { style: value };
      }
      case 'getAppearance': {
        const udid = await requireSimulatorUdid(currentSession);
        const value = await simctlCall(simctlModule.getAppearance(udid));
        return { style: value };
      }
      case 'setReduceTransparency': {
        const udid = await requireSimulatorUdid(currentSession);
        const value = await simctlCall(simctlModule.setReduceTransparency(udid, options.enabled !== false));
        return value;
      }
      case 'getReduceTransparency': {
        const udid = await requireSimulatorUdid(currentSession);
        return simctlCall(simctlModule.getReduceTransparency(udid));
      }
      case 'setPermission': {
        // Appium 语义：state = granted/allow | denied/deny | reset/unset
        const bundleId = String(options.bundleId || currentBundleId);
        if (!bundleId) throw wdError('invalid argument', '缺少 bundleId', 400);
        const state = String(options.state ?? '').toLowerCase();
        const udid = await requireSimulatorUdid(currentSession);
        if (['granted', 'allow', 'yes'].includes(state)) {
          await simctlCall(simctlModule.grantService(udid, bundleId, options.service));
        } else if (['denied', 'deny', 'no'].includes(state)) {
          await simctlCall(simctlModule.revokeService(udid, bundleId, options.service));
        } else if (['reset', 'unset', 'natural', 'prompt'].includes(state)) {
          await simctlCall(simctlModule.resetService(udid, options.service, bundleId));
        } else {
          throw wdError('invalid argument', "state 必须为 granted/allow、denied/deny 或 reset/unset", 400);
        }
        // 权限变更可能杀掉运行中的 App（simctl 不会自动拉起）：断开则主动重启并等重连
        await ensureAppAliveAfterPrivacyChange(currentSession, bundleId, udid);
        return null;
      }
      case 'resetPermission': {
        const bundleId = String(options.bundleId || '') || null;
        const udid = await requireSimulatorUdid(currentSession);
        await simctlCall(simctlModule.resetService(udid, options.service, bundleId));
        if (bundleId) {
          await ensureAppAliveAfterPrivacyChange(currentSession, bundleId, udid);
        }
        return null;
      }
      case 'appStrings': {
        const bundleId = String(options.bundleId || currentBundleId);
        if (!bundleId) throw wdError('invalid argument', '缺少 bundleId', 400);
        const udid = await requireSimulatorUdid(currentSession);
        return simctlCall(simctlModule.appStrings(udid, bundleId, options.language ?? null));
      }
      default:
        throw wdError('unknown command', `未实现的设备管理操作: ${op}`, 404);
    }
  }

  async function findElements(currentSession, using, value) {
    const locator = normalizeLocator(using, value);
    const deadline = Date.now() + currentSession.implicitWait;
    let elements = [];
    do {
      const result = await send('find_elements', {
        using: locator.using,
        value: locator.value,
        limit: 1000,
      }, 25);
      if (!result || result.ok !== true) {
        throw wdError('invalid selector', result?.error || '元素查询失败', 400);
      }
      elements = Array.isArray(result.data?.elements) ? result.data.elements : [];
      if (elements.length > 0) break;
      if (currentSession.implicitWait <= 0) break;
      await sleep(Math.min(250, Math.max(50, currentSession.implicitWait)));
    } while (Date.now() < deadline);
    return { locator, elements };
  }

  function registerElements(currentSession, locator, elements) {
    return elements.map((element, index) => {
      const id = randomUUID();
      const absoluteIndex = Number.isFinite(Number(element.elementIndex))
        ? Number(element.elementIndex) : index;
      currentSession.elements.set(id, {
        id,
        using: locator.using,
        value: locator.value,
        index: absoluteIndex,
        snapshot: element,
        createdAt: Date.now(),
      });
      return id;
    });
  }

  async function findChildElements(currentSession, parentRecord, using, value) {
    const parentSnapshot = parentRecord.snapshot || {};
    let parentXPath = parentSnapshot.xpath;
    if (!parentXPath) {
      const attr = await elementOp(parentRecord, 'get_attribute', { attribute: 'xpath' });
      parentXPath = attr?.value;
    }
    const locator = normalizeLocator(using, value);
    const scoped = scopedChildXPath(parentXPath, locator.using, locator.value);
    if (scoped) {
      const result = await findElements(currentSession, 'xpath', scoped);
      if (result.elements.length > 0) {
        return { ...result, locator: { using: 'xpath', value: scoped } };
      }
    }
    // 降级：全局查找后按父元素矩形过滤（能覆盖 accessibility id/class 等常见场景）
    const global = await findElements(currentSession, locator.using, locator.value);
    if (!global.elements.length) return global;
    const parentRect = parentSnapshot.rect ||
      (await elementOp(parentRecord, 'get_rect'));
    const filtered = global.elements.filter((element) => rectContains(parentRect, element.rect));
    // 不做“过滤为空就回退全局”的降级，避免把父元素之外的元素当作子元素返回
    return { ...global, elements: filtered };
  }

  function sameElementSnapshot(expected, actual) {
    if (!expected || !actual) return true;
    const expectedXPath = expected.xpath ? String(expected.xpath) : '';
    const actualXPath = actual.xpath ? String(actual.xpath) : '';
    if (expectedXPath && actualXPath && expectedXPath === actualXPath) return true;
    const expectedIdentifier = String(expected.identifier || '');
    const actualIdentifier = String(actual.identifier || '');
    if (expectedIdentifier && actualIdentifier && expectedIdentifier === actualIdentifier) return true;
    // 没有 identifier/xpath 时退化为类型 + 矩形 + name/label 指纹
    if (String(expected.type || '') !== String(actual.type || '')) return false;
    if (String(expected.name || '') !== String(actual.name || '')) return false;
    if (String(expected.label || '') !== String(actual.label || '')) return false;
    const ex = expected.rect || {};
    const ax = actual.rect || {};
    return number(ex.x) === number(ax.x) &&
      number(ex.y) === number(ax.y) &&
      number(ex.width) === number(ax.width) &&
      number(ex.height) === number(ax.height);
  }

  async function rawElementOp(record, action, params = {}, timeoutSec = 25) {
    const result = await send('element_action', {
      using: record.using,
      value: record.value,
      index: record.index,
      action,
      ...params,
    }, timeoutSec);
    if (!result || result.ok !== true) {
      const message = result?.error || `元素操作失败: ${action}`;
      if (/no such element|not found|找不到/i.test(message)) {
        throw wdError('stale element reference', message, 404);
      }
      if (/unknown element action|不支持|unknown action/i.test(message)) {
        throw wdError('unsupported operation', message, 500);
      }
      throw wdError('element not interactable', message, 400);
    }
    return result.data;
  }

  async function elementOp(record, action, params = {}, timeoutSec = 25) {
    // 句柄只保存 locator+index；执行动作前先无副作用地取一次当前属性，确认
    // 该 index 仍指向同一元素，避免页面变化后静默操作到别的元素。
    if (record.snapshot && action !== 'get_attributes') {
      const current = await rawElementOp(record, 'get_attributes', {}, timeoutSec);
      if (!sameElementSnapshot(record.snapshot, current)) {
        throw wdError('stale element reference', '元素已重新创建或位置发生变化，请重新查找', 404);
      }
    }
    return rawElementOp(record, action, params, timeoutSec);
  }

  async function resolveElementRect(elementId) {
    const currentSession = session;
    if (!currentSession) throw wdError('invalid session id', '会话不存在', 404);
    const record = requireElement(currentSession, elementId);
    const rect = await elementOp(record, 'get_rect');
    return {
      x: number(rect?.x),
      y: number(rect?.y),
      width: number(rect?.width),
      height: number(rect?.height),
    };
  }

  /** Appium settings → 截图质量（screenshotQuality: 0/1/2，默认 2） */
  function screenshotQuality(currentSession) {
    const value = number(currentSession?.settings?.screenshotQuality, NaN);
    return Number.isFinite(value) ? Math.min(Math.max(Math.round(value), 0), 2) : 2;
  }

  /**
   * JSON Wire touch 链（Appium TouchAction）→ W3C actions 指针源。
   * 坐标语义：无 element 为绝对坐标；带 element 时 x/y 相对元素左上角（缺省取元素中心）。
   */
  async function touchChainToW3C(actions, label) {
    const pointer = { type: 'pointer', id: label, parameters: { pointerType: 'touch' }, actions: [] };
    let current = null;
    let down = false;
    for (const step of Array.isArray(actions) ? actions : []) {
      if (!step || typeof step !== 'object') continue;
      const opts = step.options || {};
      let x = opts.x === undefined ? null : number(opts.x, null);
      let y = opts.y === undefined ? null : number(opts.y, null);
      const elementId = extractElementId(opts.element) ||
        (typeof opts.element === 'string' ? opts.element : null);
      if (elementId) {
        const rect = await resolveElementRect(elementId);
        if (x !== null) {
          x = rect.x + x;
          y = rect.y + (y ?? 0);
        } else {
          x = rect.x + rect.width / 2;
          y = rect.y + rect.height / 2;
        }
      }
      const name = String(step.action || '').toLowerCase();
      const at = (px, py) => ({
        type: 'pointerMove', duration: 0,
        x: px ?? current?.x ?? 0, y: py ?? current?.y ?? 0, origin: 'viewport',
      });
      switch (name) {
        case 'tap':
          pointer.actions.push(at(x, y));
          pointer.actions.push({ type: 'pointerDown', button: 0 });
          pointer.actions.push({ type: 'pointerUp', button: 0 });
          down = false;
          current = { x: x ?? current?.x, y: y ?? current?.y };
          break;
        case 'press':
        case 'longpress':
          pointer.actions.push(at(x, y));
          pointer.actions.push({ type: 'pointerDown', button: 0 });
          down = true;
          if (name === 'longpress') {
            const ms = opts.duration !== undefined ? number(opts.duration, 800) : 800;
            pointer.actions.push({ type: 'pause', duration: ms });
          }
          current = { x: x ?? current?.x, y: y ?? current?.y };
          break;
        case 'moveto':
          pointer.actions.push({
            type: 'pointerMove', duration: 300,
            x: x ?? current?.x ?? 0, y: y ?? current?.y ?? 0, origin: 'viewport',
          });
          current = { x: x ?? current?.x, y: y ?? current?.y };
          break;
        case 'wait': {
          const ms = number(opts.ms, 0);
          if (ms > 0) pointer.actions.push({ type: 'pause', duration: ms });
          break;
        }
        case 'release':
          if (down) pointer.actions.push({ type: 'pointerUp', button: 0 });
          down = false;
          break;
        default:
          throw wdError('unknown command', `不支持的 touch 动作: ${step.action}`, 400);
      }
    }
    // press 后未显式 release：补上，保证手势闭合
    if (down) pointer.actions.push({ type: 'pointerUp', button: 0 });
    return pointer;
  }

  /** 执行 Appium JSON Wire touch 链（单指或多指：多链自动合成 pinch/双指滑动） */
  async function performTouchChains(chains) {
    const sources = [];
    for (let i = 0; i < chains.length; i++) {
      sources.push(await touchChainToW3C(chains[i], `finger${i + 1}`));
    }
    const commands = await translateActions(sources, resolveElementRect);
    for (const command of commands) {
      await appSend(command.action, command.params, 30);
    }
    return commands;
  }

  function sessionCapabilities(clientCaps, hello, deviceInfo) {
    const env = hello?.environment || {};
    const device = deviceInfo || {};
    const bundleId = device.bundleId || env.bundleId || clientCaps['appium:bundleId'] || '';
    return {
      platformName: 'iOS',
      'appium:automationName': 'IUIAuto',
      'appium:deviceName': device.name || env.deviceModel || 'iOS Device',
      'appium:platformVersion': device.systemVersion || env.systemVersion || '',
      'appium:udid': clientCaps['appium:udid'] || process.env.IUA_UDID || '',
      'appium:bundleId': bundleId,
      'appium:app': bundleId,
      'appium:appVersion': device.appVersion || env.appVersion || '',
      'appium:deviceModel': device.deviceModel || env.deviceModel || '',
      'appium:locale': device.locale || '',
      'appium:language': device.language || '',
      'appium:noReset': true,
      'appium:fullReset': false,
      'appium:newCommandTimeout': 300,
      'appium:shouldWaitForQuiescence': false,
      'appium:waitForQuiescence': false,
      'appium:useNewWDA': false,
      'appium:usePrebuiltWDA': false,
      'appium:showXcodeLog': false,
      'appium:autoGrantPermissions': false,
      'appium:supportsAppiumActions': true,
      'appium:elementStrategies': ELEMENT_STRATEGY_DOC,
      ...extraCapabilities,
      ...clientCaps,
      platformName: 'iOS',
      'appium:automationName': 'IUIAuto',
    };
  }

  async function createSession(req, res) {
    if (session) {
      throw wdError('session not created',
        `已有活动会话 ${session.id}；请先 DELETE /session/${session.id} 或重启桥`, 500);
    }
    if (creatingSession) {
      throw wdError('session not created', '另一个会话正在创建中，请稍后重试', 500);
    }
    creatingSession = true;
    recordEvent('sessionRequested');
    try {
      const body = await readJSON(req);
      const clientCaps = parseCapabilities(body);
      const hello = await waitForApp(sessionWaitMs);
      if (!hello) {
        throw wdError('session not created',
          'IUIAuto App 未连接：请确认 App 已安装/启动，且正连接对应 WebSocket 端口', 500);
      }
      let deviceInfo = null;
      try {
        deviceInfo = await appSend('device_info', {}, 10);
      } catch {
        deviceInfo = null;
      }
      const id = randomUUID();
      session = {
        id,
        createdAt: Date.now(),
        capabilities: sessionCapabilities(clientCaps, hello, deviceInfo),
        implicitWait: 0,
        pageLoadTimeout: 300000,
        scriptTimeout: 30000,
        settings: { screenshotQuality: 2 },
        elements: new Map(),
        deviceInfo,
        hello,
      };
      // appium:orientation capability：建会话时尽力设置方向（失败不阻塞建会话）
      const requestedOrientation = String(
        clientCaps['appium:orientation'] || clientCaps.orientation || '').toUpperCase();
      if (requestedOrientation) {
        try {
          const data = await appSend('orientation', { orientation: requestedOrientation }, 15);
          log(`appium:orientation=${requestedOrientation} → ${data?.orientation ?? '?'}`);
        } catch (error) {
          log(`appium:orientation=${requestedOrientation} 设置失败（忽略）: ${error.message}`);
        }
      }
      lastCommandAt = Date.now();
      recordEvent('sessionStarted');
      log(`session ${id} created (app=${hello.agent} v${hello.version}, actions=${hello.actions?.length ?? '?'})`);
      // appium:forceAppLaunch capability：回复前重启宿主 App（尽力而为，失败不阻塞建会话）
      if (clientCaps['appium:forceAppLaunch'] === true) {
        const bundleId = String(session.capabilities['appium:bundleId'] || '');
        if (bundleId) {
          try {
            await appManagement(session, 'background', { bundleId, seconds: 0 });
            log(`appium:forceAppLaunch 已重启 ${bundleId}`);
          } catch (error) {
            log(`appium:forceAppLaunch 失败（忽略）: ${error.message}`);
          }
        }
      }
      sendJSON(res, { value: { sessionId: id, capabilities: session.capabilities } });
    } finally {
      creatingSession = false;
    }
  }

  async function handleElement(req, res, currentSession, elementId, op) {
    const record = requireElement(currentSession, elementId);
    const method = req.method;
    const key = op[0] || '';

    if (method === 'POST' && key === 'click') {
      await elementOp(record, 'click');
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'value') {
      const body = await readJSON(req);
      const text = extractKeys(body);
      if (text.length === 0) return sendJSON(res, { value: null });
      await elementOp(record, 'send_keys', { text });
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'clear') {
      await elementOp(record, 'clear');
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && key === 'text') {
      const data = await elementOp(record, 'get_text');
      return sendJSON(res, { value: data?.text ?? '' });
    }
    if (method === 'GET' && key === 'name') {
      const data = await elementOp(record, 'get_attribute', { attribute: 'name' });
      return sendJSON(res, { value: attributeValue(data?.value) });
    }
    if (method === 'GET' && key === 'rect') {
      const data = await elementOp(record, 'get_rect');
      return sendJSON(res, {
        value: {
          x: number(data?.x),
          y: number(data?.y),
          width: number(data?.width),
          height: number(data?.height),
        },
      });
    }
    if (method === 'GET' && key === 'displayed') {
      const data = await elementOp(record, 'is_displayed');
      return sendJSON(res, { value: !!data?.displayed });
    }
    if (method === 'GET' && key === 'enabled') {
      const data = await elementOp(record, 'is_enabled');
      return sendJSON(res, { value: !!data?.enabled });
    }
    if (method === 'GET' && key === 'selected') {
      const data = await elementOp(record, 'is_selected');
      return sendJSON(res, { value: !!data?.selected });
    }
    if (method === 'GET' && key === 'screenshot') {
      const data = await elementOp(record, 'screenshot', { quality: screenshotQuality(currentSession) }, 30);
      return sendJSON(res, { value: data?.image || '' });
    }
    // JSON Wire 兼容：location / location_in_view / size
    if (method === 'GET' && (key === 'location' || key === 'location_in_view')) {
      const data = await elementOp(record, 'get_rect');
      return sendJSON(res, { value: { x: number(data?.x), y: number(data?.y) } });
    }
    if (method === 'GET' && key === 'size') {
      const data = await elementOp(record, 'get_rect');
      return sendJSON(res, { value: { width: number(data?.width), height: number(data?.height) } });
    }
    if (method === 'GET' && (key === 'computedlabel' || key === 'computedrole')) {
      // W3C ARIA 兼容：computedlabel → 可访问标签；computedrole → 元素类型
      const attribute = key === 'computedlabel' ? 'label' : 'type';
      const data = await elementOp(record, 'get_attribute', { attribute });
      return sendJSON(res, { value: attributeValue(data?.value) });
    }
    if (method === 'GET' && (key === 'attribute' || key === 'property')) {
      const name = op.slice(1).join('/');
      if (!name) throw wdError('invalid argument', '缺少属性名', 400);
      try {
        const data = await elementOp(record, 'get_attribute', { attribute: name });
        return sendJSON(res, { value: attributeValue(data?.value) });
      } catch (error) {
        if (/unknown attribute/i.test(error.message || '')) return sendJSON(res, { value: null });
        throw error;
      }
    }
    if (method === 'POST' && (key === 'element' || key === 'elements')) {
      const body = await readJSON(req);
      const { locator, elements } = await findChildElements(currentSession, record, body.using ?? body.using_, body.value);
      if (key === 'element') {
        if (elements.length === 0) {
          throw wdError('no such element', `父元素下找不到子元素: ${body.using}=${body.value}`, 404);
        }
        const [id] = registerElements(currentSession, locator, [elements[0]]);
        return sendJSON(res, { value: elementHandle(id) });
      }
      const ids = registerElements(currentSession, locator, elements);
      return sendJSON(res, { value: ids.map(elementHandle) });
    }
    if (method === 'POST' && key === 'scroll') {
      await elementOp(record, 'scroll_to');
      return sendJSON(res, { value: null });
    }

    throw wdError('unknown command', `不支持的元素端点: ${method} ${op.join('/')}`, 404);
  }

  async function handleMobileCommand(currentSession, script, args) {
    const raw = String(script || '').trim();
    const name = raw.toLowerCase().replace(/^mobile:\s*/, '').replace(/\s+/g, '');
    const options = (args && typeof args[0] === 'object' && args[0] !== null) ? args[0] : {};

    const elementRecord = () => {
      const id = extractElementId(options.element) || extractElementId(options) ||
        (typeof options.element === 'string' ? options.element : null);
      return id ? requireElement(currentSession, id) : null;
    };

    const elementRect = async (record) => {
      const rect = await elementOp(record, 'get_rect');
      return {
        x: number(rect?.x), y: number(rect?.y),
        width: number(rect?.width), height: number(rect?.height),
      };
    };

    const centerFor = async (record) => {
      if (record) {
        const rect = await elementRect(record);
        return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2, rect };
      }
      const info = await appSend('device_info', {}, 10);
      const size = info?.windowSize || info?.screen || { width: 375, height: 812 };
      return { x: number(size.width) / 2, y: number(size.height) / 2, rect: null };
    };

    // 元素内坐标：Appium 语义为相对元素左上角；未提供 x/y 时取元素中心
    const pointInElement = async (record, opts) => {
      const rect = await elementRect(record);
      const hasOffset = opts.x !== undefined || opts.y !== undefined;
      if (!hasOffset) {
        return { x: rect.x + rect.width / 2, y: rect.y + rect.height / 2 };
      }
      return { x: rect.x + number(opts.x), y: rect.y + number(opts.y) };
    };

    // XCUITest mobile: scroll 语义：name/predicateString/toVisible → 循环滚动直到目标可见
    const scrollUntilVisible = async (opts) => {
      const direction = String(opts.direction || 'down').toLowerCase();
      if (!['up', 'down', 'left', 'right'].includes(direction)) {
        throw wdError('invalid argument', `不支持的滚动方向: ${direction}`, 400);
      }
      const toVisibleId = extractElementId(opts.element) ||
        (typeof opts.element === 'string' ? opts.element : null);
      let locator = null;
      if (opts.name !== undefined) locator = normalizeLocator('name', opts.name);
      else if (opts.predicateString !== undefined) {
        locator = normalizeLocator('-ios predicate string', opts.predicateString);
      } else if (!toVisibleId) {
        throw wdError('invalid argument', 'scroll 需要 name / predicateString / toVisible(element) 之一', 400);
      }

      // toVisible 时 element 是目标本身；否则 element（可选）是滚动容器
      const containerRecord = toVisibleId ? null : elementRecord();
      let containerInfo = null;
      const scrollOnce = async () => {
        if (!containerInfo) {
          const center = await centerFor(containerRecord);
          let span = 500;
          if (containerRecord) {
            const rect = await elementRect(containerRecord);
            span = Math.max(Math.min(rect.width, rect.height) * 0.8, 120);
          }
          containerInfo = { center, span };
        }
        const { center, span } = containerInfo;
        // XCUITest scroll 语义：direction 是“滚动到哪个方向”（up = 回看顶部内容），
        // 与 mobile: swipe 的手指方向相反 → 手势反向
        const to = { x: center.x, y: center.y };
        if (direction === 'up') to.y += span;
        else if (direction === 'down') to.y -= span;
        else if (direction === 'left') to.x += span;
        else to.x -= span;
        await appSend('swipe', {
          fromX: center.x, fromY: center.y, toX: to.x, toY: to.y, duration: 0.35,
        }, 20);
      };

      // 上限 25s：在常见客户端 30s 中止之前返回干净的 no such element
      const deadline = Date.now() + Math.min(Math.max(currentSession.scriptTimeout, 3000), 25000);
      while (Date.now() < deadline) {
        if (toVisibleId) {
          try {
            await elementOp(requireElement(currentSession, toVisibleId), 'scroll_to');
            return null;
          } catch (error) {
            if (/stale element/i.test(error.message || '')) throw error;
            // scroll_to 失败（目标不在可滚动容器内等）→ 继续按方向滚动重试
          }
        } else {
          const result = await send('find_elements', {
            using: locator.using, value: locator.value, limit: 1,
          }, 25);
          if (result?.ok && (result.data?.elements || []).length > 0) {
            const elements = result.data.elements.slice(0, 1);
            const [id] = registerElements(currentSession, locator, elements);
            await elementOp(currentSession.elements.get(id), 'scroll_to').catch(() => {});
            return elementHandle(id);
          }
        }
        await scrollOnce();
        await sleep(150);
      }
      throw wdError('no such element',
        `滚动后仍未找到目标: ${opts.name ?? opts.predicateString ?? 'toVisible'}`, 404);
    };

    switch (name) {
      case 'tap':
      case 'tapwithnumberoftaps': {
        const record = elementRecord();
        if (record) {
          const taps = number(options.numberOfTaps, 1);
          if (options.x !== undefined || options.y !== undefined) {
            const point = await pointInElement(record, options);
            await appSend(taps >= 2 ? 'double_tap' : 'tap', { x: point.x, y: point.y }, 15);
          } else {
            await elementOp(record, taps >= 2 ? 'double_click' : 'click');
          }
        } else {
          const taps = number(options.numberOfTaps, 1);
          if (taps >= 2) {
            await appSend('double_tap', { x: number(options.x), y: number(options.y) }, 15);
          } else {
            await appSend('tap', { x: number(options.x), y: number(options.y) }, 15);
          }
        }
        return null;
      }
      case 'doubletap': {
        const record = elementRecord();
        if (record) {
          if (options.x !== undefined || options.y !== undefined) {
            const point = await pointInElement(record, options);
            await appSend('double_tap', { x: point.x, y: point.y }, 15);
          } else {
            await elementOp(record, 'double_click');
          }
        } else {
          await appSend('double_tap', { x: number(options.x), y: number(options.y) }, 15);
        }
        return null;
      }
      case 'touchandhold': {
        const duration = Math.max(number(options.duration, 1), 0.1);
        const record = elementRecord();
        if (record) {
          if (options.x !== undefined || options.y !== undefined) {
            const point = await pointInElement(record, options);
            await appSend('long_press', { x: point.x, y: point.y, duration }, 20);
          } else {
            await elementOp(record, 'long_click', { duration });
          }
        } else {
          await appSend('long_press', { x: number(options.x), y: number(options.y), duration }, 20);
        }
        return null;
      }
      case 'swipe':
      case 'scroll': {
        // XCUITest 语义：name/predicateString/toVisible → 循环滚动直到目标可见
        if (options.name !== undefined || options.predicateString !== undefined ||
            options.toVisible === true) {
          return scrollUntilVisible(options);
        }
        const direction = String(options.direction || 'up').toLowerCase();
        const distance = number(options.distance, 300);
        const center = await centerFor(elementRecord());
        let to = { x: center.x, y: center.y };
        if (direction === 'up') to.y -= distance;
        else if (direction === 'down') to.y += distance;
        else if (direction === 'left') to.x -= distance;
        else if (direction === 'right') to.x += distance;
        else throw wdError('invalid argument', `不支持的滑动方向: ${direction}`, 400);
        await appSend('swipe', {
          fromX: center.x, fromY: center.y,
          toX: to.x, toY: to.y, duration: 0.4,
        }, 20);
        return null;
      }
      case 'pinch': {
        const record = elementRecord();
        const center = await centerFor(record);
        const rect = center.rect;
        const scale = Math.max(number(options.scale, 1.5), 0.1);
        const base = rect ? Math.max(rect.width, rect.height) / 2 : 150;
        const radiusFrom = Math.max(base * 0.6, 20);
        const radiusTo = Math.max(radiusFrom * scale, 5);
        await appSend('pinch', {
          x: center.x, y: center.y,
          radiusFrom, radiusTo,
          duration: 0.5,
        }, 20);
        return null;
      }
      case 'dragfromtoforduration': {
        let fromX = number(options.fromX);
        let fromY = number(options.fromY);
        let toX = number(options.toX);
        let toY = number(options.toY);
        const record = elementRecord();
        if (record) {
          const rect = await elementRect(record);
          fromX += rect.x;
          fromY += rect.y;
          // Appium 的 drag 坐标相对元素左上角；toX/toY 也需要平移
          // 若客户端传的是绝对坐标，可通过不传 element 使用绝对坐标模式
          toX += rect.x;
          toY += rect.y;
        }
        await appSend('swipe', {
          fromX, fromY, toX, toY,
          duration: Math.max(number(options.duration, 0.5), 0.05),
        }, 20);
        return null;
      }
      case 'scrolltoelement':
      case 'scrolltovisible': {
        const record = elementRecord();
        if (!record) throw wdError('invalid argument', '缺少元素句柄', 400);
        await elementOp(record, 'scroll_to');
        return null;
      }
      case 'scrolltotop':
      case 'scrolltobottom': {
        const actionName = name === 'scrolltotop' ? 'scroll_to_top' : 'scroll_to_bottom';
        let record = elementRecord();
        if (!record) {
          const result = await send('find_elements', { using: 'class name', value: 'UIScrollView', limit: 20 }, 25);
          const element = result?.ok ? (result.data?.elements || [])[0] : null;
          if (!element) throw wdError('no such element', '页面上没有可滚动的 UIScrollView', 404);
          record = {
            using: 'class name',
            value: 'UIScrollView',
            index: Number.isFinite(Number(element.elementIndex)) ? Number(element.elementIndex) : 0,
          };
        }
        await elementOp(record, actionName);
        return null;
      }
      case 'alert': {
        const action = String(options.action || 'getText').toLowerCase();
        if (action === 'accept' || action === 'dismiss') {
          await appSend('alert', { action }, 15);
          return null;
        }
        if (action === 'settext') {
          await appSend('alert', { action: 'set_text', text: options.text ?? '' }, 20);
          return null;
        }
        const data = await appSend('alert', { action: 'get' }, 15);
        return data?.text ?? data?.message ?? '';
      }
      case 'getpasteboard':
      case 'getclipboard': {
        const data = await appSend('clipboard_get');
        return data?.text ?? '';
      }
      case 'setpasteboard':
      case 'setclipboard': {
        const text = options.text ?? options.content ?? options.input ?? '';
        await appSend('clipboard_set', { text });
        return null;
      }
      case 'deletepasteboard':
      case 'clearclipboard': {
        await appSend('clipboard_set', { text: '' });
        return null;
      }
      case 'setpermission': {
        return appManagement(currentSession, 'setPermission', options);
      }
      case 'resetpermission': {
        return appManagement(currentSession, 'resetPermission', options);
      }
      case 'getappstrings': {
        return appManagement(currentSession, 'appStrings', options);
      }
      case 'activeelement': {
        const data = await appSend('active_element');
        if (!data?.found) return null;
        const id = randomUUID();
        currentSession.elements.set(id, {
          id,
          using: 'xpath',
          value: data.xpath,
          index: 0,
          snapshot: data,
          createdAt: Date.now(),
        });
        return elementHandle(id);
      }
      case 'source': {
        const data = await appSend('page_source', {}, 30);
        return data?.source ?? '';
      }
      case 'deviceinfo': {
        return appSend('device_info', {}, 10);
      }
      case 'keyboardshown': {
        const data = await appSend('keyboard_state');
        return !!data?.shown;
      }
      case 'hidekeyboard': {
        // Appium hideKeyboard({key}) 语义：给 key 时用按键收起键盘，否则直接 resign
        const key = String(options.key ?? '').trim();
        if (key) {
          await appSend('press_key', { key });
        } else {
          await appSend('dismiss_keyboard');
        }
        return null;
      }
      case 'keys': {
        const raw = Array.isArray(options.keys) ? options.keys.join('') : options.keys;
        for (const command of textToKeyCommands(raw)) {
          await appSend(command.action, command.params, 15);
        }
        return null;
      }
      case 'setappearance': {
        return appManagement(currentSession, 'setAppearance', options);
      }
      case 'getappearance': {
        return appManagement(currentSession, 'getAppearance', options);
      }
      case 'setreducetransparency': {
        return appManagement(currentSession, 'setReduceTransparency', options);
      }
      case 'getreducetransparency': {
        return appManagement(currentSession, 'getReduceTransparency', options);
      }
      case 'orientation': {
        const data = await appSend('orientation');
        return data?.orientation ?? 'PORTRAIT';
      }
      case 'setorientation': {
        const data = await appSend('orientation', { orientation: options.orientation }, 15);
        return data?.orientation ?? 'PORTRAIT';
      }
      case 'viewportscreenshot':
      case 'screenshot':
      case 'savescreenshot': {
        const data = await appSend('screenshot', { quality: screenshotQuality(currentSession) }, 30);
        return data?.image ?? '';
      }
      case 'performancedata': {
        const data = await appSend('perf_sample');
        return { data: [data] };
      }
      case 'startperfrecord': {
        await appSend('perf_start', { interval: Math.max(number(options.timeout, 500) / 1000, 0.1) });
        return null;
      }
      case 'stopperfrecord': {
        return appSend('perf_stop', {}, 30);
      }
      case 'compareimages': {
        // Appium images 插件同名命令：firstImage 作为基线，与当前屏幕逐像素对比
        const baseline = options.firstImage ?? options.base64 ?? null;
        if (!baseline || typeof baseline !== 'string') {
          throw wdError('invalid argument', '缺少 firstImage（基线 PNG 的 base64）', 400);
        }
        const imageOptions = (options.options && typeof options.options === 'object') ? options.options : {};
        const params = { baseline };
        // Appium 的 options.threshold（0~1 相似度阈值）换算为 App 内的差異百分比阈值；
        // >=1 视为已是百分比直传
        const threshold = number(imageOptions.threshold, NaN);
        if (Number.isFinite(threshold)) {
          params.thresholdPercent = threshold > 0 && threshold < 1
            ? threshold * 100 : threshold;
        }
        const result = await send('screenshot_compare', params, 40);
        if (!result || result.ok !== true) {
          if (result?.data) {
            // 超过阈值：ok=false 但带数据 —— 以结构化结果返回而不是报错
            return {
              pass: false,
              diffPercent: number(result.data.diffPercent, 0),
              reason: result.error || '视觉差异超过阈值',
              ...result.data,
            };
          }
          throw wdError('unknown error', result?.error || '图像对比失败', 500);
        }
        return { pass: true, diffPercent: number(result?.data?.diffPercent, 0), ...(result?.data || {}) };
      }
      case 'getdevicetime': {
        const data = await appSend('device_info', {}, 10);
        return data?.time ?? '';
      }
      case 'batteryinfo': {
        const data = await appSend('device_info', {}, 10);
        return { level: data?.batteryLevel, state: data?.batteryState ?? 'unknown' };
      }
      case 'queryappstate': {
        if (options.bundleId || options.appId) {
          return appManagement(currentSession, 'state', options);
        }
        const data = await appSend('app_state');
        return data?.state ?? 4;
      }
      case 'activateapp': {
        await appManagement(currentSession, 'activate', options);
        return true;
      }
      case 'terminateapp': {
        await appManagement(currentSession, 'terminate', options);
        return true;
      }
      case 'backgroundapp': {
        return appManagement(currentSession, 'background', options);
      }
      case 'isappinstalled': {
        return appManagement(currentSession, 'installed', options);
      }
      case 'installapp': {
        await appManagement(currentSession, 'install', options);
        return true;
      }
      case 'removeapp': {
        return appManagement(currentSession, 'remove', options);
      }
      case 'pushfile': {
        await appManagement(currentSession, 'push', options);
        return null;
      }
      case 'pullfile': {
        return appManagement(currentSession, 'pull', options);
      }
      case 'pullfolder': {
        return appManagement(currentSession, 'pullFolder', options);
      }
      case 'startrecordingscreen': {
        return appManagement(currentSession, 'startRecording', options);
      }
      case 'stoprecordingscreen': {
        return appManagement(currentSession, 'stopRecording', options);
      }
      case 'lock':
      case 'unlock':
      case 'islocked':
        throw wdError('unsupported operation', 'IUIAuto 进程内 Agent 不支持锁屏控制', 500);
      case 'shake': {
        await appSend('shake');
        return null;
      }
      default:
        throw wdError('unknown command', `不支持的 mobile 命令: mobile: ${name}`, 404);
    }
  }

  async function handleSessionRoute(req, res, currentSession, rest) {
    const method = req.method;
    const key = rest.join('/');

    if (method === 'DELETE' && rest.length === 0) {
      const ended = currentSession.id;
      session = null;
      await cleanupRecording();
      recordEvent('sessionDeleted');
      log(`session ${ended} deleted`);
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && rest.length === 0) {
      return sendJSON(res, { value: currentSession.capabilities });
    }
    if (method === 'POST' && rest[0] === 'element' && rest.length === 1) {
      const body = await readJSON(req);
      const { locator, elements } = await findElements(currentSession,
        body.using ?? body.using_, body.value);
      if (elements.length === 0) {
        throw wdError('no such element', `找不到元素: ${body.using}=${body.value}`, 404);
      }
      const [id] = registerElements(currentSession, locator, [elements[0]]);
      return sendJSON(res, { value: elementHandle(id) });
    }
    if (method === 'POST' && rest[0] === 'elements' && rest.length === 1) {
      const body = await readJSON(req);
      const { locator, elements } = await findElements(currentSession,
        body.using ?? body.using_, body.value);
      const ids = registerElements(currentSession, locator, elements);
      return sendJSON(res, { value: ids.map(elementHandle) });
    }
    if (method === 'GET' && rest[0] === 'element' && rest[1] === 'active' && rest.length === 2) {
      const data = await appSend('active_element');
      if (!data?.found) {
        throw wdError('no such element', '当前没有焦点元素', 404);
      }
      const id = randomUUID();
      currentSession.elements.set(id, {
        id,
        using: 'xpath',
        value: data.xpath,
        index: 0,
        snapshot: data,
        createdAt: Date.now(),
      });
      return sendJSON(res, { value: elementHandle(id) });
    }
    // JSON Wire 兼容：比较两个元素句柄是否指向同一元素
    if (method === 'GET' && rest[0] === 'element' && rest[2] === 'equals' && rest.length === 4) {
      const left = requireElement(currentSession, rest[1]);
      const right = requireElement(currentSession, rest[3]);
      const same = left.id === right.id ||
        (left.using === right.using && String(left.value) === String(right.value) &&
          left.index === right.index);
      return sendJSON(res, { value: same });
    }
    if (rest[0] === 'element' && rest[1]) {
      return handleElement(req, res, currentSession, rest[1], rest.slice(2));
    }

    if (method === 'GET' && (key === 'source' || key === 'appium/source')) {
      const data = await appSend('page_source', {}, 30);
      return sendJSON(res, { value: data?.source ?? '' });
    }
    if (method === 'GET' && (key === 'screenshot' || key === 'appium/screenshot')) {
      const data = await appSend('screenshot', { quality: screenshotQuality(currentSession) }, 30);
      return sendJSON(res, { value: data?.image ?? '' });
    }
    if (method === 'POST' && key === 'actions') {
      const body = await readJSON(req);
      const commands = await translateActions(body.actions ?? body, resolveElementRect);
      for (const command of commands) {
        await appSend(command.action, command.params, 30);
      }
      return sendJSON(res, { value: null });
    }
    if (method === 'DELETE' && key === 'actions') {
      return sendJSON(res, { value: null });
    }
    // JSON Wire 兼容：sendKeys（对当前焦点输入）
    if (method === 'POST' && key === 'keys') {
      const body = await readJSON(req);
      const text = extractKeys(body);
      if (text.length === 0) return sendJSON(res, { value: null });
      for (const command of textToKeyCommands(text)) {
        await appSend(command.action, command.params, 15);
      }
      return sendJSON(res, { value: null });
    }
    // JSON Wire 兼容：Appium TouchAction（单指 / 多指）
    if (method === 'POST' && key === 'touch/perform') {
      const body = await readJSON(req);
      await performTouchChains([body.actions || []]);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'touch/multi/perform') {
      const body = await readJSON(req);
      const chains = Array.isArray(body.actions) ? body.actions : [];
      if (chains.length === 0) throw wdError('invalid argument', '缺少 touch 动作链', 400);
      await performTouchChains(chains);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && (key === 'timeouts' || key === 'timeouts/implicit_wait')) {
      const body = await readJSON(req);
      if (key === 'timeouts/implicit_wait') {
        currentSession.implicitWait = Math.max(0, number(body.ms ?? body.implicit, 0));
      } else {
        if (body.implicit !== undefined) currentSession.implicitWait = Math.max(0, number(body.implicit, 0));
        if (body.pageLoad !== undefined) currentSession.pageLoadTimeout = Math.max(0, number(body.pageLoad, 0));
        if (body.script !== undefined) currentSession.scriptTimeout = Math.max(0, number(body.script, 0));
        if (body.type && body.ms !== undefined) {
          if (body.type === 'implicit') currentSession.implicitWait = Math.max(0, number(body.ms, 0));
          if (body.type === 'page load') currentSession.pageLoadTimeout = Math.max(0, number(body.ms, 0));
          if (body.type === 'script') currentSession.scriptTimeout = Math.max(0, number(body.ms, 0));
        }
      }
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && key === 'timeouts') {
      return sendJSON(res, {
        value: {
          implicit: currentSession.implicitWait,
          pageLoad: currentSession.pageLoadTimeout,
          script: currentSession.scriptTimeout,
        },
      });
    }
    if (method === 'GET' && key === 'window/rect') {
      const info = await appSend('device_info', {}, 10);
      const size = info?.windowSize || info?.screen || { width: 375, height: 812 };
      return sendJSON(res, {
        value: { x: 0, y: 0, width: number(size.width), height: number(size.height) },
      });
    }
    if (method === 'POST' && key === 'window/rect') {
      throw wdError('unsupported operation', 'IUIAuto 无法修改宿主 App 窗口尺寸', 500);
    }
    if (method === 'GET' && key === 'window/handles') {
      return sendJSON(res, { value: ['main'] });
    }
    if (method === 'GET' && key === 'window') {
      return sendJSON(res, { value: 'main' });
    }
    if (method === 'POST' && key === 'window') {
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && key === 'url') {
      return sendJSON(res, { value: currentSession.capabilities['appium:bundleId'] || '' });
    }
    if (method === 'POST' && key === 'url') {
      const body = await readJSON(req);
      if (!body.url) throw wdError('invalid argument', '缺少 url', 400);
      await appSend('open_url', { url: String(body.url) }, 20);
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && key === 'orientation') {
      const data = await appSend('orientation');
      return sendJSON(res, { value: data?.orientation ?? 'PORTRAIT' });
    }
    if (method === 'POST' && key === 'orientation') {
      const body = await readJSON(req);
      const orientation = String(body.orientation || 'PORTRAIT').toUpperCase();
      if (!orientation.includes('PORTRAIT') && !orientation.includes('LANDSCAPE')) {
        throw wdError('invalid argument', 'orientation 必须为 PORTRAIT 或 LANDSCAPE', 400);
      }
      const data = await appSend('orientation', { orientation }, 15);
      return sendJSON(res, { value: data?.orientation ?? orientation });
    }
    if (method === 'GET' && key === 'contexts') {
      return sendJSON(res, { value: ['NATIVE_APP'] });
    }
    if (method === 'GET' && key === 'context') {
      return sendJSON(res, { value: 'NATIVE_APP' });
    }
    if (method === 'POST' && key === 'context') {
      const body = await readJSON(req);
      if (String(body.name) !== 'NATIVE_APP') {
        throw wdError('unsupported operation', '仅支持 NATIVE_APP 上下文', 500);
      }
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && (key === 'execute/sync' || key === 'execute/async')) {
      const body = await readJSON(req);
      const result = await handleMobileCommand(currentSession, body.script, body.args || []);
      return sendJSON(res, { value: result });
    }

    // ---------------- Appium 设备 / 系统端点 ----------------
    if (method === 'POST' && key === 'appium/device/shake') {
      await appSend('shake');
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/device/hide_keyboard') {
      await appSend('dismiss_keyboard');
      return sendJSON(res, { value: null });
    }
    if ((method === 'GET' || method === 'POST') && key === 'appium/device/is_keyboard_shown') {
      const data = await appSend('keyboard_state');
      return sendJSON(res, { value: !!data?.shown });
    }
    if ((method === 'GET' || method === 'POST') && key === 'appium/device/system_time') {
      const data = await appSend('device_info', {}, 10);
      return sendJSON(res, { value: data?.time ?? '' });
    }
    if ((method === 'GET' || method === 'POST') && key === 'appium/device/battery_info') {
      const data = await appSend('device_info', {}, 10);
      return sendJSON(res, {
        value: { level: data?.batteryLevel, state: data?.batteryState ?? 'unknown' },
      });
    }
    if (method === 'POST' && key === 'appium/device/set_clipboard') {
      const body = await readJSON(req);
      const text = String(body.content ?? body.text ?? '');
      await appSend('clipboard_set', { text });
      return sendJSON(res, { value: null });
    }
    if ((method === 'GET' || method === 'POST') && key === 'appium/device/get_clipboard') {
      const data = await appSend('clipboard_get');
      return sendJSON(res, { value: data?.text ?? '' });
    }
    if (method === 'POST' && key === 'appium/device/delete_clipboard') {
      await appSend('clipboard_set', { text: '' });
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/device/activate_app') {
      const body = await readJSON(req);
      await appManagement(currentSession, 'activate', body);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' &&
        (key === 'appium/device/app_state' || key === 'appium/device/query_app_state')) {
      const body = await readJSON(req);
      const value = await appManagement(currentSession, 'state', body);
      return sendJSON(res, { value });
    }
    if (method === 'POST' && key === 'appium/device/app_installed') {
      const body = await readJSON(req);
      const value = await appManagement(currentSession, 'installed', body);
      return sendJSON(res, { value });
    }
    if (method === 'POST' && key === 'appium/device/terminate_app') {
      const body = await readJSON(req);
      await appManagement(currentSession, 'terminate', body);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/device/background_app') {
      const body = await readJSON(req);
      await appManagement(currentSession, 'background', body);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/device/install_app') {
      const body = await readJSON(req);
      await appManagement(currentSession, 'install', body);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/device/remove_app') {
      const body = await readJSON(req);
      const value = await appManagement(currentSession, 'remove', body);
      return sendJSON(res, { value });
    }
    if (method === 'POST' && key === 'appium/device/push_file') {
      const body = await readJSON(req);
      await appManagement(currentSession, 'push', body);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/device/pull_file') {
      const body = await readJSON(req);
      const value = await appManagement(currentSession, 'pull', body);
      return sendJSON(res, { value });
    }
    if (method === 'POST' && key === 'appium/device/pull_folder') {
      const body = await readJSON(req);
      const value = await appManagement(currentSession, 'pullFolder', body);
      return sendJSON(res, { value });
    }
    if (method === 'POST' && key === 'appium/start_recording_screen') {
      await appManagement(currentSession, 'startRecording');
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/stop_recording_screen') {
      const value = await appManagement(currentSession, 'stopRecording');
      return sendJSON(res, { value });
    }
    if (method === 'POST' && (key === 'appium/device/lock' ||
        key === 'appium/device/unlock' || key === 'appium/device/is_locked')) {
      throw wdError('unsupported operation', 'IUIAuto 进程内 Agent 不支持锁屏控制', 500);
    }
    if (method === 'POST' && (key === 'appium/device/press_keycode' ||
        key === 'appium/device/long_press_keycode' || key === 'appium/device/keyevent' ||
        key === 'appium/device/start_activity')) {
      throw wdError('unsupported operation', '该端点仅适用于 Android', 500);
    }
    if ((method === 'GET' || method === 'POST') && key === 'appium/device/network_connection') {
      throw wdError('unsupported operation', 'IUIAuto 暂不支持网络状态控制', 500);
    }
    if (method === 'GET' && key === 'appium/device/display_density') {
      const info = await appSend('device_info', {}, 10);
      return sendJSON(res, { value: number(info?.screen?.scale, 1) });
    }
    // W3C WebDriver 标准 alert 端点（WebdriverIO 的 getAlertText/acceptAlert 走这里）
    if (method === 'GET' && key === 'alert/text') {
      const data = await appSend('alert', { action: 'get' }, 15);
      return sendJSON(res, { value: data?.text ?? '' });
    }
    if (method === 'POST' && key === 'alert/text') {
      const body = await readJSON(req);
      await appSend('alert', { action: 'set_text', text: String(body.text ?? '') }, 20);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'alert/accept') {
      await appSend('alert', { action: 'accept' }, 20);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'alert/dismiss') {
      await appSend('alert', { action: 'dismiss' }, 20);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/alert/accept') {
      await appSend('alert', { action: 'accept' }, 20);
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && key === 'appium/alert/dismiss') {
      await appSend('alert', { action: 'dismiss' }, 20);
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && key === 'appium/alert/text') {
      const data = await appSend('alert', { action: 'get' }, 15);
      return sendJSON(res, { value: data?.text ?? '' });
    }
    if (method === 'POST' && key === 'appium/alert/text') {
      const body = await readJSON(req);
      await appSend('alert', { action: 'set_text', text: String(body.text ?? '') }, 20);
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && key === 'appium/settings') {
      return sendJSON(res, { value: currentSession.settings });
    }
    if (method === 'POST' && key === 'appium/settings') {
      const body = await readJSON(req);
      const settings = (body && typeof body.settings === 'object') ? body.settings : body;
      if (settings && typeof settings === 'object') {
        Object.assign(currentSession.settings, settings);
      }
      return sendJSON(res, { value: null });
    }
    if (method === 'GET' && key === 'appium/performance_data/types') {
      return sendJSON(res, { value: ['cpuinfo', 'memoryinfo', 'batteryinfo'] });
    }
    if (method === 'POST' && (key === 'appium/performance_data' ||
        key === 'appium/device/get_performance_data')) {
      const data = await appSend('perf_sample');
      return sendJSON(res, { value: { data: [data] } });
    }
    if (method === 'GET' && key === 'appium/device/device_info') {
      return sendJSON(res, { value: await appSend('device_info', {}, 10) });
    }
    // Appium Events API：GET 返回全部事件，POST 按 body.events 名称过滤
    if (method === 'GET' && key === 'appium/events') {
      return sendJSON(res, { value: { events: eventsSnapshot() } });
    }
    if (method === 'POST' && key === 'appium/events') {
      const body = await readJSON(req);
      return sendJSON(res, { value: { events: eventsSnapshot(body.events) } });
    }
    if (method === 'POST' && key === 'appium/app/launch') {
      return sendJSON(res, { value: null });
    }
    if (method === 'POST' && (key === 'appium/app/close' || key === 'appium/app/reset')) {
      throw wdError('unsupported operation', 'IUIAuto 进程内 Agent 不支持 app close/reset', 500);
    }

    throw wdError('unknown command', `不支持的 WebDriver 端点: ${method} ${key}`, 404);
  }

  async function handleRequest(req, res) {
    setCommonHeaders(res);
    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }
    let url;
    try {
      url = new URL(req.url, 'http://localhost');
    } catch {
      throw wdError('invalid argument', '非法 URL', 400);
    }
    let pathname;
    try {
      pathname = decodeURIComponent(url.pathname || '/');
    } catch {
      throw wdError('invalid argument', 'URL 编码非法', 400);
    }
    pathname = pathname.replace(/^\/wd\/hub(?=\/|$)/, '') || '/';

    if (pathname === '/' || pathname === '/health') {
      return sendJSON(res, {
        value: {
          ready: true,
          message: 'IUIAuto Appium bridge ready',
          agent: 'IUIAuto',
          version: AGENT_VERSION,
          appConnected: !!getHello(),
          session: session?.id ?? null,
        },
      });
    }
    if (pathname === '/status' && req.method === 'GET') {
      return sendJSON(res, {
        value: {
          ready: true,
          message: 'IUIAuto Appium bridge ready',
          build: { version: AGENT_VERSION },
        },
      });
    }
    if (pathname === '/sessions' && req.method === 'GET') {
      return sendJSON(res, { value: session ? [session.capabilities] : [] });
    }
    if (pathname === '/events' && req.method === 'GET') {
      return sendJSON(res, { value: { events: eventsSnapshot() } });
    }
    if (pathname === '/session' && req.method === 'POST') {
      return createSession(req, res);
    }

    const segments = pathname.split('/').filter(Boolean);
    if (segments[0] === 'session' && segments[1]) {
      const currentSession = requireSession(segments[1]);
      lastCommandAt = Date.now(); // 校验通过才算“有活动”，探活 404 不刷新计时
      return handleSessionRoute(req, res, currentSession, segments.slice(2));
    }

    throw wdError('unknown command', `未知端点: ${req.method} ${pathname}`, 404);
  }

  const server = createServer((req, res) => {
    handleRequest(req, res).catch((error) => {
      if (!error?.webdriver) {
        log(`error ${req.method} ${req.url}: ${error?.stack || error}`);
      }
      recordEvent('commandError');
      sendError(res, error);
    });
  });

  return {
    server,
    get session() { return session; },
    handleRequest,
    close() {
      return (async () => {
        clearInterval(idleTimer);
        await cleanupRecording();
        await new Promise((resolve) => {
          try { server.closeAllConnections?.(); } catch { /* ignore */ }
          server.close(() => resolve());
        });
      })();
    },
  };
}

// ---------------------------------------------------------------------------
// 独立运行模式：提供 App WebSocket :9800 + WebDriver HTTP :4723
// ---------------------------------------------------------------------------

async function main() {
  const args = process.argv.slice(2);
  const takeover = args.includes('--takeover');
  const portArg = args.find((arg) => arg.startsWith('--port='));
  const appPortArg = args.find((arg) => arg.startsWith('--app-port='));
  const bridgePort = portArg ? +portArg.split('=')[1] : DEFAULT_BRIDGE_PORT;
  const appPort = appPortArg ? +appPortArg.split('=')[1] : DEFAULT_APP_PORT;
  const bridgeHost = process.env.BRIDGE_HOST || DEFAULT_BRIDGE_HOST;

  await ensurePortFree(appPort, { takeover, label: 'App 连接端口' });
  await ensurePortFree(bridgePort, { takeover, label: 'WebDriver HTTP 端口' });

  let appSocket = null;
  let appHello = null;
  let seq = 0;
  const pending = new Map();

  function sendToApp(action, params = {}, timeoutSec = 20) {
    return new Promise((resolve) => {
      if (!appSocket || appSocket.readyState !== 1) {
        resolve({ ok: false, error: 'App 未连接' });
        return;
      }
      const id = `wd-${++seq}`;
      const timer = setTimeout(() => {
        pending.delete(id);
        resolve({ ok: false, error: `超时 ${timeoutSec}s` });
      }, timeoutSec * 1000);
      pending.set(id, { resolve, timer });
      try {
        appSocket.send(JSON.stringify({ id, action, params, timeout: timeoutSec }));
      } catch {
        clearTimeout(timer);
        pending.delete(id);
        resolve({ ok: false, error: 'App 连接已断开' });
      }
    });
  }

  const appWss = new WebSocketServer({ port: appPort, path: '/ws' });
  appWss.on('error', (error) => handleListenError(error, appPort));
  console.log(`[appium-bridge] App 连接端口 ws://0.0.0.0:${appPort}/ws`);

  appWss.on('connection', (ws) => {
    if (appSocket && appSocket !== ws) {
      try { appSocket.close(); } catch { /* ignore */ }
    }
    appSocket = ws;
    console.log('[appium-bridge] App 已连接');
    ws.on('message', (data) => {
      let message;
      try { message = JSON.parse(data.toString()); } catch { return; }
      if (message.type === 'result') {
        const entry = pending.get(message.id);
        if (entry) {
          clearTimeout(entry.timer);
          pending.delete(message.id);
          entry.resolve(message);
        }
      } else if (message.type === 'hello') {
        appHello = message;
        console.log(`[appium-bridge] hello: agent=${message.agent} version=${message.version} actions=${message.actions?.length ?? '?'}`);
      } else if (message.type === 'log') {
        const levels = ['debug', 'info', 'warn', 'error'];
        console.log(`[app-log][${levels[message.level] ?? message.level}] ${message.message}`);
      }
    });
    ws.on('close', () => {
      if (appSocket === ws) {
        appSocket = null;
        appHello = null;
        console.log('[appium-bridge] App 断开（等待重连…）');
      }
    });
    ws.on('error', (error) => console.log('[appium-bridge] App 连接错误:', error.message));
  });

  const bridge = createAppiumBridge({
    send: sendToApp,
    getHello: () => appHello,
    log: (...values) => console.log('[appium-bridge]', ...values),
  });
  bridge.server.on('error', (error) => handleListenError(error, bridgePort));
  await new Promise((resolve) => bridge.server.listen(bridgePort, bridgeHost, resolve));

  console.log(`[appium-bridge] WebDriver 端点: http://${bridgeHost}:${bridgePort}`);
  console.log(`[appium-bridge] 用法: appium 客户端 remote URL = http://127.0.0.1:${bridgePort}`);
  console.log('[appium-bridge] 能力: platformName=iOS, appium:automationName=IUIAuto');

  const connectHint = setTimeout(async () => {
    if (!appSocket) {
      console.log('[appium-bridge] ⚠ 15 秒了 App 还没连上，自动尝试拉起 App…');
      const woken = await tryWakeApp().catch(() => false);
      console.log(woken
        ? '  · 已尝试启动 App（若模拟器失焦冻结，请点一下模拟器窗口）'
        : '  · 未找到已启动的模拟器 → ./build.sh 或 ./start.sh 可自动拉起');
    }
  }, 15000);
  connectHint.unref?.();

  const shutdown = async () => {
    console.log('\n[appium-bridge] 正在关闭…');
    clearTimeout(connectHint);
    try { appWss.close(); } catch { /* ignore */ }
    await bridge.close().catch(() => {});
    process.exit(0);
  };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}

if (process.argv[1] && pathToFileURL(process.argv[1]).href === import.meta.url) {
  main().catch((error) => {
    console.error('[appium-bridge] 启动失败:', error?.stack || error);
    process.exit(1);
  });
}
