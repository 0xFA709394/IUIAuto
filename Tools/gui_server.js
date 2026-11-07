#!/usr/bin/env node
/**
 * IUIAuto GUI 控制台服务器
 *
 *   node gui_server.js            # 默认 HTTP :9900（浏览器），App 连 ws://...:9800/ws
 *   node gui_server.js --takeover # 端口被旧实例占用时自动接管
 *   PORT=9900 APP_PORT=9800 node gui_server.js
 *
 * 职责：
 *   - HTTP 托管 gui.html（单文件控制台页面）
 *   - /ws   浏览器 WebSocket（控制协议）
 *   - /app  App WebSocket（同 mock_server 的指令协议，9800 端口独立路径）
 *   - Tools/scripts/ 下的 DSL 脚本存储（列表/保存/读取/删除）
 *   - 复用 iua_runner.runSteps 执行脚本，进度实时推给浏览器
 *   - 自动在 4723 启动 Appium/W3C WebDriver 桥（与 GUI 共用 App 连接）
 */

import { createServer } from 'node:http';
import { readFileSync, writeFileSync, readdirSync, unlinkSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { parseScript, stepsToDSL, DSL_HELP } from './iua_dsl.js';
import { runSteps } from './iua_runner.js';
import { startXctraceRecording } from './iua_perf.js';
import { ensurePortFree, handleListenError, APP_BUNDLE_ID } from './iua_ports.js';
import { createAppiumBridge } from './appium_bridge.js';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const execFileAsync = promisify(execFile);

async function detectBootedSimulator() {
  const { stdout } = await execFileAsync('xcrun', ['simctl', 'list', 'devices', 'booted'], {
    env: { ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer' },
  }).catch(() => ({ stdout: '' }));
  const iosLine = stdout.split('\n').find((line) => /iPhone|iPad/.test(line) && /\([0-9A-F-]{36}\)/.test(line));
  const m = iosLine ? iosLine.match(/\(([0-9A-F-]{36})\)/) : null;
  return m ? m[1] : null;
}

const __dirname = dirname(fileURLToPath(import.meta.url));
const HTTP_PORT = +(process.env.PORT || 9900);
const APP_PORT = +(process.env.APP_PORT || 9800);
const BRIDGE_PORT = +(process.env.BRIDGE_PORT || 4723);
const GUI_HOST = process.env.GUI_HOST || '127.0.0.1';
const BRIDGE_HOST = process.env.BRIDGE_HOST || '127.0.0.1';
const DEVELOPER_DIR = process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer';
const SCRIPTS_DIR = join(__dirname, 'scripts');
if (!existsSync(SCRIPTS_DIR)) mkdirSync(SCRIPTS_DIR, { recursive: true });

// ---------------------------------------------------------------- App 连接
let appSocket = null;
let appSeq = 0;
const appPending = new Map();
let appHello = null;

function sendToApp(action, params = {}, timeoutSec = 20) {
  return new Promise((resolve) => {
    if (!appSocket || appSocket.readyState !== 1) { resolve({ ok: false, error: 'App 未连接' }); return; }
    const id = `g-${++appSeq}`;
    const timer = setTimeout(() => { appPending.delete(id); resolve({ ok: false, error: `超时 ${timeoutSec}s` }); }, timeoutSec * 1000);
    appPending.set(id, { resolve, timer });
    try {
      appSocket.send(JSON.stringify({ id, action, params, timeout: timeoutSec }));
    } catch {
      // readyState 检查后连接恰好死亡：同步 throw 会 reject 整个 Promise 链
      clearTimeout(timer);
      appPending.delete(id);
      resolve({ ok: false, error: 'App 连接已断开' });
    }
  });
}

// ---------------------------------------------------------------- 端口检查（占用时友好提示 / --takeover 自动接管）
const TAKEOVER = process.argv.includes('--takeover');
await ensurePortFree(APP_PORT, { takeover: TAKEOVER, label: 'App 连接端口' });
await ensurePortFree(HTTP_PORT, { takeover: TAKEOVER, label: '控制台 HTTP 端口' });

const appWss = new WebSocketServer({ port: APP_PORT, path: '/ws' });
appWss.on('error', (e) => handleListenError(e, APP_PORT));
console.log(`[gui] App 端口 ws://0.0.0.0:${APP_PORT}/ws（等待 App 连接）`);

const connectHint = setTimeout(() => {
  if (!appSocket) {
    console.log('[gui] ⚠ 15 秒了 App 还没连上：');
    console.log('    处理: ./build.sh 或 ./start.sh（自动拉起模拟器与 App）');
    console.log('    若模拟器窗口长时间失焦，App 会被冻结（App Nap）→ 点一下模拟器窗口唤醒');
  }
}, 15000);

appWss.on('connection', (ws) => {
  clearTimeout(connectHint);
  console.log('[gui] App 已连接');
  // 新连接顶替旧连接（App 重启/双进程）：关闭旧的，避免向死连接发送
  if (appSocket && appSocket !== ws) { try { appSocket.close(); } catch {} }
  appSocket = ws;
  ws.on('close', () => {
    // 仅当前连接可以清空状态；App 重连时旧 socket 的 close 不能覆盖新连接
    if (appSocket !== ws) return;
    console.log('[gui] App 断开（等待重连…）');
    appSocket = null;
    appHello = null;
    broadcast({ type: 'app_state', connected: false, hello: null });
  });
  ws.on('message', (data) => {
    let msg; try { msg = JSON.parse(data.toString()); } catch { return; }
    if (msg.type === 'result') {
      const e = appPending.get(msg.id);
      if (e) { clearTimeout(e.timer); appPending.delete(msg.id); e.resolve(msg); }
    } else if (msg.type === 'hello') {
      appHello = msg;
      broadcast({ type: 'app_state', connected: true, hello: msg });
    } else if (msg.type === 'log') {
      broadcast({ type: 'app_log', level: msg.level, message: msg.message });
    }
  });
});

// ---------------------------------------------------------------- 浏览器连接与控制协议
const browserSockets = new Set();
let running = false;

function broadcast(obj) {
  const text = JSON.stringify(obj);
  for (const ws of browserSockets) safeSend(ws, text);
}

/** 安全发送：连接可能在 await 期间关闭（ws v8 对非 OPEN socket 的 send 会同步 throw，
 *  在 async message handler 里抛出会变成 unhandledRejection 并崩掉整个服务进程） */
function safeSend(ws, text) {
  try {
    if (ws.readyState === 1) ws.send(text, () => { /* 发送错误由 ws 内部处理，忽略 */ });
  } catch { /* 连接已死 */ }
}

const httpServer = createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    const html = readFileSync(join(__dirname, 'gui.html'), 'utf8')
      .replace(/__IUA_BRIDGE_PORT__/g, String(BRIDGE_PORT))
      .replace(/__IUA_BRIDGE_HOST__/g, BRIDGE_HOST);
    res.end(html);
  } else {
    res.writeHead(404); res.end();
  }
});

