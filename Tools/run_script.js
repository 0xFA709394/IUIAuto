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
import { runSteps } from './iua_runner.js';
import { startXctraceRecording, perfText } from './iua_perf.js';
import { ensurePortFree, handleListenError } from './iua_ports.js';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const execFileAsync = promisify(execFile);

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
// 用法: run_script.js [--perf] [--xctrace[=模板]] [--device UDID] <脚本文件|--record 文件>
let scriptFile = null, recordFile = null;
let perfEnabled = false, xctraceTemplate = null, deviceUDID = null;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  if (a === '--perf') perfEnabled = true;
  else if (a === '--xctrace') xctraceTemplate = 'Time Profiler';
  else if (a.startsWith('--xctrace=')) xctraceTemplate = a.slice('--xctrace='.length) || 'Time Profiler';
  else if (a.startsWith('--device=')) deviceUDID = a.slice('--device='.length);
  else if (a === '--record') recordFile = args[++i] || 'recorded.txt';
  else if (!scriptFile && !a.startsWith('--')) scriptFile = a;
}
if (!scriptFile && !recordFile) {
  console.log('用法: node run_script.js [选项] <脚本文件>');
  console.log('      node run_script.js --record [输出文件]');
  console.log('选项: --perf            运行期间采样 App CPU/内存/FPS，报告性能摘要');
  console.log('      --xctrace[=模板]  同步用 xctrace 录制 .trace（默认 Time Profiler）');
  console.log('      --device=UDID     xctrace 目标设备（默认自动探测已启动的模拟器）\n' + DSL_HELP);
  process.exit(2);
}

/** 自动探测已启动的模拟器 UDID */
async function detectBootedSimulator() {
  const { stdout } = await execFileAsync('xcrun', ['simctl', 'list', 'devices', 'booted'], {
    env: { ...process.env, DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer' },
  });
  const m = stdout.match(/\(([0-9A-F-]{36})\)/);
  return m ? m[1] : null;
}

// ---------------------------------------------------------------- 连接层
let socket = null;
let seq = 0;
const pending = new Map();
let finished = false;

function finish(code) {
  finished = true;
  try { socket?.close(); } catch {}
  process.exit(code);
}

// 端口占用时友好提示 / --takeover 自动接管
await ensurePortFree(PORT, { takeover: process.argv.includes('--takeover'), label: '服务端口' });

const wss = new WebSocketServer({ port: PORT, path: '/ws' });
wss.on('error', (e) => handleListenError(e, PORT));
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
  console.log(`\n执行 ${scriptFile}（${steps.length} 步）${perfEnabled || xctraceTemplate ? ' [性能监测开启]' : ''}\n${'='.repeat(56)}`);

  // ---- 性能监测：App 端采样（可靠数据源）----
  if (perfEnabled) {
    const r = await send('perf_start', { interval: 0.5 });
    console.log(r.ok ? '◉ App 性能采样已启动（CPU/内存/FPS，0.5s 周期）' : `✗ App 采样启动失败: ${r.error}`);
  }

  // ---- 性能监测：xctrace 宿主侧录制（深度分析，环境受限时自动降级）----
  let xctraceSession = null, xctraceReady = false;
  if (xctraceTemplate) {
    const udid = deviceUDID || await detectBootedSimulator();
    if (!udid) {
      console.log('◉ xctrace: 未探测到已启动的模拟器设备（--device=UDID 指定）');
    } else {
      xctraceSession = startXctraceRecording({
        deviceUDID: udid, processName: 'IUIAuto', template: xctraceTemplate,
        outputDir: new URL('.', import.meta.url).pathname + 'traces',
      });
      console.log(`◉ xctrace 录制启动中（模板: ${xctraceTemplate}）…`);
      const ready = await xctraceSession.waitUntilRecording(30000);
      xctraceReady = ready.ok;
      console.log(ready.ok ? '◉ xctrace 已进入录制状态' : `◉ xctrace 不可用，已降级跳过: ${ready.reason}`);
      if (!ready.ok) { xctraceSession.abort(); xctraceSession = null; }
    }
  }

  const outcome = await runSteps(steps, send,
    (r) => console.log(`${r.pass ? '✓' : '✗'} L${String(r.line).padStart(3)} ${r.desc} ${r.pass ? '' : '— ' + r.detail}`),
    { shotSaver: async (file, base64) => writeFileSync(file, Buffer.from(base64, 'base64')) });

  if (!outcome.ok) await saveShot('fail.png');

  // ---- 收集性能数据（先停 App 采样，再停 xctrace）----
  let perfData = null;
  if (perfEnabled) {
    const r = await send('perf_stop');
    if (r.ok) perfData = r.data;
  }
  let xctraceResult = null;
  if (xctraceSession) {
    console.log('◉ 正在停止 xctrace 并保存 trace…');
    xctraceResult = await xctraceSession.stop();
  }

  // ---- 报告 ----
  console.log('='.repeat(56));
  console.log(`结果: ${outcome.passed}/${outcome.total} 步通过 ${outcome.ok ? '✅ PASS' : '❌ FAIL'}`);

  if (perfData) {
    console.log('\n── 性能摘要（App 内采样）─────────────────────');
    console.log(`时长 ${perfData.duration}s / ${perfData.sampleCount} 点`);
    const fmt = (s) => s ? `min ${s.min} | avg ${s.avg} | p95 ${s.p95} | max ${s.max}` : '无数据';
    console.log(`CPU%       ${fmt(perfData.cpuPercent)}`);
    console.log(`系统CPU%   ${fmt(perfData.cpuSystemPercent)}`);
    console.log(`物理内存MB ${fmt(perfData.memoryMB)}`);
    console.log(`FPS        ${fmt(perfData.fps)}`);
  }
  if (xctraceResult) {
    console.log('\n── xctrace 录制 ───────────────────────────────');
    if (xctraceResult.tracePath) {
      console.log(`trace 文件: ${xctraceResult.tracePath}（${xctraceResult.sizeMB}MB，可用 Instruments 打开分析）`);
    }
    if (xctraceResult.summary) console.log(perfText('导出摘要', xctraceResult.summary));
    if (xctraceResult.reason) console.log(`状态: ${xctraceResult.reason}`);
  }
  finish(outcome.ok ? 0 : 1);
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
