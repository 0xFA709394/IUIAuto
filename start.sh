#!/bin/bash
#
# start.sh — 测试人员一键启动：环境检查 → 构建(如需) → GUI 控制台 → 自动开浏览器
#
set -euo pipefail
cd "$(dirname "$0")"
TOOLS=Tools

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }

# xcode-select 未指向 Xcode 时自动纠正（同 build.sh）
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  [ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# 1) Node 依赖
step "检查控制端依赖"
if ! command -v node >/dev/null; then
  echo "✗ 未安装 Node.js（https://nodejs.org 下载 LTS 版本后重试）"; exit 1
fi
echo "  node $(node -v)"
if [ ! -d "$TOOLS/node_modules" ]; then
  echo "  安装 ws 依赖…"; (cd "$TOOLS" && npm install --silent)
fi

# 2) 模拟器（没有则自动处理；确实没有 Xcode/模拟器时给出指引后继续，仅启动控制台）
step "检查模拟器"
BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()' || true)
if [ -z "$BOOTED" ]; then
  echo "  没有已启动的模拟器，尝试启动…"
  if ! ./build.sh --boot-only; then
    echo "  ⚠ 无法启动模拟器（未装 Xcode?）。App 相关功能不可用，控制台仍会启动。"
  else
    BOOTED=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()' || true)
  fi
else
  echo "  模拟器已就绪: $BOOTED"
fi

# 3) App 检测：未安装→自动构建安装；已安装未运行→自动启动
step "检查 App"
if [ -z "$BOOTED" ]; then
  echo "  无运行中的模拟器，跳过 App 检查"
else
  INSTALLED=$(xcrun simctl get_app_container "$BOOTED" com.iuiauto.agent 2>/dev/null || true)
  if [ -z "$INSTALLED" ]; then
    echo "  App 未安装，开始构建安装（首次约 1-2 分钟）…"
    ./build.sh "$BOOTED"
  else
    echo "  App 已安装"
    RUNNING=$(xcrun simctl spawn "$BOOTED" launchctl list 2>/dev/null | grep -c iuiauto || true)
    if [ "${RUNNING:-0}" -eq 0 ] 2>/dev/null; then
      echo "  App 未运行，启动中…"
      xcrun simctl launch "$BOOTED" com.iuiauto.agent >/dev/null
    else
      echo "  App 运行中"
    fi
  fi
fi

# 4) 启动 GUI 控制台（占用旧实例时自动接管；日志写入文件避免挂住终端）
step "启动 GUI 控制台"
GUI_LOG=/tmp/iuiauto_gui.log
(cd "$TOOLS" && nohup node gui_server.js --takeover > "$GUI_LOG" 2>&1 &)
sleep 2
echo "  服务日志: ${GUI_LOG}（排错时查看）"

# 5) 打开浏览器
step "打开浏览器"
URL="http://localhost:9900"
if ! curl -s -o /dev/null --max-time 3 "$URL"; then
  echo "  ⚠ 控制台未就绪，稍后手动打开 $URL"; else
  open "$URL" 2>/dev/null || echo "  请手动打开 $URL"
fi

cat <<EOF

✅ IUIAuto 控制台已启动: $URL

快速上手（3 步）:
   1. 左侧「实时画面」确认 App 截图正常（顶部显示"已连接"）
   2. 点画面任意位置试试 —— 那就是一次真实的点击
   3. 「录制」页开始录制 → App 上操作 → 停止 → 自动生成脚本 → ▶ 运行

停止: pkill -f gui_server.js   （重启: 再跑一次 ./start.sh 即可）
EOF
