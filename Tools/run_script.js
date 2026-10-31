#!/usr/bin/env node
/**
 * IUIAuto 脚本执行器 / 录制器（独立控制服务器，监听 9800，等待 App 连接）
 *
 * 用法:
 *   node run_script.js <脚本文件>            # 执行 DSL 脚本（断言+报告，exit code 0/1）
 *   node run_script.js --record <输出文件>   # 录制模式：连上后发 record_start，
 *                                            # 真机/模拟器上手工操作，回车停止并保存 DSL
 *   node run_script.js --demo-check          # 无参自检：解析内置示例脚本（不连 App）
 *
 * 与 mock_server.js 不同时运行（共用 9800 端口）。
 */

import { WebSocketServer } from 'ws';
import { createInterface } from 'node:readline';
import { readFileSync, writeFileSync } from 'node:fs';
import { parseScript, stepsToDSL, DSL_HELP } from './iua_dsl.js';

const PORT = process.env.PORT || 9800;
const args = process.argv.slice(2);

// ---------------------------------------------------------------- 自检模式
if (args[0] === '--demo-check') {
  const demo = `
# 示例脚本
点击 btn.counter
点击 201 314
输入 field.input 你好 IUIAuto 世界
清空 field.input
滑动 200 600 200 300 0.4
捏合 200 400 150 30
等待 1
截图 demo.png
断言文本 label.counter 包含 Count: 2
断言文本 label.counter 等于 Count: 2
断言存在 btn.submit
断言不存在 btn.notexist
`;
  const steps = parseScript(demo);
  console.log(`解析出 ${steps.length} 步:`);
  steps.forEach(s => console.log(' ', JSON.stringify(s)));
  process.exit(0);
}

// ---------------------------------------------------------------- 参数
let scriptFile = null, recordFile = null;
if (args[0] === '--record') {
  recordFile = args[1] || 'recorded.txt';
} else {
  scriptFile = args[0];
  if (!scriptFile) {
    console.log('用法: node run_script.js <脚本文件>\n      node run_script.js --record [输出文件]\n\n' + DSL_HELP);
    process.exit(2);
  }
}

// ---------------------------------------------------------------- 连接层
let socket = null;
let seq = 0;
const pending = new Map();
const results = [];
let finished = false;

function finish(code) {
  finished = true;
  try { socket?.close(); } catch {}
  process.exit(code);
}

const wss = new WebSocketServer({ port: PORT, path: '/ws' });
console.log(`[run_script] 监听 ws://0.0.0.0:${PORT}/ws，等待 App 连接…（App 会自动重连过来）`);
wss.on('connection', (ws) => {
  socket = ws;
  console.log('[run_script] App 已连接');
  ws.on('message', (data) => {
    let msg; try { msg = JSON.parse(data.toString()); } catch { return; }
    if (msg.type === 'result') {
      const entry = pending.get(msg.id);
      if (entry) { clearTimeout(entry.timer); pending.delete(msg.id); entry.resolve(msg); }
    }
  });
  ws.on('close', () => { socket = null; if (!finished) console.log('[run_script] App 断开（等待重连…）'); });
  setTimeout(() => recordFile ? runRecord() : runScript(), 600);
});

function send(action, params = {}, timeoutSec = 20) {
  return new Promise((resolve) => {
    if (!socket || socket.readyState !== 1) { resolve({ ok: false, error: 'App 未连接' }); return; }
    const id = `s-${++seq}`;
    const timer = setTimeout(() => { pending.delete(id); resolve({ ok: false, error: `超时 ${timeoutSec}s` }); }, timeoutSec * 1000);
    pending.set(id, { resolve, timer });
    socket.send(JSON.stringify({ id, action, params, timeout: timeoutSec }));
  });
}

