#!/usr/bin/env node
/**
 * IUIAuto GUI 控制台服务器
 *
 *   node gui_server.js            # 默认 HTTP :9900（浏览器），App 连 ws://...:9800/ws
 *   PORT=9900 APP_PORT=9800 node gui_server.js
 *
 * 职责：
 *   - HTTP 托管 gui.html（单文件控制台页面）
 *   - /ws   浏览器 WebSocket（控制协议）
 *   - /app  App WebSocket（同 mock_server 的指令协议，9800 端口独立路径）
 *   - Tools/scripts/ 下的 DSL 脚本存储（列表/保存/读取/删除）
 *   - 复用 iua_runner.runSteps 执行脚本，进度实时推给浏览器
 */

import { createServer } from 'node:http';
import { readFileSync, writeFileSync, readdirSync, unlinkSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocketServer } from 'ws';
import { parseScript, stepsToDSL, DSL_HELP } from './iua_dsl.js';
import { runSteps } from './iua_runner.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const HTTP_PORT = +(process.env.PORT || 9900);
const APP_PORT = +(process.env.APP_PORT || 9800);
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
    appSocket.send(JSON.stringify({ id, action, params, timeout: timeoutSec }));
  });
}

const appWss = new WebSocketServer({ port: APP_PORT, path: '/ws' });
console.log(`[gui] App 端口 ws://0.0.0.0:${APP_PORT}/ws（等待 App 连接）`);

appWss.on('connection', (ws) => {
  console.log('[gui] App 已连接');
  appSocket = ws;
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
  ws.on('close', () => {
    console.log('[gui] App 断开（等待重连…）');
    appSocket = null;
    appHello = null;
    broadcast({ type: 'app_state', connected: false, hello: null });
  });
});

// ---------------------------------------------------------------- 浏览器连接与控制协议
const browserSockets = new Set();
let running = false;

function broadcast(obj) {
  const text = JSON.stringify(obj);
  for (const ws of browserSockets) { if (ws.readyState === 1) ws.send(text); }
}

const httpServer = createServer((req, res) => {
  if (req.url === '/' || req.url === '/index.html') {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
    res.end(readFileSync(join(__dirname, 'gui.html')));
  } else {
    res.writeHead(404); res.end();
  }
});

const browserWss = new WebSocketServer({ server: httpServer, path: '/ws' });
browserWss.on('connection', (ws) => {
  browserSockets.add(ws);
  console.log('[gui] 浏览器已连接');
  ws.send(JSON.stringify({ type: 'app_state', connected: !!appSocket, hello: appHello }));
  ws.send(JSON.stringify({ type: 'dsl_help', text: DSL_HELP }));

  ws.on('message', async (data) => {
    let msg; try { msg = JSON.parse(data.toString()); } catch { return; }
    try {
      switch (msg.type) {
        case 'send': { // 手动下发一条指令
          const r = await sendToApp(msg.action, msg.params ?? {}, msg.timeout ?? 20);
          ws.send(JSON.stringify({ type: 'result', action: msg.action, echo: msg.echo, ...pick(r) }));
          break;
        }
        case 'record_stop': {
          const r = await sendToApp('record_stop');
          ws.send(JSON.stringify({ type: 'record_result', ...pick(r), steps: r.data?.steps ?? [] }));
          break;
        }
        case 'record_save': { // 录制步骤（或当前编辑内容）保存为脚本
          const safe = String(msg.name || '').replace(/[^\w\u4e00-\u9fa5.-]/g, '_');
          if (!safe) { ws.send(JSON.stringify({ type: 'rpc_error', error: '文件名无效' })); break; }
          const file = join(SCRIPTS_DIR, safe.endsWith('.txt') ? safe : safe + '.txt');
          writeFileSync(file, String(msg.content ?? ''), 'utf8');
          ws.send(JSON.stringify({ type: 'rpc_ok', message: `已保存 ${basename(file)}` }));
          broadcast({ type: 'dsl_list', files: listScripts() });
          break;
        }
        case 'dsl_list':
          ws.send(JSON.stringify({ type: 'dsl_list', files: listScripts() }));
          break;
        case 'dsl_read': {
          const file = safeScriptPath(msg.name);
          if (!file) { ws.send(JSON.stringify({ type: 'dsl_content', name: msg.name, error: '文件名无效', content: '' })); break; }
          ws.send(JSON.stringify({ type: 'dsl_content', name: msg.name, content: readFileSync(file, 'utf8') }));
          break;
        }
        case 'dsl_delete': {
          const file = safeScriptPath(msg.name);
          if (file && existsSync(file)) unlinkSync(file);
          ws.send(JSON.stringify({ type: 'rpc_ok', message: `已删除 ${msg.name}` }));
          broadcast({ type: 'dsl_list', files: listScripts() });
          break;
        }
        case 'dsl_steps_to_text': {
          // 录制步骤（JSON）→ DSL 文本（浏览器也可自己转，统一在服务端做）
          ws.send(JSON.stringify({ type: 'dsl_text', text: stepsToDSL(msg.steps ?? []) }));
          break;
        }
        case 'run': {
          if (running) { ws.send(JSON.stringify({ type: 'run_done', passed: 0, total: 0, ok: false, error: '已有脚本在运行' })); break; }
          let steps;
          try {
            steps = parseScript(String(msg.content ?? ''));
          } catch (e) {
            ws.send(JSON.stringify({ type: 'run_done', passed: 0, total: 0, ok: false, error: `脚本解析失败: ${e.message}` }));
            break;
          }
          running = true;
          broadcast({ type: 'run_start', total: steps.length });
          const outcome = await runSteps(steps, sendToApp, (r) => broadcast({ type: 'run_progress', ...r }));
          running = false;
          // 失败时抓现场截图推给浏览器
          let failShot = null;
          if (!outcome.ok) {
            const s = await sendToApp('screenshot', { quality: 1 });
            if (s.ok) failShot = `data:image/png;base64,${s.data.image}`;
          }
          broadcast({ type: 'run_done', passed: outcome.passed, total: outcome.total, ok: outcome.ok, failShot });
          break;
        }
        default:
          break;
      }
    } catch (e) {
      ws.send(JSON.stringify({ type: 'rpc_error', error: e.message }));
    }
  });

  ws.on('close', () => browserSockets.delete(ws));
});

httpServer.listen(HTTP_PORT, () => {
  console.log(`[gui] 控制台已启动: http://localhost:${HTTP_PORT}`);
});

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
