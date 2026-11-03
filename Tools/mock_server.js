#!/usr/bin/env node
/**
 * IUIAuto 控制服务器模拟器
 *
 * 用法:
 *   npm install          # 首次
 *   node mock_server.js              # 交互模式：等待 App 连接后键入指令
 *   node mock_server.js --demo       # 自动演示模式：App 连上后自动执行全流程验证
 *
 * 交互模式指令示例:
 *   ping
 *   tap 100 200                    # 坐标点击
 *   tapv btn.counter               # 按 identifier 点击
 *   dtap 100 200                   # 双击
 *   press 100 200 1.0              # 长按 1s
 *   swipe 200 600 200 200          # 滑动(上滑)
 *   text field.input 你好IUIAuto   # 按 identifier 输入文本
 *   textfirst 直接当前焦点输入      # 当前 firstResponder 输入
 *   clear field.input              # 清空输入框
 *   tree                           # 打印 view 树(截断)
 *   info btn.counter               # 查询元素信息
 *   shot [quality]                 # 截图保存 shot.png
 *   wait 2                         # 等待 2s
 *   quit
 */

import { WebSocketServer } from 'ws';
import { createInterface } from 'node:readline';
import { writeFileSync } from 'node:fs';
import { stepsToDSL } from './iua_dsl.js';
import { ensurePortFree, handleListenError } from './iua_ports.js';

const PORT = process.env.PORT || 9800;
const DEMO = process.argv.includes('--demo');

let socket = null;
let seq = 0;
let demoStarted = false;
const pending = new Map(); // id -> {resolve, timer}

// 端口占用时友好提示 / --takeover 自动接管
await ensurePortFree(PORT, { takeover: process.argv.includes('--takeover'), label: '服务端口' });

const wss = new WebSocketServer({ port: PORT, path: '/ws' });
wss.on('error', (e) => handleListenError(e, PORT));
console.log(`[mock-server] listening on ws://0.0.0.0:${PORT}/ws`);

// 等待 App 提示（避免无提示干等）
const connectHint = setTimeout(() => {
  console.log('\n⚠ 15 秒了 App 还没连上，请检查：');
  console.log('  · 模拟器与 App 是否在运行 → ./build.sh 或 ./start.sh 可自动拉起');
  console.log('  · App 状态页显示的地址是否为本机 9800（卸载重装 App 可恢复默认）');
  console.log('  · 端口是否被其他工具占用 → 加 --takeover 接管');
  console.log('  · 模拟器窗口失焦过久会冻结 App（App Nap）→ 点一下模拟器窗口或 open -a Simulator 唤醒\n');
}, 15000);

wss.on('connection', (ws, req) => {
  clearTimeout(connectHint);
  console.log(`[mock-server] App 已连接 (${req.socket.remoteAddress})`);
  socket = ws;

  ws.on('message', (data) => {
    let msg;
    try { msg = JSON.parse(data.toString()); } catch { console.log('[recv][非JSON]', data.toString().slice(0, 200)); return; }
    onMessage(msg);
  });

  ws.on('close', () => {
    console.log('[mock-server] App 已断开');
    socket = null;
  });

  ws.on('error', (e) => console.log('[mock-server] 连接错误:', e.message));

  if (DEMO) {
    if (demoStarted) { console.log('[mock-server] 忽略重复触发的 demo'); return; }
    demoStarted = true;
    setTimeout(runDemo, 1500);   // 给冷启动 App 的 UI 布局留余量
  } else {
    console.log('\n输入指令（help 查看示例）:');
  }
});

function onMessage(msg) {
  if (msg.type === 'result') {
    const entry = pending.get(msg.id);
    if (entry) {
      clearTimeout(entry.timer);
      pending.delete(msg.id);
      entry.resolve(msg);
    } else {
      console.log('[recv][迟到结果]', JSON.stringify(msg).slice(0, 300));
    }
    return;
  }
  if (msg.type === 'hello') {
    console.log('[recv][hello]', JSON.stringify({
      agent: msg.agent, version: msg.version,
      environment: msg.environment,
      actions: msg.actions,
    }, null, 2));
    return;
  }
  if (msg.type === 'pong') {
    console.log('[recv][pong]', new Date(msg.timestamp).toISOString());
    return;
  }
  if (msg.type === 'log') {
    console.log(`[app-log][${['debug','info','warn','error'][msg.level] ?? msg.level}] ${msg.message}`);
    return;
  }
  console.log('[recv]', JSON.stringify(msg).slice(0, 300));
}

