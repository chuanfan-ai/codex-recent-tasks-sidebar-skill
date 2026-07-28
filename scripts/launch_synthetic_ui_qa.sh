#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/build"
FIXTURE_DIR="$BUILD_DIR/qa-fixture"
UI_QA_DIR="$BUILD_DIR/ui-qa"
SOURCE_APP="$UI_QA_DIR/本机AI状态栏.app"
QA_APP="$UI_QA_DIR/本机AI状态栏 QA.app"
QA_BINARY="$QA_APP/Contents/MacOS/本机AI状态栏"
MODE="${1:---prepare-only}"

case "$MODE" in
  --prepare-only|--launch) ;;
  *)
    print -u2 "用法：$0 --prepare-only | --launch"
    exit 2
    ;;
esac

required_fixture_paths=(
  "$FIXTURE_DIR/state.sqlite"
  "$FIXTURE_DIR/session_index.jsonl"
  "$FIXTURE_DIR/codex-global-state.json"
  "$FIXTURE_DIR/fake-codex"
  "$FIXTURE_DIR/qwen-agents.db"
  "$FIXTURE_DIR/qwen-desktop-snapshot.json"
  "$FIXTURE_DIR/kimi-session-index.jsonl"
  "$FIXTURE_DIR/kimi-monitor"
  "$FIXTURE_DIR/kimi-usage.txt"
  "$FIXTURE_DIR/kimi-main.log"
)
for fixture_path in "${required_fixture_paths[@]}"; do
  [[ -e "$fixture_path" ]] || {
    print -u2 "缺少合成测试数据：$fixture_path"
    print -u2 "请先运行：$ROOT/scripts/qa.sh"
    exit 3
  }
done

[[ "$UI_QA_DIR" == "$ROOT/build/ui-qa" ]] || {
  print -u2 "拒绝使用不安全的桌面验收目录：$UI_QA_DIR"
  exit 4
}
existing_qa_pid=$(/usr/bin/pgrep -f -x "$QA_BINARY" | /usr/bin/head -n 1 || true)
if [[ -n "$existing_qa_pid" ]]; then
  /bin/kill -TERM "$existing_qa_pid"
  for _ in {1..20}; do
    /bin/kill -0 "$existing_qa_pid" 2>/dev/null || break
    /bin/sleep 0.1
  done
  /bin/kill -0 "$existing_qa_pid" 2>/dev/null && {
    print -u2 "无法安全结束旧的合成桌面验收副本"
    exit 5
  }
fi
/bin/rm -rf "$UI_QA_DIR"
mkdir -p "$UI_QA_DIR"
"$ROOT/skills/codex-recent-tasks-sidebar/scripts/build_app.sh" \
  "$UI_QA_DIR" >/dev/null
/bin/mv "$SOURCE_APP" "$QA_APP"

/usr/libexec/PlistBuddy \
  -c "Set :CFBundleIdentifier io.github.local-ai-statusbar.ui-qa" \
  -c "Set :CFBundleDisplayName 本机AI状态栏 QA" \
  -c "Set :CFBundleName 本机AI状态栏 QA" \
  -c "Set :LSMultipleInstancesProhibited false" \
  "$QA_APP/Contents/Info.plist"
/usr/bin/codesign --force --deep --sign - "$QA_APP" >/dev/null 2>&1
/usr/bin/codesign --verify --deep --strict "$QA_APP"

if [[ "$MODE" == "--prepare-only" ]]; then
  print "SYNTHETIC_UI_QA_READY app=$QA_APP"
  exit 0
fi

/usr/bin/open -n -F \
  --env "CODEX_TASK_DB_OVERRIDE=$FIXTURE_DIR/state.sqlite" \
  --env "CODEX_SESSION_INDEX_OVERRIDE=$FIXTURE_DIR/session_index.jsonl" \
  --env "CODEX_GLOBAL_STATE_OVERRIDE=$FIXTURE_DIR/codex-global-state.json" \
  --env "CODEX_ROLLOUT_ROOT_OVERRIDE=$FIXTURE_DIR" \
  --env "CODEX_APP_SERVER_OVERRIDE=$FIXTURE_DIR/fake-codex" \
  --env "QWEN_TASK_DB_OVERRIDE=$FIXTURE_DIR/qwen-agents.db" \
  --env "QWEN_DESKTOP_SNAPSHOT_OVERRIDE=$FIXTURE_DIR/qwen-desktop-snapshot.json" \
  --env "KIMI_SESSION_INDEX_OVERRIDE=$FIXTURE_DIR/kimi-session-index.jsonl" \
  --env "KIMI_MONITOR_DIRECTORY_OVERRIDE=$FIXTURE_DIR/kimi-monitor" \
  --env "KIMI_MONITOR_SESSION_ID_OVERRIDE=kimi-monitor" \
  --env "KIMI_ACTIVE_WORK_DIRS_OVERRIDE=/tmp/Kimi中文项目" \
  --env "KIMI_USAGE_TEXT_OVERRIDE=$FIXTURE_DIR/kimi-usage.txt" \
  --env "KIMI_TOTAL_USAGE_LOG_OVERRIDE=$FIXTURE_DIR/kimi-main.log" \
  "$QA_APP"

print "SYNTHETIC_UI_QA_LAUNCHED app=$QA_APP"
