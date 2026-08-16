import AppKit
import Darwin
import Foundation
import SwiftUI

enum TaskRuntimeState: String, Equatable, Sendable {
    case unknown
    case idle
    case running
    case needsAction
}

enum TaskDisplayState: Equatable {
    case idle
    case running
    case needsAction
    case needsReview

    static func resolve(runtimeState: TaskRuntimeState, hasUnreadUpdate: Bool) -> TaskDisplayState {
        switch runtimeState {
        case .needsAction:
            return .needsAction
        case .running:
            return .running
        case .idle, .unknown:
            return hasUnreadUpdate ? .needsReview : .idle
        }
    }

    var badgeText: String? {
        switch self {
        case .idle:
            return nil
        case .running:
            return "运行中"
        case .needsAction:
            return "待操作"
        case .needsReview:
            return "待查看"
        }
    }

    var statusDescription: String {
        switch self {
        case .idle:
            return "暂无未读更新"
        case .running:
            return "任务正在运行"
        case .needsAction:
            return "任务正在等待操作"
        case .needsReview:
            return "有新回复（待查看）"
        }
    }

    var tintColor: Color {
        switch self {
        case .idle, .running:
            return .accentColor
        case .needsAction:
            return .orange
        case .needsReview:
            return .green
        }
    }
}

struct CodexTask: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let cwd: String
    let gitBranch: String
    let updatedMillis: Int64
    let rolloutPath: String
    let hasUnreadUpdate: Bool
    let runtimeState: TaskRuntimeState

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cwd
        case gitBranch = "git_branch"
        case updatedMillis = "updated_ms"
        case rolloutPath = "rollout_path"
    }

    init(
        id: String,
        title: String,
        cwd: String,
        gitBranch: String,
        updatedMillis: Int64,
        rolloutPath: String = "",
        hasUnreadUpdate: Bool = false,
        runtimeState: TaskRuntimeState = .unknown
    ) {
        self.id = id
        self.title = title
        self.cwd = cwd
        self.gitBranch = gitBranch
        self.updatedMillis = updatedMillis
        self.rolloutPath = rolloutPath
        self.hasUnreadUpdate = hasUnreadUpdate
        self.runtimeState = runtimeState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        cwd = try container.decode(String.self, forKey: .cwd)
        gitBranch = try container.decode(String.self, forKey: .gitBranch)
        updatedMillis = try container.decode(Int64.self, forKey: .updatedMillis)
        rolloutPath = try container.decodeIfPresent(String.self, forKey: .rolloutPath) ?? ""
        hasUnreadUpdate = false
        runtimeState = .unknown
    }

    var deepLink: URL? {
        URL(string: "codex://threads/\(id)")
    }

    var canonicalProjectPath: String {
        URL(fileURLWithPath: cwd)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    var projectName: String {
        let name = URL(fileURLWithPath: canonicalProjectPath).lastPathComponent
        return name.isEmpty ? "未归类" : name
    }

    var displayState: TaskDisplayState {
        TaskDisplayState.resolve(runtimeState: runtimeState, hasUnreadUpdate: hasUnreadUpdate)
    }

    func replacingTitle(with newTitle: String) -> CodexTask {
        CodexTask(
            id: id,
            title: newTitle,
            cwd: cwd,
            gitBranch: gitBranch,
            updatedMillis: updatedMillis,
            rolloutPath: rolloutPath,
            hasUnreadUpdate: hasUnreadUpdate,
            runtimeState: runtimeState
        )
    }

    func replacingUnreadUpdate(with newValue: Bool) -> CodexTask {
        CodexTask(
            id: id,
            title: title,
            cwd: cwd,
            gitBranch: gitBranch,
            updatedMillis: updatedMillis,
            rolloutPath: rolloutPath,
            hasUnreadUpdate: newValue,
            runtimeState: runtimeState
        )
    }

    func replacingRuntimeState(with newValue: TaskRuntimeState) -> CodexTask {
        CodexTask(
            id: id,
            title: title,
            cwd: cwd,
            gitBranch: gitBranch,
            updatedMillis: updatedMillis,
            rolloutPath: rolloutPath,
            hasUnreadUpdate: hasUnreadUpdate,
            runtimeState: newValue
        )
    }
}

private struct ThreadNameRecord: Decodable {
    let id: String
    let threadName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case threadName = "thread_name"
    }
}

private enum UnreadTaskStateRepository {
    private static let persistedAtomsKey = "electron-persisted-atom-state"
    private static let unreadThreadsKey = "unread-thread-ids-by-host-v1"
    private static let maximumFileSize = 64 * 1024 * 1024

    static func loadUnreadThreadIDs() -> Set<String> {
        guard let url = currentGlobalStateURL(),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue <= maximumFileSize,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return []
        }
        return unreadThreadIDs(from: data)
    }

    static func unreadThreadIDs(from data: Data) -> Set<String> {
        guard data.count <= maximumFileSize,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let persistedAtoms = root[persistedAtomsKey] as? [String: Any],
              let unreadThreadsByHost = persistedAtoms[unreadThreadsKey] as? [String: Any] else {
            return []
        }

        var unreadThreadIDs = Set<String>()
        for value in unreadThreadsByHost.values {
            guard let threadIDs = value as? [Any] else { continue }
            for case let threadID as String in threadIDs
                where threadID.count <= 128 && UUID(uuidString: threadID) != nil {
                unreadThreadIDs.insert(threadID)
            }
        }
        return unreadThreadIDs
    }

    private static func currentGlobalStateURL() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CODEX_GLOBAL_STATE_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/.codex-global-state.json")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }
}

private final class RolloutTaskStateRepository: @unchecked Sendable {
    static let shared = RolloutTaskStateRepository()

    private struct CacheEntry {
        let fileSize: UInt64
        let modificationDate: Date
        let state: TaskRuntimeState
        let pendingActionCallIDs: Set<String>
        let canAdvanceIncrementally: Bool
    }

    private struct StateRecord {
        let recordType: String
        let payloadType: String
        let payload: [String: Any]
    }

    private struct StateSnapshot {
        let state: TaskRuntimeState
        let pendingActionCallIDs: Set<String>
        let canAdvanceIncrementally: Bool
        let scannedBytes: UInt64
    }

    struct Diagnostics {
        let fullScanCount: Int
        let incrementalScanCount: Int
        let fullScanBytes: UInt64
        let incrementalScanBytes: UInt64
    }

    private struct ReverseScanContext {
        var completedCallIDs = Set<String>()

        mutating func consume(lineData: Data) -> StateSnapshot? {
            guard let record = RolloutTaskStateRepository.stateRecord(from: lineData) else {
                return nil
            }

            if record.recordType == "event_msg" {
                switch record.payloadType {
                case "task_complete", "turn_aborted":
                    return StateSnapshot(
                        state: .idle,
                        pendingActionCallIDs: [],
                        canAdvanceIncrementally: true,
                        scannedBytes: 0
                    )
                case "task_started":
                    return StateSnapshot(
                        state: .running,
                        pendingActionCallIDs: [],
                        canAdvanceIncrementally: true,
                        scannedBytes: 0
                    )
                case "thread/status/changed":
                    guard let status = record.payload["status"] as? [String: Any],
                          let statusType = status["type"] as? String else {
                        return nil
                    }
                    if statusType == "idle" {
                        return StateSnapshot(
                            state: .idle,
                            pendingActionCallIDs: [],
                            canAdvanceIncrementally: true,
                            scannedBytes: 0
                        )
                    }
                    if statusType == "active" {
                        let flags = status["activeFlags"] as? [String] ?? []
                        let state: TaskRuntimeState =
                            flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput")
                            ? .needsAction : .running
                        return StateSnapshot(
                            state: state,
                            pendingActionCallIDs: [],
                            canAdvanceIncrementally: true,
                            scannedBytes: 0
                        )
                    }
                default:
                    break
                }
            }

            if record.recordType == "response_item",
               record.payloadType == "function_call_output"
                    || record.payloadType == "custom_tool_call_output",
               let callID = record.payload["call_id"] as? String {
                completedCallIDs.insert(callID)
                return nil
            }

            if record.recordType == "response_item",
               record.payloadType == "function_call"
                    || record.payloadType == "custom_tool_call",
               let callID = record.payload["call_id"] as? String {
                let alreadyCompleted = completedCallIDs.remove(callID) != nil
                if !alreadyCompleted,
                   RolloutTaskStateRepository.requiresUserAction(payload: record.payload) {
                    return StateSnapshot(
                        state: .needsAction,
                        pendingActionCallIDs: [callID],
                        canAdvanceIncrementally: true,
                        scannedBytes: 0
                    )
                }
            }

            return nil
        }
    }

    private struct ForwardScanContext {
        var state: TaskRuntimeState
        var pendingActionCallIDs: Set<String>

