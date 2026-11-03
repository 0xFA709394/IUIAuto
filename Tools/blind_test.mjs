/** 盲区压测：换行文本/超长输入/深view树/连续perf/多次screenshot/双击长按捏合 */
import { WebSocketServer } from 'ws';
const results = [];
const check = (n, p, d = '') => { results.push(p); console.log(`${p ? '✓' : '✗'} ${n}${d ? ' — ' + d : ''}`); };
let ws = null, seq = 0;
const pending = new Map();
const send = (action, params = {}, t = 15) => new Promise((resolve) => {
  if (!ws) return resolve({ ok: false, error: '未连接' });
  const id = `b-${++seq}`;
  const timer = setTimeout(() => { pending.delete(id); resolve({ ok: false, error: 'timeout' }); }, t * 1000);
  pending.set(id, (m) => { clearTimeout(timer); resolve(m); });
  ws.send(JSON.stringify({ id, action, params, timeout: t }));
});
const wss = new WebSocketServer({ port: 9800, path: '/ws' });
let flow = false;
const waitTimer = setTimeout(() => { console.log('未连上 App'); process.exit(1); }, 20000);
wss.on('connection', async (sock) => {
  ws = sock;
  clearTimeout(waitTimer);
  if (flow) return; flow = true;
  sock.on('message', (d) => {
    let m; try { m = JSON.parse(d.toString()); } catch { return; }
    if (m.type === 'result') { const e = pending.get(m.id); if (e) { pending.delete(m.id); e(m); } }
  });
  await new Promise(r => setTimeout(r, 1500));

  // 1. 换行文本（\n 对 UITextField 会触发 didEndOnExit?）
  let r = await send('clear_text', { identifier: 'field.input' });
  r = await send('type_text', { identifier: 'field.input', text: '第一行\n第二行' });
  const t1 = await send('element_info', { identifier: 'field.input' });
  check('换行文本输入不崩溃', r.ok, `回读="${t1.data?.text?.replace(/\n/g, '\\n')}"`);

  // 2. 超长文本 5000 字符
  const long = '长'.repeat(5000);
  r = await send('clear_text', { identifier: 'field.input' });
  const t0 = Date.now();
  r = await send('type_text', { identifier: 'field.input', text: long }, 60);
  check(`5000字输入 ${r.ok ? (Date.now() - t0) + 'ms' : ''}`, r.ok);
  const t2 = await send('element_info', { identifier: 'field.input' });
  check('5000字完整回读', t2.data?.text?.length === 5000, `${t2.data?.text?.length} 字`);
  r = await send('clear_text', { identifier: 'field.input' });
  const t3 = await send('element_info', { identifier: 'field.input' });
  check('5000字清空', t3.data?.text === '');

  // 3. 深 view 树（maxDepth=30）性能
  const s0 = Date.now();
  r = await send('view_tree', { maxDepth: 30 });
  check(`view_tree maxDepth=30 (${Date.now() - s0}ms)`, r.ok && r.elapsed < 3);

  // 4. 连续 perf 三轮
  let allOk = true, detail = '';
  for (let i = 0; i < 3; i++) {
    const a = await send('perf_start', { interval: 0.3 });
    await new Promise(x => setTimeout(x, 1000));
    const b = await send('perf_stop');
    if (!a.ok || !b.ok || !b.data?.sampleCount) { allOk = false; detail = `第${i+1}轮: start=${a.ok} stop=${b.ok} n=${b.data?.sampleCount}`; break; }
  }
  check('连续 3 轮 perf start/stop', allOk, detail);

  // 5. 连续 screenshot ×5（内存/稳定性）
  let shotOk = true;
  for (let i = 0; i < 5; i++) { const s = await send('screenshot', { quality: 0 }); if (!s.ok || !s.data?.image) { shotOk = false; break; } }
  check('连续 5 次 screenshot', shotOk);

  // 6. 双击/长按/捏合（手动面板同款指令）
  r = await send('double_tap', { x: 201, y: 340 }); check('双击不崩溃', r.ok);
  r = await send('long_press', { identifier: 'btn.counter', duration: 1.0 }); check('长按(identifier) 1s', r.ok);
  r = await send('pinch', { x: 200, y: 400, radiusFrom: 120, radiusTo: 30, duration: 0.5 }); check('捏合不崩溃', r.ok);

  // 7. 大 payload 消息（200KB 文本 type）
  r = await send('type_text', { identifier: 'field.input', text: 'x'.repeat(30000) }, 60);
  check('30000 字符大 payload', r.ok, r.ok ? '' : r.error?.slice(0, 40));
  await send('clear_text', { identifier: 'field.input' });

  // 8. 收尾存活
  r = await send('ping'); check('收尾存活', r.ok);

  const passed = results.filter(Boolean).length;
  console.log(`\n====== 盲区压测: ${passed}/${results.length} ======`);
  process.exit(passed === results.length ? 0 : 1);
});
console.log('[blind_test] 等待 App…');
