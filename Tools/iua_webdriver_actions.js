/**
 * W3C WebDriver Actions → IUIAuto 指令翻译
 *
 * Appium 客户端（WebdriverIO / Appium Python / Java）的 ActionChains 最终都会调用
 * POST /session/:id/actions，body 形如：
 *   { actions: [ { type:'pointer', id:'finger1', actions:[
 *       {type:'pointerMove', duration:0, x:100, y:200, origin:'viewport'},
 *       {type:'pointerDown', button:0},
 *       {type:'pointerUp', button:0} ] } ] }
 *
 * IUIAuto 只提供单击/双击/长按/滑动/捏合等语义指令，因此这里把 W3C 时间轴
 * 归约为语义手势。支持：
 *   - 单指 tap / double tap / long press / swipe
 *   - 双指 pinch（两指距离变化）与双指平移近似
 *   - 键盘 keyDown → press_key
 *   - origin: viewport / pointer / 元素句柄（元素中心 + offset）
 */

export const ELEMENT_KEY = 'element-6066-11e4-a52e-4f735466cecf';

const SPECIAL_KEYS = {
  '\uE003': 'delete',   // Backspace
  '\uE004': 'tab',
  '\uE006': 'return',
  '\uE007': 'return',   // Enter
  '\uE00C': 'escape',
};

const MODIFIER_KEYS = new Set([
  '\uE008', // Shift
  '\uE009', // Control
  '\uE00A', // Alt
  '\uE03D', // Meta/Command
  '\uE050', // Right Shift
  '\uE051', // Right Control
  '\uE052', // Right Alt
  '\uE053', // Right Meta
]);

const distance = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
const midpoint = (a, b) => ({ x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 });
const number = (value, fallback = 0) => {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
};

export function extractElementId(origin) {
  if (!origin || typeof origin !== 'object') return null;
  return origin[ELEMENT_KEY] || origin.ELEMENT || origin.elementId || null;
}

async function resolvePoint(action, current, resolveElementRect) {
  const origin = action.origin ?? 'viewport';
  let base = { x: 0, y: 0 };
  if (origin === 'viewport') {
    base = { x: 0, y: 0 };
  } else if (origin === 'pointer') {
    base = current;
  } else if (typeof origin === 'object') {
    const elementId = extractElementId(origin);
    if (!elementId) throw new Error('pointerMove origin 缺少元素句柄');
    const rect = await resolveElementRect(elementId);
    base = {
      x: number(rect.x) + number(rect.width) / 2,
      y: number(rect.y) + number(rect.height) / 2,
    };
  } else {
    throw new Error(`不支持的 pointerMove origin: ${String(origin)}`);
  }
  return { x: base.x + number(action.x), y: base.y + number(action.y) };
}

async function buildPointerTrack(source, resolveElementRect) {
  let x = 0;
  let y = 0;
  let time = 0;
  let down = false;
  let downTime = null;
  let downPoint = null;
  let lastPoint = null;
  let upTime = null;
  const moves = [];
  const taps = [];

  for (const action of source.actions || []) {
    switch (action.type) {
      case 'pointerMove': {
        const target = await resolvePoint(action, { x, y }, resolveElementRect);
        const duration = Math.max(0, number(action.duration));
        if (down) {
          moves.push({
            from: { x, y },
            to: target,
            start: time,
            end: time + duration,
          });
        }
        x = target.x;
        y = target.y;
        time += duration;
        break;
      }
      case 'pointerDown': {
        if (!down) {
          down = true;
          downTime = time;
          downPoint = { x, y };
        }
        break;
      }
      case 'pointerUp': {
        if (down) {
          down = false;
          lastPoint = { x, y };
          upTime = time;
          if (downPoint) {
            taps.push({ point: { x, y }, downPoint, downTime, upTime });
          }
        }
        break;
      }
      case 'pointerCancel': {
        down = false;
        break;
      }
      case 'pause': {
        time += Math.max(0, number(action.duration));
        break;
      }
      default:
        break;
    }
  }

  if (downPoint && lastPoint) {
    return {
      sourceId: source.id,
      start: downPoint,
      end: lastPoint,
      downTime: downTime ?? 0,
      upTime: upTime ?? time,
      time,
      moves,
      taps,
    };
  }
  return null;
}