/** 下发指令并等待结果 */
function send(action, params = {}, timeoutSec = 15) {
  return new Promise((resolve) => {
    if (!socket || socket.readyState !== 1) {
      resolve({ ok: false, error: 'App 未连接' });
      return;
    }
    const id = `cmd-${++seq}`;
    const timer = setTimeout(() => {
      pending.delete(id);
      resolve({ ok: false, error: `本地等待超时 ${timeoutSec}s` });
    }, timeoutSec * 1000);
    pending.set(id, { resolve, timer });
    const payload = JSON.stringify({ id, action, params, timeout: timeoutSec });
    socket.send(payload);
    console.log(`\n[send] ${payload.slice(0, 160)}`);
  });
}

// ---------------------------------------------------------------------------
// 交互模式
// ---------------------------------------------------------------------------
const HELP = `指令: ping | tap x y | tapv identifier | dtap x y | press x y dur |
      swipe fx fy tx ty | text identifier 文本 | textfirst 文本 | clear identifier |
      tree | info identifier | shot [0|1|2] | wait 秒 |
      rec start | rec stop [文件]   （录制手工操作为 DSL 脚本）
      quit`

const rl = createInterface({ input: process.stdin, output: process.stdout, prompt: 'cmd> ' });

rl.on('line', async (line) => {
  const parts = line.trim().split(/\s+/);
  const [cmd, ...args] = parts;
  if (!cmd) return;
  try {
    switch (cmd) {
      case 'help': console.log(HELP); break;
      case 'ping': console.log(resultLine(await send('ping'))); break;
      case 'tap': console.log(resultLine(await send('tap', { x: +args[0], y: +args[1] }))); break;
      case 'tapv': console.log(resultLine(await send('tap_view', { identifier: args[0] }))); break;
      case 'dtap': console.log(resultLine(await send('double_tap', { x: +args[0], y: +args[1] }))); break;
      case 'press': console.log(resultLine(await send('long_press', { x: +args[0], y: +args[1], duration: +args[2] || 0.8 }))); break;
      case 'swipe': console.log(resultLine(await send('swipe', { fromX: +args[0], fromY: +args[1], toX: +args[2], toY: +args[3], duration: +args[4] || 0.4 }))); break;
      case 'text': console.log(resultLine(await send('type_text', { identifier: args[0], text: args.slice(1).join(' ') }))); break;
      case 'textfirst': console.log(resultLine(await send('type_text', { text: args.join(' ') }))); break;
      case 'clear': console.log(resultLine(await send('clear_text', { identifier: args[0] }))); break;
      case 'rec': {
        if (args[0] === 'start') {
          console.log(resultLine(await send('record_start')));
        } else if (args[0] === 'stop') {
          const r = await send('record_stop');
          if (r.ok) {
            const steps = r.data.steps ?? [];
            const dsl = stepsToDSL(steps);
            const file = args[1] || 'recorded.txt';
            writeFileSync(file, dsl);
            console.log(`已录制 ${steps.length} 步 → ${file}\n${dsl}`);
          } else { console.log(resultLine(r)); }
        } else {
          console.log('用法: rec start | rec stop [文件名]');
        }
        break;
      }
      case 'tree': {
        const r = await send('view_tree', { maxDepth: 6 });
        console.log(JSON.stringify(r.data?.windows?.map(w => summarizeTree(w)).filter(Boolean), null, 2));
        break;
      }
      case 'info': console.log(JSON.stringify((await send('element_info', { identifier: args[0] })).data, null, 2)); break;
      case 'shot': {
        const r = await send('screenshot', { quality: +(args[0] ?? 1) });
        if (r.ok) {
          writeFileSync('shot.png', Buffer.from(r.data.image, 'base64'));
          console.log(`已保存 shot.png (${r.data.width}x${r.data.height}, ${(r.data.bytes / 1024).toFixed(0)}KB)`);
        } else { console.log(resultLine(r)); }
        break;
      }
      case 'wait': await new Promise(r => setTimeout(r, (+args[0] || 1) * 1000)); break;
      case 'quit': process.exit(0); break;
      default: console.log('未知指令，' + HELP);
    }
  } catch (e) {
    console.log('执行出错:', e.message);
  }
  rl.prompt();
});

function resultLine(r) {
  return r.ok ? `  ✓ ok (${r.elapsed}s) data=${JSON.stringify(r.data).slice(0, 200)}`
              : `  ✗ 失败: ${r.error} (${r.elapsed}s)`;
}