// ---------------------------------------------------------------- 断言
async function runAssert(step) {
  const { kind, identifier, value } = step;
  if (kind === 'exists' || kind === 'missing') {
    const r = await send('element_info', { identifier });
    return kind === 'exists'
      ? { pass: r.ok, detail: r.ok ? '存在' : '不存在' }
      : { pass: !r.ok, detail: r.ok ? '仍存在' : '不存在' };
  }
  // 文本断言
  const r = await send('element_info', { identifier });
  if (!r.ok) return { pass: false, detail: `元素不存在` };
  const text = r.data?.text ?? '';
  return kind === 'text_contains'
    ? { pass: text.includes(value), detail: `实际="${text}"` }
    : { pass: text === value, detail: `实际="${text}" 期望="${value}"` };
}

// ---------------------------------------------------------------- 执行脚本
async function runScript() {
  let steps;
  try {
    steps = parseScript(readFileSync(scriptFile, 'utf8'));
  } catch (e) {
    console.error(`脚本解析失败: ${e.message}`);
    finish(2);
    return;
  }
  console.log(`\n执行 ${scriptFile}（${steps.length} 步）\n${'='.repeat(56)}`);

  const sleep = (s) => new Promise(r => setTimeout(r, s * 1000));
  for (const step of steps) {
    const tag = `L${String(step.line).padStart(3)}`;
    if (step.type === 'action') {
      const r = await send(step.action, step.params);
      const pass = r.ok;
      results.push({ line: step.line, desc: `${step.action} ${JSON.stringify(step.params)}`, pass, detail: r.error || '' });
      console.log(`${pass ? '✓' : '✗'} ${tag} ${step.action} ${JSON.stringify(step.params).slice(0, 60)} ${pass ? '' : '— ' + r.error}`);
      if (!pass) { await saveShot('fail.png'); break; }
    } else if (step.type === 'shot') {
      const r = await send('screenshot', step.params);
      if (r.ok) { writeFileSync(step.file, Buffer.from(r.data.image, 'base64')); }
      results.push({ line: step.line, desc: `截图 → ${step.file}`, pass: r.ok, detail: '' });
      console.log(`${r.ok ? '✓' : '✗'} ${tag} 截图 → ${step.file}${r.ok ? ` (${r.data.width|0}x${r.data.height|0})` : ' — ' + r.error}`);
    } else if (step.type === 'assert') {
      const a = await runAssert(step);
      results.push({ line: step.line, desc: `断言 ${step.kind} ${step.identifier} ${step.value ?? ''}`, pass: a.pass, detail: a.detail });
      console.log(`${a.pass ? '✓' : '✗'} ${tag} 断言 ${step.kind} ${step.identifier} ${step.value ?? ''} ${a.pass ? '' : '— ' + a.detail}`);
      if (!a.pass) { await saveShot('fail.png'); break; }
    }
    await sleep(0.15);
  }

  const passed = results.filter(r => r.pass).length;
  console.log('='.repeat(56));
  console.log(`结果: ${passed}/${results.length} 步通过 ${passed === results.length ? '✅ PASS' : '❌ FAIL'}`);
  finish(passed === results.length && results.length > 0 ? 0 : 1);
}

async function saveShot(file) {
  const r = await send('screenshot', { quality: 1 });
  if (r.ok) { writeFileSync(file, Buffer.from(r.data.image, 'base64')); console.log(`  失败现场已截图 → ${file}`); }
}

// ---------------------------------------------------------------- 录制模式
async function runRecord() {
  const start = await send('record_start');
  if (!start.ok) { console.error('record_start 失败:', start.error); finish(1); return; }
  console.log(`\n● 录制中 — 请在 App 里手工操作（点击/滑动/输入）`);
  console.log(`  完成后按 回车 停止录制\n`);

  await new Promise((resolve) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout });
    rl.once('line', () => { rl.close(); resolve(); });
  });

  const stop = await send('record_stop');
  if (!stop.ok) { console.error('record_stop 失败:', stop.error); finish(1); return; }
  const steps = stop.data?.steps ?? [];
  const dsl = stepsToDSL(steps);
  writeFileSync(recordFile, dsl);
  console.log(`\n已录制 ${steps.length} 步，DSL 已保存 → ${recordFile}\n`);
  console.log(dsl);
  finish(0);
}
