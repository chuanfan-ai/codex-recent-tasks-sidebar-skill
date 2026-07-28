#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/本机AI状态栏.app"
BINARY="$APP_DIR/Contents/MacOS/本机AI状态栏"
FIXTURE_DIR="$BUILD_DIR/qa-fixture"
FIXTURE_DB="$FIXTURE_DIR/state.sqlite"
FIXTURE_INDEX="$FIXTURE_DIR/session_index.jsonl"
FIXTURE_GLOBAL_STATE="$FIXTURE_DIR/codex-global-state.json"
FIXTURE_RUNNING_ROLLOUT="$FIXTURE_DIR/running-rollout.jsonl"
FIXTURE_ACTION_ROLLOUT="$FIXTURE_DIR/action-rollout.jsonl"
FIXTURE_USAGE_SERVER="$FIXTURE_DIR/fake-codex"
FIXTURE_FLAKY_USAGE_SERVER="$FIXTURE_DIR/fake-codex-flaky"
FIXTURE_QWEN_DB="$FIXTURE_DIR/qwen-agents.db"
FIXTURE_QWEN_SNAPSHOT="$FIXTURE_DIR/qwen-desktop-snapshot.json"
FIXTURE_KIMI_INDEX="$FIXTURE_DIR/kimi-session-index.jsonl"
FIXTURE_KIMI_RUNNING_DIR="$FIXTURE_DIR/kimi-running"
FIXTURE_KIMI_IDLE_DIR="$FIXTURE_DIR/kimi-idle"
FIXTURE_KIMI_MONITOR_DIR="$FIXTURE_DIR/kimi-monitor"
FIXTURE_KIMI_USAGE="$FIXTURE_DIR/kimi-usage.txt"

"$ROOT/scripts/build_app.sh"
/usr/bin/swiftc \
  -parse-as-library \
  -target "$(/usr/bin/uname -m)-apple-macos13.0" \
  -module-cache-path "$BUILD_DIR/.module-cache" \
  -warn-concurrency \
  -warnings-as-errors \
  -typecheck \
  "$ROOT/skills/codex-recent-tasks-sidebar/assets/app-template/Codex最近任务栏.swift"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_DIR/Contents/Info.plist")" == "本机AI状态栏" \
   && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DIR/Contents/Info.plist")" == "本机AI状态栏" \
   && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" == "io.github.local-ai-statusbar" ]] || {
  print -u2 "应用名称自检失败"
  exit 19
}
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
  agent_path TEXT,
  rollout_path TEXT
);
CREATE TABLE thread_spawn_edges (
  parent_thread_id TEXT NOT NULL,
  child_thread_id TEXT NOT NULL PRIMARY KEY,
  status TEXT NOT NULL
);
INSERT INTO threads VALUES
  ('00000000-0000-0000-0000-000000000001', 'Codex 原始中文线程', '/tmp/Codex中文项目甲', 'main', 4102444800000, 4102444800, 0, '', '', '', ''),
  ('00000000-0000-0000-0000-000000000002', 'Codex 中文运行线程', '/tmp/Codex中文项目乙', '', 4102444700000, 4102444700, 0, '', '', '', ''),
  ('00000000-0000-0000-0000-000000000003', '应排除的内部线程', '/tmp/Codex中文项目甲', '', 4102444600000, 4102444600, 0, 'subagent', '{"subagent":true}', '/tmp/agent', ''),
  ('00000000-0000-0000-0000-000000000004', '恢复的顶层线程', '/tmp/Codex中文项目甲', '', 4102444500000, 4102444500, 0, 'subagent', '', '', ''),
  ('00000000-0000-0000-0000-000000000005', '应排除的子线程', '/tmp/Codex中文项目甲', '', 4102444400000, 4102444400, 0, 'subagent', '', '', '');
INSERT INTO thread_spawn_edges VALUES
  ('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000005', 'running');
SQL

cat > "$FIXTURE_INDEX" <<'JSONL'
{"id":"00000000-0000-0000-0000-000000000001","thread_name":"较早的中文线程名","updated_at":"2099-12-31T23:59:00Z"}
{"id":"00000000-0000-0000-0000-000000000001","thread_name":"用户修改后的中文线程","updated_at":"2100-01-01T00:00:00Z"}
{"id":"00000000-0000-0000-0000-000000000002","thread_name":"   ","updated_at":"2100-01-01T00:00:00Z"}
{"id":"partial"
JSONL

cat > "$FIXTURE_GLOBAL_STATE" <<'JSON'
{
  "electron-persisted-atom-state": {
    "unread-thread-ids-by-host-v1": {
      "local": [
        "00000000-0000-0000-0000-000000000002",
        "00000000-0000-0000-0000-000000000005",
        "invalid"
      ]
    }
  }
}
JSON

cat > "$FIXTURE_RUNNING_ROLLOUT" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_complete"}}
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"message"}}
JSONL