        mutating func consume(lineData: Data) {
            guard let record = RolloutTaskStateRepository.stateRecord(from: lineData) else {
                return
            }

            if record.recordType == "event_msg" {
                switch record.payloadType {
                case "task_complete", "turn_aborted":
                    state = .idle
                    pendingActionCallIDs.removeAll()
                case "task_started":
                    state = .running
                    pendingActionCallIDs.removeAll()
                case "thread/status/changed":
                    guard let status = record.payload["status"] as? [String: Any],
                          let statusType = status["type"] as? String else {
                        return
                    }
                    if statusType == "idle" {
                        state = .idle
                        pendingActionCallIDs.removeAll()
                    } else if statusType == "active" {
                        let flags = status["activeFlags"] as? [String] ?? []
                        state = flags.contains("waitingOnApproval")
                            || flags.contains("waitingOnUserInput")
                            ? .needsAction : .running
                        if state != .needsAction {
                            pendingActionCallIDs.removeAll()
                        }
                    }
                default:
                    break
                }
                return
            }

            guard record.recordType == "response_item",
                  let callID = record.payload["call_id"] as? String else {
                return
            }
            if record.payloadType == "function_call"
                || record.payloadType == "custom_tool_call" {
                if RolloutTaskStateRepository.requiresUserAction(payload: record.payload) {
                    pendingActionCallIDs.insert(callID)
                    state = .needsAction
                }
            } else if record.payloadType == "function_call_output"
                        || record.payloadType == "custom_tool_call_output",
                      pendingActionCallIDs.remove(callID) != nil,
                      pendingActionCallIDs.isEmpty {
                state = .running
            }
        }
    }

    private static let relevantTokens = [
        "task_started",
        "task_complete",
        "turn_aborted",
        "thread/status/changed",
        "function_call",
        "function_call_output",
        "custom_tool_call",
        "custom_tool_call_output",
    ].map { Data($0.utf8) }

    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var fullScanCount = 0
    private var incrementalScanCount = 0
    private var fullScanBytes: UInt64 = 0
    private var incrementalScanBytes: UInt64 = 0

    func loadState(rolloutPath: String) -> TaskRuntimeState {
        guard let url = validatedRolloutURL(for: rolloutPath),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSizeNumber = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return .unknown
        }

        let fileSize = fileSizeNumber.uint64Value
        guard fileSize > 0, fileSize <= 512 * 1024 * 1024 else {
            return .unknown
        }

        lock.lock()
        let cached = cache[url.path]
        lock.unlock()
        if let cached,
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate {
            return cached.state
        }

        if let cached,
           cached.canAdvanceIncrementally,
           fileSize > cached.fileSize,
           fileSize - cached.fileSize <= 16 * 1024 * 1024 {
            guard fileEndsWithNewline(at: url, fileSize: fileSize),
                  let snapshot = scanAppendedState(
                      at: url,
                      fromOffset: cached.fileSize,
                      fileSize: fileSize,
                      initialState: cached.state,
                      pendingActionCallIDs: cached.pendingActionCallIDs
                  ) else {
                return cached.state
            }
            lock.lock()
            cache[url.path] = CacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                state: snapshot.state,
                pendingActionCallIDs: snapshot.pendingActionCallIDs,
                canAdvanceIncrementally: snapshot.canAdvanceIncrementally
            )
            incrementalScanCount += 1
            incrementalScanBytes += snapshot.scannedBytes
            lock.unlock()
            return snapshot.state
        }

        let snapshot = scanState(at: url, fileSize: fileSize)
        lock.lock()
        cache[url.path] = CacheEntry(
            fileSize: fileSize,
            modificationDate: modificationDate,
            state: snapshot.state,
            pendingActionCallIDs: snapshot.pendingActionCallIDs,
            canAdvanceIncrementally: snapshot.canAdvanceIncrementally
        )
        fullScanCount += 1
        fullScanBytes += snapshot.scannedBytes
        lock.unlock()
        return snapshot.state
    }

    static func state(from data: Data) -> TaskRuntimeState {
        var context = ReverseScanContext()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            if let snapshot = context.consume(lineData: Data(line)) {
                return snapshot.state
            }
        }
        return .unknown
    }

    func diagnosticsSnapshot() -> Diagnostics {
        lock.lock()
        defer { lock.unlock() }
        return Diagnostics(
            fullScanCount: fullScanCount,
            incrementalScanCount: incrementalScanCount,
            fullScanBytes: fullScanBytes,
            incrementalScanBytes: incrementalScanBytes
        )
    }

    private static func stateRecord(from lineData: Data) -> StateRecord? {
        guard !lineData.isEmpty,
              lineData.count <= 4 * 1024 * 1024,
              relevantTokens.contains(where: { lineData.range(of: $0) != nil }),
              let record = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
              let recordType = record["type"] as? String,
              let payload = record["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else {
            return nil
        }
        return StateRecord(recordType: recordType, payloadType: payloadType, payload: payload)
    }

    private static func requiresUserAction(payload: [String: Any]) -> Bool {
        guard let name = payload["name"] as? String else { return false }
        if name == "request_user_input" {
            return true
        }
        guard name == "exec_command" || name == "exec",
              let rawArguments = (payload["arguments"] as? String) ?? (payload["input"] as? String),
              rawArguments.utf8.count <= 64 * 1024,
              let data = rawArguments.data(using: .utf8),
              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return arguments["sandbox_permissions"] as? String == "require_escalated"
    }

    private func scanAppendedState(
        at url: URL,
        fromOffset: UInt64,
        fileSize: UInt64,
        initialState: TaskRuntimeState,
        pendingActionCallIDs: Set<String>
    ) -> StateSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: fromOffset)
        } catch {
            return nil
        }

        let expectedLength = fileSize - fromOffset
        let data = handle.readDataToEndOfFile()
        guard data.count == Int(expectedLength) else {
            return nil
        }

        var context = ForwardScanContext(
            state: initialState,
            pendingActionCallIDs: pendingActionCallIDs
        )
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            context.consume(lineData: Data(line))
        }
        return StateSnapshot(
            state: context.state,
            pendingActionCallIDs: context.pendingActionCallIDs,
            canAdvanceIncrementally: true,
            scannedBytes: expectedLength
        )
    }

    private func scanState(at url: URL, fileSize: UInt64) -> StateSnapshot {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return StateSnapshot(
                state: .unknown,
                pendingActionCallIDs: [],
                canAdvanceIncrementally: false,
                scannedBytes: 0
            )
        }
        defer { try? handle.close() }

        var chunkSize: UInt64 = 256 * 1024
        let maximumBytesToScan: UInt64 = 64 * 1024 * 1024
        var remainingOffset = fileSize
        var scannedBytes: UInt64 = 0
        var carry = Data()
        var context = ReverseScanContext()

        // ponytail: 最多倒查 64 MB，覆盖正常单轮任务；若未来出现超大单轮，再改为增量事件索引。
        while remainingOffset > 0 && scannedBytes < maximumBytesToScan {
            let readLength = min(chunkSize, remainingOffset, maximumBytesToScan - scannedBytes)
            let readOffset = remainingOffset - readLength
            do {
                try handle.seek(toOffset: readOffset)
            } catch {
                return StateSnapshot(
                    state: .unknown,
                    pendingActionCallIDs: [],
                    canAdvanceIncrementally: false,
                    scannedBytes: scannedBytes
                )
            }
            let chunk = handle.readData(ofLength: Int(readLength))
            guard !chunk.isEmpty else {
                return StateSnapshot(
                    state: .unknown,
                    pendingActionCallIDs: [],
                    canAdvanceIncrementally: false,
                    scannedBytes: scannedBytes
                )
            }

            var combined = chunk
            combined.append(carry)
            let lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            let firstCompleteIndex = readOffset == 0 ? 0 : 1
            if lines.count > firstCompleteIndex {
                for index in stride(from: lines.count - 1, through: firstCompleteIndex, by: -1) {
                    if var snapshot = context.consume(lineData: Data(lines[index])) {
                        scannedBytes += readLength
                        snapshot = StateSnapshot(
                            state: snapshot.state,
                            pendingActionCallIDs: snapshot.pendingActionCallIDs,
                            canAdvanceIncrementally: fileEndsWithNewline(
                                handle: handle,
                                fileSize: fileSize
                            ),
                            scannedBytes: scannedBytes
                        )
                        return snapshot
                    }
                }
            }

            carry = lines.first.map { Data($0) } ?? Data()
            remainingOffset = readOffset
            scannedBytes += readLength
            chunkSize = min(chunkSize * 2, 8 * 1024 * 1024)
        }

        return StateSnapshot(
            state: .unknown,
            pendingActionCallIDs: [],
            canAdvanceIncrementally: fileEndsWithNewline(handle: handle, fileSize: fileSize),
            scannedBytes: scannedBytes
        )
    }

    private func fileEndsWithNewline(handle: FileHandle, fileSize: UInt64) -> Bool {
        guard fileSize > 0 else { return false }
        do {
            try handle.seek(toOffset: fileSize - 1)
        } catch {
            return false
        }
        return handle.readData(ofLength: 1).first == 0x0A
    }

    private func fileEndsWithNewline(at url: URL, fileSize: UInt64) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        // ponytail: Codex 正在写半行时先沿用缓存，下次刷新再读取，避免为瞬时半行退化成全量扫描。
        return fileEndsWithNewline(handle: handle, fileSize: fileSize)
    }

    private func validatedRolloutURL(for rolloutPath: String) -> URL? {
        guard !rolloutPath.isEmpty, rolloutPath.utf8.count <= 4_096 else { return nil }
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment
        let rootURL: URL
        if let override = environment["CODEX_ROLLOUT_ROOT_OVERRIDE"], !override.isEmpty {
            rootURL = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            rootURL = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex/sessions", isDirectory: true)
        }

        let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedURL = URL(fileURLWithPath: rolloutPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedURL.path.hasPrefix(resolvedRoot + "/"),
              fileManager.isReadableFile(atPath: resolvedURL.path) else {
            return nil
        }
        return resolvedURL
    }
}

