#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SKILL_DIR="${SCRIPT_DIR:h}"
TEMPLATE_DIR="$SKILL_DIR/assets/app-template"
OUTPUT_DIR="${1:-$PWD/build}"

if [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == "/" || "$OUTPUT_DIR" == "$HOME" ]]; then
  print -u2 "拒绝使用不安全的输出目录：$OUTPUT_DIR"
  exit 2
fi

APP_DIR="$OUTPUT_DIR/本机AI状态栏.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ARCH="$(/usr/bin/uname -m)"
MIN_MACOS="${MACOSX_DEPLOYMENT_TARGET:-13.0}"

case "$ARCH" in
  arm64|x86_64) ;;
  *)
    print -u2 "不支持的 Mac 架构：$ARCH"
    exit 3
    ;;
esac

BUILD_SCRATCH="$(/usr/bin/mktemp -d /private/tmp/local-ai-statusbar-build.XXXXXX)"
if [[ "$BUILD_SCRATCH" != /private/tmp/local-ai-statusbar-build.* ]]; then
  print -u2 "无法创建安全的临时构建目录"
  exit 4
fi
cleanup_scratch() {
  /bin/rm -rf -- "$BUILD_SCRATCH"
}
trap cleanup_scratch EXIT
SCRATCH_SOURCE_DIR="$BUILD_SCRATCH/sources"
SCRATCH_MODULE_CACHE="$BUILD_SCRATCH/module-cache"
SCRATCH_BINARY="$BUILD_SCRATCH/本机AI状态栏"

rm -rf "$APP_DIR"
mkdir -p \
  "$MACOS_DIR" \
  "$RESOURCES_DIR" \
  "$SCRATCH_SOURCE_DIR" \
  "$SCRATCH_MODULE_CACHE"
cp "$TEMPLATE_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$TEMPLATE_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$TEMPLATE_DIR/AgentAdapter.swift" "$SCRATCH_SOURCE_DIR/AgentAdapter.swift"
cp "$TEMPLATE_DIR/Codex最近任务栏.swift" "$SCRATCH_SOURCE_DIR/Codex最近任务栏.swift"

/usr/bin/swiftc \
  -parse-as-library \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  -module-cache-path "$SCRATCH_MODULE_CACHE" \
  "$SCRATCH_SOURCE_DIR/AgentAdapter.swift" \
  "$SCRATCH_SOURCE_DIR/Codex最近任务栏.swift" \
  -o "$SCRATCH_BINARY"
cp "$SCRATCH_BINARY" "$MACOS_DIR/本机AI状态栏"

/usr/bin/codesign --force --deep --sign - "$APP_DIR"
print "已构建：$APP_DIR"
