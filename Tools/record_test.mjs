#!/usr/bin/env node
/**
 * 录制功能端到端验证：
 * 1. 连接 App → record_start
 * 2. 下发合成操作（tap×2 / type_text / swipe）——合成事件经 deliverTouches 钩子被录制
 * 3. record_stop → 校验录制步骤的数量与内容
 * 4. 生成 recorded_demo.txt（纯录制 DSL）与 replay_check.txt（录制 DSL + 断言，供 run_script.js 回放）
 */
import { WebSocketServer } from 'ws';
import { writeFileSync } from 'node:fs';
import { stepsToDSL } from './iua_dsl.js';

let socket = null, seq = 0;
const pending = new Map();

const wss = new WebSocketServer({ port: 9800, path: '/ws' });
console.log('[record_test] 监听 9800，等待 App 连接…');
const connectHint = setTimeout(() => {
  console.log('\n⚠ 15 秒了 App 还没连上：./build.sh 或 ./start.sh 可自动拉起模拟器与 App');
  console.log('  · 模拟器窗口失焦过久会冻结 App（App Nap）→ 点一下模拟器窗口唤醒\n');
}, 15000);
let flowStarted = false;
wss.on('connection', (ws) => {
  clearTimeout(connectHint);
  // App 启动初期的连接风暴（旧 client 断开+新 client 建立）不应让流程跑两遍
  if (flowStarted) {
    console.log('[record_test] 忽略重复连接（流程已在执行）');
    try { ws.close(); } catch {}
    return;
  }
  console.log('[record_test] App 已连接');
  socket = ws;
  ws.on('message', (data) => {
    let msg; try { msg = JSON.parse(data.toString()); } catch { return; }
    if (msg.type === 'result') {
      const e = pending.get(msg.id);
      if (e) { clearTimeout(e.timer); pending.delete(msg.id); e.resolve(msg); }
    }
  });
  setTimeout(main, 800);
});

const sleep = (s) => new Promise(r => setTimeout(r, s * 1000));
const send = (action, params = {}, timeoutSec = 15) => new Promise((resolve) => {
  if (!socket) { resolve({ ok: false, error: '未连接' }); return; }
  const id = `rt-${++seq}`;
  const timer = setTimeout(() => { pending.delete(id); resolve({ ok: false, error: 'timeout' }); }, timeoutSec * 1000);
  pending.set(id, { resolve, timer });
  socket.send(JSON.stringify({ id, action, params, timeout: timeoutSec }));
});

async function main() {
  flowStarted = true;
  const checks = [];
  const check = (name, cond, detail = '') => {
    checks.push(cond);
    console.log(`${cond ? '✓' : '✗'} ${name} ${detail}`);
  };

  // 预置：清空输入框（避免回放时文本叠加）
  await send('clear_text', { identifier: 'field.input' });

  // 1. 开始录制
  const start = await send('record_start');
  check('record_start', start.ok);

  // 2. 合成操作序列（应全部被录制）
  await send('tap_view', { identifier: 'btn.counter' }); await sleep(0.4);
  await send('tap_view', { identifier: 'btn.counter' }); await sleep(0.4);
  await send('type_text', { identifier: 'field.input', text: '录制内容测试' }); await sleep(0.5);
  await send('swipe', { fromX: 200, fromY: 620, toX: 200, toY: 340, duration: 0.4 }); await sleep(0.8);

  // 3. 停止录制并校验
  const stop = await send('record_stop');
  check('record_stop', stop.ok);
  const steps = stop.data?.steps ?? [];
  console.log('\n录制步骤:');
  steps.forEach((s, i) => console.log(`  ${i + 1}. ${JSON.stringify(s)}`));
  console.log('');

  const taps = steps.filter(s => s.action === 'tap' && s.identifier === 'btn.counter');
  const types = steps.filter(s => s.action === 'type_text' && s.identifier === 'field.input' && s.text === '录制内容测试');
  const swipes = steps.filter(s => s.action === 'swipe');
  check('录到 2 次 btn.counter 点击', taps.length === 2, `实际 ${taps.length}`);
  check('录到 type_text(field.input)', types.length === 1, `实际 ${types.length}`);
  check('录到 swipe', swipes.length === 1, `实际 ${swipes.length}`);
  check('总步骤 = 4', steps.length === 4, `实际 ${steps.length}`);

  // 4. 生成 DSL
  const dsl = stepsToDSL(steps);
  writeFileSync('recorded_demo.txt', dsl);
  console.log('\nrecorded_demo.txt:\n' + dsl);

  // 回放校验脚本：录制 DSL + 断言（录制已把计数点到 2，回放再 +2 → Count: 4）
  const replay = dsl + '\n断言文本 label.counter 包含 Count: 4\n断言存在 field.input\n';
  writeFileSync('replay_check.txt', replay);
  console.log('replay_check.txt 已生成');

  const passed = checks.filter(Boolean).length;
  console.log(`\n录制验证: ${passed}/${checks.length} 通过`);
  process.exit(passed === checks.length ? 0 : 1);
}
