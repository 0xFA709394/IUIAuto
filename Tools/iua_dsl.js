/**
 * IUIAuto 脚本 DSL：解析与生成
 *
 * 面向业务测试人员的行式脚本（# 开头为注释，中英命令等价）：
 *
 *   点击    btn.counter            / tap    btn.counter | tap 201 314
 *   双击    201 314                / dtap   201 314
 *   长按    201 314 1.0            / press  201 314 1.0 | press btn.submit
 *   输入    field.input 你好 世界  / type   field.input 你好 世界
 *   清空    field.input            / clear  field.input
 *   滑动    200 600 200 300 [0.4]  / swipe  200 600 200 300
 *   捏合    200 400 150 30         / pinch  200 400 150 30
 *   等待    1                      / wait   1
 *   截图    shot01.png             / shot   shot01.png
 *   断言文本 label.counter 包含 Count: 2   / assert-text id contains|equals text
 *   断言存在  btn.submit           / assert-exists btn.submit
 *   断言不存在 btn.gone            / assert-missing btn.gone
 */

// 命令别名 → 规范名
const ALIASES = {
  '探活': 'ping', 'ping': 'ping',
  '点击': 'tap', 'tap': 'tap', 'click': 'tap',
  '双击': 'dtap', 'dtap': 'dtap', 'double': 'dtap',
  '长按': 'press', 'press': 'press', 'long': 'press', 'longpress': 'press',
  '输入': 'type', 'type': 'type', 'input': 'type',
  '清空': 'clear', 'clear': 'clear',
  '滑动': 'swipe', 'swipe': 'swipe',
  '上滑': 'swipeup', '下滑': 'swipedown', '左滑': 'swipeleft', '右滑': 'swiperight',
  '等待出现': 'waitappear', '等待消失': 'waitdisappear', '滚动到': 'scrollto',
  '断言值': 'avalue', 'assert-value': 'avalue',
  '断言外观': 'alook', 'assert-look': 'alook', 'assert-appearance': 'alook',
  '捏合': 'pinch', 'pinch': 'pinch',
  '等待': 'wait', 'wait': 'wait', 'sleep': 'wait',
  '收起键盘': 'keyboard', '收键盘': 'keyboard', 'dismiss': 'keyboard', 'keyboard': 'keyboard',
  '按键': 'key', 'key': 'key', 'keypress': 'key',
  '截图': 'shot', 'shot': 'shot', 'screenshot': 'shot',
  '断言文本': 'atext', 'assert-text': 'atext', 'asserttext': 'atext',
  '断言存在': 'aexists', 'assert-exists': 'aexists', 'assertexists': 'aexists',
  '断言不存在': 'amissing', 'assert-missing': 'amissing', 'assertmissing': 'amissing',
};

const isNumber = (s) => s !== '' && !isNaN(+s);

/**
 * 解析脚本文本为步骤数组。每个步骤：
 *   { type:'action', action, params, line }        → 下发给 App
 *   { type:'assert', kind, identifier, value, line } → 本地断言
 * 支持块语法：`循环 N` … `结束循环`（编译期展开为重复步骤，N 上限 100）
 * 解析失败时 throw Error（含行号）。
 */
/** DSL 变量替换：${ts}/${date}/${uuid}/${rand-N}/${env.XXX} */
export function expandVariables(text) {
  const now = new Date();
  const pad = (n) => String(n).padStart(2, '0');
  const vars = {
    ts: String(Math.floor(now.getTime() / 1000)),
    date: `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}`,
    uuid: 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
      const r = Math.random() * 16 | 0;
      return (c === 'x' ? r : (r & 0x3 | 0x8)).toString(16);
    }),
  };
  return text
    .replace(/\$\{rand-(\d+)\}/g, (_, n) => {
      let s = '';
      for (let i = 0; i < +n; i++) s += Math.floor(Math.random() * 10);
      return s;
    })
    .replace(/\$\{ts\}/g, vars.ts)
    .replace(/\$\{date\}/g, vars.date)
    .replace(/\$\{uuid\}/g, vars.uuid)
    .replace(/\$\{env\.([A-Za-z_][A-Za-z0-9_]*)\}/g, (_, k) => process.env[k] ?? '');
}