const browserWss = new WebSocketServer({ server: httpServer, path: '/ws' });
browserWss.on('connection', (ws) => {
  browserSockets.add(ws);
  console.log('[gui] 浏览器已连接');
  safeSend(ws, JSON.stringify({ type: 'app_state', connected: !!appSocket, hello: appHello }));
  safeSend(ws, JSON.stringify({ type: 'dsl_help', text: DSL_HELP }));

  ws.on('message', async (data) => {
    let msg; try { msg = JSON.parse(data.toString()); } catch { return; }
    try {
      switch (msg.type) {
        case 'send': { // 手动下发一条指令
          const r = await sendToApp(msg.action, msg.params ?? {}, msg.timeout ?? 20);
          safeSend(ws, JSON.stringify({ type: 'result', action: msg.action, echo: msg.echo, ...pick(r) }));
          break;
        }
        case 'record_stop': {
          const r = await sendToApp('record_stop');
          safeSend(ws, JSON.stringify({ type: 'record_result', ...pick(r), steps: r.data?.steps ?? [] }));
          break;
        }
        case 'record_save': { // 录制步骤（或当前编辑内容）保存为脚本
          const safe = String(msg.name || '').replace(/[^\w\u4e00-\u9fa5.-]/g, '_');
          if (!safe) { safeSend(ws, JSON.stringify({ type: 'rpc_error', error: '文件名无效' })); break; }
          const file = join(SCRIPTS_DIR, safe.endsWith('.txt') ? safe : safe + '.txt');
          writeFileSync(file, String(msg.content ?? ''), 'utf8');
          safeSend(ws, JSON.stringify({ type: 'rpc_ok', message: `已保存 ${basename(file)}` }));
          broadcast({ type: 'dsl_list', files: listScripts() });
          break;
        }
        case 'dsl_list':
          safeSend(ws, JSON.stringify({ type: 'dsl_list', files: listScripts() }));
          break;
        case 'dsl_read': {
          const file = safeScriptPath(msg.name);
          if (!file) { safeSend(ws, JSON.stringify({ type: 'dsl_content', name: msg.name, error: '文件名无效', content: '' })); break; }
          safeSend(ws, JSON.stringify({ type: 'dsl_content', name: msg.name, content: readFileSync(file, 'utf8') }));
          break;
        }
        case 'dsl_delete': {
          const file = safeScriptPath(msg.name);
          if (file && existsSync(file)) unlinkSync(file);
          safeSend(ws, JSON.stringify({ type: 'rpc_ok', message: `已删除 ${msg.name}` }));
          broadcast({ type: 'dsl_list', files: listScripts() });
          break;
        }
        case 'dsl_steps_to_text': {
          // 录制步骤（JSON）→ DSL 文本（浏览器也可自己转，统一在服务端做）
          safeSend(ws, JSON.stringify({ type: 'dsl_text', text: stepsToDSL(msg.steps ?? []) }));
          break;
        }
        case 'run': {
          if (running) { safeSend(ws, JSON.stringify({ type: 'run_done', passed: 0, total: 0, ok: false, error: '已有脚本在运行' })); break; }
          let steps;
          try {
            steps = parseScript(String(msg.content ?? ''));
          } catch (e) {
            safeSend(ws, JSON.stringify({ type: 'run_done', passed: 0, total: 0, ok: false, error: `脚本解析失败: ${e.message}` }));
            break;
          }
          running = true;
          const perfOn = !!msg.perf;
          const xctraceOn = !!msg.xctrace;
          let perfStopped = false;
          let xctraceSession = null;
          let doneSent = false;
          const finishRun = (payload) => {
            if (doneSent) return;
            doneSent = true;
            broadcast({ type: 'run_done', ...payload });
          };
          try {
            broadcast({ type: 'run_start', total: steps.length, perf: perfOn, xctrace: xctraceOn });

            // App 端性能采样
            if (perfOn) await sendToApp('perf_start', { interval: 0.5 });
            // xctrace 宿主侧录制（环境受限自动降级，不阻塞测试）
            try {
              if (xctraceOn) {
                const udid = await detectBootedSimulator();
                if (udid) {
                  xctraceSession = startXctraceRecording({
                    deviceUDID: udid, processName: 'IUIAuto', template: 'Time Profiler',
                    outputDir: join(SCRIPTS_DIR, '..', 'traces'),
                  });
                  const ready = await xctraceSession.waitUntilRecording(30000);
                  if (!ready.ok) { xctraceSession.abort(); xctraceSession = null; broadcast({ type: 'app_log', level: 2, message: `xctrace 不可用已降级: ${ready.reason}` }); }
                }
              }

              const outcome = await runSteps(steps, sendToApp, (r) => broadcast({ type: 'run_progress', ...r }));

              const perfData = perfOn ? ((await sendToApp('perf_stop')).data ?? null) : null;
              if (perfOn) perfStopped = true;
              let xctraceResult = null;
              if (xctraceSession) {
                try { xctraceResult = await xctraceSession.stop(); }
                catch (e) { broadcast({ type: 'app_log', level: 2, message: `xctrace 停止失败（已降级）: ${e.message}` }); }
              }

              // 失败时抓现场截图推给浏览器
              let failShot = null;
              if (!outcome.ok) {
                const s = await sendToApp('screenshot', { quality: 1 });
                if (s.ok) failShot = `data:image/png;base64,${s.data.image}`;
              }
              finishRun({ passed: outcome.passed, total: outcome.total, ok: outcome.ok,
                          failShot, perf: perfData, xctrace: xctraceResult });
            } catch (runError) {
              if (perfOn && !perfStopped) {
                try { await sendToApp('perf_stop'); } catch { /* ignore */ }
                perfStopped = true;
              }
              finishRun({ passed: 0, total: steps.length, ok: false,
                          error: `运行异常: ${runError.message}`, perf: null, xctrace: null });
            } finally {
              // 异常路径也必须停止 xctrace，避免孤儿录制进程
              if (xctraceSession) { try { xctraceSession.abort(); } catch {} }
            }
          } finally {
            running = false;  // 任何异常都不得卡死运行标志
          }
          break;
        }
        default:
          break;
      }
    } catch (e) {
      safeSend(ws, JSON.stringify({ type: 'rpc_error', error: e.message }));
    }
  });

  ws.on('close', () => browserSockets.delete(ws));
});

