#!/bin/bash
#
# publish-pod.sh — 发布 IUIAUTO 到 CocoaPods
#
# 用法:
#   ./publish-pod.sh              # 发布到官方 trunk（CocoaPods Specs）
#   ./publish-pod.sh private <私有spec仓库名> [git地址]
#                                 # 发布到私有 spec repo（如团队内部源）
#   ./publish-pod.sh check        # 检查发布前置条件（lint/tag/远端）
#
# 注意：CocoaPods Trunk 自 2026-12-02 起永久只读，之后新版本需走私有源；
#       只读前的测试周窗口内 push 会被拒（提示 read-only test week）。
#
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

MODE="${1:-trunk}"
PODSPEC=IUIAUTO.podspec
VERSION=$(grep -m1 "s.version" $PODSPEC | sed "s/.*= *'\([^']*\)'.*/\1/")
REMOTE=IUIAuto

step() { printf '\n\033[1;36m▸ %s\033[0m\n' "$1"; }

check_prereq() {
  step "前置检查（version=$VERSION）"
  # 1) 工作区干净
  if [ -n "$(git status --porcelain | grep -v '^??')" ]; then
    echo "✗ 有未提交改动，先 commit/push"; exit 1
  fi
  # 2) 本地 tag 与 podspec 版本一致且已推送
  if ! git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "▹ 本地无 tag $VERSION，创建并推送…"
    git tag "$VERSION" && git push "$REMOTE" "$VERSION"
  elif ! git ls-remote --tags "$REMOTE" | grep -q "refs/tags/$VERSION"; then
    git push "$REMOTE" "$VERSION"
  else
    # tag 存在但落后 HEAD 时提示（首次发布后 tag 不可移动，需升版本）
    TAG_COMMIT=$(git rev-parse "${VERSION}^{commit}" 2>/dev/null || echo "")
    HEAD_COMMIT=$(git rev-parse HEAD)
    if [ -n "$TAG_COMMIT" ] && [ "$TAG_COMMIT" != "$HEAD_COMMIT" ]; then
      echo "⚠ tag $VERSION 指向 ${TAG_COMMIT:0:7}，HEAD 是 ${HEAD_COMMIT:0:7}——若该版本未发布过，重打 tag；已发布过则升版本号"
    fi
  fi
  echo "✓ 前置就绪"
}

case "$MODE" in
  check)
    check_prereq
    step "完整 lint（含 @import 模块验证）"
    pod lib lint $PODSPEC --allow-warnings
    ;;

  trunk)
    check_prereq
    step "完整 lint"
    pod lib lint $PODSPEC --allow-warnings
    step "trunk push"
    pod trunk push $PODSPEC --allow-warnings
    echo "✅ 已发布。验证: https://cocoapods.org/pods/IUIAUTO"
    ;;

  private)
    REPO="${2:?用法: publish-pod.sh private <私有spec仓库名> [git地址]}"
    if [ -n "${3:-}" ] && ! pod repo list | grep -q "^$REPO"; then
      pod repo add "$REPO" "$3"
    fi
    check_prereq
    step "lint"
    pod lib lint $PODSPEC --allow-warnings
    step "推送到私有源 $REPO"
    pod repo push "$REPO" $PODSPEC --allow-warnings --sources="https://cdn.cocoapods.org/"
    echo "✅ 已发布到私有源。宿主 Podfile 添加：source '$3' 与 pod 'IUIAUTO'"
    ;;

  *)
    echo "用法: $0 [check|trunk|private <repo> <git>]"; exit 1
    ;;
esac