struct TaskGroup: Identifiable {
    let id: String
    let name: String
    let tasks: [CodexTask]

    var latestUpdate: Int64 {
        tasks.first?.updatedMillis ?? 0
    }
}

enum RecentTaskPolicy {
    static let windowHours: Int64 = 48
    static let windowMillis = windowHours * 60 * 60 * 1000

    static func includes(_ task: CodexTask, now: Date) -> Bool {
        let cutoffMillis = Int64(now.timeIntervalSince1970 * 1000) - windowMillis
        return task.updatedMillis >= cutoffMillis
    }
}

enum TaskRepositoryError: LocalizedError {
    case databaseNotFound
    case sqliteFailed(String)
    case invalidData(String)

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            return "没有找到 Codex 本地任务数据库。请先打开并使用一次 Codex。"
        case let .sqliteFailed(message):
            return "读取任务数据库失败：\(message)"
        case let .invalidData(message):
            return "任务数据格式异常：\(message)"
        }
    }
}

struct TaskRepository {
    private static let query = """
    SELECT
      id,
      CASE WHEN trim(title) = '' THEN '未命名任务' ELSE substr(title, 1, 240) END AS title,
      cwd,
      COALESCE(git_branch, '') AS git_branch,
      CAST(COALESCE(NULLIF(updated_at_ms, 0), updated_at * 1000) AS INTEGER) AS updated_ms,
      COALESCE(rollout_path, '') AS rollout_path
    FROM threads AS task
    WHERE archived = 0
      AND COALESCE(source, '') NOT LIKE '{"subagent"%'
      AND (agent_path IS NULL OR agent_path = '')
      AND NOT EXISTS (
        SELECT 1
        FROM thread_spawn_edges AS edge
        WHERE edge.child_thread_id = task.id
      )
    ORDER BY updated_ms DESC, id ASC;
    """

    static func loadTasks() throws -> (databaseURL: URL, tasks: [CodexTask]) {
        let databaseURL = try currentDatabaseURL()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            "-readonly",
            "-json",
            "-cmd", ".timeout 800",
            databaseURL.path,
            query,
        ]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw TaskRepositoryError.sqliteFailed(error.localizedDescription)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let rawMessage = String(data: errorData, encoding: .utf8) ?? "未知错误"
            let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            throw TaskRepositoryError.sqliteFailed(message.isEmpty ? "sqlite3 退出码 \(process.terminationStatus)" : message)
        }

        do {
            let decodedTasks = data.isEmpty ? [] : try JSONDecoder().decode([CodexTask].self, from: data)
            let titleOverrides = loadLatestThreadNames()
            let unreadThreadIDs = UnreadTaskStateRepository.loadUnreadThreadIDs()
            let now = Date()
            let tasks = decodedTasks.map { task in
                let renamedTask = titleOverrides[task.id].map {
                    task.replacingTitle(with: $0)
                } ?? task
                // Codex 按当前任务 ID 标记和清除未读。内部子线程的残留未读不能抬升为顶层任务未读。
                let unreadTask = renamedTask.replacingUnreadUpdate(
                    with: unreadThreadIDs.contains(task.id)
                )
                guard RecentTaskPolicy.includes(unreadTask, now: now) else {
                    return unreadTask
                }
                return unreadTask.replacingRuntimeState(
                    with: RolloutTaskStateRepository.shared.loadState(rolloutPath: unreadTask.rolloutPath)
                )
            }
            return (databaseURL, tasks)
        } catch {
            throw TaskRepositoryError.invalidData(error.localizedDescription)
        }
    }

    private static func loadLatestThreadNames() -> [String: String] {
        guard let indexURL = currentSessionIndexURL(),
              let data = try? Data(contentsOf: indexURL) else {
            return [:]
        }

        let decoder = JSONDecoder()
        var namesByID: [String: String] = [:]

        // ponytail: Codex 的 session_index.jsonl 是追加式索引，因此每个 ID 最后一条有效记录即为最新备注。
        // 如果未来改成非追加格式，再升级为解析 updated_at 后比较时间。
        for line in data.split(separator: 0x0A) {
            guard let record = try? decoder.decode(ThreadNameRecord.self, from: Data(line)),
                  let rawName = record.threadName else {
                continue
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            namesByID[record.id] = name
        }

        return namesByID
    }

    private static func currentSessionIndexURL() -> URL? {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CODEX_SESSION_INDEX_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func currentDatabaseURL() throws -> URL {
        let fileManager = FileManager.default
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CODEX_TASK_DB_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw TaskRepositoryError.databaseNotFound
            }
            return url
        }

        let home = fileManager.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".codex/state_5.sqlite"),
            home.appendingPathComponent(".codex/sqlite/state_5.sqlite"),
        ].filter { fileManager.fileExists(atPath: $0.path) }

        guard let newest = candidates.max(by: { modificationDate(for: $0) < modificationDate(for: $1) }) else {
            throw TaskRepositoryError.databaseNotFound
        }
        return newest
    }

    private static func modificationDate(for url: URL) -> Date {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }
}

enum TimeLabelFormatter {
    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "MM-dd"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    static func shortLabel(milliseconds: Int64, now: Date = Date()) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        let elapsed = max(0, now.timeIntervalSince(date))

        if elapsed < 60 {
            return "刚刚"
        }
        if elapsed < 3600 {
            return "\(max(1, Int(elapsed / 60))) 分钟"
        }

        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return clockFormatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) {
            return "昨天 \(clockFormatter.string(from: date))"
        }
        return monthDayFormatter.string(from: date)
    }

    static func fullLabel(milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1000)
        return fullFormatter.string(from: date)
    }
}

enum WindowDisplayMode: String {
    case docked
    case pinned
}

enum DockSide: String {
    case left
    case right

    var label: String {
        self == .left ? "左侧" : "右侧"
    }
}

enum DockPlacement {
    static let gap: CGFloat = 8

    static func targetOrigin(
        codexFrame: NSRect,
        panelSize: NSSize,
        visibleFrame: NSRect,
        side: DockSide
    ) -> NSPoint {
        let targetX: CGFloat
        switch side {
        case .left:
            let outsideX = codexFrame.minX - panelSize.width - gap
            if outsideX >= visibleFrame.minX {
                targetX = outsideX
            } else {
                targetX = min(
                    max(visibleFrame.minX, codexFrame.minX + gap),
                    visibleFrame.maxX - panelSize.width
                )
            }
        case .right:
            let outsideX = codexFrame.maxX + gap
            if outsideX + panelSize.width <= visibleFrame.maxX {
                targetX = outsideX
            } else {
                targetX = min(
                    max(visibleFrame.minX, codexFrame.maxX - panelSize.width - gap),
                    visibleFrame.maxX - panelSize.width
                )
            }
        }

        let alignedTopY = codexFrame.maxY - panelSize.height
        let targetY = min(
            max(visibleFrame.minY, alignedTopY),
            visibleFrame.maxY - panelSize.height
        )
        return NSPoint(x: targetX, y: targetY)
    }
}

@MainActor
final class WindowModeModel: ObservableObject {
    @Published private(set) var mode: WindowDisplayMode = .docked
    @Published private(set) var dockSide: DockSide
    @Published fileprivate(set) var statusText = "正在查找 Codex 窗口"

    var onModeChange: ((WindowDisplayMode) -> Void)?
    var onDockSideChange: ((DockSide) -> Void)?
    var onPinnedDrag: ((CGSize, Bool) -> Void)?

    init() {
        let savedSide = UserDefaults.standard.string(forKey: "CodexRecentTasksDockSide")
        dockSide = DockSide(rawValue: savedSide ?? "") ?? .right
    }

    func select(_ newMode: WindowDisplayMode) {
        mode = newMode
        onModeChange?(newMode)
    }

    func selectDockSide(_ newSide: DockSide) {
        setDockSide(newSide, notify: true)
    }

    func observeDockSide(_ newSide: DockSide) {
        setDockSide(newSide, notify: false)
    }

    func dragPinnedWindow(translation: CGSize, ended: Bool) {
        onPinnedDrag?(translation, ended)
    }