function summarizeTree(node, depth = 0) {
  if (!node || depth > 4) return null;
  return {
    id: node.identifier || undefined,
    cls: node.class,
    text: node.text?.slice?.(0, 20) || undefined,
    frame: node.frame,
    children: (node.children || []).slice(0, 25).map(c => summarizeTree(c, depth + 1)).filter(Boolean),
  };
}

// ---------------------------------------------------------------------------
// 自动演示模式（端到端闭环验证）
// ---------------------------------------------------------------------------
async function runDemo() {
  console.log('\n========== 自动演示开始 ==========\n');
  const results = [];
  const check = (name, cond, detail = '') => {
    results.push({ name, pass: !!cond });
    console.log(`${cond ? '✓' : '✗'} ${name} ${detail}`);
  };

  const wait = (s) => new Promise(r => setTimeout(r, s * 1000));
  const info = async (id) => (await send('element_info', { identifier: id })).data;

  // 1. ping
  const ping = await send('ping');
  check('ping', ping.ok);

  // 2. 读取按钮初始计数
  const before = await info('label.counter');
  const countBefore = parseInt((before?.text || '').replace(/\D+/g, ''), 10) || 0;
  check('element_info 读取计数(前)', before != null, `text="${before?.text}"`);

  // 3. 按 identifier 点击计数按钮（触控合成）
  const tap = await send('tap_view', { identifier: 'btn.counter' });
  check('tap_view btn.counter', tap.ok);
  await wait(0.5);

  // 4. 再坐标点击一次（用 element_info 拿坐标）
  const btn = tap.ok ? await info('btn.counter') : null;
  if (!btn) {
    check('tap 坐标点击', false, 'btn.counter 不可用，跳过');
    finishDemo(results);
    return;
  }
  const cx = btn.frame.x + btn.frame.width / 2, cy = btn.frame.y + btn.frame.height / 2;
  const tap2 = await send('tap', { x: cx, y: cy });
  check('tap 坐标点击', tap2.ok, `(${cx.toFixed(0)},${cy.toFixed(0)})`);
  await wait(0.5);

  // 5. 验证计数 +2
  const after = await info('label.counter');
  const countAfter = parseInt((after?.text || '').replace(/\D+/g, ''), 10) || 0;
  check('计数 +2（触控真实生效）', countAfter === countBefore + 2, `${before?.text} → ${after?.text}`);

  // 6. 文本输入（先清空，保证断言不受残留内容影响）
  await send('clear_text', { identifier: 'field.input' });
  const typed = await send('type_text', { identifier: 'field.input', text: '自动化输入ABC123' });
  check('type_text', typed.ok);
  await wait(0.3);
  const field = await info('field.input');
  check('输入内容可见', field?.text === '自动化输入ABC123', `text="${field?.text}"`);

  // 7. 点击提交按钮 → label.output 更新
  const submit = await send('tap_view', { identifier: 'btn.submit' });
  check('tap_view btn.submit', submit.ok);
  await wait(0.4);
  const output = await info('label.output');
  check('提交联动生效', (output?.text || '').includes('自动化输入ABC123'), `text="${output?.text}"`);

  // 8. 滑动滚动列表
  const swipe = await send('swipe', { fromX: 200, fromY: 620, toX: 200, toY: 300, duration: 0.4 });
  check('swipe 上滑', swipe.ok);
  await wait(0.5);

  // 9. 截图
  const shot = await send('screenshot', { quality: 0 });
  if (shot.ok) {
    writeFileSync('shot.png', Buffer.from(shot.data.image, 'base64'));
    check('screenshot', shot.data.image.length > 1000, `${shot.data.width}x${shot.data.height}, ${(shot.data.bytes / 1024).toFixed(0)}KB → shot.png`);
  } else {
    check('screenshot', false, shot.error);
  }

  // 10. view_tree
  const tree = await send('view_tree', { maxDepth: 3 });
  check('view_tree', tree.ok && Array.isArray(tree.data?.windows));

  finishDemo(results);
}

function finishDemo(results) {
  const passed = results.filter(r => r.pass).length;
  console.log(`\n========== 演示结束: ${passed}/${results.length} 通过 ==========`);
  console.log(passed === results.length ? 'ALL PASS ✅' : 'SOME FAILED ❌');
  process.exit(passed === results.length ? 0 : 1);
}