httpServer.on('error', (e) => handleListenError(e, HTTP_PORT));
httpServer.listen(HTTP_PORT, GUI_HOST, () => {
  console.log(`[gui] 控制台已启动: http://${GUI_HOST}:${HTTP_PORT}`);
});

// ---------------------------------------------------------------- Appium / WebDriver 桥（与 GUI 共存）
// 标准 Appium 客户端可直接连接 http://localhost:4723；App 连接仍由本进程统一持有。
let appiumBridge = null;
try {
  appiumBridge = createAppiumBridge({
    send: sendToApp,
    getHello: () => appHello,
    log: (...values) => console.log('[gui][appium]', ...values),
  });
  appiumBridge.server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') {
      console.log(`[gui] ⚠ Appium 桥端口 ${BRIDGE_PORT} 已被占用，已跳过（可设置 BRIDGE_PORT 更换端口）`);
    } else {
      console.log('[gui] Appium 桥错误:', e.message);
    }
  });
  appiumBridge.server.listen(BRIDGE_PORT, BRIDGE_HOST, () => {
    console.log(`[gui] Appium 桥已启动: http://${BRIDGE_HOST}:${BRIDGE_PORT}`);
  });
} catch (e) {
  console.log('[gui] Appium 桥初始化失败:', e.message);
}