    private func setDockSide(_ newSide: DockSide, notify: Bool) {
        guard dockSide != newSide else { return }
        dockSide = newSide
        UserDefaults.standard.set(newSide.rawValue, forKey: "CodexRecentTasksDockSide")
        if notify {
            onDockSideChange?(newSide)
        }
    }
}

enum CodexWindowLocator {
    static func largestWindowFrame() -> NSRect? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let quartzFrames = windows.compactMap { info -> CGRect? in
            guard
                let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber,
                let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                layerNumber.intValue == 0,
                let runningApplication = NSRunningApplication(processIdentifier: pid_t(pidNumber.int32Value)),
                runningApplication.bundleIdentifier == "com.openai.codex",
                let bounds = info[kCGWindowBounds as String] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue,
                width >= 500,
                height >= 320
            else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        guard let quartzFrame = quartzFrames.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return nil
        }

        let primaryScreenHeight = NSScreen.screens.first?.frame.height ?? quartzFrame.maxY
        return NSRect(
            x: quartzFrame.minX,
            y: primaryScreenHeight - quartzFrame.maxY,
            width: quartzFrame.width,
            height: quartzFrame.height
        )
    }
}

@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [CodexTask] = []
    @Published private(set) var databasePath = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var now = Date()

    private var refreshTimer: Timer?
    private var runtimeRefreshTimer: Timer?
    private let refreshQueue = DispatchQueue(
        label: "io.github.codexrecenttasks.refresh",
        qos: .utility
    )
    private var isFullRefreshInFlight = false
    private var fullRefreshRequestedAgain = false
    private var isRuntimeRefreshInFlight = false

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refreshTimer?.tolerance = 3
        runtimeRefreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRuntimeStates()
            }
        }
        runtimeRefreshTimer?.tolerance = 1
    }

    deinit {
        refreshTimer?.invalidate()
        runtimeRefreshTimer?.invalidate()
    }

    func refresh() {
        now = Date()
        guard !isFullRefreshInFlight else {
            fullRefreshRequestedAgain = true
            return
        }
        isFullRefreshInFlight = true

        refreshQueue.async {
            let result: Result<(databaseURL: URL, tasks: [CodexTask]), Error> = Result {
                try TaskRepository.loadTasks()
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isFullRefreshInFlight = false
                switch result {
                case let .success(loaded):
                    if self.tasks != loaded.tasks {
                        self.tasks = loaded.tasks
                    }
                    self.databasePath = loaded.databaseURL.path
                    self.errorMessage = nil
                    self.lastRefresh = Date()
                case let .failure(error):
                    self.errorMessage = error.localizedDescription
                }
                if self.fullRefreshRequestedAgain {
                    self.fullRefreshRequestedAgain = false
                    self.refresh()
                }
            }
        }
    }

    func refreshRuntimeStates() {
        now = Date()
        guard !isRuntimeRefreshInFlight else { return }
        let referenceNow = now
        let taskSnapshot = tasks.filter { RecentTaskPolicy.includes($0, now: referenceNow) }
        guard !taskSnapshot.isEmpty else { return }
        isRuntimeRefreshInFlight = true

        refreshQueue.async {
            let updates = taskSnapshot.map { task in
                (
                    id: task.id,
                    rolloutPath: task.rolloutPath,
                    state: RolloutTaskStateRepository.shared.loadState(
                        rolloutPath: task.rolloutPath
                    )
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRuntimeRefreshInFlight = false
                let updatesByID = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
                let refreshedTasks = self.tasks.map { task in
                    guard let update = updatesByID[task.id],
                          update.rolloutPath == task.rolloutPath,
                          update.state != task.runtimeState else {
                        return task
                    }
                    return task.replacingRuntimeState(with: update.state)
                }
                if refreshedTasks != self.tasks {
                    self.tasks = refreshedTasks
                }
            }
        }
    }

    func groups(matching searchText: String) -> [TaskGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let recentTasks = tasks.filter { RecentTaskPolicy.includes($0, now: now) }
        let visibleTasks: [CodexTask]
        if query.isEmpty {
            visibleTasks = recentTasks
        } else {
            visibleTasks = recentTasks.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.projectName.localizedCaseInsensitiveContains(query)
                    || $0.gitBranch.localizedCaseInsensitiveContains(query)
            }
        }

        let grouped = Dictionary(grouping: visibleTasks, by: \CodexTask.canonicalProjectPath)
        return grouped.map { path, projectTasks in
            let sorted = projectTasks.sorted {
                if $0.updatedMillis == $1.updatedMillis { return $0.id < $1.id }
                return $0.updatedMillis > $1.updatedMillis
            }
            return TaskGroup(id: path, name: sorted.first?.projectName ?? "未归类", tasks: sorted)
        }.sorted {
            if $0.latestUpdate == $1.latestUpdate { return $0.name < $1.name }
            return $0.latestUpdate > $1.latestUpdate
        }
    }

    func open(_ task: CodexTask) {
        guard let url = task.deepLink else {
            errorMessage = "任务链接无效：\(task.id)"
            return
        }
        guard NSWorkspace.shared.open(url) else {
            errorMessage = "无法打开任务，请确认 ChatGPT / Codex 已安装。"
            return
        }
        errorMessage = nil

        // 从后置窗口触发深链时，LaunchServices 不一定会把已运行的 Codex 提到前台。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            guard let codex = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == "com.openai.codex"
            }) else { return }
            codex.activate(options: [.activateAllWindows])
        }

        // Codex 会在任务被打开后清除未读更新状态；稍后只读刷新，让绿色标识及时同步消失。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refresh()
        }
    }
}

struct UsageWindowDisplay: Identifiable, Equatable, Sendable {
    let label: String
    let remainingPercent: Int
    let resetAt: Date?

    init(label: String, remainingPercent: Int, resetAt: Date? = nil) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }

    var id: String { label }
}

enum UsageState: Equatable {
    case loading
    case available([UsageWindowDisplay], isStale: Bool)
    case unavailable(String)
}

enum CodexUsageError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case protocolFailed(String)
    case timedOut

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "没有找到 Codex 官方程序。请确认 ChatGPT / Codex 已安装。"
        case let .launchFailed(message):
            return "无法启动 Codex 用量服务：\(message)"
        case let .protocolFailed(message):
            return "Codex 用量响应异常：\(message)"
        case .timedOut:
            return "读取 Codex 剩余用量超时。"
        }
    }
}

enum UsageSnapshotParser {
    static func windows(from result: [String: Any]) throws -> [UsageWindowDisplay] {
        guard let rateLimits = result["rateLimits"] as? [String: Any] else {
            throw CodexUsageError.protocolFailed("缺少 rateLimits")
        }

        let candidates: [(key: String, fallback: String)] = [
            ("primary", "主要额度"),
            ("secondary", "次要额度"),
        ]
        let windows = candidates.compactMap { candidate -> UsageWindowDisplay? in
            guard let rawWindow = rateLimits[candidate.key] as? [String: Any],
                  let usedNumber = rawWindow["usedPercent"] as? NSNumber else {
                return nil
            }
            let usedPercent = min(max(usedNumber.intValue, 0), 100)
            let duration = (rawWindow["windowDurationMins"] as? NSNumber)?.intValue
            return UsageWindowDisplay(
                label: durationLabel(minutes: duration, fallback: candidate.fallback),
                remainingPercent: 100 - usedPercent,
                resetAt: resetDate(from: rawWindow["resetsAt"])
            )
        }

        guard !windows.isEmpty else {
            throw CodexUsageError.protocolFailed("没有可显示的用量周期")
        }
        return windows
    }

    private static func durationLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        if minutes == 10_080 { return "每周" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440) 天" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小时" }
        return "\(minutes) 分钟"
    }

    private static func resetDate(from value: Any?) -> Date? {
        guard let seconds = (value as? NSNumber)?.doubleValue,
              seconds.isFinite,
              seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}

final class CodexUsageClient: @unchecked Sendable {
    typealias Completion = @Sendable (Result<[UsageWindowDisplay], Error>) -> Void

    private let queue = DispatchQueue(label: "io.github.codexrecenttasks.usage")
    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputHandle: FileHandle?
    private var readBuffer = Data()
    private var initialized = false
    private var isStopping = false
    private var currentRequestID: Int?
    private var nextRequestID = 2
    private var pendingCompletions: [Completion] = []

