/** 新功能健壮性压测：press_key 边界 / 悬浮条生命周期 / 组合压力 */
import { WebSocketServer} from 'ws';
let ws=null,seq=0; const pending=new Map();
const send=(a,p={},t=15)=>new Promise(r=>{ if(!ws){r({ok:false,error:'App 未连接'});return;} const id=`n-${++seq}`;const tm=setTimeout(()=>{pending.delete(id);r({ok:false,error:'timeout'})},t*1000);pending.set(id,m=>{clearTimeout(tm);r(m)});ws.send(JSON.stringify({id,action:a,params:p,timeout:t}))});
const wss=new WebSocketServer({port:9800,path:'/ws'});
const wt=setTimeout(()=>{console.log('未连上');process.exit(1)},25000);
let flowStarted=false;
wss.on('connection',async s=>{
  // 每次连接（含重连）都接管消息路由；旧连接顶替
  if (ws && ws !== s) { try { ws.close(); } catch {} }
  ws=s;clearTimeout(wt);
  s.on('message',d=>{let m;try{m=JSON.parse(d.toString())}catch{return}if(m.type==='result'){const e=pending.get(m.id);if(e){pending.delete(m.id);e(m)}}});
  s.on('close',()=>{ if (ws===s) ws=null; });
  if (flowStarted) return;
  flowStarted=true;
  const R=[]; const check=(n,p,d='')=>{R.push(p);console.log(`${p?'✓':'✗'} ${n}${d?' — '+d:''}`)};
  const el=id=>send('element_info',{identifier:id});
  await new Promise(r=>setTimeout(r,2500));

  console.log('── A. press_key 边界 ──');
  let r;
  r = await send('press_key',{key:'return'});                       // 无焦点（此前无输入交互）
  check('无焦点 press_key → 明确错误不崩', !r.ok && /没有可接收/.test(r.error||''), r.error?.slice(0,30));
  r = await send('press_key',{key:'x',identifier:'no.such.field'});
  check('非法 identifier → 明确错误', !r.ok, r.error?.slice(0,30));
  r = await send('clear_text',{identifier:'field.input'});
  r = await send('press_key',{key:'delete',identifier:'field.input'});   // 空框删除
  check('空框删除幂等成功', r.ok, JSON.stringify(r.data));
  r = await send('press_key',{key:'abc',identifier:'field.input'});      // 多字符 key → 插首字符
  const t1 = (await el('field.input')).data?.text;
  check('多字符 key 语义(插首字符)', r.ok && t1 === 'a', `text="${t1}"`);
  r = await send('press_key',{key:' ',identifier:'field.input'});        // 空格
  const t2=(await el('field.input')).data?.text;
  check('空格 key', r.ok && t2==='a ', `text="${t2}"`);
  await send('clear_text',{identifier:'field.input'});

  console.log('── B. 悬浮条生命周期（server 主动断连 → App 自动重连）──');
  let bar = await el('label.floating.status');
  check('初始悬浮条在', bar.ok);
  for (let i=0;i<3;i++) {
    // server 主动关闭连接（App 视为被动断开 → 触发自动重连 + 悬浮条隐藏）
    try { ws.close(1000,'stress'); } catch {} ws=null; await new Promise(x=>setTimeout(x,300));
    // 断开瞬间：指令不可达（隐藏状态无法用指令自证——用"指令失败"侧面验证连接已断）
    const unreachable = !(await send('ping')).ok;
    // 等 App 自动重连（退避 1~2s）
    let recovered = false;
    for (let t=0; t<20 && !recovered; t++) {
      await new Promise(x=>setTimeout(x,500));
      recovered = (await send('ping')).ok;
    }
    // 重连后悬浮条恢复（连接成功通知驱动）
    const barBack = (await el('label.floating.status')).ok;
    check(`被动断连循环 ${i+1}（断开→自动重连→悬浮条恢复）`, unreachable && recovered && barBack,
          `断开=${unreachable} 重连=${recovered} 悬浮条=${barBack}`);
  }
  // 开关快速抖动 ×5（连接保持，指令全程可达）——开关在配置页内，先打开配置页
  await send('tap_view',{identifier:'bar.floating'});
  await new Promise(x=>setTimeout(x,1200));
  for (let i=0;i<5;i++) {
    await send('tap_view',{identifier:'switch.config.floating'});
    await new Promise(x=>setTimeout(x,300));
  }
  const alive = await send('ping');
  check('开关快速抖动×5 后 App 存活', alive.ok);
  const finalHidden = !(await el('label.floating.status')).ok;
  check('开关终态(5次=关)悬浮条隐藏', finalHidden);
  await send('tap_view',{identifier:'switch.config.floating'});
  await new Promise(x=>setTimeout(x,900));
  check('开关恢复后悬浮条重现', (await el('label.floating.status')).ok);

  console.log('── C. 组合压力：循环×100 + press_key + wait ──');
  // 关闭配置页（C 段点击目标在主页面，配置页 modal 会造成遮挡）
  await send('tap_view',{identifier:'btn.config.done'});
  await new Promise(x=>setTimeout(x,1000));
  const t0=Date.now();
  r = await send('tap_view',{identifier:'btn.counter'});
  const c0 = parseInt(((await el('label.counter')).data?.text||'').replace(/\D+/g,''))||0;
  const { parseScript } = await import('./iua_dsl.js');
  const steps = parseScript('循环 100\n点击 btn.counter\n结束循环\n断言文本 label.counter 包含 Count');
  check('DSL 循环100 展开', steps.length===101, `${steps.length} 步`);
  // 直接用引擎跑：逐条 send（脚本端循环模拟——真实 run_script 路径已测过；这里压力点在引擎连续 101 指令）
  let allOk=true;
  const actions = steps.filter(st=>st.type==='action');
  check('action 步骤数=100', actions.length===100, `${actions.length}`);
  for (const st of actions) {
    const rr = await send(st.action, st.params);
    if (!rr.ok) { allOk=false; console.log('  失败于:', st.action, rr.error); break; }
  }
  const c1 = parseInt(((await el('label.counter')).data?.text||'').replace(/\D+/g,''))||0;
  check('101 连续指令全部成功', allOk);
  check('计数真实+100', c1 - c0 >= 100, `${c0}→${c1} (${Date.now()-t0}ms)`);

  const passed = R.filter(Boolean).length;
  console.log(`\n====== 新功能压测: ${passed}/${R.length} ======`);
  process.exit(passed===R.length?0:1);
});
console.log('等待 App…');
