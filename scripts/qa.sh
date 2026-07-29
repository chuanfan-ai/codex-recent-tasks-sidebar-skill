#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/本机AI状态栏.app"
BINARY="$APP_DIR/Contents/MacOS/本机AI状态栏"
SOURCE="$ROOT/skills/codex-recent-tasks-sidebar/assets/app-template/Codex最近任务栏.swift"
ADAPTER_SOURCE="$ROOT/skills/codex-recent-tasks-sidebar/assets/app-template/AgentAdapter.swift"
ADAPTER_CONTRACT_TEST="$ROOT/tests/AgentAdapterContractTests.swift"
PRODUCT_PRESENTATION_CONTRACT_TEST="$ROOT/tests/ProductPeerPresentationContractTests.sh"
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
FIXTURE_KIMI_STALE_DIR="$FIXTURE_DIR/kimi-stale"
FIXTURE_KIMI_MONITOR_DIR="$FIXTURE_DIR/kimi-monitor"
FIXTURE_KIMI_WORK_DIR="$FIXTURE_DIR/kimi-work"
FIXTURE_KIMI_USAGE="$FIXTURE_DIR/kimi-usage.txt"
FIXTURE_KIMI_TOTAL_USAGE_LOG="$FIXTURE_DIR/kimi-main.log"

if /usr/bin/grep -q "getPendingCompletions" "$SOURCE"; then
  print -u2 "QwenWorkCN 待查看读取回归为会消费状态的接口"
  exit 21
fi
for unread_store in "agents:unseenChanges" "agents:subChatUnseenChanges"; do
  /usr/bin/grep -q "$unread_store" "$SOURCE" || {
    print -u2 "QwenWorkCN 持久化待查看状态适配缺失：$unread_store"
    exit 22
  }
done

"$PRODUCT_PRESENTATION_CONTRACT_TEST"
"$ROOT/scripts/build_app.sh"
/usr/bin/swiftc \
  -parse-as-library \
  -target "$(/usr/bin/uname -m)-apple-macos13.0" \
  -module-cache-path "$BUILD_DIR/.module-cache" \
  -warn-concurrency \
  -warnings-as-errors \
  -typecheck \
  "$ADAPTER_SOURCE" \
  "$SOURCE"
/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$APP_DIR/Contents/Info.plist")" == "本机AI状态栏" \
   && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$APP_DIR/Contents/Info.plist")" == "本机AI状态栏" \
   && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")" == "io.github.local-ai-statusbar" \
   && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")" == "2.1.0" \
   && "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")" == "12" ]] || {
  print -u2 "应用名称自检失败"
  exit 19
}
/usr/bin/codesign --verify --deep --strict "$APP_DIR"
/usr/bin/file "$BINARY" "$APP_DIR/Contents/Resources/AppIcon.icns"

rm -rf "$FIXTURE_DIR"
mkdir -p "$FIXTURE_DIR"
/usr/bin/swiftc \
  -parse-as-library \
  -target "$(/usr/bin/uname -m)-apple-macos13.0" \
  -module-cache-path "$BUILD_DIR/.module-cache" \
  -warn-concurrency \
  -warnings-as-errors \
  "$ADAPTER_SOURCE" \
  "$ADAPTER_CONTRACT_TEST" \
  -o "$FIXTURE_DIR/agent-adapter-contract-tests"
adapter_contract_output="$("$FIXTURE_DIR/agent-adapter-contract-tests")"
[[ "$adapter_contract_output" == "AGENT_ADAPTER_CONTRACT_OK products=2 official_icons=ok kimi_work_status=ok workbuddy_public_sessions=ok runtime_first=ok invalid_response=ok trae_ide_excluded=ok version_gate=ok isolation=ok presentation=ok" ]] || {
  print -u2 "Agent 适配器契约自检失败：$adapter_contract_output"
  exit 23
}
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
  "unreadChatIDs": ["qwen-chat-review"],
  "unreadSubChatIDs": ["qwen-sub-review"]
}
JSON

