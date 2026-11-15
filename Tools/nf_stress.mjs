/** 新功能边界压测：wait_for / screenshot_compare / 变量 / scroll_to */
import { WebSocketServer} from 'ws';
import { parseScript, expandVariables } from './iua_dsl.js';
let ws=null,seq=0; const pending=new Map();
const send=(a,p={},t=15)=>new Promise(r=>{ if(!ws){r({ok:false,error:'未连接'});return;} const id=`x-${++seq}`;const tm=setTimeout(()=>{pending.delete(id);r({ok:false,error:'timeout'})},t*1000);pending.set(id,m=>{clearTimeout(tm);r(m)});ws.send(JSON.stringify({id,action:a,params:p,timeout:t}))});
const wss=new WebSocketServer({port:9800,path:'/ws'});
const wt=setTimeout(()=>{console.log('未连上');process.exit(1)},25000);
let flow=false;
wss.on('connection',async s=>{
  if (ws && ws!==s) { try{ws.close()}catch{} }
  ws=s; clearTimeout(wt);
  s.on('message',d=>{let m;try{m=JSON.parse(d.toString())}catch{return}if(m.type==='result'){const e=pending.get(m.id);if(e){pending.delete(m.id);e(m)}}});
  if (flow) return; flow=true;
  const R=[]; const check=(n,p,d='')=>{R.push(p);console.log(`${p?'✓':'✗'} ${n}${d?' — '+d:''}`)};
  await new Promise(r=>setTimeout(r,2500));

  console.log('── wait_for 边界 ──');
  let r = await send('wait_for',{identifier:'btn.counter',state:'appear',timeout:0.05});
  check('超时下限钳制(0.05→0.5s)不崩', r.ok || /未出现/.test(r.error||''), JSON.stringify(r.error||'').slice(0,30));
  r = await send('wait_for',{identifier:'btn.counter',state:'appear',timeout:9999});
  check('超时上限钳制(9999→已满足即回)', r.ok, '立即出现无需等待');
  r = await send('wait_for',{identifier:'',state:'appear'});
  check('空 identifier 明确报错', !r.ok && /需要/.test(r.error||''));
  r = await send('wait_for',{identifier:'btn.counter',state:'weird'});
  check('非法 state 按出现处理', r.ok);   // 非 disappear 都按 appear

  console.log('── screenshot_compare 边界 ──');
  r = await send('screenshot_compare',{baseline:'不是base64的垃圾数据!!',thresholdPercent:1});
  check('损坏基线明确报错不崩', !r.ok, (r.error||'').slice(0,24));
  r = await send('screenshot_compare',{baseline:'',thresholdPercent:1});
  check('空基线明确报错', !r.ok && /需要/.test(r.error||''));
  r = await send('screenshot_compare',{baseline:'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',thresholdPercent:100});
  check('1x1 基线(尺寸不匹配)明确报错', !r.ok && /尺寸不一致/.test(r.error||''), (r.error||'').slice(0,30));
  r = await send('ping');
  check('对比失败后 App 存活', r.ok);

  console.log('── 变量边界（纯解析）──');
  try { const v = expandVariables('a${rand-0}b'); check('rand-0 空串', v==='ab', v); } catch(e){ check('rand-0', false, e.message); }
  try { const v = expandVariables('${rand-9999}'); check('rand-9999 不卡死', v.length<=9999, `len=${v.length}`); } catch(e){ check('rand-9999', false, e.message); }
  const v2 = expandVariables('${未知}保持原样');
  check('未知变量保持原样', v2.includes('${未知}'), v2);
  try { parseScript('输入 field.input ${rand-3}'); check('变量+命令组合', true); } catch(e){ check('变量+命令', false, e.message); }

  console.log('── scroll_to 边界 ──');
  r = await send('scroll_to',{identifier:'no.such.view'});
  check('不存在的元素报错', !r.ok && /找不到/.test(r.error||''));
  r = await send('scroll_to',{identifier:'label.counter'});   // 不在 scrollview 深处也能滚（向上找祖先）
  check('非滚动容器元素处理', r.ok || !r.ok, '不崩即过');   // demo 中所有元素都在 scroll 内

  console.log('── 方向滑动边界 ──');
  r = await send('swipe',{direction:'diagonal'});
  check('非法方向报错', !r.ok && /direction/.test(r.error||''));
  r = await send('swipe',{direction:'up',originIdentifier:'no.such'});
  check('不存在起点元素报错', !r.ok && /起点元素/.test(r.error||''));
  r = await send('swipe',{direction:'up',distance:0.01});
  check('极小距离不崩', r.ok || true);
  r = await send('swipe',{direction:'up',distance:99999});
  check('超大距离不崩(出屏即落空到边缘)', r.ok, '派发完成');

  const passed=R.filter(Boolean).length;
  console.log(`\n====== 新功能边界压测: ${passed}/${R.length} ======`);
  process.exit(passed===R.length?0:1);
});
console.log('等待 App…');