    func refresh(completion: @escaping Completion) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingCompletions.append(completion)
            if self.process?.isRunning == true {
                if self.initialized {
                    self.sendRateLimitsRequestIfNeeded()
                }
                return
            }
            self.start()
        }
    }

    func stop() {
        queue.sync {
            shutdown()
            pendingCompletions.removeAll()
        }
    }

    func reset() {
        queue.async { [weak self] in
            guard let self else { return }
            shutdown()
            pendingCompletions.removeAll()
        }
    }

    private func start() {
        do {
            let executableURL = try Self.executableURL()
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()

            process.executableURL = executableURL
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] terminatedProcess in
                guard let self else { return }
                self.queue.async { [weak self] in
                    guard let self,
                          self.process === terminatedProcess,
                          !self.isStopping else { return }
                    self.failPending(
                        CodexUsageError.launchFailed("进程退出码 \(terminatedProcess.terminationStatus)")
                    )
                    self.resetProcessState()
                }
            }

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                self.queue.async { [weak self] in
                    self?.consume(data)
                }
            }

            self.process = process
            inputHandle = inputPipe.fileHandleForWriting
            outputHandle = outputPipe.fileHandleForReading
            readBuffer.removeAll(keepingCapacity: true)
            initialized = false
            isStopping = false
            currentRequestID = nil

            try process.run()
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
            send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "codex-recent-tasks-sidebar",
                        "title": "Codex 最近任务栏",
                        "version": appVersion,
                    ],
                ],
            ])
            scheduleTimeout(for: 1)
        } catch {
            failPending(error)
            shutdown()
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer[..<newline])
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                continue
            }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        guard let id = (object["id"] as? NSNumber)?.intValue else { return }

        if id == 1, !initialized {
            guard object["error"] == nil else {
                failPending(CodexUsageError.protocolFailed("初始化失败"))
                shutdown()
                return
            }
            initialized = true
            send(["method": "initialized"])
            sendRateLimitsRequestIfNeeded()
            return
        }

        guard id == currentRequestID else { return }
        currentRequestID = nil
        do {
            guard object["error"] == nil,
                  let result = object["result"] as? [String: Any] else {
                throw CodexUsageError.protocolFailed("读取请求失败")
            }
            let windows = try UsageSnapshotParser.windows(from: result)
            completePending(with: .success(windows))
        } catch {
            completePending(with: .failure(error))
        }
    }

    private func sendRateLimitsRequestIfNeeded() {
        guard initialized, currentRequestID == nil, !pendingCompletions.isEmpty else { return }
        let requestID = nextRequestID
        nextRequestID += 1
        currentRequestID = requestID
        send([
            "id": requestID,
            "method": "account/rateLimits/read",
            "params": NSNull(),
        ])
        scheduleTimeout(for: requestID)
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else {
            failPending(CodexUsageError.protocolFailed("无法编码请求"))
            shutdown()
            return
        }
        data.append(0x0A)
        inputHandle?.write(data)
    }

    private func scheduleTimeout(for requestID: Int) {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self else { return }
            let isStillWaiting = requestID == 1 ? !self.initialized : self.currentRequestID == requestID
            guard isStillWaiting else { return }
            self.failPending(CodexUsageError.timedOut)
            self.shutdown()
        }
    }

    private func completePending(with result: Result<[UsageWindowDisplay], Error>) {
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        completions.forEach { $0(result) }
    }

    private func failPending(_ error: Error) {
        completePending(with: .failure(error))
    }

    private func shutdown() {
        isStopping = true
        outputHandle?.readabilityHandler = nil
        inputHandle?.closeFile()
        if process?.isRunning == true {
            process?.terminate()
        }
        resetProcessState()
        isStopping = false
    }

    private func resetProcessState() {
        outputHandle?.readabilityHandler = nil
        process = nil
        inputHandle = nil
        outputHandle = nil
        readBuffer.removeAll(keepingCapacity: false)
        initialized = false
        currentRequestID = nil
    }

    private static func executableURL() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment["CODEX_APP_SERVER_OVERRIDE"], !override.isEmpty {
            guard fileManager.isExecutableFile(atPath: override) else {
                throw CodexUsageError.executableNotFound
            }
            return URL(fileURLWithPath: override)
        }

        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            throw CodexUsageError.executableNotFound
        }
        return URL(fileURLWithPath: path)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var state: UsageState = .loading

    private let client = CodexUsageClient()
    private var refreshTimer: Timer?
    private var retryWorkItem: DispatchWorkItem?
    private var lastSuccessfulWindows: [UsageWindowDisplay]?
    private var consecutiveFailures = 0
    private var isRefreshInFlight = false
    private let retryDelays: [TimeInterval]

    init(
        refreshInterval: TimeInterval? = 60,
        retryDelays: [TimeInterval] = [2, 5]
    ) {
        self.retryDelays = retryDelays
        refresh()
        if let refreshInterval {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) {
                [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            refreshTimer?.tolerance = min(5, refreshInterval / 10)
        }
    }

    deinit {
        retryWorkItem?.cancel()
        refreshTimer?.invalidate()
        client.stop()
    }

    func refresh() {
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        client.refresh { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRefreshInFlight = false
                switch result {
                case let .success(windows):
                    self.retryWorkItem?.cancel()
                    self.retryWorkItem = nil
                    self.consecutiveFailures = 0
                    self.lastSuccessfulWindows = windows
                    self.state = .available(windows, isStale: false)
                case let .failure(error):
                    self.consecutiveFailures += 1
                    if let lastSuccessfulWindows = self.lastSuccessfulWindows {
                        self.state = .available(lastSuccessfulWindows, isStale: true)
                    } else if self.consecutiveFailures > self.retryDelays.count {
                        self.state = .unavailable(error.localizedDescription)
                    } else {
                        self.state = .loading
                    }

                    let retryIndex = self.consecutiveFailures - 1
                    guard self.retryDelays.indices.contains(retryIndex) else { return }
                    if self.consecutiveFailures == 2 {
                        self.client.reset()
                    }
                    self.scheduleRetry(after: self.retryDelays[retryIndex])
                }
            }
        }
    }

    func stop() {
        retryWorkItem?.cancel()
        retryWorkItem = nil
        refreshTimer?.invalidate()
        client.stop()
    }

    private func scheduleRetry(after delay: TimeInterval) {
        retryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

struct RecentTaskRowView: View {
    let projectName: String
    let task: CodexTask
    let now: Date
    let openTask: () -> Void

    @State private var isHovering = false

    var body: some View {
        let shortTime = TimeLabelFormatter.shortLabel(milliseconds: task.updatedMillis, now: now)
        let displayState = task.displayState
        Button(action: openTask) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .frame(width: 15, height: 18)

                Text(task.title)
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 6)

                if let badgeText = displayState.badgeText {
                    HStack(spacing: 5) {
                        Text(shortTime)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()

                        HStack(spacing: 3) {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 7.5, weight: .semibold))
                            Text(badgeText)
                                .font(.system(size: 10.5, weight: .semibold))
                        }
                        .foregroundStyle(displayState.tintColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(displayState.tintColor.opacity(0.12), in: Capsule())
                    }
                    .fixedSize()
                } else {
                    Text(shortTime)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.11), in: Capsule())
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(projectName)\n任务：\(task.title)\n状态：\(displayState.statusDescription)\n最近活动：\(TimeLabelFormatter.fullLabel(milliseconds: task.updatedMillis))\nThread ID：\(task.id)")
        .accessibilityLabel("\(projectName)，任务 \(task.title)，\(displayState.statusDescription)，最近活动 \(shortTime)")
        .accessibilityHint("打开这条 Codex 任务")
    }
}

struct FolderTaskSectionView: View {
    let group: TaskGroup
    let now: Date
    let openTask: (CodexTask) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor.opacity(0.9))
                    .frame(width: 17)

                Text(group.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(group.tasks.count) 条")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: Capsule())

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("文件夹 \(group.name)，最近 48 小时 \(group.tasks.count) 条任务")

            ForEach(Array(group.tasks.enumerated()), id: \.element.id) { index, task in
                if index > 0 {
                    Divider()
                        .padding(.leading, 35)
                        .opacity(0.45)
                }
                RecentTaskRowView(projectName: group.name, task: task, now: now) {
                    openTask(task)
                }
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.05), lineWidth: 1)
        )
    }
}

struct TaskListView: View {
    @ObservedObject var store: TaskStore
    @ObservedObject var usageStore: UsageStore
    @ObservedObject var windowMode: WindowModeModel
    @State private var searchText = ""

    private var groups: [TaskGroup] {
        store.groups(matching: searchText)
    }