function buildKeyCommands(source) {
  const commands = [];
  for (const action of source.actions || []) {
    if (action.type !== 'keyDown') continue;
    const raw = action.value;
    if (raw == null) continue;
    const text = String(raw);
    if (MODIFIER_KEYS.has(text)) continue;
    if (SPECIAL_KEYS[text]) {
      commands.push({ action: 'press_key', params: { key: SPECIAL_KEYS[text] } });
      continue;
    }
    for (const char of Array.from(text)) {
      if (char === '\n' || char === '\r') {
        commands.push({ action: 'press_key', params: { key: 'return' } });
      } else if (char === '\b') {
        commands.push({ action: 'press_key', params: { key: 'delete' } });
      } else {
        commands.push({ action: 'press_key', params: { key: char } });
      }
    }
  }
  return commands;
}

function singlePointerCommands(track) {
  const durationMs = Math.max(0, (track.upTime ?? 0) - (track.downTime ?? 0));
  const moved = distance(track.start, track.end);
  const durationSec = Math.max(durationMs / 1000, 0.01);

  // 双 tap（两次快速抬起，点位接近）
  if (track.taps.length >= 2) {
    const first = track.taps[0];
    const second = track.taps[1];
    if (distance(first.point, second.point) <= 12 &&
        (second.downTime - first.upTime) <= 600) {
      return [{
        action: 'double_tap',
        params: { x: first.point.x, y: first.point.y },
      }];
    }
  }

  if (moved >= 5) {
    return [{
      action: 'swipe',
      params: {
        fromX: track.start.x,
        fromY: track.start.y,
        toX: track.end.x,
        toY: track.end.y,
        duration: Math.min(Math.max(durationSec, 0.05), 10),
      },
    }];
  }

  if (durationMs >= 450) {
    return [{
      action: 'long_press',
      params: {
        x: track.start.x,
        y: track.start.y,
        duration: Math.min(Math.max(durationSec, 0.1), 30),
      },
    }];
  }

  return [{
    action: 'tap',
    params: { x: track.start.x, y: track.start.y },
  }];
}

function twoPointerCommands(trackA, trackB) {
  const startDistance = distance(trackA.start, trackB.start);
  const endDistance = distance(trackA.end, trackB.end);
  const durationMs = Math.max(
    Math.max(trackA.upTime, trackB.upTime) - Math.min(trackA.downTime, trackB.downTime),
    100,
  );
  const durationSec = Math.min(Math.max(durationMs / 1000, 0.1), 10);

  if (startDistance > 1 && endDistance > 1 && Math.abs(endDistance - startDistance) >= 10) {
    const center = midpoint(trackA.start, trackB.start);
    return [{
      action: 'pinch',
      params: {
        x: center.x,
        y: center.y,
        radiusFrom: startDistance / 2,
        radiusTo: endDistance / 2,
        duration: durationSec,
      },
    }];
  }

  // 双指平移：用两指中点近似单指滑动（IUIAuto 合成触控目前以单指/双指 pinch 为主）
  const start = midpoint(trackA.start, trackB.start);
  const end = midpoint(trackA.end, trackB.end);
  if (distance(start, end) >= 5) {
    return [{
      action: 'swipe',
      params: {
        fromX: start.x,
        fromY: start.y,
        toX: end.x,
        toY: end.y,
        duration: durationSec,
      },
    }];
  }
  return singlePointerCommands(trackA);
}

/**
 * @param {Array|Object} rawActions W3C actions 数组，或 {actions:[...]}
 * @param {(elementId:string)=>Promise<{x:number,y:number,width:number,height:number}>} resolveElementRect
 * @returns {Promise<Array<{action:string, params:Object}>>}
 */
export async function translateActions(rawActions, resolveElementRect = async () => {
  throw new Error('未提供元素矩形解析器');
}) {
  const sources = Array.isArray(rawActions) ? rawActions : rawActions?.actions;
  if (!Array.isArray(sources)) {
    throw new Error('actions 必须是 W3C actions 数组');
  }

  const pointerTracks = [];
  const keyCommands = [];
  for (const source of sources) {
    if (!source || typeof source !== 'object') continue;
    if (source.type === 'pointer') {
      const track = await buildPointerTrack(source, resolveElementRect);
      if (track) pointerTracks.push(track);
    } else if (source.type === 'key') {
      keyCommands.push(...buildKeyCommands(source));
    }
  }

  let commands = [];
  if (pointerTracks.length >= 2) {
    commands = twoPointerCommands(pointerTracks[0], pointerTracks[1]);
  } else if (pointerTracks.length === 1) {
    commands = singlePointerCommands(pointerTracks[0]);
  }
  return [...commands, ...keyCommands];
}
