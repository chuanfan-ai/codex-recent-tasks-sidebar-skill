#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/CodexRecentTasksSidebar.app"
BINARY="$APP_DIR/Contents/MacOS/Codex最近任务栏"
FIXTURE_DIR="$BUILD_DIR/qa-fixture"
FIXTURE_DB="$FIXTURE_DIR/state.sqlite"
FIXTURE_INDEX="$FIXTURE_DIR/session_index.jsonl"
FIXTURE_USAGE_SERVER="$FIXTURE_DIR/fake-codex"

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
CREATE TABLE thread_spawn_edges (
  parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL
);
INSERT INTO threads VALUES
  ('00000000-0000-0000-0000-000000000001', 'Original example task', '/tmp/example-project-a', 'main', 4102444800000, 4102444800, 0, '', '', ''),
  ('00000000-0000-0000-0000-000000000002', 'Second example task', '/tmp/example-project-b', '', 4102444700000, 4102444700, 0, '', '', ''),
  ('00000000-0000-0000-0000-000000000003', 'Excluded internal agent task', '/tmp/example-project-a', '', 4102444600000, 4102444600, 0, 'subagent', '{"subagent":true}', '/tmp/agent'),
  ('00000000-0000-0000-0000-000000000004', 'Recovered root task', '/tmp/example-project-a', '', 4102444500000, 4102444500, 0, 'subagent', '', ''),
  ('00000000-0000-0000-0000-000000000005', 'Excluded child task', '/tmp/example-project-a', '', 4102444400000, 4102444400, 0, 'subagent', '', '');
INSERT INTO thread_spawn_edges VALUES
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005', 'running');
SQL

cat > "$FIXTURE_INDEX" <<'JSONL'
{"id":"00000000-0000-0000-0000-000000000001","thread_name":"Earlier example name","updated_at":"2099-12-31T23:59:00Z"}
{"id":"00000000-0000-0000-0000-000000000001","thread_name":"Renamed example task","updated_at":"2100-01-01T00:00:00Z"}
{"id":"00000000-0000-0000-0000-000000000002","thread_name":"   ","updated_at":"2100-01-01T00:00:00Z"}
{"id":"partial"
JSONL

cat > "$FIXTURE_USAGE_SERVER" <<'ZSH'
#!/bin/zsh
request_count=0
while IFS= read -r line; do
  (( request_count += 1 ))
  if (( request_count == 1 )); then
    print '{"id":1,"result":{"serverInfo":{"name":"fake-codex","version":"1"}}}'
  elif (( request_count >= 2 )); then
    print '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":35,"windowDurationMins":300},"secondary":{"usedPercent":90,"windowDurationMins":10080}}}}'
  fi
done
ZSH
chmod +x "$FIXTURE_USAGE_SERVER"

before_hash="$(/usr/bin/shasum "$FIXTURE_DB")"
before_index_hash="$(/usr/bin/shasum "$FIXTURE_INDEX")"
self_test_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_INDEX" \
  CODEX_SELF_TEST_EXPECT_TITLE="Renamed example task" \
  "$BINARY" --self-test
)"
after_hash="$(/usr/bin/shasum "$FIXTURE_DB")"
after_index_hash="$(/usr/bin/shasum "$FIXTURE_INDEX")"

[[ "$self_test_output" == *"SELF_TEST_OK count=3 title_override=ok usage=ok"* ]] || {
  print -u2 "固定测试库自检失败：$self_test_output"
  exit 3
}

usage_test_output="$(
  CODEX_APP_SERVER_OVERRIDE="$FIXTURE_USAGE_SERVER" \
  "$BINARY" --usage-self-test
)"
[[ "$usage_test_output" == "USAGE_SELF_TEST_OK windows=2" ]] || {
  print -u2 "Codex 用量协议自检失败：$usage_test_output"
  exit 9
}

set +e
missing_usage_output="$({
  CODEX_APP_SERVER_OVERRIDE="$FIXTURE_DIR/missing-codex" \
  "$BINARY" --usage-self-test
} 2>&1)"
missing_usage_status=$?
set -e
[[ $missing_usage_status -eq 12 && "$missing_usage_output" == *"USAGE_SELF_TEST_FAILED"* ]] || {
  print -u2 "Codex 用量程序缺失边界测试失败"
  exit 10
}
[[ "$before_hash" == "$after_hash" ]] || {
  print -u2 "自检修改了固定测试库"
  exit 4
}
[[ "$before_index_hash" == "$after_index_hash" ]] || {
  print -u2 "自检修改了固定任务备注索引"
  exit 7
}

fallback_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_DIR/missing-session-index.jsonl" \
  "$BINARY" --self-test
)"
[[ "$fallback_output" == *"SELF_TEST_OK count=3"* ]] || {
  print -u2 "缺失任务备注索引回退测试失败：$fallback_output"
  exit 8
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
print "$usage_test_output"
print "QA_OK app=$APP_DIR"
