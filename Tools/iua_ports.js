/**
 * IUIAuto 端口管理：占用检测 / 友好冲突提示 / --takeover 自动接管
 * （gui_server / mock_server / run_script 共用 9800 端口，避免裸崩溃）
 */

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const execFileAsync = promisify(execFile);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 端口监听（LISTEN）进程列表 [{pid, command, isOurs}]。
 *  只认 LISTEN 状态：与端口仅有出站连接的进程（如浏览器网络服务）不算占用。 */
export async function portOccupiers(port) {
  const { stdout } = await execFileAsync('lsof', ['-ti', `:${port}`, '-sTCP:LISTEN']).catch(() => ({ stdout: '' }));
  const pids = [...new Set(stdout.trim().split('\n').filter(Boolean))];
  const result = [];
  for (const pid of pids) {
    const { stdout: psOut } = await execFileAsync('ps', ['-p', pid, '-o', 'command=']).catch(() => ({ stdout: '' }));
    const command = psOut.trim();
    if (!command) {
      continue;
    }
    // 只把本项目的 node 工具进程视为"可自动接管"目标
    const isOurs = /\bnode\b/.test(command) &&
      /(gui_server|mock_server|run_script|record_test)/.test(command);
    result.push({ pid, command: command.split(/\s+/).slice(0, 6).join(' '), isOurs });
  }
  return result;
}

/**
 * 确保端口可用：
 * - 空闲 → 直接返回
 * - 占用且 takeover=true → SIGTERM 旧进程并等待释放
 * - 占用且 takeover=false → 打印友好指引并 process.exit(1)
 */
export async function ensurePortFree(port, { takeover = false, label = '' } = {}) {
  const occupiers = await portOccupiers(port);
  if (occupiers.length === 0) {
    return;
  }
  const title = label ? `${label}(:${port})` : `端口 ${port}`;
  const ours = occupiers.filter((o) => o.isOurs);
  const foreign = occupiers.filter((o) => !o.isOurs);

  if (!takeover) {
    console.error(`\n✗ ${title} 已被占用：`);
    for (const o of occupiers) {
      console.error(`    pid ${o.pid}  ${o.command}`);
    }
    console.error(`\n  处理方式：`);
    if (ours.length) {
      console.error(`    · 结束旧实例后重试:   kill ${ours.map((o) => o.pid).join(' ')}`);
      console.error(`    · 或自动接管:         在启动命令后加 --takeover`);
    }
    if (foreign.length) {
      console.error(`    · 非本工具进程占用，请手动处理或换端口:  PORT=9801 APP_PORT=9801 前缀启动`);
    }
    console.error('');
    process.exit(1);
  }

  // takeover：只自动结束本工具的旧实例；非本工具进程不碰（防误杀）
  if (foreign.length) {
    console.error(`\n✗ ${title} 被非本工具进程占用，--takeover 不会自动结束它：`);
    for (const o of foreign) {
      console.error(`    pid ${o.pid}  ${o.command}`);
    }
    console.error(`  请手动处理，或换端口启动（PORT=… APP_PORT=…）。\n`);
    process.exit(1);
  }
  console.log(`◉ ${title} 被旧实例占用，--takeover 自动接管：`);
  for (const o of ours) {
    console.log(`    kill ${o.pid}  (${o.command})`);
    try { process.kill(Number(o.pid), 'SIGTERM'); } catch { /* 已退出 */ }
  }
  // 等待端口释放（最多 5s）
  for (let i = 0; i < 25; i++) {
    await sleep(200);
    if ((await portOccupiers(port)).length === 0) {
      console.log(`◉ 端口 ${port} 已释放`);
      return;
    }
  }
  console.error(`✗ 端口 ${port} 等待 5s 仍被占用（进程可能忽略 SIGTERM，可手动 kill -9）`);
  process.exit(1);
}

/**
 * listen 错误兜底（防 EADDRINUSE 等未处理事件直接崩溃堆栈）。
 * 用法：server.on('error', e => handleListenError(e, 9800))
 */
export function handleListenError(err, port) {
  if (err && err.code === 'EADDRINUSE') {
    console.error(`\n✗ 端口 ${port} 已被占用（EADDRINUSE）。结束旧进程后重试，或加 --takeover 自动接管。\n`);
  } else {
    console.error(`\n✗ 服务启动失败: ${err && err.message ? err.message : err}\n`);
  }
  process.exit(1);
}