mkdir -p \
  "$FIXTURE_KIMI_RUNNING_DIR/agents/main" \
  "$FIXTURE_KIMI_IDLE_DIR/agents/main" \
  "$FIXTURE_KIMI_STALE_DIR/agents/main" \
  "$FIXTURE_KIMI_MONITOR_DIR/agents/main" \
  "$FIXTURE_KIMI_WORK_DIR"

cat > "$FIXTURE_KIMI_INDEX" <<JSONL
{"sessionId":"kimi-running","sessionDir":"$FIXTURE_KIMI_RUNNING_DIR","workDir":"/tmp/Kimi中文项目"}
{"sessionId":"kimi-idle","sessionDir":"$FIXTURE_KIMI_IDLE_DIR","workDir":"/tmp/Kimi历史项目"}
{"sessionId":"kimi-stale","sessionDir":"$FIXTURE_KIMI_STALE_DIR","workDir":"/tmp/Kimi已退出项目"}
{"sessionId":"kimi-monitor","sessionDir":"$FIXTURE_KIMI_MONITOR_DIR","workDir":"/tmp/local-ai-statusbar-monitor"}
JSONL

cat > "$FIXTURE_KIMI_RUNNING_DIR/state.json" <<'JSON'
{"createdAt":"2099-12-31T23:00:00.000Z","updatedAt":"2100-01-01T00:00:00.000Z","title":"Kimi 中文运行线程","isCustomTitle":true,"workDir":"/tmp/Kimi中文项目"}
JSON
cat > "$FIXTURE_KIMI_IDLE_DIR/state.json" <<'JSON'
{"createdAt":"2099-12-31T22:00:00.000Z","updatedAt":"2099-12-31T23:00:00.000Z","title":"Kimi 中文历史线程","isCustomTitle":true,"workDir":"/tmp/Kimi历史项目"}
JSON
cat > "$FIXTURE_KIMI_STALE_DIR/state.json" <<'JSON'
{"createdAt":"2099-12-31T21:30:00.000Z","updatedAt":"2099-12-31T22:30:00.000Z","title":"Kimi 已退出残留线程","isCustomTitle":true,"workDir":"/tmp/Kimi已退出项目"}
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
cat > "$FIXTURE_KIMI_STALE_DIR/agents/main/wire.jsonl" <<'JSONL'
{"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"synthetic-stale-step"}}
JSONL
cat > "$FIXTURE_KIMI_MONITOR_DIR/agents/main/wire.jsonl" <<'JSONL'
{"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"synthetic-monitor-step"}}
JSONL

cat > "$FIXTURE_KIMI_WORK_DIR/conversation-statuses.json" <<'JSON'
{
  "synthetic-work-running": "running",
  "synthetic-work-blocked": "blocked",
  "synthetic-work-completed-unread": "completed",
  "synthetic-work-completed-read": "completed"
}
JSON
cat > "$FIXTURE_KIMI_WORK_DIR/conversation-unread.json" <<'JSON'
[
  "synthetic-work-completed-unread"
]
JSON
cat > "$FIXTURE_KIMI_WORK_DIR/conversation-titles.json" <<'JSON'
{
  "synthetic-work-running": "Kimi Work 中文运行线程",
  "synthetic-work-blocked": "Kimi Work 中文待处理线程",
  "synthetic-work-completed-read": "不应显示的 Work 已读线程"
}
JSON

cat > "$FIXTURE_KIMI_USAGE" <<'TEXT'
Plan usage
  Weekly limit  [##################--]  90% used
  5h limit      [########------------]  40% used
TEXT

cat > "$FIXTURE_KIMI_TOTAL_USAGE_LOG" <<'TEXT'
[2099-12-31 23:00:00] [info] [SubscriptionManager] refreshed(sub): level=3 isMember=true omniRatio=0.2500 exhausted=false resetAt=2100-01-20T00:00:00Z
[2100-01-01 00:00:00] [info] [SubscriptionManager] refreshed(sub): level=3 isMember=true omniRatio=0.7832 exhausted=false resetAt=2100-02-20T00:00:00Z
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
before_kimi_stale_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_STALE_DIR/agents/main/wire.jsonl")"
before_kimi_monitor_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_MONITOR_DIR/agents/main/wire.jsonl")"
before_kimi_work_status_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_WORK_DIR/conversation-statuses.json")"
before_kimi_work_unread_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_WORK_DIR/conversation-unread.json")"
before_kimi_work_title_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_WORK_DIR/conversation-titles.json")"
before_kimi_total_usage_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_TOTAL_USAGE_LOG")"
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
  QWEN_UNREAD_CHAT_IDS_OVERRIDE="qwen-chat-review" \
  QWEN_UNREAD_SUBCHAT_IDS_OVERRIDE="qwen-sub-review" \
  KIMI_SESSION_INDEX_OVERRIDE="$FIXTURE_KIMI_INDEX" \
  KIMI_MONITOR_SESSION_ID_OVERRIDE="kimi-monitor" \
  KIMI_ACTIVE_WORK_DIRS_OVERRIDE="/tmp/Kimi中文项目" \
  KIMI_WORK_STATUS_DIRECTORY_OVERRIDE="$FIXTURE_KIMI_WORK_DIR" \
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
after_kimi_stale_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_STALE_DIR/agents/main/wire.jsonl")"
after_kimi_monitor_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_MONITOR_DIR/agents/main/wire.jsonl")"
after_kimi_work_status_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_WORK_DIR/conversation-statuses.json")"
after_kimi_work_unread_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_WORK_DIR/conversation-unread.json")"
after_kimi_work_title_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_WORK_DIR/conversation-titles.json")"

[[ "$self_test_output" == *"SELF_TEST_OK count=3 title_override=ok unread_override=ok read_override=ok runtime_override=ok action_override=ok incremental_runtime=ok usage=ok unread_state=ok runtime_state=ok display_state=ok active_policy=ok qwen_usage=ok kimi_usage=ok kimi_quota_lines=ok kimi_quota_tint=ok kimi_environment=ok qwen_state=ok kimi_state=ok qwen_repository=ok kimi_repository=ok kimi_work_repository=ok compact_layout=ok bottom_dock=ok unread_update_count=1"* ]] || {
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
[[ "$qwen_bridge_output" == "QWEN_BRIDGE_SELF_TEST_OK unread_chat=1 unread_subchat=1 quota=ok" ]] || {
  print -u2 "QwenWorkCN 本机额度桥自检失败：$qwen_bridge_output"
  exit 17
}

kimi_usage_output="$(
  KIMI_USAGE_TEXT_OVERRIDE="$FIXTURE_KIMI_USAGE" \
  KIMI_TOTAL_USAGE_LOG_OVERRIDE="$FIXTURE_KIMI_TOTAL_USAGE_LOG" \
  "$BINARY" --kimi-usage-self-test
)"
after_kimi_total_usage_hash="$(/usr/bin/shasum "$FIXTURE_KIMI_TOTAL_USAGE_LOG")"
[[ "$kimi_usage_output" == "KIMI_USAGE_SELF_TEST_OK windows=3" ]] || {
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
  KIMI_ACTIVE_WORK_DIRS_OVERRIDE="/tmp/Kimi中文项目" \
  KIMI_WORK_STATUS_DIRECTORY_OVERRIDE="$FIXTURE_KIMI_WORK_DIR" \
  "$BINARY" --activity-probe
)"
[[ "$activity_probe_output" == "ACTIVITY_PROBE_OK codex=2 qwen=2 kimi=4" ]] || {
  print -u2 "三类 Agent 活动探测自检失败：$activity_probe_output"
  exit 20
}

kimi_work_only_probe_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_INDEX" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_GLOBAL_STATE" \
  CODEX_ROLLOUT_ROOT_OVERRIDE="$FIXTURE_DIR" \
  QWEN_TASK_DB_OVERRIDE="$FIXTURE_QWEN_DB" \
  QWEN_DESKTOP_SNAPSHOT_OVERRIDE="$FIXTURE_QWEN_SNAPSHOT" \
  KIMI_SESSION_INDEX_OVERRIDE="$FIXTURE_DIR/missing-kimi-index.jsonl" \
  KIMI_WORK_STATUS_DIRECTORY_OVERRIDE="$FIXTURE_KIMI_WORK_DIR" \
  "$BINARY" --activity-probe
)"
[[ "$kimi_work_only_probe_output" == "ACTIVITY_PROBE_OK codex=2 qwen=2 kimi=3" ]] || {
  print -u2 "Kimi Work 独立活动探测自检失败：$kimi_work_only_probe_output"
  exit 25
}

kimi_cli_only_probe_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_INDEX" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_GLOBAL_STATE" \
  CODEX_ROLLOUT_ROOT_OVERRIDE="$FIXTURE_DIR" \
  QWEN_TASK_DB_OVERRIDE="$FIXTURE_QWEN_DB" \
  QWEN_DESKTOP_SNAPSHOT_OVERRIDE="$FIXTURE_QWEN_SNAPSHOT" \
  KIMI_SESSION_INDEX_OVERRIDE="$FIXTURE_KIMI_INDEX" \
  KIMI_MONITOR_SESSION_ID_OVERRIDE="kimi-monitor" \
  KIMI_ACTIVE_WORK_DIRS_OVERRIDE="/tmp/Kimi中文项目" \
  KIMI_WORK_STATUS_DIRECTORY_OVERRIDE="$FIXTURE_DIR/missing-kimi-work" \
  "$BINARY" --activity-probe
)"
[[ "$kimi_cli_only_probe_output" == "ACTIVITY_PROBE_OK codex=2 qwen=2 kimi=1" ]] || {
  print -u2 "Kimi CLI 独立活动探测回退失败：$kimi_cli_only_probe_output"
  exit 26
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
   && "$before_kimi_stale_hash" == "$after_kimi_stale_hash" \
   && "$before_kimi_monitor_hash" == "$after_kimi_monitor_hash" \
   && "$before_kimi_work_status_hash" == "$after_kimi_work_status_hash" \
   && "$before_kimi_work_unread_hash" == "$after_kimi_work_unread_hash" \
   && "$before_kimi_work_title_hash" == "$after_kimi_work_title_hash" \
   && "$before_kimi_total_usage_hash" == "$after_kimi_total_usage_hash" ]] || {
  print -u2 "自检修改了固定 Kimi 测试会话"
  exit 16
}

fallback_output="$(
  CODEX_TASK_DB_OVERRIDE="$FIXTURE_DB" \
  CODEX_SESSION_INDEX_OVERRIDE="$FIXTURE_DIR/missing-session-index.jsonl" \
  CODEX_GLOBAL_STATE_OVERRIDE="$FIXTURE_DIR/missing-global-state.json" \
  QWEN_TASK_DB_OVERRIDE="$FIXTURE_QWEN_DB" \
  QWEN_UNREAD_CHAT_IDS_OVERRIDE="qwen-chat-review" \
  QWEN_UNREAD_SUBCHAT_IDS_OVERRIDE="qwen-sub-review" \
  KIMI_SESSION_INDEX_OVERRIDE="$FIXTURE_KIMI_INDEX" \
  KIMI_MONITOR_SESSION_ID_OVERRIDE="kimi-monitor" \
  KIMI_ACTIVE_WORK_DIRS_OVERRIDE="/tmp/Kimi中文项目" \
  KIMI_WORK_STATUS_DIRECTORY_OVERRIDE="$FIXTURE_KIMI_WORK_DIR" \
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

synthetic_ui_output="$(
  "$ROOT/scripts/launch_synthetic_ui_qa.sh" --prepare-only
)"
[[ "$synthetic_ui_output" == "SYNTHETIC_UI_QA_READY app=$BUILD_DIR/ui-qa/本机AI状态栏 QA.app" ]] || {
  print -u2 "合成数据桌面验收副本准备失败：$synthetic_ui_output"
  exit 24
}

print "$self_test_output"
print "$usage_test_output"
print "$usage_resilience_output"
print "$qwen_bridge_output"
print "$kimi_usage_output"
print "$activity_probe_output"
print "$kimi_work_only_probe_output"
print "$kimi_cli_only_probe_output"
print "QA_OK app=$APP_DIR"
