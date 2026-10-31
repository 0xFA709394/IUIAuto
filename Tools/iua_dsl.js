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
  '点击': 'tap', 'tap': 'tap', 'click': 'tap',
  '双击': 'dtap', 'dtap': 'dtap', 'double': 'dtap',
  '长按': 'press', 'press': 'press', 'long': 'press', 'longpress': 'press',
  '输入': 'type', 'type': 'type', 'input': 'type',
  '清空': 'clear', 'clear': 'clear',
  '滑动': 'swipe', 'swipe': 'swipe',
  '捏合': 'pinch', 'pinch': 'pinch',
  '等待': 'wait', 'wait': 'wait', 'sleep': 'wait',
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
 * 解析失败时 throw Error（含行号）。
 */
export function parseScript(text) {
  const steps = [];
  const lines = text.split('\n');
  lines.forEach((raw, i) => {
    const lineNo = i + 1;
    const line = raw.replace(/#.*$/, '').trim(); // 去注释
    if (!line) return;
    const sp = line.indexOf(' ');
    const cmdWord = (sp === -1 ? line : line.slice(0, sp)).toLowerCase();
    const rest = sp === -1 ? '' : line.slice(sp + 1).trim();
    const args = rest.split(/\s+/).filter(Boolean);
    const canonical = ALIASES[cmdWord];
    if (!canonical) throw new Error(`第 ${lineNo} 行: 未知命令 "${cmdWord}"`);

    switch (canonical) {
      case 'tap':
        if (!args.length) throw new Error(`第 ${lineNo} 行: 点击 需要 identifier 或 x y`);
        if (isNumber(args[0])) {
          if (!isNumber(args[1])) throw new Error(`第 ${lineNo} 行: 点击 坐标需要两个数字`);
          steps.push(action('tap', { x: +args[0], y: +args[1] }, lineNo));
        } else {
          steps.push(action('tap_view', { identifier: args[0] }, lineNo));
        }
        break;
      case 'dtap':
        if (!isNumber(args[0]) || !isNumber(args[1])) throw new Error(`第 ${lineNo} 行: 双击 需要 x y`);
        steps.push(action('double_tap', { x: +args[0], y: +args[1] }, lineNo));
        break;
      case 'press': {
        if (isNumber(args[0])) {
          if (!isNumber(args[1])) throw new Error(`第 ${lineNo} 行: 长按 坐标需要两个数字`);
          const dur = isNumber(args[2]) ? +args[2] : 0.8;
          steps.push(action('long_press', { x: +args[0], y: +args[1], duration: dur }, lineNo));
        } else {
          const dur = isNumber(args[1]) ? +args[1] : 0.8;
          steps.push(action('long_press', { identifier: args[0], duration: dur }, lineNo));
        }
        break;
      }
      case 'type': {
        if (args.length < 2) throw new Error(`第 ${lineNo} 行: 输入 需要 identifier 文本`);
        const identifier = args[0];
        const text = rest.slice(rest.indexOf(identifier) + identifier.length).trim();
        steps.push(action('type_text', { identifier, text }, lineNo));
        break;
      }
      case 'clear':
        if (!args.length) throw new Error(`第 ${lineNo} 行: 清空 需要 identifier`);
        steps.push(action('clear_text', { identifier: args[0] }, lineNo));
        break;
      case 'swipe': {
        const nums = args.filter(isNumber).map(Number);
        if (nums.length < 4) throw new Error(`第 ${lineNo} 行: 滑动 需要 fromX fromY toX toY`);
        const params = { fromX: nums[0], fromY: nums[1], toX: nums[2], toY: nums[3] };
        if (nums[4]) params.duration = nums[4];
        steps.push(action('swipe', params, lineNo));
        break;
      }
      case 'pinch': {
        const nums = args.filter(isNumber).map(Number);
        if (nums.length < 4) throw new Error(`第 ${lineNo} 行: 捏合 需要 centerX centerY radiusFrom radiusTo`);
        steps.push(action('pinch', { x: nums[0], y: nums[1], radiusFrom: nums[2], radiusTo: nums[3] }, lineNo));
        break;
      }
      case 'wait': {
        const sec = +args[0] || 1;
        steps.push(action('wait', { seconds: Math.min(sec, 60) }, lineNo));
        break;
      }
      case 'shot': {
        const params = { quality: 1 };
        steps.push({ type: 'shot', file: args[0] || 'shot.png', params, line: lineNo });
        break;
      }
      case 'atext': {
        if (args.length < 3) throw new Error(`第 ${lineNo} 行: 断言文本 需要 identifier [包含|等于] 文本`);
        const identifier = args[0];
        const opWord = args[1];
        const kind = opWord === '包含' || opWord === 'contains' ? 'text_contains' : 'text_equals';
        const value = rest.slice(rest.indexOf(opWord) + opWord.length).trim();
        steps.push(assert(kind, identifier, value, lineNo));
        break;
      }
      case 'aexists':
        if (!args[0]) throw new Error(`第 ${lineNo} 行: 断言存在 需要 identifier`);
        steps.push(assert('exists', args[0], null, lineNo));
        break;
      case 'amissing':
        if (!args[0]) throw new Error(`第 ${lineNo} 行: 断言不存在 需要 identifier`);
        steps.push(assert('missing', args[0], null, lineNo));
        break;
    }
  });
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
        lines.push(`输入 ${id} ${s.text}`);
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
  断言文本 id 包含|等于 文本
  断言存在 id             断言不存在 id`;
