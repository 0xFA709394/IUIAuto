#!/bin/bash
#
# build.sh — 一键构建：生成 Example 工程 → pod install → 编译 → 安装 → 启动 App
#
# 仓库结构（pod 化后）：
#   Sources/            IUIAUTO pod 库源码（Core/Actions/UI）
#   Example/            示例 App 工程（xcodegen + Podfile :path 引用 pod）
#   IUIAUTO.podspec     pod 描述
#
# 用法:
#   ./build.sh                 # 编译+安装+启动到（自动选择的）已启动模拟器
#   ./build.sh <模拟器UDID>    # 指定设备（未启动会自动 boot）
#   ./build.sh --boot-only     # 只确保有模拟器在跑
#
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="${IUA_BUNDLE_ID:-com.iuiauto.example}"
EXAMPLE_DIR=Example

# ---- Xcode 环境（xcode-select 指向 CommandLineTools 时自动纠正）----
if ! xcode-select -p 2>/dev/null | grep -q "Xcode.app"; then
  if [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    echo "ℹ  xcode-select 未指向 Xcode，本次使用 DEVELOPER_DIR=$DEVELOPER_DIR"
  else
    echo "✗ 未找到 /Applications/Xcode.app，请先安装 Xcode"; exit 1
  fi
fi

# ---- 依赖检查 ----
if ! command -v xcodegen >/dev/null; then
  echo "ℹ  安装 xcodegen（工程生成器）…"; brew install xcodegen
fi
if ! command -v pod >/dev/null; then
  echo "ℹ  安装 CocoaPods…"; brew install cocoapods
fi

# ---- 生成 Example 工程（新增/删除源文件后必须重新生成）----
echo "▸ 生成 Example 工程…"
(cd "$EXAMPLE_DIR" && xcodegen generate >/dev/null)
# xcodegen 重建工程会覆盖 workspace，需要重新执行 pod install 恢复 Pods 集成
echo "▸ pod install…"
(cd "$EXAMPLE_DIR" && pod install >/dev/null)

# ---- 选择模拟器（默认第一个 booted；否则 boot 第一台 iPhone）----
UDID="${1:-}"
if [ "$UDID" = "--boot-only" ] || [ -z "$UDID" ]; then
  # 选择顺序：IUA_UDID 环境变量 > 第一台 booted > 第一台 available iPhone
  UDID="${IUA_UDID:-}"
  if [ -z "$UDID" ]; then
    # 只从 iOS 段选择设备，避免误选同时 booted 的 visionOS 模拟器
    UDID=$(xcrun simctl list devices booted | sed -n '/-- iOS/,/^-- /p' | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()')
  fi
  if [ -z "$UDID" ]; then
    UDID=$(xcrun simctl list devices available | grep "iPhone" | grep -oE '\([0-9A-F-]{36}\)' | head -1 | tr -d '()')
    if [ -z "$UDID" ]; then
      echo "✗ 未找到可用的 iPhone 模拟器（Xcode → Settings → Components 下载运行时）"; exit 1
    fi
    echo "▸ 启动模拟器 $(xcrun simctl list devices | grep "$UDID" | head -1 | sed 's/^ *//')…"
    xcrun simctl boot "$UDID" 2>/dev/null || true
    xcrun simctl bootstatus "$UDID" -b
    open -a Simulator 2>/dev/null || true
  fi
fi
echo "▸ 模拟器: $UDID"

if [ "${1:-}" = "--boot-only" ]; then exit 0; fi

# ---- 编译（Example workspace，模拟器，免签名）----
echo "▸ 编译 IUIAutoExample（模拟器）…"
xcodebuild -workspace "$EXAMPLE_DIR/IUIAutoExample.xcworkspace" -scheme IUIAutoExample \
  -sdk iphonesimulator -destination "platform=iOS Simulator,id=$UDID" \
  -quiet build

# ---- 定位产物并安装启动 ----
APP=$(find ~/Library/Developer/Xcode/DerivedData/IUIAutoExample-*/Build/Products/Debug-iphonesimulator \
      -maxdepth 1 -name "IUIAutoExample.app" 2>/dev/null | head -1)
if [ -z "$APP" ]; then echo "✗ 未找到编译产物"; exit 1; fi

echo "▸ 安装 App…"
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl install "$UDID" "$APP"

echo "▸ 启动 App…"
xcrun simctl launch "$UDID" "$BUNDLE_ID"

cat <<EOF

✅ 构建完成
   模拟器: $UDID
   App 已启动（自动连接 ws://127.0.0.1:9800/ws）

下一步:
   测试人员:  ./start.sh            # 打开 GUI 控制台
   CLI 验证:   cd Tools && node mock_server.js --demo
   pod 校验:   ./publish-pod.sh check
EOF