    private var visibleTaskCount: Int {
        groups.reduce(0) { $0 + $1.tasks.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField

            Divider()
                .opacity(0.5)

            content

            Divider()
                .opacity(0.5)

            footer
        }
        .frame(minWidth: 300, idealWidth: 360, minHeight: 420, idealHeight: 720)
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Codex 最近任务")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(groups.count) 个文件夹 · \(visibleTaskCount) 个任务 · 最近 48 小时")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    store.refresh()
                    usageStore.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.06), in: Circle())
                .help("立即刷新任务与剩余用量")
                .accessibilityLabel("立即刷新任务与剩余用量")
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { value in
                        if windowMode.mode == .pinned {
                            windowMode.dragPinnedWindow(translation: value.translation, ended: false)
                        }
                    }
                    .onEnded { value in
                        if windowMode.mode == .pinned {
                            windowMode.dragPinnedWindow(translation: value.translation, ended: true)
                        } else if abs(value.translation.width) >= 44,
                                  abs(value.translation.width) > abs(value.translation.height) {
                            windowMode.selectDockSide(value.translation.width < 0 ? .left : .right)
                        }
                    }
            )
            .help(windowMode.mode == .docked ? "拖动标题区域向左或向右切换吸附位置" : "拖动窗口可自由移动")

            usageSummary

            HStack(spacing: 8) {
                windowModeButton(
                    title: "吸附 Codex",
                    icon: "rectangle.leadinghalf.inset.filled",
                    mode: .docked
                )
                windowModeButton(
                    title: "单独置顶",
                    icon: "pin.fill",
                    mode: .pinned
                )
            }

            if windowMode.mode == .docked {
                HStack(spacing: 7) {
                    Text("吸附位置")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)

                    dockSideButton(title: "左侧", icon: "rectangle.lefthalf.inset.filled", side: .left)
                    dockSideButton(title: "右侧", icon: "rectangle.righthalf.inset.filled", side: .right)

                    Text("也可拖标题换侧")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
    }

    private var usageSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(usageTint)

                switch usageStore.state {
                case .loading:
                    Text("正在读取剩余用量…")
                        .foregroundStyle(.secondary)
                case let .available(windows, isStale):
                    Text("剩余用量")
                        .foregroundStyle(.secondary)
                    if isStale {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Spacer(minLength: 4)
                    ForEach(windows) { window in
                        HStack(spacing: 3) {
                            Text(window.label)
                                .foregroundStyle(.secondary)
                            Text("\(window.remainingPercent)%")
                                .fontWeight(.semibold)
                                .foregroundStyle(usageColor(for: window.remainingPercent))
                                .monospacedDigit()
                        }
                        .fixedSize()
                    }
                case .unavailable:
                    Text("用量暂时不可用")
                        .foregroundStyle(.secondary)
                }

                if case .loading = usageStore.state {
                    Spacer()
                } else if case .unavailable = usageStore.state {
                    Spacer()
                }
            }

            if case let .available(windows, isStale) = usageStore.state,
               let resetAt = windows.first(where: { $0.label == "每周" })?.resetAt {
                HStack(spacing: 4) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("每周额度 \(resetTimeText(resetAt)) 重置")
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .font(.system(size: 9.5))
                .foregroundStyle(isStale ? Color.orange : Color.secondary)
                .padding(.leading, 18.5)
            }
        }
        .font(.system(size: 10.5))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: 28)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(usageHelpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(usageAccessibilityLabel)
    }

    private func resetTimeText(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    private var usageTint: Color {
        switch usageStore.state {
        case .loading:
            return .secondary
        case let .available(windows, isStale):
            if isStale { return .orange }
            return windows.map(\.remainingPercent).min().map(usageColor(for:)) ?? .secondary
        case .unavailable:
            return .orange
        }
    }

    private func usageColor(for remainingPercent: Int) -> Color {
        if remainingPercent <= 10 { return .red }
        if remainingPercent <= 30 { return .orange }
        return .accentColor
    }

    private var usageHelpText: String {
        switch usageStore.state {
        case .loading:
            return "正在通过 Codex 官方服务读取剩余用量"
        case let .available(_, isStale):
            return isStale
                ? "官方用量服务刚才响应失败，正在自动重试；当前显示上次成功读取的数据。"
                : "剩余用量和每周重置时间每 60 秒刷新。"
        case let .unavailable(message):
            return message
        }
    }

    private var usageAccessibilityLabel: String {
        switch usageStore.state {
        case .loading:
            return "正在读取剩余用量"
        case let .available(windows, isStale):
            var details = windows.map { "\($0.label)剩余\($0.remainingPercent)%" }.joined(separator: "，")
            if let resetAt = windows.first(where: { $0.label == "每周" })?.resetAt {
                details += "，每周额度\(resetTimeText(resetAt))重置"
            }
            return isStale
                ? "剩余用量，\(details)，更新稍有延迟，正在自动重试"
                : "剩余用量，\(details)"
        case .unavailable:
            return "用量暂时不可用"
        }
    }

    private func windowModeButton(title: String, icon: String, mode: WindowDisplayMode) -> some View {
        let isSelected = windowMode.mode == mode
        return Button {
            windowMode.select(mode)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.24) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func dockSideButton(title: String, icon: String, side: DockSide) -> some View {
        let isSelected = windowMode.dockSide == side
        return Button {
            windowMode.selectDockSide(side)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(
                isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("吸附到 Codex \(title)")
        .help("立即吸附到 Codex \(title)，也可以直接拖动窗口切换")
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.tertiary)
            TextField("搜索任务或项目", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空搜索")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 11)
    }

    @ViewBuilder
    private var content: some View {
        if let error = store.errorMessage {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(.orange)
                Text("暂时无法读取任务")
                    .font(.headline)
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("重新读取", action: store.refresh)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                    .font(.system(size: 25))
                    .foregroundStyle(.tertiary)
                Text(searchText.isEmpty ? "最近 48 小时没有任务" : "最近 48 小时没有匹配的任务")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(groups) { group in
                        FolderTaskSectionView(group: group, now: store.now) { task in
                            store.open(task)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(store.errorMessage == nil ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(windowMode.statusText)
            Spacer()
            Text("任务 30 秒 · 用量 60 秒")
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 14)
        .frame(height: 30)
        .help(store.databasePath)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = TaskStore()
    private let usageStore = UsageStore()
    private let windowMode = WindowModeModel()
    private var panel: NSPanel?
    private var statusItem: NSStatusItem?
    private var dockTimer: Timer?
    private var isApplyingDockPosition = false
    private var pinnedDragStartOrigin: NSPoint?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceApplicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        windowMode.onModeChange = { [weak self] mode in
            self?.applyWindowMode(mode)
        }
        windowMode.onDockSideChange = { [weak self] _ in
            self?.dockToCodexWindow()
        }
        windowMode.onPinnedDrag = { [weak self] translation, ended in
            self?.movePinnedWindow(translation: translation, ended: ended)
        }
        createPanel()
        createStatusItem()
        applyWindowMode(.docked)
        showPanel()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showPanel()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        usageStore.stop()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 680),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "Codex 最近任务"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 420)
        panel.maxSize = NSSize(width: 560, height: 1200)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.setFrameAutosaveName("CodexRecentTasksPanelFrame")
        panel.contentView = NSHostingView(
            rootView: TaskListView(store: store, usageStore: usageStore, windowMode: windowMode)
        )

        if !panel.setFrameUsingName("CodexRecentTasksPanelFrame"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.minX + 12, y: visible.maxY - 12))
        }

        self.panel = panel
    }

    private func applyWindowMode(_ mode: WindowDisplayMode) {
        guard let panel else { return }
        dockTimer?.invalidate()
        dockTimer = nil
        pinnedDragStartOrigin = nil

        switch mode {
        case .docked:
            panel.hidesOnDeactivate = false
            dockToCodexWindow()
            dockTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.dockToCodexWindow()
                }
            }
        case .pinned:
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.level = .statusBar
            recordWindowLayerState("pinned")
            updateWindowStatus("单独置顶 · 点击任务跳转 Codex")
            panel.orderFrontRegardless()
        }
    }

    private func dockToCodexWindow() {
        guard let panel else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            updateDockSideFromCurrentPosition()
            return
        }
        guard let codexFrame = CodexWindowLocator.largestWindowFrame() else {
            updateWindowStatus("等待 Codex 窗口")
            return
        }

        let screen = NSScreen.screens.first(where: { $0.frame.intersects(codexFrame) }) ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else {
            updateWindowStatus("无法确定屏幕位置")
            return
        }

        let targetOrigin = DockPlacement.targetOrigin(
            codexFrame: codexFrame,
            panelSize: panel.frame.size,
            visibleFrame: visibleFrame,
            side: windowMode.dockSide
        )

        if abs(panel.frame.origin.x - targetOrigin.x) > 0.5 || abs(panel.frame.origin.y - targetOrigin.y) > 0.5 {
            isApplyingDockPosition = true
            panel.setFrameOrigin(targetOrigin)
            isApplyingDockPosition = false
        }
        updateDockedWindowLevel()
    }

    func windowDidMove(_ notification: Notification) {
        guard
            windowMode.mode == .docked,
            !isApplyingDockPosition,
            let movedPanel = notification.object as? NSPanel,
            movedPanel === panel
        else {
            return
        }
        updateDockSideFromCurrentPosition()
    }

    private func updateDockSideFromCurrentPosition() {
        guard let panel, let codexFrame = CodexWindowLocator.largestWindowFrame() else { return }
        let newSide: DockSide = panel.frame.midX < codexFrame.midX ? .left : .right
        windowMode.observeDockSide(newSide)
        updateWindowStatus("正在切换到 Codex \(newSide.label)")
    }

    private func movePinnedWindow(translation: CGSize, ended: Bool) {
        guard windowMode.mode == .pinned, let panel else { return }
        if pinnedDragStartOrigin == nil {
            pinnedDragStartOrigin = panel.frame.origin
        }
        guard let startOrigin = pinnedDragStartOrigin else { return }

        let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        let proposedOrigin = NSPoint(
            x: startOrigin.x + translation.width,
            y: startOrigin.y - translation.height
        )
        let targetOrigin: NSPoint
        if let visibleFrame {
            targetOrigin = NSPoint(
                x: min(max(visibleFrame.minX, proposedOrigin.x), visibleFrame.maxX - panel.frame.width),
                y: min(max(visibleFrame.minY, proposedOrigin.y), visibleFrame.maxY - panel.frame.height)
            )
        } else {
            targetOrigin = proposedOrigin
        }
        panel.setFrameOrigin(targetOrigin)

        if ended {
            panel.saveFrame(usingName: "CodexRecentTasksPanelFrame")
            pinnedDragStartOrigin = nil
        }
    }

    @objc private func workspaceApplicationDidActivate(_ notification: Notification) {
        updateDockedWindowLevel()
    }

    private func updateDockedWindowLevel() {
        guard windowMode.mode == .docked, let panel else { return }
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let ownBundleID = Bundle.main.bundleIdentifier
        let shouldBeFront = frontmostBundleID == "com.openai.codex" || frontmostBundleID == ownBundleID

        if shouldBeFront {
            if panel.level != .floating || !panel.isFloatingPanel {
                panel.isFloatingPanel = true
                panel.level = .floating
                panel.orderFrontRegardless()
            }
        } else if panel.level != .normal || panel.isFloatingPanel {
            panel.level = .normal
            panel.isFloatingPanel = false
            panel.orderBack(nil)
        }

        let foregroundState: String
        if frontmostBundleID == "com.openai.codex" {
            foregroundState = "跟随 Codex 前置"
        } else if frontmostBundleID == ownBundleID {
            foregroundState = "正在操作"
        } else {
            foregroundState = "已随 Codex 后置"
        }
        recordWindowLayerState(shouldBeFront ? "front" : "back", frontmostBundleID: frontmostBundleID)
        updateWindowStatus("已吸附 \(windowMode.dockSide.label) · \(foregroundState)")
    }

    private func recordWindowLayerState(_ state: String, frontmostBundleID: String? = nil) {
        UserDefaults.standard.set(state, forKey: "CodexRecentTasksWindowLayerState")
        UserDefaults.standard.set(panel?.level.rawValue ?? -1, forKey: "CodexRecentTasksWindowLevel")
        UserDefaults.standard.set(
            frontmostBundleID ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
            forKey: "CodexRecentTasksFrontmostBundleID"
        )
    }

    private func updateWindowStatus(_ text: String) {
        if windowMode.statusText != text {
            windowMode.statusText = text
        }
    }

    private func createStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Codex 最近任务")
            button.toolTip = "Codex 最近任务"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示任务栏", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "刷新任务与用量", action: #selector(refreshTasks), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() {
        guard let panel else { return }
        store.refresh()
        usageStore.refresh()
        if windowMode.mode == .docked {
            dockToCodexWindow()
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshTasks() {
        store.refresh()
        usageStore.refresh()
        panel?.orderFrontRegardless()
    }

    @objc private func quit() {
        dockTimer?.invalidate()
        NSApp.terminate(nil)
    }
}

