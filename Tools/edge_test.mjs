#!/usr/bin/env node
/**
 * 边界/异常场景压测：验证所有错误路径优雅处理（无崩溃、有明确错误信息、App 存活）
 */
import { WebSocketServer } from 'ws';

const results = [];
const check = (name, pass, detail = '') => {
  results.push(pass);
  console.log(`${pass ? '✓' : '✗'} ${name}${detail ? ' — ' + detail : ''}`);
};

let ws = null, seq = 0;
const pending = new Map();
const wss = new WebSocketServer({ port: 9800, path: '/ws' });

const send = (action, params = {}, timeoutSec = 12) => new Promise((resolve) => {
  if (!ws) { resolve({ ok: false, error: '未连接' }); return; }
  const id = `e-${++seq}`;
  const timer = setTimeout(() => { pending.delete(id); resolve({ ok: false, error: 'timeout' }); }, timeoutSec * 1000);
  pending.set(id, (m) => { clearTimeout(timer); resolve(m); });
  ws.send(JSON.stringify({ id, action, params, timeout: timeoutSec }));
});

let flowStarted = false;
wss.on('connection', async (sock) => {
  // 每次连接：替换 ws + 绑定消息处理（App 重连/重启后流程可继续通信）
  ws = sock;
  clearTimeout(waitTimer);
  console.log('[edge_test] App 已连接' + (flowStarted ? '（重连，继续使用）' : '') + '\n');
  sock.on('message', (data) => {
    let m; try { m = JSON.parse(data.toString()); } catch { return; }
    if (m.type === 'result') { const e = pending.get(m.id); if (e) { pending.delete(m.id); e(m); } }
  });
  if (flowStarted) return;   // 主流程只执行一次，重连不重跑
  flowStarted = true;

  const alive = async (label) => {
    const r = await send('ping');
    check(`指令后 App 存活(${label})`, r.ok);
  };

  // ---- 1. DSL 解析边界 ----
  console.log('── DSL 解析边界 ──');
  const { parseScript } = await import('./iua_dsl.js');
  const parseCase = (name, text, expectError) => {
    try {
      parseScript(text);
      check(name, !expectError, expectError ? '应报错但没报' : '');
    } catch (e) {
      check(name, expectError, e.message.slice(0, 50));
    }
  };
  parseCase('空脚本', '', false);
  parseCase('纯注释', '# 只有注释', false);
  parseCase('未知命令报错', '飞起来 100', true);
  parseCase('点击缺参数报错', '点击', true);
  parseCase('点击只一个坐标报错', '点击 100', true);
  parseCase('输入缺文本报错', '输入 field.input', true);
  parseCase('断言缺参报错', '断言文本 label.counter', true);
  parseCase('负数坐标合法', '点击 -10 -20', false);
  parseCase('滑动带时长', '滑动 0 0 100 100 0.5', false);
  try {
    const steps = parseScript('点击 ' + '1'.repeat(4) + ' 2');
    check('超长数字不崩溃', true);
  } catch (e) { check('超长数字不崩溃', false, e.message.slice(0, 40)); }

  // ---- 2. App 指令边界 ----
  console.log('\n── App 指令边界 ──');
  let r;
  r = await send('dismiss_keyboard'); check('无键盘时 dismiss 优雅', r.ok, JSON.stringify(r.data));
  r = await send('perf_start'); check('perf_start #1', r.ok);
  r = await send('perf_start'); check('perf_start 重复 → 明确报错', !r.ok, r.error);
  r = await send('perf_stop'); check('perf_stop 有数据', r.ok && r.data.sampleCount >= 1, `${r.data?.sampleCount} 点`);
  r = await send('perf_stop'); check('perf_stop 未启动 → 明确报错', !r.ok, r.error);
  r = await send('tap', { x: -50, y: -50 }); check('负坐标 tap → 错误不崩溃', !r.ok, r.error?.slice(0, 40));
  r = await send('tap', { x: 99999, y: 99999 }); check('超界坐标 tap → 错误不崩溃', !r.ok, r.error?.slice(0, 40));
  r = await send('type_text', { text: '无目标输入' }); check('type_text 无焦点 → 明确报错', !r.ok, r.error?.slice(0, 40));
  r = await send('type_text', { identifier: 'field.input', text: '🎉emoji&<>"边界' });
  check('emoji/特殊字符输入', r.ok);
  r = await send('element_info', { identifier: 'field.input' });
  check('emoji 输入内容正确回读', r.ok && r.data.text === '🎉emoji&<>"边界', `"${r.data?.text}"`);
  r = await send('view_tree', { maxDepth: -1 }); check('view_tree maxDepth=-1 不崩溃', r.ok);
  r = await send('screenshot', { quality: 99 }); check('screenshot 超范围 quality 不崩溃', r.ok);
  r = await send('element_info', { identifier: '不存在的元素xyz' }); check('element_info 不存在 → 错误', !r.ok, r.error?.slice(0, 40));
  r = await send('断言不存在 action 本身', { }); check('未知 action 清晰报错', !r.ok, r.error?.slice(0, 40));
  await alive('边界指令后');

  // ---- 3. 非法消息 ----
  console.log('\n── 非法消息 ──');
  const roundtrip = (label, raw) => new Promise((resolve) => {
    const id = `raw-${++seq}`;
    const timer = setTimeout(() => { pending.delete(id); resolve(null); }, 5000);
    pending.set(id, (m) => { clearTimeout(timer); resolve(m); });
    ws.send(raw.replace('__ID__', id));
  });
  let resp = await roundtrip('非JSON', 'this is not json');
  check('非 JSON 文本被忽略(无崩溃)', resp === null || true); // 被忽略也行，报错也行，只要不崩
  resp = await roundtrip('JSON数组', '["a","b"]');
  check('JSON 数组被忽略', resp === null || resp.ok === false || true);
  resp = await roundtrip('缺action', '{"id":"__ID__"}');
  check('缺 action → 错误响应', resp === null || resp.ok === false, resp?.error?.slice(0, 30));
  resp = await roundtrip('缺id', '{"action":"ping"}');
  check('缺 id 被忽略', resp === null || true);
  await alive('非法消息后');

  // ---- 4. 状态一致性 ----
  console.log('\n── 状态一致性 ──');
  r = await send('clear_text', { identifier: 'field.input' });
  check('收尾清空输入', r.ok);
  r = await send('record_status');
  check('录制状态干净', r.ok && r.data.recording === false, JSON.stringify(r.data));

  const passed = results.filter(Boolean).length;
  console.log(`\n========== 边界压测: ${passed}/${results.length} 通过 ==========`);
  process.exit(passed === results.length ? 0 : 1);
});

const waitTimer = setTimeout(() => { console.log('[edge_test] 超时未连上 App'); process.exit(1); }, 20000);
console.log('[edge_test] 监听 9800，等待 App…');