cat > "$FIXTURE_ACTION_ROLLOUT" <<'JSONL'
{"type":"event_msg","payload":{"type":"task_started"}}
{"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}
JSONL

/usr/bin/sqlite3 "$FIXTURE_DB" \
  ".parameter init" \
  ".parameter set @running \"$FIXTURE_RUNNING_ROLLOUT\"" \
  ".parameter set @action \"$FIXTURE_ACTION_ROLLOUT\"" \
  "UPDATE threads SET rollout_path=@running WHERE id='00000000-0000-0000-0000-000000000002';" \
  "UPDATE threads SET rollout_path=@action WHERE id='00000000-0000-0000-0000-000000000001';"

/usr/bin/sqlite3 "$FIXTURE_QWEN_DB" <<'SQL'
CREATE TABLE projects (
  id TEXT PRIMARY KEY,
  name TEXT,
  path TEXT
);
CREATE TABLE chats (
  id TEXT PRIMARY KEY,
  name TEXT,
  project_id TEXT,
  updated_at INTEGER,
  archived_at INTEGER,
  deleted_at INTEGER,
  ext TEXT
);
CREATE TABLE sub_chats (
  id TEXT PRIMARY KEY,
  name TEXT,
  chat_id TEXT,
  updated_at INTEGER,
  stream_id TEXT
);
INSERT INTO projects VALUES
  ('qwen-project-1', '千问中文项目', '/tmp/qwen-project-1');
INSERT INTO chats VALUES
  ('qwen-chat-running', '千问运行任务', 'qwen-project-1', 4102444800, NULL, NULL, '{"taskStatus":"running"}'),
  ('qwen-chat-review', '千问待查看任务', 'qwen-project-1', 4102444700, NULL, NULL, '{"taskStatus":"completed"}'),
  ('qwen-chat-idle', '千问已完成任务', 'qwen-project-1', 4102444600, NULL, NULL, '{"taskStatus":"completed"}');
INSERT INTO sub_chats VALUES
  ('qwen-sub-running', '千问运行线程', 'qwen-chat-running', 4102444800, 'stream-running'),
  ('qwen-sub-review', '千问待查看线程', 'qwen-chat-review', 4102444700, ''),
  ('qwen-sub-idle', '千问历史线程', 'qwen-chat-idle', 4102444600, '');
SQL

cat > "$FIXTURE_QWEN_SNAPSHOT" <<'JSON'
{
  "userQuota": {
    "total": 1000,
    "used": 275.5,
    "remaining": 724.5,
    "percentage": 27.55,
    "unit": "credits"
  },
  "pendingChatIDs": ["qwen-chat-review"]
}
JSON

mkdir -p \
  "$FIXTURE_KIMI_RUNNING_DIR/agents/main" \
  "$FIXTURE_KIMI_IDLE_DIR/agents/main" \
  "$FIXTURE_KIMI_MONITOR_DIR/agents/main"

cat > "$FIXTURE_KIMI_INDEX" <<JSONL
{"sessionId":"kimi-running","sessionDir":"$FIXTURE_KIMI_RUNNING_DIR","workDir":"/tmp/Kimi中文项目"}
{"sessionId":"kimi-idle","sessionDir":"$FIXTURE_KIMI_IDLE_DIR","workDir":"/tmp/Kimi历史项目"}
{"sessionId":"kimi-monitor","sessionDir":"$FIXTURE_KIMI_MONITOR_DIR","workDir":"/tmp/local-ai-statusbar-monitor"}
JSONL

cat > "$FIXTURE_KIMI_RUNNING_DIR/state.json" <<'JSON'
{"createdAt":"2099-12-31T23:00:00.000Z","updatedAt":"2100-01-01T00:00:00.000Z","title":"Kimi 中文运行线程","isCustomTitle":true,"workDir":"/tmp/Kimi中文项目"}
JSON
cat > "$FIXTURE_KIMI_IDLE_DIR/state.json" <<'JSON'
{"createdAt":"2099-12-31T22:00:00.000Z","updatedAt":"2099-12-31T23:00:00.000Z","title":"Kimi 中文历史线程","isCustomTitle":true,"workDir":"/tmp/Kimi历史项目"}
JSON
cat > "$FIXTURE_KIMI_MONITOR_DIR/state.json" <<'JSON'
{"createdAt":"2099-12-31T21:00:00.000Z","updatedAt":"2099-12-31T22:00:00.000Z","title":"本机AI状态栏额度监控","isCustomTitle":true,"workDir":"/tmp/local-ai-statusbar-monitor"}
JSON

cat > "$FIXTURE_KIMI_RUNNING_DIR/agents/main/wire.jsonl" <<'JSONL'
{"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"synthetic-running-step"}}
JSONL
cat > "$FIXTURE_KIMI_IDLE_DIR/agents/main/wire.jsonl" <<'JSONL'
{"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"synthetic-idle-step"}}
{"type":"context.append_loop_event","event":{"type":"step.end","uuid":"synthetic-idle-step"}}
JSONL
cat > "$FIXTURE_KIMI_MONITOR_DIR/agents/main/wire.jsonl" <<'JSONL'
{"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"synthetic-monitor-step"}}
JSONL

cat > "$FIXTURE_KIMI_USAGE" <<'TEXT'
Plan usage
  5-hour   [########------------]  40% used
  Weekly   [##################--]  90% used
TEXT

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

cat > "$FIXTURE_FLAKY_USAGE_SERVER" <<'ZSH'
#!/bin/zsh
rate_request_count=0
while IFS= read -r line; do
  if [[ "$line" == *'"method"'*'"initialize"'* ]]; then
    print '{"id":1,"result":{"serverInfo":{"name":"fake-codex-flaky","version":"1"}}}'
  elif [[ "$line" == *'"id"'* ]]; then
    (( rate_request_count += 1 ))
    request_id="$(print -r -- "$line" | /usr/bin/sed -E 's/.*"id"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/')"
    if (( rate_request_count == 2 )); then
      print "{\"id\":${request_id},\"error\":{\"code\":-32000,\"message\":\"temporary fixture failure\"}}"
    else
      print "{\"id\":${request_id},\"result\":{\"rateLimits\":{\"limitId\":\"codex\",\"primary\":{\"usedPercent\":35,\"windowDurationMins\":300},\"secondary\":{\"usedPercent\":90,\"windowDurationMins\":10080}}}}"
    fi
  fi
done
ZSH
chmod +x "$FIXTURE_FLAKY_USAGE_SERVER"

before_hash="$(/usr/bin/shasum "$FIXTURE_DB")"
before_index_hash="$(/usr/bin/shasum "$FIXTURE_INDEX")"
before_global_state_hash="$(/usr/bin/shasum "$FIXTURE_GLOBAL_STATE")"
before_running_rollout_hash="$(/usr/bin/shasum "$FIXTURE_RUNNING_ROLLOUT")"
before_action_rollout_hash="$(/usr/bin/shasum "$FIXTURE_ACTION_ROLLOUT")"
before_qwen_hash="$(/usr/bin/shasum "$FIXTURE_QWEN_DB")"
before_kimi_index_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_INDEX")"
before_kimi_running_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_RUNNING_DIR/agents/main/wire.jsonl")"
before_kimi_idle_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_IDLE_DIR/agents/main/wire.jsonl")"
before_kimi_monitor_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_MONITOR_DIR/agents/main/wire.jsonl")"
self_test_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_INDEX" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_GLOBAL_STATE" \
  CODEX_ROLLOUT_ROOT_OVERRIDE="$FIXTURE_DIR" \
  CODEX_SELF_TEST_EXPECT_TITLE="用户修改后的中文线程" \
  CODEX_SELF_TEST_EXPECT_UNREAD_ID="00000000-0000-0000-0000-000000000002" \
  CODEX_SELF_TEST_EXPECT_READ_ID="00000000-0000-0000-0000-000000000001" \
  CODEX_SELF_TEST_EXPECT_RUNNING_ID="00000000-0000-0000-0000-000000000002" \
  CODEX_SELF_TEST_EXPECT_ACTION_ID="00000000-0000-0000-0000-000000000001" \
  QWEN_TASK_DB_OVERRIDE="$FIXTURE_QWEN_DB" \
  QWEN_PENDING_CHAT_IDS_OVERRIDE="qwen-chat-review" \
  KIMI_SESSION_INDEX_OVERRIDE="$FIXTURE_KIMI_INDEX" \
  KIMI_MONITOR_SESSION_ID_OVERRIDE="kimi-monitor" \
  "$BINARY" --self-test
)"
after_hash="$(/usr/bin/shasum "$FIXTURE_DB")"
after_index_hash="$(/usr/bin/shasum "$FIXTURE_INDEX")"
after_global_state_hash="$(/usr/bin/shasum "$FIXTURE_GLOBAL_STATE")"
after_running_rollout_hash="$(/usr/bin/shasum "$FIXTURE_RUNNING_ROLLOUT")"
after_action_rollout_hash="$(/usr/bin/shasum "$FIXTURE_ACTION_ROLLOUT")"
after_qwen_hash="$(/usr/bin/shasum "$FIXTURE_QWEN_DB")"
after_kimi_index_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_INDEX")"
after_kimi_running_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_RUNNING_DIR/agents/main/wire.jsonl")"
after_kimi_idle_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_IDLE_DIR/agents/main/wire.jsonl")"
after_kimi_monitor_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_MONITOR_DIR/agents/main/wire.jsonl")"

[[ "$self_test_output" == *"SELF_TEST_OK count=3 title_override=ok unread_override=ok read_override=ok runtime_override=ok action_override=ok incremental_runtime=ok usage=ok unread_state=ok runtime_state=ok display_state=ok active_policy=ok qwen_usage=ok kimi_usage=ok kimi_environment=ok qwen_state=ok kimi_state=ok qwen_repository=ok kimi_repository=ok compact_layout=ok bottom_dock=ok unread_update_count=1"* ]] || {
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

usage_resilience_output="$(
  CODEX_APP_SERVER_OVERRIDE="$FIXTURE_FLAKY_USAGE_SERVER" \
  "$BINARY" --usage-resilience-self-test
)"
[[ "$usage_resilience_output" == "USAGE_RESILIENCE_SELF_TEST_OK stale=ok retry=ok" ]] || {
  print -u2 "Codex 用量容错自检失败：$usage_resilience_output"
  exit 14
}

qwen_bridge_output="$(
  QWEN_DESKTOP_SNAPSHOT_OVERRIDE="$FIXTURE_QWEN_SNAPSHOT" \
  "$BINARY" --qwen-bridge-self-test
)"
[[ "$qwen_bridge_output" == "QWEN_BRIDGE_SELF_TEST_OK pending=1 quota=ok" ]] || {
  print -u2 "QwenWorkCN 本机额度桥自检失败：$qwen_bridge_output"
  exit 17
}

kimi_usage_output="$(
  KIMI_USAGE_TEXT_OVERRIDE="$FIXTURE_KIMI_USAGE" \
  "$BINARY" --kimi-usage-self-test
)"
[[ "$kimi_usage_output" == "KIMI_USAGE_SELF_TEST_OK windows=2" ]] || {
  print -u2 "Kimi 官方额度输出自检失败：$kimi_usage_output"
  exit 18
}

activity_probe_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_INDEX" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_GLOBAL_STATE" \
  CODEX_ROLLOUT_ROOT_OVERRIDE="$FIXTURE_DIR" \
  QWEN_TASK_DB_OVERRIDE="$FIXTURE_QWEN_DB" \
  QWEN_DESKTOP_SNAPSHOT_OVERRIDE="$FIXTURE_QWEN_SNAPSHOT" \
  KIMI_SESSION_INDEX_OVERRIDE="$FIXTURE_KIMI_INDEX" \
  KIMI_MONITOR_SESSION_ID_OVERRIDE="kimi-monitor" \
  "$BINARY" --activity-probe
)"
[[ "$activity_probe_output" == "ACTIVITY_PROBE_OK codex=2 qwen=2 kimi=1" ]] || {
  print -u2 "三类 Agent 活动探测自检失败：$activity_probe_output"
  exit 20
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
[[ "$before_global_state_hash" == "$after_global_state_hash" ]] || {
  print -u2 "自检修改了固定未读状态文件"
  exit 11
}
[[ "$before_running_rollout_hash" == "$after_running_rollout_hash" ]] || {
  print -u2 "自检修改了固定运行中事件文件"
  exit 12
}
[[ "$before_action_rollout_hash" == "$after_action_rollout_hash" ]] || {
  print -u2 "自检修改了固定待操作事件文件"
  exit 13
}
[[ "$before_qwen_hash" == "$after_qwen_hash" ]] || {
  print -u2 "自检修改了固定 QwenWorkCN 测试库"
  exit 15
}
[[ "$before_kimi_index_hash" == "$after_kimi_index_hash" \
   && "$before_kimi_running_hash" == "$after_kimi_running_hash" \
   && "$before_kimi_idle_hash" == "$after_kimi_idle_hash" \
   && "$before_kimi_monitor_hash" == "$after_kimi_monitor_hash" ]] || {
  print -u2 "自检修改了固定 Kimi 测试会话"
  exit 16
}

fallback_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_DIR/missing-session-index.jsonl" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_DIR/missing-global-state.json" \
  QWEN_TASK_DB_OVERRIDE="$FIXTURE_QWEN_DB" \
  QWEN_PENDING_CHAT_IDS_OVERRIDE="qwen-chat-review" \
  KIMI_SESSION_INDEX_OVERRIDE="$FIXTURE_KIMI_INDEX" \
  KIMI_MONITOR_SESSION_ID_OVERRIDE="kimi-monitor" \
  "$BINARY" --self-test
)"
[[ "$fallback_output" == *"SELF_TEST_OK count=3"* ]] || {
  print -u2 "缺失任务备注索引或未读状态回退测试失败：$fallback_output"
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
print "$usage_resilience_output"
print "$qwen_bridge_output"
print "$kimi_usage_output"
print "$activity_probe_output"
print "QA_OK app=$APP_DIR"
