---
name: codex-recent-tasks-sidebar
description: Build, customize, validate, or repair the native macOS 本机AI状态栏. Use when a user wants a 240-point always-on-top utility that monitors active Codex, QwenWorkCN, and Kimi threads and remaining quota without exposing task content or credentials.
---

# 本机AI状态栏

Use the bundled native SwiftUI template. Preserve the local-only privacy boundary and complete both synthetic QA and privacy-safe live checks before delivery.

## Workflow

1. Confirm macOS 13+ and the presence of `/usr/bin/swiftc`, `/usr/bin/sqlite3`, `/usr/bin/codesign`, and `/usr/bin/plutil`.
2. Keep all real Codex, QwenWorkCN, and Kimi task stores read-only. Never print, copy, upload, commit, or summarize real task titles, IDs, messages, database rows, session files, credentials, or raw quota responses.
3. Build with `scripts/build_app.sh [output-directory]`. It creates the ad-hoc-signed `本机AI状态栏.app` for the current Mac architecture.
4. Run repository-level `scripts/qa.sh`. The fixed fixtures must cover all three agents, active-only filtering, Chinese names, the 240-point layout, bottom-aligned docking, quota parsing, fault recovery, input hashes, signing, and redaction.
5. Launch only the app in the build directory unless the user explicitly authorizes an `/Applications` write.
6. Verify the live application without exposing task content:
   - custom icon, Dock entry, and menu bar item exist;
   - the window width is 240 points and text remains readable;
   - only running, waiting-for-action, and pending-review threads appear;
   - real Chinese project and thread names are preserved;
   - pinned and docked modes both stay above other applications;
   - left and right docking align the panel with the Codex bottom edge;
   - Codex opens the exact `codex://threads/{id}` target;
   - QwenWorkCN opens the exact local Chat ID through its desktop bridge;
   - Kimi opens the Agent page, with exact-session navigation reported as unavailable until a verifiable upstream route exists;
   - quota failures degrade to a visible unavailable/stale state without blocking task monitoring.

## Data adapters

### Codex

- Read the task database, `session_index.jsonl`, `.codex-global-state.json`, and bounded rollout event metadata.
- Match unread state by top-level Thread ID.
- Treat `needsAction`, `running`, and stopped-unread `needsReview` as active.
- Use the bundled Codex service for quota, retaining only in-memory percentages.

### QwenWorkCN

- Open `agents.db` read-only and select only project/chat/sub-chat identity, status, and timestamps.
- Use the running desktop app's localhost bridge for `auth.getUsage` and `desktopApi.openMainWindowWithChat(chatId)`.
- Read pending-review state non-destructively from the persistent `agents:unseenChanges` and `agents:subChatUnseenChanges` local stores. Never call `getPendingCompletions`; it consumes the completion queue and clears the desktop badge.
- Do not read page titles, DOM content, cookies, bearer tokens, or credential stores.
- If the bridge is unavailable, keep local activity visible where possible and mark quota unavailable.

### Kimi

- Read only the local session index, state metadata, and `context.append_loop_event` records needed to balance `step.begin` and `step.end`.
- Bound wire-file reads and prefilter event lines before JSON parsing.
- Treat an unmatched `step.begin` as only an activity candidate. Display it only when a currently running `kimi` executable has the same working directory; fail closed when the process cannot be verified.
- Read combined Kimi + Code total usage only from the latest `omniRatio` aggregate in a bounded tail of `~/Library/Logs/kimi-desktop/main.log`; never parse or emit unrelated log lines.
- Read the Code 5-hour and 7-day limits through a real PTY invocation of Kimi CLI `/usage`, normalize current labels such as `5h limit`, and merge them after the total row.
- Reuse one dedicated monitoring session, save only its session ID, and exclude it from activity results.
- Never delete diagnostic or monitor sessions without explicit user authorization.

## Presentation rules

- Product name: `本机AI状态栏`.
- Fixed panel width: 240 points.
- Use compact native macOS typography and system materials.
- Keep semantic status indicators restrained: running, waiting for action, pending review, unavailable.
- Render Kimi quota as three compact rows ordered `总量`, `5h`, `7天`, with values formatted as `余 n%`. If the desktop aggregate is unavailable, keep the verified Code rows instead of inventing a total.
- Group active threads by real project name. Do not substitute English demo labels in live UI.
- Always-on-top is the invariant. Docked versus pinned changes position, not layer.
- Docking aligns bottom edges, not top edges.

## Safety boundaries

- Never write to source task databases, task indexes, rollout/wire files, unread state, or credentials.
- Never consume or clear QwenWorkCN unread/completion state while monitoring it.
- Never log real titles, IDs, local usernames, task payloads, quota payloads, or tokens.
- Never copy or expose Kimi desktop logs; inspect only the bounded aggregate line needed for total usage.
- Never infer authorization to install or replace `/Applications/本机AI状态栏.app`.
- Keep task selection keyed by unique IDs; titles are display labels only.
- Do not present Kimi navigation as exact until a working per-session route is independently verified.
- Treat upstream schema, local bridge, CLI output, bundle ID, and deep-link changes as adapter failures, not permission to inspect secrets.

## Delivery report

Report:

- build app path and architecture;
- synthetic QA result;
- privacy-safe live connection result for each agent;
- icon, Dock, always-on-top, left/right bottom docking, and navigation checks;
- known limitations and any unverified check;
- confirmation that `/Applications` was untouched.

Do not mark delivery complete if a required check was skipped or if any result would require revealing real task content.
