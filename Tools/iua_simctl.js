#!/usr/bin/env node
/**
 * IUIAuto 宿主侧设备管理（xcrun simctl 封装）
 *
 * 参考 Appium XCUITest driver 的设备能力面，把"进程外"操作放在 macOS 宿主上完成：
 *   - App 生命周期：activateApp / terminateApp / backgroundApp / queryAppState
 *   - 安装管理：installApp / removeApp / isAppInstalled
 *   - 文件传输：pushFile / pullFile / pullFolder（@bundleId/相对路径 或 绝对路径）
 *   - 屏幕录制：startRecording / stopRecording（simctl io recordVideo）
 *
 * 仅模拟器可用（真机上 App 进程外的控制宿主做不到）。
 * 所有 simctl 调用走 run/spawnVideo 执行器，单测可注入假实现：
 *   createSimctl({ run: fakeRun, spawnVideo: fakeSpawnVideo })
 */

import { execFile, spawn } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

const execFileAsync = promisify(execFile);

/** 单文件 / 录屏返回体积上限（base64 前的原始字节数） */
const MAX_TRANSFER_BYTES = 64 * 1024 * 1024;

const simctlEnv = () => ({
  ...process.env,
  DEVELOPER_DIR: process.env.DEVELOPER_DIR || '/Applications/Xcode.app/Contents/Developer',
});

/** uname machine 为纯架构名（arm64/x86_64/...）说明 App 跑在模拟器；真机是 iPhone17,1 等 */
export function looksLikeSimulatorModel(model) {
  return /^(i386|x86_64|arm64|arm64e)$/i.test(String(model || '').trim());
}

/** 带 kind 的模块错误，桥层据此映射 WebDriver 错误码 */
function fail(kind, message) {
  const error = new Error(message);
  error.kind = kind; // device | invalid | not-found | busy | limit | no-recording
  return error;
}

async function defaultRun(args, timeoutSec = 30) {
  const { stdout } = await execFileAsync('xcrun', ['simctl', ...args], {
    env: simctlEnv(),
    maxBuffer: 32 * 1024 * 1024,
    timeout: timeoutSec * 1000,
  });
  return stdout;
}

/** 默认录屏进程：SIGINT 结束（simctl 需要 SIGINT 才会正确 finalize 视频文件） */
function defaultSpawnVideo(args) {
  const child = spawn('xcrun', ['simctl', ...args], { env: simctlEnv(), stdio: 'ignore' });
  return {
    stop() {
      return new Promise((resolveStop) => {
        let settled = false;
        const done = () => { if (!settled) { settled = true; resolveStop(); } };
        // SIGINT 无响应时依次升级 SIGTERM / SIGKILL，保证一定能停下
        const killTimer = setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* ignore */ } }, 10000);
        const termTimer = setTimeout(() => { try { child.kill('SIGTERM'); } catch { /* ignore */ } }, 3500);
        child.once('exit', () => { clearTimeout(killTimer); clearTimeout(termTimer); done(); });
        try { child.kill('SIGINT'); } catch { done(); }
      });
    },
  };
}