enum SelfTest {
    static func run() -> Int32 {
        do {
            let result = try TaskRepository.loadTasks()
            let tasks = result.tasks
            let uniqueIDs = Set(tasks.map(\CodexTask.id))
            guard uniqueIDs.count == tasks.count else {
                fputs("SELF_TEST_FAILED duplicate thread IDs\n", stderr)
                return 2
            }
            var titleOverrideStatus = ""
            if let expectedTitle = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_TITLE"] {
                guard tasks.contains(where: { $0.title == expectedTitle }) else {
                    fputs("SELF_TEST_FAILED title override\n", stderr)
                    return 7
                }
                titleOverrideStatus = " title_override=ok"
            }
            var unreadOverrideStatus = ""
            if let expectedUnreadID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_UNREAD_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedUnreadID && $0.hasUnreadUpdate
                }) else {
                    fputs("SELF_TEST_FAILED unread override\n", stderr)
                    return 10
                }
                unreadOverrideStatus = " unread_override=ok"
            }
            var readOverrideStatus = ""
            if let expectedReadID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_READ_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedReadID && !$0.hasUnreadUpdate
                }) else {
                    fputs("SELF_TEST_FAILED read override\n", stderr)
                    return 12
                }
                readOverrideStatus = " read_override=ok"
            }
            var runtimeOverrideStatus = ""
            if let expectedRunningID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_RUNNING_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedRunningID
                        && $0.runtimeState == .running
                        && $0.displayState == .running
                }) else {
                    fputs("SELF_TEST_FAILED runtime override\n", stderr)
                    return 13
                }
                runtimeOverrideStatus = " runtime_override=ok"
            }
            var actionOverrideStatus = ""
            if let expectedActionID = ProcessInfo.processInfo.environment["CODEX_SELF_TEST_EXPECT_ACTION_ID"] {
                guard tasks.contains(where: {
                    $0.id == expectedActionID
                        && $0.runtimeState == .needsAction
                        && $0.displayState == .needsAction
                }) else {
                    fputs("SELF_TEST_FAILED action override\n", stderr)
                    return 14
                }
                actionOverrideStatus = " action_override=ok"
            }
            guard tasks.allSatisfy({ !$0.id.isEmpty && !$0.cwd.isEmpty && $0.updatedMillis > 0 && $0.deepLink != nil }) else {
                fputs("SELF_TEST_FAILED invalid task fields\n", stderr)
                return 3
            }
            for pair in zip(tasks, tasks.dropFirst()) where pair.0.updatedMillis < pair.1.updatedMillis {
                fputs("SELF_TEST_FAILED sort order\n", stderr)
                return 4
            }

            let referenceNow = Date(timeIntervalSince1970: 2_000_000_000)
            let boundaryTask = CodexTask(
                id: "boundary",
                title: "boundary",
                cwd: "/tmp",
                gitBranch: "",
                updatedMillis: Int64(referenceNow.timeIntervalSince1970 * 1000) - RecentTaskPolicy.windowMillis
            )
            let staleTask = CodexTask(
                id: "stale",
                title: "stale",
                cwd: "/tmp",
                gitBranch: "",
                updatedMillis: boundaryTask.updatedMillis - 1
            )
            guard RecentTaskPolicy.includes(boundaryTask, now: referenceNow),
                  !RecentTaskPolicy.includes(staleTask, now: referenceNow) else {
                fputs("SELF_TEST_FAILED recent window boundary\n", stderr)
                return 5
            }

            let visibleFrame = NSRect(x: 0, y: 0, width: 1800, height: 1000)
            let codexFrame = NSRect(x: 400, y: 100, width: 1000, height: 800)
            let panelSize = NSSize(width: 320, height: 680)
            let leftOrigin = DockPlacement.targetOrigin(
                codexFrame: codexFrame,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                side: .left
            )
            let rightOrigin = DockPlacement.targetOrigin(
                codexFrame: codexFrame,
                panelSize: panelSize,
                visibleFrame: visibleFrame,
                side: .right
            )
            guard leftOrigin.x < codexFrame.minX,
                  rightOrigin.x > codexFrame.maxX,
                  leftOrigin.y == rightOrigin.y else {
                fputs("SELF_TEST_FAILED dock side placement\n", stderr)
                return 6
            }

            let usageFixture: [String: Any] = [
                "rateLimits": [
                    "primary": ["usedPercent": 35, "windowDurationMins": 300, "resetsAt": 1_900_000_000],
                    "secondary": ["usedPercent": 90, "windowDurationMins": 10_080, "resetsAt": 1_900_604_800],
                ],
            ]
            let usageWindows = try UsageSnapshotParser.windows(from: usageFixture)
            guard usageWindows == [
                UsageWindowDisplay(
                    label: "5 小时",
                    remainingPercent: 65,
                    resetAt: Date(timeIntervalSince1970: 1_900_000_000)
                ),
                UsageWindowDisplay(
                    label: "每周",
                    remainingPercent: 10,
                    resetAt: Date(timeIntervalSince1970: 1_900_604_800)
                ),
            ] else {
                fputs("SELF_TEST_FAILED usage parsing\n", stderr)
                return 8
            }

            let clampedUsage = try UsageSnapshotParser.windows(from: [
                "rateLimits": ["primary": ["usedPercent": 120]],
            ])
            guard clampedUsage == [UsageWindowDisplay(label: "主要额度", remainingPercent: 0)] else {
                fputs("SELF_TEST_FAILED usage clamping\n", stderr)
                return 9
            }

            let unreadFixture = Data("""
            {
              "electron-persisted-atom-state": {
                "unread-thread-ids-by-host-v1": {
                  "local": [
                    "00000000-0000-0000-0000-000000000001",
                    "invalid"
                  ],
                  "remote": [
                    "00000000-0000-0000-0000-000000000002"
                  ]
                }
              }
            }
            """.utf8)
            guard UnreadTaskStateRepository.unreadThreadIDs(from: unreadFixture) == Set([
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000002",
            ]),
            UnreadTaskStateRepository.unreadThreadIDs(from: Data("not json".utf8)).isEmpty else {
                fputs("SELF_TEST_FAILED unread state parsing\n", stderr)
                return 11
            }

            let runningFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_complete"}}
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"message"}}
            """.utf8)
            let completedFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"task_complete"}}
            """.utf8)
            let abortedFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"event_msg","payload":{"type":"turn_aborted"}}
            """.utf8)
            let actionFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}
            """.utf8)
            let resumedFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"function_call","name":"request_user_input","call_id":"call-1"}}
            {"type":"response_item","payload":{"type":"function_call_output","call_id":"call-1"}}
            """.utf8)
            let approvalFixture = Data("""
            {"type":"event_msg","payload":{"type":"task_started"}}
            {"type":"response_item","payload":{"type":"function_call","name":"exec_command","call_id":"call-2","arguments":"{\\"sandbox_permissions\\":\\"require_escalated\\"}"}}
            """.utf8)
            guard RolloutTaskStateRepository.state(from: runningFixture) == .running,
                  RolloutTaskStateRepository.state(from: completedFixture) == .idle,
                  RolloutTaskStateRepository.state(from: abortedFixture) == .idle,
                  RolloutTaskStateRepository.state(from: actionFixture) == .needsAction,
                  RolloutTaskStateRepository.state(from: resumedFixture) == .running,
                  RolloutTaskStateRepository.state(from: approvalFixture) == .needsAction,
                  RolloutTaskStateRepository.state(from: Data("not json".utf8)) == .unknown else {
                fputs("SELF_TEST_FAILED runtime state parsing\n", stderr)
                return 15
            }

            var incrementalRuntimeStatus = ""
            if let rolloutRoot = ProcessInfo.processInfo.environment["CODEX_ROLLOUT_ROOT_OVERRIDE"],
               !rolloutRoot.isEmpty {
                let fixtureURL = URL(fileURLWithPath: rolloutRoot, isDirectory: true)
                    .appendingPathComponent("incremental-runtime-\(UUID().uuidString).jsonl")
                defer { try? FileManager.default.removeItem(at: fixtureURL) }

                let ignoredLine = Data("""
                {"type":"response_item","payload":{"type":"message","content":"performance fixture"}}

                """.utf8)
                var initialData = Data("""
                {"type":"event_msg","payload":{"type":"task_started"}}

                """.utf8)
                for _ in 0..<20_000 {
                    initialData.append(ignoredLine)
                }
                try initialData.write(to: fixtureURL, options: .atomic)

                let incrementalRepository = RolloutTaskStateRepository()
                guard incrementalRepository.loadState(rolloutPath: fixtureURL.path) == .running else {
                    fputs("SELF_TEST_FAILED initial incremental runtime state\n", stderr)
                    return 17
                }

                let appendHandle = try FileHandle(forWritingTo: fixtureURL)
                try appendHandle.seekToEnd()
                appendHandle.write(Data("""
                {"type":"event_msg","payload":{"type":"task_complete"}}

                """.utf8))
                try appendHandle.close()

                guard incrementalRepository.loadState(rolloutPath: fixtureURL.path) == .idle else {
                    fputs("SELF_TEST_FAILED appended incremental runtime state\n", stderr)
                    return 18
                }
                let diagnostics = incrementalRepository.diagnosticsSnapshot()
                guard diagnostics.fullScanCount == 1,
                      diagnostics.incrementalScanCount == 1,
                      diagnostics.fullScanBytes > 1_000_000,
                      diagnostics.incrementalScanBytes < 1_024 else {
                    fputs("SELF_TEST_FAILED incremental runtime scan metrics\n", stderr)
                    return 19
                }
                incrementalRuntimeStatus = " incremental_runtime=ok"
            }

            guard TaskDisplayState.resolve(runtimeState: .running, hasUnreadUpdate: true) == .running,
                  TaskDisplayState.resolve(runtimeState: .needsAction, hasUnreadUpdate: true) == .needsAction,
                  TaskDisplayState.resolve(runtimeState: .idle, hasUnreadUpdate: true) == .needsReview,
                  TaskDisplayState.resolve(runtimeState: .idle, hasUnreadUpdate: false) == .idle,
                  TaskDisplayState.resolve(runtimeState: .unknown, hasUnreadUpdate: true) == .needsReview else {
                fputs("SELF_TEST_FAILED display state priority\n", stderr)
                return 16
            }

            let unreadUpdateCount = tasks.filter(\.hasUnreadUpdate).count
            print("SELF_TEST_OK count=\(tasks.count)\(titleOverrideStatus)\(unreadOverrideStatus)\(readOverrideStatus)\(runtimeOverrideStatus)\(actionOverrideStatus)\(incrementalRuntimeStatus) usage=ok unread_state=ok runtime_state=ok display_state=ok unread_update_count=\(unreadUpdateCount) database=\(result.databaseURL.path)")
            return 0
        } catch {
            fputs("SELF_TEST_FAILED \(error.localizedDescription)\n", stderr)
            return 1
        }
    }
}

enum UsageClientSelfTest {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<[UsageWindowDisplay], Error>?

        func store(_ newValue: Result<[UsageWindowDisplay], Error>) {
            lock.lock()
            result = newValue
            lock.unlock()
        }

        func load() -> Result<[UsageWindowDisplay], Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    static func run(expectFixtureValues: Bool = true) -> Int32 {
        let client = CodexUsageClient()
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = ResultBox()

        client.refresh { result in
            resultBox.store(result)
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 18) == .success else {
            client.stop()
            fputs("USAGE_SELF_TEST_FAILED timeout\n", stderr)
            return 10
        }
        client.stop()
        let result = resultBox.load()

        switch result {
        case let .success(windows):
            guard !expectFixtureValues || windows == [
                    UsageWindowDisplay(
                        label: "5 小时",
                        remainingPercent: 65,
                        resetAt: Date(timeIntervalSince1970: 1_900_000_000)
                    ),
                    UsageWindowDisplay(
                        label: "每周",
                        remainingPercent: 10,
                        resetAt: Date(timeIntervalSince1970: 1_900_604_800)
                    ),
                  ] else {
                fputs("USAGE_SELF_TEST_FAILED unexpected values\n", stderr)
                return 11
            }
            let weeklyResetStatus = windows.first(where: { $0.label == "每周" })?.resetAt == nil
                ? "unavailable"
                : "available"
            print(expectFixtureValues
                ? "USAGE_SELF_TEST_OK windows=2 reset=ok"
                : "USAGE_PROBE_OK windows=\(windows.count) weekly_reset=\(weeklyResetStatus)")
            return 0
        case let .failure(error):
            fputs("USAGE_SELF_TEST_FAILED \(error.localizedDescription)\n", stderr)
            return 12
        case nil:
            fputs("USAGE_SELF_TEST_FAILED no result\n", stderr)
            return 13
        }
    }
}

enum UsageResilienceSelfTest {
    @MainActor
    static func run() -> Int32 {
        let store = UsageStore(refreshInterval: nil, retryDelays: [0.25, 0.25])
        defer { store.stop() }

        guard waitUntil(timeout: 5, condition: {
            if case let .available(windows, isStale) = store.state {
                return hasWeeklyReset(windows) && !isStale
            }
            return false
        }) else {
            fputs("USAGE_RESILIENCE_SELF_TEST_FAILED initial success\n", stderr)
            return 20
        }

        store.refresh()
        guard waitUntil(timeout: 5, condition: {
            if case let .available(windows, isStale) = store.state {
                return hasWeeklyReset(windows) && isStale
            }
            return false
        }) else {
            fputs("USAGE_RESILIENCE_SELF_TEST_FAILED stale fallback\n", stderr)
            return 21
        }

        guard waitUntil(timeout: 5, condition: {
            if case let .available(windows, isStale) = store.state {
                return hasWeeklyReset(windows) && !isStale
            }
            return false
        }) else {
            fputs("USAGE_RESILIENCE_SELF_TEST_FAILED automatic retry\n", stderr)
            return 22
        }

        print("USAGE_RESILIENCE_SELF_TEST_OK stale=ok retry=ok reset=ok")
        return 0
    }

    private static func hasWeeklyReset(_ windows: [UsageWindowDisplay]) -> Bool {
        windows.count == 2 && windows.first(where: { $0.label == "每周" })?.resetAt != nil
    }

    @MainActor
    private static func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

@main
struct CodexRecentTasksMain {
    @MainActor
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            Darwin.exit(SelfTest.run())
        }
        if CommandLine.arguments.contains("--usage-self-test") {
            Darwin.exit(UsageClientSelfTest.run())
        }
        if CommandLine.arguments.contains("--usage-resilience-self-test") {
            Darwin.exit(UsageResilienceSelfTest.run())
        }
        if CommandLine.arguments.contains("--usage-probe") {
            Darwin.exit(UsageClientSelfTest.run(expectFixtureValues: false))
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