export function parseScript(text) {
  text = expandVariables(text);
  const steps = [];
  const loopStack = [];  // { count, bodyStart: steps.length 快照用数组 }
  const loopBodies = []; // 与 loopStack 平行：每层循环体的独立步骤数组
  const lines = text.split('\n');
  const MAX_LOOP = 100;

  lines.forEach((raw, i) => {
    const lineNo = i + 1;
    const line = raw.replace(/#.*$/, '').trim(); // 去注释
    if (!line) return;
    const sp = line.indexOf(' ');
    const cmdWord = (sp === -1 ? line : line.slice(0, sp)).toLowerCase();
    const rest = sp === -1 ? '' : line.slice(sp + 1).trim();
    const args = rest.split(/\s+/).filter(Boolean);

    // ---- 循环块语法（在别名表之前处理）----
    if (cmdWord === '循环' || cmdWord === 'loop' || cmdWord === 'repeat') {
      const count = parseInt(args[0], 10);
      if (!Number.isInteger(count) || count < 1) {
        throw new Error(`第 ${lineNo} 行: 循环 需要正整数次数（如: 循环 3）`);
      }
      if (count > MAX_LOOP) {
        throw new Error(`第 ${lineNo} 行: 循环次数 ${count} 超过上限 ${MAX_LOOP}（防误写死循环）`);
      }
      loopStack.push({ count, line: lineNo });
      loopBodies.push([]);
      return;
    }
    if (cmdWord === '结束循环' || cmdWord === 'endloop' || cmdWord === 'end-loop') {
      const frame = loopStack.pop();
      if (!frame) {
        throw new Error(`第 ${lineNo} 行: 结束循环 没有匹配的 循环 开始`);
      }
      const body = loopBodies.pop();
      const target = loopBodies.length > 0 ? loopBodies[loopBodies.length - 1] : steps;
      for (let n = 0; n < frame.count; n++) {
        for (const s of body) target.push(s);
      }
      return;
    }

    // 步骤路由：循环体内进入当前循环体数组，否则进入顶层步骤
    const emit = (s) => (loopBodies.length ? loopBodies[loopBodies.length - 1].push(s) : steps.push(s));

    const canonical = ALIASES[cmdWord];
    if (!canonical) throw new Error(`第 ${lineNo} 行: 未知命令 "${cmdWord}"`);

    switch (canonical) {
      case 'ping':
        emit(action('ping', {}, lineNo));
        break;
      case 'tap':
        if (!args.length) throw new Error(`第 ${lineNo} 行: 点击 需要 identifier 或 x y`);
        if (isNumber(args[0])) {
          if (!isNumber(args[1])) throw new Error(`第 ${lineNo} 行: 点击 坐标需要两个数字`);
          emit(action('tap', { x: +args[0], y: +args[1] }, lineNo));
        } else {
          emit(action('tap_view', { identifier: args[0] }, lineNo));
        }
        break;
      case 'dtap':
        if (isNumber(args[0])) {
          if (!isNumber(args[1])) throw new Error(`第 ${lineNo} 行: 双击 坐标需要两个数字`);
          emit(action('double_tap', { x: +args[0], y: +args[1] }, lineNo));
        } else {
          if (!args[0]) throw new Error(`第 ${lineNo} 行: 双击 需要 identifier 或 x y`);
          emit(action('double_tap', { identifier: args[0] }, lineNo));
        }
        break;
      case 'press': {
        if (isNumber(args[0])) {
          if (!isNumber(args[1])) throw new Error(`第 ${lineNo} 行: 长按 坐标需要两个数字`);
          const dur = isNumber(args[2]) ? +args[2] : 0.8;
          emit(action('long_press', { x: +args[0], y: +args[1], duration: dur }, lineNo));
        } else {
          const dur = isNumber(args[1]) ? +args[1] : 0.8;
          emit(action('long_press', { identifier: args[0], duration: dur }, lineNo));
        }
        break;
      }
      case 'type': {
        if (args.length < 2) throw new Error(`第 ${lineNo} 行: 输入 需要 identifier 文本`);
        const identifier = args[0];
        // 从 args[1] 起重组文本（indexOf 方案在 identifier 含特殊片段时可能错位）
        const text = rest.slice(rest.indexOf(identifier) + identifier.length).trim();
        emit(action('type_text', { identifier, text: text || args.slice(1).join(' ') }, lineNo));
        break;
      }
      case 'clear':
        if (!args.length) throw new Error(`第 ${lineNo} 行: 清空 需要 identifier`);
        emit(action('clear_text', { identifier: args[0] }, lineNo));
        break;
      case 'swipe': {
        // 按位置校验（filter 方案会把非数字 token 静默挤掉导致坐标错位配对）
        if (![0, 1, 2, 3].every((i) => isNumber(args[i]))) {
          throw new Error(`第 ${lineNo} 行: 滑动 需要 fromX fromY toX toY 四个数字`);
        }
        const params = { fromX: +args[0], fromY: +args[1], toX: +args[2], toY: +args[3] };
        if (isNumber(args[4])) params.duration = +args[4];
        emit(action('swipe', params, lineNo));
        break;
      }
      case 'swipeup': case 'swipedown': case 'swipeleft': case 'swiperight': {
        // 方向滑动：可选 [距离pt] [起点元素标识] [秒]
        // 上滑=手指向上（内容向上滚动看下方内容）
        const dirMap = { swipeup: 'up', swipedown: 'down', swipeleft: 'left', swiperight: 'right' };
        const params = { direction: dirMap[canonical] };
        if (isNumber(args[0])) params.distance = +args[0];
        const originId = args.find(a => !isNumber(a));
        if (originId) params.originIdentifier = originId;
        if (args.length >= 2 && isNumber(args[args.length - 1]) && args.length > 1) {
          const maybeDur = +args[args.length - 1];
          if (maybeDur <= 3 && args.indexOf(args[args.length - 1]) > (isNumber(args[0]) ? 1 : 0)) {
            params.duration = maybeDur;   // 末尾 ≤3 的小数视为时长
          }
        }
        steps.push(action('swipe', params, lineNo));
        break;
      }
      case 'waitappear': case 'waitdisappear': {
        if (!args[0]) throw new Error(`第 ${lineNo} 行: ${cmdWord} 需要 identifier [超时秒]`);
        const params = { identifier: args[0], state: canonical === 'waitappear' ? 'appear' : 'disappear', timeout: 10 };
        if (isNumber(args[1])) params.timeout = Math.min(+args[1], 60);
        steps.push(action('wait_for', params, lineNo));
        break;
      }
      case 'scrollto': {
        if (!args[0]) throw new Error(`第 ${lineNo} 行: 滚动到 需要 identifier`);
        steps.push(action('scroll_to', { identifier: args[0] }, lineNo));
        break;
      }
      case 'avalue': {
        if (args.length < 3) throw new Error(`第 ${lineNo} 行: 断言值 需要 identifier [包含|等于] 值`);
        const kind = args[1] === '包含' ? 'value_contains' : 'value_equals';
        const at = rest.indexOf(args[1]);
        const value = at >= 0 ? rest.slice(at + args[1].length).trim() : args.slice(2).join(' ');
        steps.push(assert(kind, args[0], value, lineNo));
        break;
      }
      case 'alook': {
        // 断言外观 <名称> [阈值%]：视觉回归（基线不存在时自动建立）
        if (!args[0]) throw new Error(`第 ${lineNo} 行: 断言外观 需要 基线名称 [阈值%]`);
        steps.push({ type: 'look', name: args[0],
                     threshold: isNumber(args[1]) ? +args[1] : 1.0, line: lineNo });
        break;
      }
      case 'pinch': {
        if (![0, 1, 2, 3].every((i) => isNumber(args[i]))) {
          throw new Error(`第 ${lineNo} 行: 捏合 需要 centerX centerY radiusFrom radiusTo 四个数字`);
        }
        emit(action('pinch', { x: +args[0], y: +args[1], radiusFrom: +args[2], radiusTo: +args[3] }, lineNo));
        break;
      }
      case 'wait': {
        const sec = +args[0] || 1;
        emit(action('wait', { seconds: Math.min(sec, 60) }, lineNo));
        break;
      }
      case 'keyboard':
        emit(action('dismiss_keyboard', {}, lineNo));
        break;
      case 'key': {
        // 按键 回车/删除/A/任意字符（不依赖系统键盘 UI 是否显示）
        const alias = { '回车': 'return', 'enter': 'return', 'return': 'return',
                        '删除': 'delete', '退格': 'delete', 'delete': 'delete', 'backspace': 'delete' };
        const k = args[0];
        if (!k) throw new Error(`第 ${lineNo} 行: 按键 需要 回车/删除/任意字符`);
        emit(action('press_key', { key: alias[k.toLowerCase()] || k, identifier: args[1] || undefined }, lineNo));
        break;
      }
      case 'key': {
        // 按键 回车/删除/A/任意字符（不依赖系统键盘 UI 是否显示）
        const alias = { '回车': 'return', 'enter': 'return', 'return': 'return',
                        '删除': 'delete', '退格': 'delete', 'delete': 'delete', 'backspace': 'delete' };
        const k = args[0];
        if (!k) throw new Error(`第 ${lineNo} 行: 按键 需要 回车/删除/任意字符`);
        emit(action('press_key', { key: alias[k.toLowerCase()] || k, identifier: args[1] || undefined }, lineNo));
        break;
      }
      case 'shot': {
        const params = { quality: 1 };
        emit({ type: 'shot', file: args[0] || 'shot.png', params, line: lineNo });
        break;
      }
      case 'atext': {
        if (args.length < 3) throw new Error(`第 ${lineNo} 行: 断言文本 需要 identifier [包含|等于] 文本`);
        const identifier = args[0];
        const opWord = args[1];
        const isContains = opWord === '包含' || opWord === 'contains';
        const isEquals = opWord === '等于' || opWord === 'equals';
        if (!isContains && !isEquals) {
          throw new Error(`第 ${lineNo} 行: 断言文本 第二个参数须为 包含/等于（实际 "${opWord}"）`);
        }
        const kind = isContains ? 'text_contains' : 'text_equals';
        // 安全提取：indexOf 未命中时回退为 args[2] 起重组，避免负索引错位截断
        const at = rest.indexOf(opWord);
        const value = at >= 0 ? rest.slice(at + opWord.length).trim() : args.slice(2).join(' ');
        emit(assert(kind, identifier, value, lineNo));
        break;
      }
      case 'aexists':
        if (!args[0]) throw new Error(`第 ${lineNo} 行: 断言存在 需要 identifier`);
        emit(assert('exists', args[0], null, lineNo));
        break;
      case 'amissing':
        if (!args[0]) throw new Error(`第 ${lineNo} 行: 断言不存在 需要 identifier`);
        emit(assert('missing', args[0], null, lineNo));
        break;
    }
  });
  if (loopStack.length > 0) {
    throw new Error(`第 ${loopStack[loopStack.length - 1].line} 行: 循环 未闭合（缺少 结束循环）`);
  }
  return steps;

  function action(name, params, line) { return { type: 'action', action: name, params, line }; }
  function assert(kind, identifier, value, line) { return { type: 'assert', kind, identifier, value, line }; }
}

/** 录制步骤（record_stop 返回的 steps）→ DSL 文本 */
export function stepsToDSL(steps) {
  const lines = ['# IUIAuto 录制脚本（可手工编辑）', `# 生成时间: ${new Date().toLocaleString()}`];
  for (const s of steps || []) {
    const id = s.identifier || '';
    const withId = (cmd, extra = '') => id ? `${cmd} ${id}${extra ? ' ' + extra : ''}` : `${cmd} ${extra}`;
    switch (s.action) {
      case 'tap':
        lines.push((s.tapCount || 1) >= 2 ? withId('双击', `${s.x} ${s.y}`) : (id ? `点击 ${id}` : `点击 ${s.x} ${s.y}`));
        break;
      case 'long_press':
        lines.push(id ? `长按 ${id} ${s.duration}` : `长按 ${s.x} ${s.y} ${s.duration}`);
        break;
      case 'swipe':
        lines.push(`滑动 ${s.fromX} ${s.fromY} ${s.toX} ${s.toY}${id ? `   # ${id}` : ''}`);
        break;
      case 'type_text':
        // 回放的输入是追加式（insertText），先清空再输入保证终态与录制时一致
        lines.push(id ? `清空 ${id}` : `# 跳过无标识输入步骤: ${JSON.stringify(s)}`);
        if (id) lines.push(`输入 ${id} ${s.text}`);
        break;
      case 'clear_text':
        lines.push(`清空 ${id}`);
        break;
      default:
        lines.push(`# 未识别步骤: ${JSON.stringify(s)}`);
    }
  }
  return lines.join('\n') + '\n';
}

/** 使用说明文本 */
export const DSL_HELP = `支持的命令（# 为注释）:
  点击 id|x y            双击 x y            长按 id|x y [秒]
  输入 id 文本            清空 id
  滑动 fx fy tx ty [秒]   捏合 cx cy r1 r2
  等待 秒                 截图 [文件名]
  循环 N ... 结束循环     （块内步骤重复 N 次，上限 100）
  断言文本 id 包含|等于 文本
  断言存在 id             断言不存在 id`;