export function createSimctl({ run = defaultRun, spawnVideo = defaultSpawnVideo, log = () => {} } = {}) {
  let recording = null; // { handle, videoPath, udid, startedAt }

  async function simctl(args, timeoutSec) {
    return run(args, timeoutSec);
  }

  async function bootedUdids() {
    const stdout = await simctl(['list', 'devices', '-j'], 20);
    let parsed;
    try { parsed = JSON.parse(stdout); } catch {
      throw fail('device', `simctl list 输出无法解析: ${String(stdout).slice(0, 120)}`);
    }
    const udids = [];
    for (const group of Object.values(parsed?.devices ?? {})) {
      for (const device of group || []) {
        if (String(device?.state).toLowerCase() === 'booted' && device.udid) udids.push(device.udid);
      }
    }
    return [...new Set(udids)];
  }

  /**
   * 解析目标模拟器 UDID：
   * 显式 hint 直接使用；否则要求恰好一台 booted（0 台报错、多台要求指定）。
   */
  async function resolveUdid(hint = null) {
    const text = String(hint || '').trim();
    if (text) return text;
    const booted = await bootedUdids();
    if (booted.length === 1) return booted[0];
    if (booted.length === 0) {
      throw fail('device', '没有已启动（Booted）的模拟器：请先 ./build.sh、./start.sh 或 xcrun simctl boot');
    }
    throw fail('device', `有 ${booted.length} 台模拟器在运行，请用 appium:udid（或环境变量 IUA_UDID）指定其一: ${booted.join(' / ')}`);
  }

  // ---- App 生命周期 ----

  /** 进程是否在跑：launchctl 列表里能看到 UIKitApplication:<bundleId> */
  async function isProcessRunning(udid, bundleId) {
    try {
      const stdout = await simctl(['spawn', udid, 'launchctl', 'list'], 20);
      return stdout.includes(bundleId);
    } catch {
      return false;
    }
  }

  async function launchApp(udid, bundleId) {
    const stdout = await simctl(['launch', udid, bundleId], 30);
    const pid = Number((String(stdout).match(/(\d+)\s*$/) || [])[1]) || null;
    return { pid };
  }

  /** Appium 语义：对未运行的 App terminate 也算成功（返回 wasRunning=false） */
  async function terminateApp(udid, bundleId) {
    if (!(await isProcessRunning(udid, bundleId))) {
      return { terminated: false, wasRunning: false };
    }
    await simctl(['terminate', udid, bundleId], 30);
    return { terminated: true, wasRunning: true };
  }

  /** 1=未运行 3=后台运行；前台判定（4）由桥结合当前宿主 App 给出 */
  async function appState(udid, bundleId) {
    return (await isProcessRunning(udid, bundleId)) ? 3 : 1;
  }

  // ---- 外观（Appium mobile: setAppearance / getAppearance）----

  async function getAppearance(udid) {
    const stdout = String(await simctl(['ui', udid, 'appearance'], 20)).trim().toLowerCase();
    if (stdout === 'light' || stdout === 'dark') return stdout;
    throw fail('device', `模拟器不支持外观读取/设置: ${stdout || '无输出'}`);
  }

  async function setAppearance(udid, style) {
    const value = String(style || '').toLowerCase();
    if (value !== 'light' && value !== 'dark') {
      throw fail('invalid', 'appearance 必须为 light 或 dark');
    }
    await simctl(['ui', udid, 'appearance', value], 20);
    return getAppearance(udid);
  }

  // ---- 权限（Appium mobile: setPermission / resetPermission，服务名与 simctl/XCUITest 一致）----

  const PRIVACY_SERVICES = new Set([
    'all', 'calendar', 'contacts-limited', 'contacts', 'location', 'location-always',
    'photos-add', 'photos', 'media-library', 'microphone', 'motion', 'reminders', 'siri',
  ]);

  function privacyService(service) {
    const value = String(service || 'all').trim();
    if (!PRIVACY_SERVICES.has(value)) {
      throw fail('invalid', `不支持的权限服务: ${value}（支持: ${[...PRIVACY_SERVICES].join(' / ')}）`);
    }
    return value;
  }

  async function grantService(udid, bundleId, service) {
    await simctl(['privacy', udid, 'grant', privacyService(service), bundleId], 20);
    return true;
  }

  async function revokeService(udid, bundleId, service) {
    await simctl(['privacy', udid, 'revoke', privacyService(service), bundleId], 20);
    return true;
  }

  async function resetService(udid, service, bundleId) {
    const args = ['privacy', udid, 'reset', privacyService(service)];
    if (bundleId) args.push(bundleId);
    await simctl(args, 20);
    return true;
  }

  // ---- App 本地化字符串（Appium mobile: getAppStrings）----

  /** 读取 App bundle 内 .lproj/Localizable.strings，返回 {key: value}；无资源返回 {} */
  async function appStrings(udid, bundleId, language = null) {
    const bundlePath = String(await simctl(['get_app_container', udid, bundleId, 'app'], 20)).trim();
    if (!bundlePath || !existsSync(bundlePath)) {
      throw fail('device', `无法定位 App 安装目录: ${bundleId}`);
    }
    const lprojs = readdirSync(bundlePath).filter((name) => name.endsWith('.lproj'));
    const wanted = language ? String(language).trim() : null;
    let candidates = [];
    if (wanted) {
      // 先精确（zh-Hans），再退化到主语言（zh）
      candidates = lprojs.filter((n) => n === `${wanted}.lproj` || n.startsWith(`${wanted.split('-')[0]}-`) || n === `${wanted.split('-')[0]}.lproj`);
    } else {
      candidates = lprojs;
    }
    // 找不到指定语言时回退到任意一个（Base/en 优先）
    if (candidates.length === 0 && wanted) candidates = lprojs.filter((n) => /^(en|Base)\.lproj$/.test(n));
    if (candidates.length === 0) candidates = lprojs;
    for (const lproj of candidates) {
      const file = join(bundlePath, lproj, 'Localizable.strings');
      if (!existsSync(file)) continue;
      const { stdout } = await execFileAsync('plutil', ['-convert', 'json', '-o', '-', file]);
      try {
        const map = JSON.parse(stdout || '{}');
        if (map && typeof map === 'object') {
          return { language: lproj.replace(/\.lproj$/, ''), strings: map };
        }
      } catch {
        throw fail('device', `Localizable.strings 解析失败: ${lproj}`);
      }
    }
    return { language: null, strings: {} };
  }

  // ---- 安装管理 ----

  async function isAppInstalled(udid, bundleId) {
    const stdout = await simctl(['listapps', udid], 30);
    // listapps 输出为 plist：顶层键即 bundle id（<key>com.x</key>）；宽松兼容引号形式
    return stdout.includes(`<key>${bundleId}</key>`) || stdout.includes(`"${bundleId}"`);
  }

  async function installApp(udid, appPath) {
    const path = String(appPath || '');
    if (!isAbsolute(path)) throw fail('invalid', `installApp 需要宿主 .app 绝对路径: ${path}`);
    if (!existsSync(path)) throw fail('not-found', `App 路径不存在: ${path}`);
    await simctl(['install', udid, path], 180);
    return true;
  }

  async function removeApp(udid, bundleId) {
    if (!(await isAppInstalled(udid, bundleId))) return false;
    await simctl(['uninstall', udid, bundleId], 60);
    return true;
  }

  // ---- 文件传输（Appium 语义：@bundleId/相对路径 → App 数据容器；否则绝对路径）----

  async function appDataContainer(udid, bundleId) {
    const stdout = String(await simctl(['get_app_container', udid, bundleId, 'data'], 20)).trim();
    if (!stdout) throw fail('device', `无法定位 App 数据容器: ${bundleId}`);
    return stdout;
  }

  async function resolveDevicePath(udid, path) {
    const text = String(path || '');
    if (text.startsWith('@')) {
      const slash = text.indexOf('/');
      const bundleId = slash > 1 ? text.slice(1, slash) : '';
      const relative = slash >= 0 ? text.slice(slash + 1) : '';
      if (!bundleId || !relative) {
        throw fail('invalid', `路径格式应为 @bundleId/相对路径: ${text}`);
      }
      const container = await appDataContainer(udid, bundleId);
      const target = resolve(container, relative);
      if (target !== container && !target.startsWith(container + '/')) {
        throw fail('invalid', `路径越出 App 容器: ${text}`);
      }
      return { path: target, container };
    }
    if (!isAbsolute(text)) {
      throw fail('invalid', `路径必须是绝对路径或 @bundleId/相对路径: ${text}`);
    }
    return { path: text, container: null };
  }

  function checkSize(bytes) {
    if (bytes > MAX_TRANSFER_BYTES) {
      throw fail('limit', `文件超过 ${Math.round(MAX_TRANSFER_BYTES / 1024 / 1024)}MB 传输上限`);
    }
  }

  async function pushFile(udid, path, base64Data) {
    const target = await resolveDevicePath(udid, path);
    const data = Buffer.from(String(base64Data || ''), 'base64');
    checkSize(data.length);
    mkdirSync(dirname(target.path), { recursive: true });
    writeFileSync(target.path, data);
    return { path: target.path, bytes: data.length };
  }

  async function pullFile(udid, path) {
    const target = await resolveDevicePath(udid, path);
    let data;
    try {
      data = readFileSync(target.path);
    } catch {
      throw fail('not-found', `no such file: ${path}`);
    }
    checkSize(data.length);
    return data.toString('base64');
  }

  async function pullFolder(udid, path) {
    const target = await resolveDevicePath(udid, path);
    let stats;
    try {
      stats = statSync(target.path);
    } catch {
      throw fail('not-found', `no such folder: ${path}`);
    }
    if (!stats.isDirectory()) throw fail('invalid', `不是目录: ${path}`);
    const zipPath = join(tmpdir(), `iua-pull-${randomUUID()}.zip`);
    try {
      await execFileAsync('ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', target.path, zipPath]);
      const data = readFileSync(zipPath);
      checkSize(data.length);
      return data.toString('base64');
    } finally {
      rmSync(zipPath, { force: true });
    }
  }

  // ---- 屏幕录制 ----

  /** 同一实例同一时间只允许一路录屏（Appium 同样限制） */
  async function startRecording(udid) {
    if (recording) throw fail('busy', '录屏已在进行中（同一会话只允许一路），请先 stopRecordingScreen');
    const videoPath = join(tmpdir(), `iua-rec-${randomUUID()}.mp4`);
    const handle = spawnVideo(['io', udid, 'recordVideo', '--force', videoPath]);
    recording = { handle, videoPath, udid, startedAt: Date.now() };
    log(`录屏开始: ${videoPath}`);
    return { videoPath };
  }

  /**
   * 停止录屏并返回 mp4 的 base64；discard=true 只停止并清理（会话收尾用）。
   */
  async function stopRecording({ discard = false } = {}) {
    const entry = recording;
    if (!entry) throw fail('no-recording', '当前没有进行中的录屏');
    recording = null;
    try {
      await entry.handle.stop();
    } catch (error) {
      log(`录屏进程停止异常（忽略）: ${error?.message || error}`);
    }
    try {
      if (!discard) {
        if (!existsSync(entry.videoPath) || statSync(entry.videoPath).size === 0) {
          throw fail('device', `录屏文件未生成: ${entry.videoPath}`);
        }
        const data = readFileSync(entry.videoPath);
        checkSize(data.length);
        return data.toString('base64');
      }
    } finally {
      rmSync(entry.videoPath, { force: true });
    }
    return null;
  }

  function isRecording() {
    return !!recording;
  }

  return {
    resolveUdid,
    bootedUdids,
    launchApp,
    terminateApp,
    appState,
    getAppearance,
    setAppearance,
    grantService,
    revokeService,
    resetService,
    appStrings,
    isProcessRunning,
    isAppInstalled,
    installApp,
    removeApp,
    appDataContainer,
    resolveDevicePath,
    pushFile,
    pullFile,
    pullFolder,
    startRecording,
    stopRecording,
    isRecording,
  };
}
