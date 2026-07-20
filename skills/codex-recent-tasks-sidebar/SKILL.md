---
name: codex-recent-tasks-sidebar
description: Build, customize, validate, or repair a native macOS Codex recent-tasks companion window. Use when a user wants a Dock-visible SwiftUI utility that reads recent Codex tasks and remaining usage, groups tasks by working folder, shows activity times, opens exact tasks, docks on either side of Codex, follows Codex foreground state, or stays independently pinned.
---

# Codex Recent Tasks Sidebar

Build from the bundled template instead of recreating the app. Preserve its read-only data boundary and complete the real macOS checks before delivery.

## Workflow

1. Confirm the machine is macOS 13 or newer and has `/usr/bin/swiftc`, `/usr/bin/sqlite3`, `/usr/bin/codesign`, and `/usr/bin/plutil`.
2. Confirm Codex or the ChatGPT desktop app has been used at least once. Locate its task database and `session_index.jsonl` under `~/.codex/` without copying, printing, or committing task contents. Remaining usage is enabled by default and requires the official bundled `codex app-server` plus the user's existing signed-in state.
3. Use `scripts/build_app.sh [output-directory]`. The script compiles the template for the current Mac architecture and creates an ad-hoc-signed `CodexRecentTasksSidebar.app` whose visible name is “Codex 最近任务”.
4. Run the repository-level `scripts/qa.sh` when working from the full repository. If the Skill is installed alone, run the built binary with `--self-test` against a disposable SQLite fixture and `--usage-self-test` against a fake executable supplied through `CODEX_APP_SERVER_OVERRIDE` before using real data.
5. Launch the app and verify the real UI:
   - the custom icon and Dock item are present;
   - recent tasks are grouped by canonical working folder and sorted newest first;
   - renamed task notes from `session_index.jsonl` replace stale database titles on the next refresh;
   - remaining usage percentages appear without reset times; a usage failure leaves the task list usable;
   - left and right docking both work;
   - docked mode follows the Codex foreground/background layer;
   - pinned mode stays above other apps and remains draggable;
   - clicking a task activates Codex and opens its exact `codex://threads/{id}` deep link;
   - switching to Codex does not close or terminate the companion app.
6. Install or replace an app in `/Applications` only when the user has authorized that write.

## Customization

Edit only files under `assets/app-template/` when the user asks for a different app name, bundle identifier, time window, colors, or layout. Keep the default behavior when no customization is requested.

The public template intentionally uses the generic bundle identifier `io.github.codexrecenttasks.sidebar`. Change it before distributing a separately branded fork.

## Safety boundaries

- Treat the Codex SQLite database and `session_index.jsonl` as read-only. Never migrate, vacuum, replace, upload, or write to them.
- Fetch remaining usage only through the official `codex app-server` using the existing login state. Do not read, print, persist, or commit auth files, tokens, raw account responses, or reset timestamps.
- Never commit a real `.sqlite` file, task title, thread ID, username path, API key, token, crash log, or local build cache.
- Keep task selection keyed by the unique thread ID; titles are not unique identifiers.
- Keep archived tasks, threads with a real parent edge, and internal agent records excluded. Do not exclude a root thread solely because `thread_source` is labeled `subagent`.
- Do not claim cross-platform support. The bundled app targets macOS 13+ and is validated on Apple Silicon; compile natively on the target Mac.
- If the Codex database schema, app-server rate-limit response, bundle identifier, or deep-link scheme changes, diagnose the current installation before patching the template.

## Delivery report

Report the output app path, macOS architecture, self-test result, UI checks, database read-only evidence, known issues, and unverified items. Do not mark delivery complete when a required real UI check is missing.
