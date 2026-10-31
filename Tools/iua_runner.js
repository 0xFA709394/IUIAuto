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
        await opts.shotSaver(step.file, r.data.image);
        detail = `${Math.round(r.data.width)}x${Math.round(r.data.height)}`;
      } else if (!r.ok) {
        detail = r.error || '失败';
      }
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
  const text = r.data?.text ?? '';
  return kind === 'text_contains'
    ? { pass: text.includes(value), detail: `实际="${text}"` }
    : { pass: text === value, detail: `实际="${text}" 期望="${value}"` };
}