// ---------------------------------------------------------------- 启动环境自检（新手引导）
(async () => {
  const udid = await detectBootedSimulator().catch(() => null);
  if (!udid) {
    console.log('[gui] ⚠ 未检测到已启动的模拟器 → App 无法连接。');
    console.log('    处理: ./build.sh --boot-only   （或在 Xcode 里启动一个模拟器）');
    return;
  }
  const installed = await execFileAsync('xcrun', ['simctl', 'get_app_container', udid, APP_BUNDLE_ID], { env: { ...process.env, DEVELOPER_DIR } }).catch(() => null);
  if (!installed) {
    console.log(`[gui] ⚠ 模拟器(${udid.slice(0, 8)}…)上未安装 IUIAuto App。`);
    console.log('    处理: ./build.sh   （一键编译+安装+启动）');
  }
})();

// ---------------------------------------------------------------- 工具函数
function pick(r) { return { ok: r.ok, data: r.data ?? null, error: r.error ?? null, elapsed: r.elapsed ?? 0 }; }
function basename(p) { return p.split('/').pop(); }
function listScripts() {
  try {
    return readdirSync(SCRIPTS_DIR).filter((f) => f.endsWith('.txt'))
      .map((f) => ({ name: f, mtime: Date.now() }));
  } catch { return []; }
}
function safeScriptPath(name) {
  const safe = String(name || '').replace(/[^\w\u4e00-\u9fa5.-]/g, '_');
  if (!safe) return null;
  const file = join(SCRIPTS_DIR, safe.endsWith('.txt') ? safe : safe + '.txt');
  return file.startsWith(SCRIPTS_DIR) ? file : null;
}
