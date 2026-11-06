/**
 * IUIAuto 脚本执行器（共享模块）
 * 供 run_script.js（CLI）与 gui_server.js（GUI）复用：
 * 输入 parseScript 产出的步骤数组 + send 函数，逐条执行并回调进度。
 */

/**
 * @param {Array} steps parseScript() 输出的步骤
 * @param {Function} send (action, params, timeoutSec?) => Promise<{ok, data?, error?}>
 * @param {Function} [onProgress] 可选 (result) => void
 *   result: { index, total, line, kind: 'action'|'shot'|'assert',
 *             desc, pass, detail, aborted }
 * @param {Object} [opts] { shotSaver: async (file, dataUrlBase64) => void }
 * @returns {Promise<{passed:number, total:number, ok:boolean, results:Array}>}
 */
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const BASELINE_DIR = join(dirname(fileURLToPath(import.meta.url)), 'baselines');

export async function runSteps(steps, send, onProgress = () => {}, opts = {}) {
  const results = [];
  const total = steps.length;
  const sleep = (s) => new Promise((r) => setTimeout(r, s * 1000));

  for (let i = 0; i < steps.length; i++) {
    const step = steps[i];
    let pass = false, detail = '', desc = '', kind = 'action';

    if (step.type === 'action') {
      kind = 'action';
      desc = `${step.action} ${JSON.stringify(step.params)}`;
      const r = await send(step.action, step.params);
      pass = r.ok;
      detail = r.ok ? '' : (r.error || '失败');
    } else if (step.type === 'shot') {
      kind = 'shot';
      desc = `截图 → ${step.file}`;
      const r = await send('screenshot', step.params);
      pass = r.ok;
      if (r.ok && opts.shotSaver) {
        // 写盘异常（磁盘满/路径非法）不应中断整个脚本执行
        try {
          if (!r.data?.image) throw new Error('截图数据为空');
          await opts.shotSaver(step.file, r.data.image);
          detail = `${Math.round(r.data.width)}x${Math.round(r.data.height)}`;
        } catch (e) {
          detail = `截图数据获取成功但保存失败: ${e.message}`;
        }
      } else if (!r.ok) {
        detail = r.error || '失败';
      }
    } else if (step.type === 'look') {
      kind = 'assert';
      desc = `断言外观 ${step.name}（阈值 ${step.threshold}%）`;
      const a = await runLookAssert(step, send);
      pass = a.pass;
      detail = a.detail;
    } else if (step.type === 'assert') {
      kind = 'assert';
      desc = `断言 ${step.kind} ${step.identifier} ${step.value ?? ''}`.trim();
      const a = await runAssert(step, send);
      pass = a.pass;
      detail = a.detail;
    }

    const result = { index: i, total, line: step.line, kind, desc, pass, detail, aborted: false };
    results.push(result);
    onProgress(result);
    if (!pass) {
      // 失败即停（失败现场截图由调用方决定）
      result.aborted = true;
      break;
    }
    await sleep(0.15);
  }

  const passed = results.filter((r) => r.pass).length;
  const allPass = passed === total && total > 0;
  return { passed, total, ok: allPass, results };
}

async function runAssert(step, send) {
  const { kind, identifier, value } = step;
  if (kind === 'exists' || kind === 'missing') {
    const r = await send('element_info', { identifier });
    return kind === 'exists'
      ? { pass: r.ok, detail: r.ok ? '存在' : '不存在' }
      : { pass: !r.ok, detail: r.ok ? '仍存在' : '不存在' };
  }
  const r = await send('element_info', { identifier });
  if (!r.ok) return { pass: false, detail: '元素不存在' };
  if (kind === 'value_equals' || kind === 'value_contains') {
    // 控件值断言（UISlider/UISwitch 等的 value 字段）
    const v = String(r.data?.value ?? '');
    const pass = kind === 'value_equals' ? v === String(value) : v.includes(String(value));
    return { pass, detail: `实际值="${v}" 期望="${value}"` };
  }
  const text = r.data?.text ?? '';
  return kind === 'text_contains'
    ? { pass: text.includes(value), detail: `实际="${text}"` }
    : { pass: text === value, detail: `实际="${text}" 期望="${value}"` };
}


/** 视觉回归：基线不存在→自动建立并 pass；存在→screenshot_compare */
async function runLookAssert(step, send) {
  if (!existsSync(BASELINE_DIR)) mkdirSync(BASELINE_DIR, { recursive: true });
  const file = join(BASELINE_DIR, step.name.endsWith('.png') ? step.name : step.name + '.png');

  if (!existsSync(file)) {
    // 首次：以当前截图建立基线
    const r = await send('screenshot', { quality: 2 }, 30);
    if (!r.ok) return { pass: false, detail: `基线建立失败: ${r.error}` };
    writeFileSync(file, Buffer.from(r.data.image, 'base64'));
    return { pass: true, detail: `基线已建立 → ${file.split('/').pop()}（${r.data.width | 0}x${r.data.height | 0}）` };
  }

  const baselineBase64 = readFileSync(file).toString('base64');
  const r = await send('screenshot_compare', { baseline: baselineBase64, thresholdPercent: step.threshold }, 30);
  if (!r.ok) {
    return { pass: false, detail: r.error || '对比失败' };
  }
  const d = r.data;
  return { pass: d.pass !== false, detail: `差异 ${d.diffPercent}% / 阈值 ${d.thresholdPercent}%（${d.diffPixels}/${d.totalPixels} 像素）` };
}
