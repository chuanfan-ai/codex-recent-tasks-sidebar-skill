#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/CodexRecentTasksSidebar.app"
BINARY="$APP_DIR/Contents/MacOS/Codex最近任务栏"
FIXTURE_DIR="$BUILD_DIR/qa-fixture"
FIXTURE_DB="$FIXTURE_DIR/state.sqlite"

"$ROOT/scripts/build_app.sh"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/file "$BINARY" "$APP_DIR/Contents/Resources/AppIcon.icns"

rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"
/usr/bin/sqlite3 "$FIXTURE_DB" <<'SQL'
CREATE TABLE threads (
  id TEXT PRIMARY KEY,
  title TEXT,
  cwd TEXT,
  git_branch TEXT,
  updated_at_ms INTEGER,
  updated_at INTEGER,
  archived INTEGER DEFAULT 0,
  thread_source TEXT,
  source TEXT,
  agent_path TEXT
);
INSERT INTO threads VALUES
  ('00000000-0000-0000-0000-000000000001', 'Example recent task', '/tmp/example-project-a', 'main', 4102444800000, 4102444800, 0, '', '', ''),
  ('00000000-0000-0000-0000-000000000002', 'Second example task', '/tmp/example-project-b', '', 4102444700000, 4102444700, 0, '', '', ''),
  ('00000000-0000-0000-0000-000000000003', 'Excluded subagent task', '/tmp/example-project-a', '', 4102444600000, 4102444600, 0, 'subagent', '{"subagent":true}', '/tmp/agent');
SQL

before_hash="$(/usr/bin/shasum "$FIXTURE_DB")"
self_test_output="$(CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" "$BINARY" --self-test)"
after_hash="$(/usr/bin/shasum "$FIXTURE_DB")"

[[ "$self_test_output" == *"SELF_TEST_OK count=2"* ]] || {
  print -u2 "固定测试库自检失败：$self_test_output"
  exit 3
}
[[ "$before_hash" == "$after_hash" ]] || {
  print -u2 "自检修改了固定测试库"
  exit 4
}

set +e
missing_output="$(CODEX_TASK_DB_OVERRIDE="$FIXTURE_DIR/missing.sqlite" "$BINARY" --self-test 2>&1)"
missing_status=$?
set -e
[[ $missing_status -eq 1 && "$missing_output" == *"SELF_TEST_FAILED"* ]] || {
  print -u2 "缺失数据库边界测试失败"
  exit 5
}

personal_path="/Users/"'chuanfan'
personal_bundle='com\.''chuanfan'
if /usr/bin/grep -R -n -E \
  --exclude-dir=.git \
  --exclude-dir=build \
  --exclude='*.icns' \
  "(${personal_path}|${personal_bundle}|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (RSA |OPENSSH )?PRIVATE KEY)" \
  "$ROOT"; then
  print -u2 "脱敏扫描失败"
  exit 6
fi

print "$self_test_output"
print "QA_OK app=$APP_DIR"
