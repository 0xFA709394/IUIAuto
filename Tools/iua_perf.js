/**
 * IUIAuto xctrace 集成（宿主侧 Instruments 录制）
 *
 * 用途：UI 自动化脚本运行期间，用 xctrace 附加到 App 进程录制 .trace，
 * 测试结束后：trace 文件可用 Instruments GUI 打开深挖；并尽力导出摘要数据。
 *
 * 环境适配（实测结论）：
 * - 真机：各模板（Time Profiler / Allocations / Activity Monitor…）通常可用
 * - 模拟器：Activity Monitor 服务不可用（报 "Activity monitoring service not
 *   available on this device"）；Time Profiler 在部分环境 CLI 停止管线挂起。
 *   本封装对所有失败模式做超时保护与优雅降级：测试永远不被性能录制阻塞。
 *
 * 与 App 端 IUAPerfSampler（perf_start/perf_stop 指令）互补：
 * xctrace = 深度分析(.trace 可视化)，App 采样 = 任何环境可靠的实时摘要。
 */

import { spawn } from 'node:child_process';
import { existsSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const DEVELOPER_DIR = process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer';

/**
 * 录制会话句柄：
 * { start(), stop() -> { ok, tracePath, sizeMB, reason?, summary? } }
 */
export function startXctraceRecording({ deviceUDID, processName = 'IUIAuto', template = 'Time Profiler',
                                        outputDir, appTimeoutSec = 180 }) {
  mkdirSync(outputDir, { recursive: true });
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const tracePath = join(outputDir, `${stamp}_${template.replace(/\s+/g, '-')}.trace`);

  const args = ['xctrace', 'record',
    '--template', template,
    '--device', deviceUDID,
    '--attach', processName,
    '--output', tracePath];
  const child = spawn('xcrun', args, {
    env: { ...process.env, DEVELOPER_DIR },
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stderr = '', startedAt = Date.now();
  let outputSeen = false;
  child.stdout.on('data', (d) => { if (/Starting recording/.test(String(d))) outputSeen = true; });
  child.stderr.on('data', (d) => { stderr += String(d); });
  let exited = false;
  child.on('exit', () => { exited = true; });

  return {
    tracePath,
    template,
    /** true 表示录制进程已确认进入 Recording 状态 */
    async waitUntilRecording(timeoutMs = 30000) {
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (exited) return { ok: false, reason: reasonFromOutput(stderr, template) };
        if (outputSeen) return { ok: true };
        await sleep(500);
      }
      return { ok: false, reason: `xctrace ${timeoutMs / 1000}s 内未进入录制状态` };
    },
    /** 停止录制：SIGINT → 等待退出 → 必要时 SIGKILL，返回结果与摘要 */
    async stop() {
      if (exited) {
        return finalize(tracePath, template, reasonFromOutput(stderr, template), Date.now() - startedAt);
      }
      // 优雅停止：Instruments CLI 收 SIGINT 后应保存 trace 退出
      child.kill('SIGINT');
      const graceMs = 20000;
      const deadline = Date.now() + graceMs;
      while (Date.now() < deadline && !exited) await sleep(500);
      if (!exited) {
        child.kill('SIGKILL');
        await sleep(1000);
        return finalize(tracePath, template,
          'xctrace 未响应 SIGINT 优雅停止（已强制结束，trace 可能不完整）', Date.now() - startedAt);
      }
      return finalize(tracePath, template, reasonFromOutput(stderr, template), Date.now() - startedAt);
    },
    abort() { if (!exited) { child.kill('SIGKILL'); } },
  };
}

async function finalize(tracePath, template, reason, elapsedMs) {
  const hasTrace = existsSync(tracePath);
  const result = {
    ok: hasTrace && !reason,
    tracePath: hasTrace ? tracePath : null,
    template,
    elapsedSec: Math.round(elapsedMs / 100) / 10,
    reason: reason || null,
  };
  if (hasTrace) {
    const { stdout } = await execFileAsync('du', ['-sk', tracePath]).catch(() => ({ stdout: '' }));
    result.sizeMB = Math.round((parseInt(stdout, 10) || 0) / 1024 * 10) / 10;
    result.summary = await summarizeTrace(tracePath, 'IUIAuto').catch(() => null);
  }
  return result;
}

/** 把 xctrace 输出翻译成可读的降级原因 */
function reasonFromOutput(stderr, template) {
  const out = stderr || '';
  if (/Activity monitoring service not available/i.test(out)) {
    return `模板「${template}」依赖的 Activity Monitoring 服务在目标设备上不可用（模拟器限制，真机可用）`;
  }
  if (/Cannot find process/i.test(out)) {
    return '找不到目标进程（App 未运行？）';
  }
  if (/Recording failed/i.test(out)) {
    return `录制失败: ${out.split('\n').filter(l => l.includes('Error') || l.includes('error')).slice(0, 2).join('; ') || '未知错误'}`;
  }
  return null;
}

/**
 * 尽力导出摘要：优先 sysmon-process（CPU%/内存时间序列），统计目标进程样本。
 * 解析失败/无数据不抛错（返回 { note }），trace 仍可用 Instruments GUI 打开。
 */
export async function summarizeTrace(tracePath, processName) {
  const env = { ...process.env, DEVELOPER_DIR };
  // 1) toc 找可用 schema
  const { stdout: toc } = await execFileAsync('xcrun', ['xctrace', 'export', '--input', tracePath, '--toc'], { env });
  const schemas = [...toc.matchAll(/schema="([^"]+)"/g)].map((m) => m[1]);

  const preferred = ['sysmon-process', 'activity-monitor-process-ledger', 'time-profile'].find((s) => schemas.includes(s));
  if (!preferred) {
    return { note: 'trace 中无可导出的性能表', schemas: schemas.slice(0, 10) };
  }

  // 2) 导出表并解析目标进程的行
  const { stdout: xml } = await execFileAsync('xcrun', [
    'xctrace', 'export', '--input', tracePath,
    '--xpath', `/trace-toc/run[@number="1"]/data/table[@schema="${preferred}"]`,
  ], { env, maxBuffer: 64 * 1024 * 1024 });

  const rows = [...xml.matchAll(/<row>([\s\S]*?)<\/row>/g)].map((m) => m[1]);
  const mine = rows.filter((r) => r.includes(processName));
  if (mine.length === 0) {
    return { note: `表 ${preferred} 无 ${processName} 样本`, totalRows: rows.length };
  }

  const nums = (re) => mine.map((r) => parseFloat((r.match(re) || [])[1])).filter((v) => !isNaN(v));
  const cpu = nums(/<cpu-percent>([^<]+)</);
  const mem = nums(/<memory-physical-footprint>([^<]+)</);
  const memAnon = nums(/<memory-anonymous>([^<]+)</);
  const faults = nums(/<faults>([^<]+)</);

  return {
    schema: preferred,
    samples: mine.length,
    cpuPercent: summaryOf(cpu),
    physicalFootprintMB: mem.length ? summaryOf(mem.map((b) => b / 1048576)) : null,
    anonymousMB: memAnon.length ? summaryOf(memAnon.map((b) => b / 1048576)) : null,
    faults: faults.length ? { total: faults.reduce((a, b) => a + b, 0) } : null,
  };
}

function summaryOf(values) {
  if (!values.length) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return {
    min: round1(sorted[0]),
    avg: round1(values.reduce((a, b) => a + b, 0) / values.length),
    max: round1(sorted[sorted.length - 1]),
    p95: round1(sorted[Math.min(Math.floor(sorted.length * 0.95), sorted.length - 1)]),
  };
}
const round1 = (v) => Math.round(v * 10) / 10;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 摘要对象 → 一行可读文本（报告用） */
export function perfText(title, data) {
  if (!data) return `${title}: 无数据`;
  const fmt = (s) => s ? `min ${s.min} / avg ${s.avg} / p95 ${s.p95} / max ${s.max}` : '-';
  if (data.cpuPercent) {
    return `${title}: 样本 ${data.samples}，CPU% ${fmt(data.cpuPercent)}` +
      (data.physicalFootprintMB ? `，物理内存MB ${fmt(data.physicalFootprintMB)}` : '') +
      (data.faults ? `，内存页错误 ${data.faults.total}` : '');
  }
  return `${title}: ${data.note || JSON.stringify(data).slice(0, 120)}`;
}
