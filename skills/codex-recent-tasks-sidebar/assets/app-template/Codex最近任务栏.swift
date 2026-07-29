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

enum TaskDisplayState: Equatable, Sendable {
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

enum ActivityTaskPolicy {
    static func includes(_ displayState: TaskDisplayState) -> Bool {
        displayState != .idle
    }
}

enum AppLayout {
    static let panelWidth: CGFloat = 240
    static let minimumPanelHeight: CGFloat = 360
    static let idealPanelHeight: CGFloat = 720
    static let defaultWindowMode: WindowDisplayMode = .pinned
    static let alwaysOnTop = true
}

struct AgentQuotaDisplay: Identifiable, Equatable, Sendable {
    let label: String
    let remainingPercent: Int
    let remainingValueText: String?

    var id: String { label }
}

struct CompactQuotaLine: Equatable, Sendable {
    let label: String
    let value: String
}

enum QuotaTintRole: Equatable, Sendable {
    case neutral
    case warning
    case critical
}

enum QuotaTintPolicy {
    static func role(
        remainingPercent: Int,
        isStale: Bool,
        emphasizesLowBalance: Bool
    ) -> QuotaTintRole {
        if isStale {
            return .warning
        }
        guard emphasizesLowBalance else {
            return .neutral
        }
        if remainingPercent <= 10 {
            return .critical
        }
        if remainingPercent <= 30 {
            return .warning
        }
        return .neutral
    }
}

enum CompactQuotaLineFormatter {
    static func inline(
        windows: [UsageWindowDisplay],
        isStale: Bool
    ) -> [CompactQuotaLine] {
        let summary = windows.map {
            "\(compactLabel($0.label)) \($0.remainingPercent)%"
        }.joined(separator: " · ")
        return [
            CompactQuotaLine(
                label: "",
                value: isStale ? "\(summary) · 延迟" : summary
            ),
        ]
    }

    static func expanded(
        windows: [UsageWindowDisplay],
        isStale: Bool
    ) -> [CompactQuotaLine] {
        windows.map {
            CompactQuotaLine(
                label: expandedLabel($0.label),
                value: isStale
                    ? "余 \($0.remainingPercent)% · 延迟"
                    : "余 \($0.remainingPercent)%"
            )
        }
    }

    private static func expandedLabel(_ label: String) -> String {
        switch label {
        case "5 小时":
            return "Code 5h"
        case "每周":
            return "Code 7天"
        default:
            return label
        }
    }

    private static func compactLabel(_ label: String) -> String {
        switch label {
        case "5 小时":
            return "5时"
        case "每周":
            return "周"
        case "每月":
            return "月"
        default:
            return label
        }
    }
}

enum QwenUsageSnapshotParser {
    static func quota(from result: [String: Any]) throws -> AgentQuotaDisplay {
        let payload = (result["json"] as? [String: Any]) ?? result
        guard let quota = payload["userQuota"] as? [String: Any],
              let total = number(quota["total"]),
              let remaining = number(quota["remaining"]),
              total > 0 else {
            throw CodexUsageError.protocolFailed("QwenWorkCN 用量缺少 userQuota")
        }

        let remainingPercent = Int(
            min(max(remaining / total * 100, 0), 100).rounded()
        )
        return AgentQuotaDisplay(
            label: "积分",
            remainingPercent: remainingPercent,
            remainingValueText: decimalText(remaining)
        )
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let text = value as? String {
            return Double(text)
        }
        return nil
    }

    private static func decimalText(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

enum QwenTaskStatusParser {
    static func runtimeState(taskStatus: String?, streamID: String?) -> TaskRuntimeState {
        let normalized = taskStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if [
            "waiting_for_user",
            "waiting_for_input",
            "waiting_on_user",
            "waiting_on_approval",
            "needs_action",
            "pending_approval",
        ].contains(normalized) {
            return .needsAction
        }
        if [
            "completed",
            "complete",
            "cancelled",
            "canceled",
            "failed",
            "error",
            "idle",
            "stopped",
        ].contains(normalized) {
            return .idle
        }
        if [
            "running",
            "active",
            "streaming",
            "pending",
            "queued",
            "in_progress",
        ].contains(normalized) {
            return .running
        }
        if let streamID,
           !streamID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .running
        }
        return .unknown
    }
}

enum KimiUsageTextParser {
    private static let ansiPattern =
        #"\u001B\][^\u0007]*(?:\u0007|\u001B\\)|\u001B\[[0-?]*[ -/]*[@-~]"#
    private static let rowPattern =
        #"(?im)^\s*([^\r\n\[]+?)\s+(?:\[[^\r\n\]]*\]\s+)?(\d{1,3})%\s+used\b"#

    static func windows(from rawText: String) -> [UsageWindowDisplay] {
        let cleaned = replacingMatches(
            pattern: ansiPattern,
            in: rawText,
            template: ""
        )
        guard let expression = try? NSRegularExpression(pattern: rowPattern) else {
            return []
        }
        let range = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        var seenLabels = Set<String>()
        var windows: [UsageWindowDisplay] = []
        for match in expression.matches(in: cleaned, range: range) {
            guard let labelRange = Range(match.range(at: 1), in: cleaned),
                  let usedRange = Range(match.range(at: 2), in: cleaned),
                  let usedPercent = Int(cleaned[usedRange]) else {
                continue
            }
            let label = localizedLabel(String(cleaned[labelRange]))
            guard !label.isEmpty, seenLabels.insert(label).inserted else { continue }
            windows.append(
                UsageWindowDisplay(
                    label: label,
                    remainingPercent: 100 - min(max(usedPercent, 0), 100)
                )
            )
        }
        return windows
    }

    private static func localizedLabel(_ rawLabel: String) -> String {
        let label = rawLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let lowercased = label.lowercased()
        if lowercased.range(
            of: #"(^|[^0-9])5[\s-]*h(?:our)?s?\b"#,
            options: .regularExpression
        ) != nil {
            return "5 小时"
        }
        if lowercased.contains("weekly") || lowercased == "week" {
            return "每周"
        }
        if lowercased.contains("monthly") || lowercased == "month" {
            return "每月"
        }
        return label
    }

    private static func replacingMatches(
        pattern: String,
        in input: String,
        template: String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return input
        }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return expression.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: template
        )
    }
}

enum KimiTotalUsageLogParser {
    private static let ratioPattern =
        #"\bomniRatio=([0-9]+(?:\.[0-9]+)?)\b"#
    private static let maximumLineSize = 4 * 1024

    static func window(from data: Data) -> UsageWindowDisplay? {
        let text = String(decoding: data, as: UTF8.self)
        guard let latestRefreshLine = text.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ).reversed().first(where: { $0.contains("refreshed(sub):") }),
        latestRefreshLine.utf8.count <= maximumLineSize else {
            return nil
        }

        let line = String(latestRefreshLine)
        guard let expression = try? NSRegularExpression(pattern: ratioPattern),
              let match = expression.firstMatch(
                  in: line,
                  range: NSRange(line.startIndex..<line.endIndex, in: line)
              ),
              let ratioRange = Range(match.range(at: 1), in: line),
              let rawRatio = Double(line[ratioRange]),
              rawRatio.isFinite,
              rawRatio >= 0,
              rawRatio <= 100 else {
            return nil
        }
        let usedRatio = rawRatio > 1 ? rawRatio / 100 : rawRatio
        let remainingPercent = Int(
            ((1 - min(max(usedRatio, 0), 1)) * 100).rounded()
        )
        return UsageWindowDisplay(
            label: "总量",
            remainingPercent: remainingPercent
        )
    }
}

enum KimiTotalUsageLogReader {
    private static let maximumTailSize = 4 * 1024 * 1024

    static func currentWindow() -> UsageWindowDisplay? {
        let environment = ProcessInfo.processInfo.environment
        let url: URL
        if let override = environment["KIMI_TOTAL_USAGE_LOG_OVERRIDE"],
           !override.isEmpty {
            url = URL(fileURLWithPath: override)
        } else {
            url = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/kimi-desktop/main.log")
        }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let fileSizeNumber = attributes[.size] as? NSNumber,
        fileSizeNumber.int64Value > 0,
        let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = UInt64(fileSizeNumber.int64Value)
        let readSize = min(fileSize, UInt64(maximumTailSize))
        do {
            try handle.seek(toOffset: fileSize - readSize)
        } catch {
            return nil
        }
        return KimiTotalUsageLogParser.window(
            from: handle.readData(ofLength: Int(readSize))
        )
    }
}

enum KimiWireStateParser {
    private static let loopEventMarker = Data(#""context.append_loop_event""#.utf8)

    static func runtimeState(from data: Data) -> TaskRuntimeState {
        var activeStepCount = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count <= 4 * 1024 * 1024 else {
                continue
            }
            let recordData = Data(line)
            guard recordData.range(of: loopEventMarker) != nil,
                  let record = try? JSONSerialization.jsonObject(with: recordData)
                    as? [String: Any],
                  record["type"] as? String == "context.append_loop_event",
                  let event = record["event"] as? [String: Any],
                  let eventType = event["type"] as? String else {
                continue
            }
            if eventType == "step.begin" {
                activeStepCount += 1
            } else if eventType == "step.end" {
                activeStepCount = max(0, activeStepCount - 1)
            }
        }
        return activeStepCount > 0 ? .running : .idle
    }
}

enum AgentKind: String, CaseIterable, Identifiable, Sendable {
    case codex
    case qwen
    case kimi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .qwen:
            return "QwenWorkCN"
        case .kimi:
            return "Kimi"
        }
    }

    var symbolName: String {
        switch self {
        case .codex:
            return "chevron.left.forwardslash.chevron.right"
        case .qwen:
            return "sparkles"
        case .kimi:
            return "moon.stars.fill"
        }
    }
}

struct LocalAgentTask: Identifiable, Equatable, Sendable {
    let id: String
    let agent: AgentKind
    let title: String
    let projectName: String
    let projectPath: String
    let updatedMillis: Int64
    let displayState: TaskDisplayState
    let navigationID: String
}

enum CodexProjectNameResolver {
    private static let maximumMetadataSize = 256 * 1024
    private static let projectPattern =
        #"local mirror of the ChatGPT project\s+[“"]([^”"\r\n]{1,160})[”"]"#

    static func projectName(for path: String) -> String {
        let canonicalURL = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let fallback = canonicalURL.lastPathComponent.isEmpty
            ? "未归类" : canonicalURL.lastPathComponent
        guard fallback.hasPrefix("g-p-") else {
            return fallback
        }

        let instructionsURL = canonicalURL.appendingPathComponent("AGENTS.md")
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: instructionsURL.path
        ),
        let fileSize = attributes[.size] as? NSNumber,
        fileSize.intValue <= maximumMetadataSize,
        let data = try? Data(contentsOf: instructionsURL, options: .mappedIfSafe),
        let resolved = projectName(fromAgentInstructions: data) else {
            return fallback
        }
        return resolved
    }

    static func projectName(fromAgentInstructions data: Data) -> String? {
        guard data.count <= maximumMetadataSize,
              let text = String(data: data, encoding: .utf8),
              let expression = try? NSRegularExpression(
                  pattern: projectPattern,
                  options: [.caseInsensitive]
              ) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: range),
              let nameRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let name = text[nameRange].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

private struct QwenTaskRecord: Decodable {
    let id: String
    let chatID: String
    let title: String
    let projectName: String
    let projectPath: String
    let updatedMillis: Int64
    let taskStatus: String
    let streamID: String

    enum CodingKeys: String, CodingKey {
        case id
        case chatID = "chat_id"
        case title
        case projectName = "project_name"
        case projectPath = "project_path"
        case updatedMillis = "updated_ms"
        case taskStatus = "task_status"
        case streamID = "stream_id"
    }
}

struct QwenTaskRepository {
    private static let query = """
    SELECT
      sub.id AS id,
      chat.id AS chat_id,
      CASE
        WHEN trim(COALESCE(sub.name, '')) <> '' THEN substr(sub.name, 1, 240)
        WHEN trim(COALESCE(chat.name, '')) <> '' THEN substr(chat.name, 1, 240)
        ELSE '未命名线程'
      END AS title,
      COALESCE(NULLIF(trim(project.name), ''), '未归类') AS project_name,
      COALESCE(NULLIF(trim(project.path), ''), '') AS project_path,
      CAST(MAX(COALESCE(sub.updated_at, 0), COALESCE(chat.updated_at, 0)) * 1000 AS INTEGER)
        AS updated_ms,
      CASE
        WHEN json_valid(COALESCE(chat.ext, '')) THEN
          COALESCE(json_extract(chat.ext, '$.taskStatus'), '')
        ELSE ''
      END AS task_status,
      COALESCE(sub.stream_id, '') AS stream_id
    FROM sub_chats AS sub
    JOIN chats AS chat ON chat.id = sub.chat_id
    LEFT JOIN projects AS project ON project.id = chat.project_id
    WHERE chat.archived_at IS NULL
      AND chat.deleted_at IS NULL
    ORDER BY updated_ms DESC, sub.id ASC;
    """

    static func loadActiveTasks(
        unreadChatIDs explicitUnreadChatIDs: Set<String>? = nil,
        unreadSubChatIDs explicitUnreadSubChatIDs: Set<String>? = nil
    ) throws -> (databaseURL: URL, tasks: [LocalAgentTask]) {
        let databaseURL = try currentDatabaseURL()
        let records: [QwenTaskRecord] = try SQLiteJSONReader.read(
            databaseURL: databaseURL,
            query: query
        )
        let unreadChatIDs = explicitUnreadChatIDs
            ?? identifierOverride(named: "QWEN_UNREAD_CHAT_IDS_OVERRIDE")
        let unreadSubChatIDs = explicitUnreadSubChatIDs
            ?? identifierOverride(named: "QWEN_UNREAD_SUBCHAT_IDS_OVERRIDE")
        let chatsWithSpecificUnreadSubChat = Set(
            records.compactMap { record in
                unreadSubChatIDs.contains(record.id) ? record.chatID : nil
            }
        )
        var unreadRecordIDs = unreadSubChatIDs
        var representedChatIDs = Set<String>()
        for record in records
        where unreadChatIDs.contains(record.chatID)
            && !chatsWithSpecificUnreadSubChat.contains(record.chatID)
            && representedChatIDs.insert(record.chatID).inserted {
            unreadRecordIDs.insert(record.id)
        }
        let tasks = records.compactMap { record -> LocalAgentTask? in
            let runtimeState = QwenTaskStatusParser.runtimeState(
                taskStatus: record.taskStatus,
                streamID: record.streamID
            )
            let displayState = TaskDisplayState.resolve(
                runtimeState: runtimeState,
                hasUnreadUpdate: unreadRecordIDs.contains(record.id)
            )
            guard ActivityTaskPolicy.includes(displayState) else {
                return nil
            }
            let projectPath = record.projectPath.isEmpty
                ? record.projectName : record.projectPath
            let projectName = record.projectName == "未归类"
                ? CodexProjectNameResolver.projectName(for: projectPath)
                : record.projectName
            return LocalAgentTask(
                id: record.id,
                agent: .qwen,
                title: record.title,
                projectName: projectName,
                projectPath: projectPath,
                updatedMillis: record.updatedMillis,
                displayState: displayState,
                navigationID: record.chatID
            )
        }
        return (databaseURL, tasks)
    }

    private static func identifierOverride(named environmentKey: String) -> Set<String> {
        guard let rawValue = ProcessInfo.processInfo.environment[environmentKey] else {
            return []
        }
        return Set(
            rawValue.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.utf8.count <= 256 }
        )
    }

    private static func currentDatabaseURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        if let override = environment["QWEN_TASK_DB_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw TaskRepositoryError.databaseNotFound
            }
            return url
        }

        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/QwenWorkCN/data/agents.db"
            )
        guard fileManager.fileExists(atPath: url.path) else {
            throw TaskRepositoryError.databaseNotFound
        }
        return url
    }
}

private struct KimiSessionIndexRecord: Decodable {
    let sessionID: String
    let sessionDir: String
    let workDir: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case sessionDir
        case workDir
    }
}

private struct KimiSessionState: Decodable {
    let updatedAt: String?
    let title: String?
    let workDir: String?
}

enum KimiMonitorSession {
    static let defaultsKey = "LocalAIStatusBarKimiMonitorSessionID"
    private static let legacyDefaultsDomain = "io.github.codexrecenttasks.sidebar"

    static func storedID() -> String? {
        if let current = UserDefaults.standard.string(forKey: defaultsKey),
           !current.isEmpty {
            return current
        }
        guard let legacy = UserDefaults.standard.persistentDomain(
            forName: legacyDefaultsDomain
        )?[defaultsKey] as? String,
        !legacy.isEmpty else {
            return nil
        }
        UserDefaults.standard.set(legacy, forKey: defaultsKey)
        return legacy
    }
}

enum KimiMonitorDirectory {
    static func url(createIfNeeded: Bool = true) throws -> URL {
        let fileManager = FileManager.default
        let url: URL
        if let override = ProcessInfo.processInfo.environment[
            "KIMI_MONITOR_DIRECTORY_OVERRIDE"
        ], !override.isEmpty {
            url = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let baseURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: createIfNeeded
            )
            url = baseURL
                .appendingPathComponent("本机AI状态栏", isDirectory: true)
                .appendingPathComponent("Kimi额度监控", isDirectory: true)
        }
        if createIfNeeded {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
        return url
    }
}

enum KimiProcessInspector {
    private static let maximumOutputSize = 4 * 1024 * 1024

    static func activeWorkDirectoryCounts() -> [String: Int] {
        if let override = ProcessInfo.processInfo.environment[
            "KIMI_ACTIVE_WORK_DIRS_OVERRIDE"
        ] {
            return workDirectoryCounts(
                override.split(separator: ",").map(String.init)
            )
        }

        guard let processData = commandOutput(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,comm="]
        ),
        let processText = String(data: processData, encoding: .utf8) else {
            return [:]
        }
        let monitorPath = (try? KimiMonitorDirectory.url(createIfNeeded: false))
            .map { canonicalPath($0.path) }
        var workDirectories: [String] = []
        for line in processText.split(
            separator: "\n",
            omittingEmptySubsequences: true
        ) {
            let fields = line.split(
                maxSplits: 1,
                omittingEmptySubsequences: true,
                whereSeparator: \.isWhitespace
            )
            guard fields.count == 2,
                  let processID = Int32(fields[0]),
                  URL(fileURLWithPath: String(fields[1]))
                    .lastPathComponent == "kimi",
                  let workDirectory = currentWorkingDirectory(
                      processID: processID
                  ) else {
                continue
            }
            let canonicalWorkDirectory = canonicalPath(workDirectory)
            if canonicalWorkDirectory != monitorPath {
                workDirectories.append(canonicalWorkDirectory)
            }
        }
        return workDirectoryCounts(workDirectories)
    }

    static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    private static func workDirectoryCounts(_ paths: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 4_096 else {
                continue
            }
            counts[canonicalPath(trimmed), default: 0] += 1
        }
        return counts
    }

    private static func currentWorkingDirectory(processID: Int32) -> String? {
        guard let data = commandOutput(
            executable: "/usr/sbin/lsof",
            arguments: [
                "-a",
                "-p", String(processID),
                "-d", "cwd",
                "-Fn",
            ]
        ),
        let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text.split(separator: "\n").compactMap { line -> String? in
            guard line.first == "n" else { return nil }
            let path = String(line.dropFirst())
            return path.isEmpty ? nil : path
        }.first
    }

    private static func commandOutput(
        executable: String,
        arguments: [String]
    ) -> Data? {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              data.count <= maximumOutputSize else {
            return nil
        }
        return data
    }
}

private struct KimiCLITaskRepository {
    private struct Candidate {
        let task: LocalAgentTask
        let canonicalWorkDirectory: String
    }

    private static let maximumIndexSize = 32 * 1024 * 1024
    private static let maximumStateSize = 2 * 1024 * 1024
    private static let maximumWireTailSize = 16 * 1024 * 1024

    static func loadActiveTasks() throws -> (indexURL: URL, tasks: [LocalAgentTask]) {
        let indexURL = try currentSessionIndexURL()
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: indexURL.path
        ),
        let fileSize = attributes[.size] as? NSNumber,
        fileSize.intValue <= maximumIndexSize,
        let data = try? Data(contentsOf: indexURL, options: .mappedIfSafe) else {
            throw TaskRepositoryError.invalidData("Kimi 会话索引不可读")
        }

        let decoder = JSONDecoder()
        var latestRecords: [String: KimiSessionIndexRecord] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count <= 64 * 1024,
                  let record = try? decoder.decode(
                      KimiSessionIndexRecord.self,
                      from: Data(line)
                  ),
                  !record.sessionID.isEmpty,
                  record.sessionID.utf8.count <= 256 else {
                continue
            }
            latestRecords[record.sessionID] = record
        }

        let monitorSessionID = ProcessInfo.processInfo.environment[
            "KIMI_MONITOR_SESSION_ID_OVERRIDE"
        ] ?? KimiMonitorSession.storedID()
        let candidates = latestRecords.values.compactMap { record -> Candidate? in
            guard record.sessionID != monitorSessionID,
                  let sessionURL = validatedSessionURL(
                      path: record.sessionDir,
                      indexURL: indexURL
                  ),
                  let state = loadState(at: sessionURL),
                  let runtimeState = loadRuntimeState(at: sessionURL),
                  runtimeState == .running else {
                return nil
            }

            let workDir = nonempty(state.workDir) ?? nonempty(record.workDir) ?? sessionURL.path
            let title = nonempty(state.title) ?? "未命名线程"
            let updatedMillis = timestampMillis(
                from: state.updatedAt,
                fallbackURL: sessionURL.appendingPathComponent("agents/main/wire.jsonl")
            )
            return Candidate(
                task: LocalAgentTask(
                    id: record.sessionID,
                    agent: .kimi,
                    title: title,
                    projectName: CodexProjectNameResolver.projectName(for: workDir),
                    projectPath: workDir,
                    updatedMillis: updatedMillis,
                    displayState: .running,
                    navigationID: record.sessionID
                ),
                canonicalWorkDirectory: KimiProcessInspector.canonicalPath(workDir)
            )
        }.sorted {
            if $0.task.updatedMillis == $1.task.updatedMillis {
                return $0.task.id < $1.task.id
            }
            return $0.task.updatedMillis > $1.task.updatedMillis
        }
        var remainingProcessCounts = KimiProcessInspector.activeWorkDirectoryCounts()
        let tasks = candidates.compactMap { candidate -> LocalAgentTask? in
            let workDirectory = candidate.canonicalWorkDirectory
            guard let count = remainingProcessCounts[workDirectory],
                  count > 0 else {
                return nil
            }
            remainingProcessCounts[workDirectory] = count - 1
            return candidate.task
        }
        return (indexURL, tasks)
    }

    private static func loadState(at sessionURL: URL) -> KimiSessionState? {
        let stateURL = sessionURL.appendingPathComponent("state.json")
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: stateURL.path
        ),
        let fileSize = attributes[.size] as? NSNumber,
        fileSize.intValue <= maximumStateSize,
        let data = try? Data(contentsOf: stateURL, options: .mappedIfSafe) else {
            return nil
        }
        return try? JSONDecoder().decode(KimiSessionState.self, from: data)
    }

    private static func loadRuntimeState(at sessionURL: URL) -> TaskRuntimeState? {
        let wireURL = sessionURL.appendingPathComponent("agents/main/wire.jsonl")
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: wireURL.path
        ),
        let fileSizeNumber = attributes[.size] as? NSNumber,
        fileSizeNumber.int64Value > 0,
        let handle = try? FileHandle(forReadingFrom: wireURL) else {
            return nil
        }
        defer { try? handle.close() }

        let fileSize = UInt64(fileSizeNumber.int64Value)
        let readSize = min(fileSize, UInt64(maximumWireTailSize))
        do {
            try handle.seek(toOffset: fileSize - readSize)
        } catch {
            return nil
        }
        let data = handle.readData(ofLength: Int(readSize))
        return KimiWireStateParser.runtimeState(from: data)
    }

    private static func validatedSessionURL(path: String, indexURL: URL) -> URL? {
        guard !path.isEmpty, path.utf8.count <= 4_096 else { return nil }
        let candidate = URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let allowedRoot: URL
        if ProcessInfo.processInfo.environment["KIMI_SESSION_INDEX_OVERRIDE"] != nil {
            allowedRoot = indexURL.deletingLastPathComponent()
        } else {
            allowedRoot = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".kimi-code")
        }
        let rootPath = allowedRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard candidate.path.hasPrefix(rootPath + "/"),
              FileManager.default.fileExists(atPath: candidate.path) else {
            return nil
        }
        return candidate
    }

    private static func currentSessionIndexURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        if let override = environment["KIMI_SESSION_INDEX_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw TaskRepositoryError.databaseNotFound
            }
            return url
        }
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/session_index.jsonl")
        guard fileManager.fileExists(atPath: url.path) else {
            throw TaskRepositoryError.databaseNotFound
        }
        return url
    }

    private static func timestampMillis(from rawValue: String?, fallbackURL: URL) -> Int64 {
        if let rawValue {
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let basicFormatter = ISO8601DateFormatter()
            basicFormatter.formatOptions = [.withInternetDateTime]
            if let date = fractionalFormatter.date(from: rawValue)
                ?? basicFormatter.date(from: rawValue) {
                return Int64(date.timeIntervalSince1970 * 1000)
            }
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fallbackURL.path)
        let date = attributes?[.modificationDate] as? Date ?? .distantPast
        return Int64(date.timeIntervalSince1970 * 1000)
    }

    private static func nonempty(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private struct KimiWorkTaskRepository {
    private static let maximumStatusSize = 512 * 1_024
    private static let maximumTitleSize = 1_024 * 1_024

    static func loadActiveTasks() throws -> (
        sourceURL: URL,
        tasks: [LocalAgentTask]
    ) {
        let directoryURL = try currentStatusDirectoryURL()
        let statusURL = directoryURL.appendingPathComponent(
            "conversation-statuses.json",
            isDirectory: false
        )
        let unreadURL = directoryURL.appendingPathComponent(
            "conversation-unread.json",
            isDirectory: false
        )
        let titleURL = directoryURL.appendingPathComponent(
            "conversation-titles.json",
            isDirectory: false
        )
        let statusData = try readOptionalFile(
            at: statusURL,
            maximumSize: maximumStatusSize
        )
        let unreadData = try readOptionalFile(
            at: unreadURL,
            maximumSize: maximumStatusSize
        )
        let titleData = try readOptionalFile(
            at: titleURL,
            maximumSize: maximumTitleSize
        )
        guard let records = KimiWorkStatusParser.activeRecords(
            statusData: statusData,
            unreadData: unreadData,
            titleData: titleData
        ) else {
            throw TaskRepositoryError.invalidData(
                "Kimi Work 本机任务状态不可读"
            )
        }

        let sourceURLs = [
            statusData == nil ? nil : statusURL,
            unreadData == nil ? nil : unreadURL,
        ].compactMap { $0 }
        guard let sourceURL = sourceURLs.first else {
            throw TaskRepositoryError.databaseNotFound
        }
        let updatedMillis = sourceURLs.map(modificationMillis)
            .max() ?? 0
        let tasks = records.map { record in
            LocalAgentTask(
                id: "kimi-work:\(record.conversationKey)",
                agent: .kimi,
                title: record.title ?? fallbackTitle(for: record.state),
                projectName: "Kimi Work",
                projectPath: "kimi-work://home",
                updatedMillis: updatedMillis,
                displayState: displayState(for: record.state),
                navigationID: record.conversationKey
            )
        }
        return (sourceURL, tasks)
    }

    private static func currentStatusDirectoryURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let directoryURL: URL
        if let override = environment[
            "KIMI_WORK_STATUS_DIRECTORY_OVERRIDE"
        ], !override.isEmpty {
            directoryURL = URL(
                fileURLWithPath: override,
                isDirectory: true
            )
        } else {
            let applicationSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
            directoryURL = applicationSupportURL
                .appendingPathComponent(
                    "kimi-desktop",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "kimi-agent",
                    isDirectory: true
                )
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: directoryURL.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue else {
            throw TaskRepositoryError.databaseNotFound
        }
        return directoryURL
    }

    private static func readOptionalFile(
        at url: URL,
        maximumSize: Int
    ) throws -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        guard let attributes = try? fileManager.attributesOfItem(
            atPath: url.path
        ),
        attributes[.type] as? FileAttributeType == .typeRegular,
        let fileSize = attributes[.size] as? NSNumber,
        fileSize.intValue <= maximumSize,
        let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw TaskRepositoryError.invalidData(
                "Kimi Work 本机任务状态不可读"
            )
        }
        return data
    }

    private static func modificationMillis(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let date = attributes?[.modificationDate] as? Date ?? .distantPast
        return Int64(date.timeIntervalSince1970 * 1_000)
    }

    private static func displayState(
        for state: KimiWorkActivityState
    ) -> TaskDisplayState {
        switch state {
        case .running:
            return .running
        case .needsAction:
            return .needsAction
        case .needsReview:
            return .needsReview
        }
    }

    private static func fallbackTitle(
        for state: KimiWorkActivityState
    ) -> String {
        switch state {
        case .running:
            return "Kimi Work 运行中"
        case .needsAction:
            return "Kimi Work 待操作"
        case .needsReview:
            return "Kimi Work 待查看"
        }
    }
}

struct KimiTaskRepository {
    static func loadActiveTasks() throws -> (
        indexURL: URL,
        tasks: [LocalAgentTask]
    ) {
        var sourceURLs: [URL] = []
        var tasks: [LocalAgentTask] = []

        do {
            let loaded = try KimiCLITaskRepository.loadActiveTasks()
            sourceURLs.append(loaded.indexURL)
            tasks.append(contentsOf: loaded.tasks)
        } catch {
            // CLI 与 Work 数据源互相隔离；继续尝试 Work。
        }
        do {
            let loaded = try KimiWorkTaskRepository.loadActiveTasks()
            sourceURLs.insert(loaded.sourceURL, at: 0)
            tasks.append(contentsOf: loaded.tasks)
        } catch {
            // Work 不可用时仍保留已确认的 CLI 活动。
        }

        guard let indexURL = sourceURLs.first else {
            throw KimiTaskRepositoryError.unavailable
        }
        var seenIDs = Set<String>()
        let mergedTasks = tasks.filter {
            seenIDs.insert($0.id).inserted
        }.sorted {
            let leftPriority = priority($0.displayState)
            let rightPriority = priority($1.displayState)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            if $0.updatedMillis != $1.updatedMillis {
                return $0.updatedMillis > $1.updatedMillis
            }
            return $0.id < $1.id
        }
        return (indexURL, mergedTasks)
    }

    private static func priority(_ state: TaskDisplayState) -> Int {
        switch state {
        case .needsAction:
            return 0
        case .running:
            return 1
        case .needsReview:
            return 2
        case .idle:
            return 3
        }
    }
}

private enum KimiTaskRepositoryError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "暂时没有读取到 Kimi CLI 或 Kimi Work 的本机任务状态"
    }
}

enum KimiUsageError: LocalizedError {
    case executableNotFound
    case sessionIndexNotFound
    case monitorSessionNotFound
    case commandFailed
    case timedOut
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "没有找到 Kimi 官方命令行程序"
        case .sessionIndexNotFound:
            return "没有找到 Kimi 本机会话索引"
        case .monitorSessionNotFound:
            return "无法建立 Kimi 额度监控会话"
        case .commandFailed:
            return "Kimi 额度读取命令执行失败"
        case .timedOut:
            return "读取 Kimi 剩余额度超时"
        case .invalidResponse:
            return "Kimi 没有返回可识别的剩余额度"
        }
    }
}

enum KimiProcessEnvironment {
    static func sanitized(_ inherited: [String: String]) -> [String: String] {
        let blockedPrefixes = [
            "AWS_",
            "AZURE_",
            "BROWSER_USE_",
            "CODEX_",
            "GH_",
            "GITHUB_",
            "GOOGLE_",
            "LOOMLOOM_",
            "NODE_REPL_",
            "OPENAI_",
        ]
        let blockedFragments = [
            "ACCESS_KEY",
            "API_KEY",
            "AUTH",
            "CONNECTION_STRING",
            "COOKIE",
            "CREDENTIAL",
            "DATABASE",
            "DSN",
            "PASSWORD",
            "PASSWD",
            "PRIVATE_KEY",
            "SECRET",
            "SESSION_KEY",
            "TOKEN",
        ]
        let blockedExactKeys = Set([
            "_",
            "OLDPWD",
            "PWD",
            "SHLVL",
        ])
        return inherited.filter { key, _ in
            let uppercaseKey = key.uppercased()
            return !blockedExactKeys.contains(key)
                && !blockedPrefixes.contains(where: uppercaseKey.hasPrefix)
                && !blockedFragments.contains(where: uppercaseKey.contains)
        }
    }
}

final class KimiUsageClient: @unchecked Sendable {
    typealias Completion = @Sendable (Result<[UsageWindowDisplay], Error>) -> Void

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ newData: Data, maximumSize: Int) {
            lock.lock()
            let remainingCapacity = max(0, maximumSize - data.count)
            if remainingCapacity > 0 {
                data.append(newData.prefix(remainingCapacity))
            }
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static let maximumOutputSize = 4 * 1024 * 1024
    private static let maximumIndexSize = 32 * 1024 * 1024
    private let queue = DispatchQueue(
        label: "io.github.local-ai-statusbar.kimi-usage",
        qos: .utility
    )

    func refresh(completion: @escaping Completion) {
        queue.async {
            completion(Result {
                try Self.fetchWindowsSynchronously()
            })
        }
    }

    private static func fetchWindowsSynchronously() throws -> [UsageWindowDisplay] {
        if let override = ProcessInfo.processInfo.environment[
            "KIMI_USAGE_TEXT_OVERRIDE"
        ], !override.isEmpty {
            let data = try boundedData(at: URL(fileURLWithPath: override))
            guard let text = String(data: data, encoding: .utf8) else {
                throw KimiUsageError.invalidResponse
            }
            return try mergedWindows(from: text)
        }

        let executableURL = try executableURL()
        let indexURL = try sessionIndexURL()
        let monitorDirectory = try KimiMonitorDirectory.url()
        let storedSessionID = KimiMonitorSession.storedID()
        let currentRecords = try sessionRecords(at: indexURL)
        let reusableSessionID = storedSessionID.flatMap { sessionID in
            currentRecords.contains(where: { $0.sessionID == sessionID })
                ? sessionID : nil
        }

        let output: Data
        if let reusableSessionID {
            output = try runUsage(
                executableURL: executableURL,
                sessionID: reusableSessionID,
                workingDirectory: monitorDirectory
            )
        } else {
            let previousIDs = Set(currentRecords.map(\.sessionID))
            output = try runUsage(
                executableURL: executableURL,
                sessionID: nil,
                workingDirectory: monitorDirectory
            )
            let refreshedRecords = try sessionRecords(at: indexURL)
            let canonicalMonitorPath = monitorDirectory
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            let monitorRecord = refreshedRecords.reversed().first { record in
                guard !previousIDs.contains(record.sessionID) else { return false }
                let workPath = URL(fileURLWithPath: record.workDir)
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                    .path
                return workPath == canonicalMonitorPath
            }
            guard let monitorRecord else {
                throw KimiUsageError.monitorSessionNotFound
            }
            UserDefaults.standard.set(
                monitorRecord.sessionID,
                forKey: KimiMonitorSession.defaultsKey
            )
        }

        guard output.count <= maximumOutputSize,
              let text = String(data: output, encoding: .utf8) else {
            throw KimiUsageError.invalidResponse
        }
        return try mergedWindows(from: text)
    }

    private static func mergedWindows(from text: String) throws -> [UsageWindowDisplay] {
        let codeWindows = KimiUsageTextParser.windows(from: text).sorted {
            let leftPriority = windowPriority($0.label)
            let rightPriority = windowPriority($1.label)
            if leftPriority == rightPriority {
                return $0.label < $1.label
            }
            return leftPriority < rightPriority
        }
        guard !codeWindows.isEmpty else {
            throw KimiUsageError.invalidResponse
        }
        guard let totalWindow = KimiTotalUsageLogReader.currentWindow() else {
            return codeWindows
        }
        return [totalWindow] + codeWindows
    }

    private static func windowPriority(_ label: String) -> Int {
        switch label {
        case "5 小时":
            return 0
        case "每周":
            return 1
        default:
            return 2
        }
    }

    private static func runUsage(
        executableURL: URL,
        sessionID: String?,
        workingDirectory: URL
    ) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        let outputBox = DataBox()
        let expectScript = #"""
        set timeout 18
        set executable $env(LOCAL_AI_STATUSBAR_KIMI_EXECUTABLE)
        set session $env(LOCAL_AI_STATUSBAR_KIMI_SESSION)
        if {$session eq ""} {
          spawn -noecho $executable
        } else {
          spawn -noecho $executable --session $session
        }
        after 1800
        send -- "/usage"
        after 300
        send -- "\033\[13u"
        expect {
          -re {[0-9]{1,3}% used} {
            after 1500
            send -- "/exit"
            after 300
            send -- "\033\[13u"
            set timeout 5
            expect eof
          }
          timeout {
            send -- "\003"
            exit 124
          }
          eof {}
        }
        """#
        process.executableURL = URL(fileURLWithPath: "/usr/bin/expect")
        process.arguments = ["-c", expectScript]
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let inheritedEnvironment = ProcessInfo.processInfo.environment
        var environment = KimiProcessEnvironment.sanitized(inheritedEnvironment)
        if environment["PATH"] == nil {
            environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        environment["TERM"] = "xterm-256color"
        environment["COLUMNS"] = "80"
        environment["LINES"] = "24"
        environment["LOCAL_AI_STATUSBAR_KIMI_EXECUTABLE"] = executableURL.path
        environment["LOCAL_AI_STATUSBAR_KIMI_SESSION"] = sessionID ?? ""
        process.environment = environment

        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputBox.append(data, maximumSize: maximumOutputSize)
        }
        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            throw KimiUsageError.commandFailed
        }
        let deadline = Date().addingTimeInterval(24)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < terminationDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        outputPipe.fileHandleForReading.readabilityHandler = nil
        outputBox.append(
            outputPipe.fileHandleForReading.readDataToEndOfFile(),
            maximumSize: maximumOutputSize
        )
        if process.isRunning {
            throw KimiUsageError.timedOut
        }
        guard process.terminationStatus == 0 || !outputBox.snapshot().isEmpty else {
            throw KimiUsageError.commandFailed
        }
        return outputBox.snapshot()
    }

    private static func sessionRecords(at indexURL: URL) throws -> [KimiSessionIndexRecord] {
        let data = try boundedData(at: indexURL, maximumSize: maximumIndexSize)
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { line in
                guard line.count <= 64 * 1024 else { return nil }
                return try? decoder.decode(
                    KimiSessionIndexRecord.self,
                    from: Data(line)
                )
            }
    }

    private static func sessionIndexURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        if let override = environment["KIMI_SESSION_INDEX_OVERRIDE"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard fileManager.fileExists(atPath: url.path) else {
                throw KimiUsageError.sessionIndexNotFound
            }
            return url
        }
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".kimi-code/session_index.jsonl")
        guard fileManager.fileExists(atPath: url.path) else {
            throw KimiUsageError.sessionIndexNotFound
        }
        return url
    }

    private static func executableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let fileManager = FileManager.default
        let candidates: [URL]
        if let override = environment["KIMI_EXECUTABLE_OVERRIDE"], !override.isEmpty {
            candidates = [URL(fileURLWithPath: override)]
        } else {
            let home = fileManager.homeDirectoryForCurrentUser
            candidates = [
                home.appendingPathComponent(".local/bin/kimi"),
                home.appendingPathComponent(".kimi-code/bin/kimi"),
                URL(fileURLWithPath: "/usr/local/bin/kimi"),
                URL(fileURLWithPath: "/opt/homebrew/bin/kimi"),
            ]
        }
        guard let executable = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) else {
            throw KimiUsageError.executableNotFound
        }
        return executable
    }

    private static func boundedData(
        at url: URL,
        maximumSize: Int = maximumOutputSize
    ) throws -> Data {
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: url.path
        ),
        let fileSize = attributes[.size] as? NSNumber,
        fileSize.intValue <= maximumSize,
        let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw KimiUsageError.invalidResponse
        }
        return data
    }
}

private enum SQLiteJSONReader {
    static func read<Record: Decodable>(
        databaseURL: URL,
        query: String
    ) throws -> [Record] {
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
            throw TaskRepositoryError.sqliteFailed(
                message.isEmpty
                    ? "sqlite3 退出码 \(process.terminationStatus)" : message
            )
        }
        do {
            return data.isEmpty ? [] : try JSONDecoder().decode([Record].self, from: data)
        } catch {
            throw TaskRepositoryError.invalidData(error.localizedDescription)
        }
    }
}

struct QwenDesktopSnapshot: Equatable, Sendable {
    let quota: AgentQuotaDisplay
    let unreadChatIDs: Set<String>
    let unreadSubChatIDs: Set<String>
}

enum QwenDesktopError: LocalizedError {
    case appNotRunning
    case bridgeUnavailable
    case invalidResponse
    case timedOut

    var errorDescription: String? {
        switch self {
        case .appNotRunning:
            return "QwenWorkCN 尚未运行"
        case .bridgeUnavailable:
            return "QwenWorkCN 本机状态接口暂时不可用"
        case .invalidResponse:
            return "QwenWorkCN 返回了无法识别的额度状态"
        case .timedOut:
            return "读取 QwenWorkCN 状态超时"
        }
    }
}

enum QwenDesktopSnapshotParser {
    static func snapshot(from result: [String: Any]) throws -> QwenDesktopSnapshot {
        let quota = try QwenUsageSnapshotParser.quota(from: result)
        let unreadChatIDs = identifiers(from: result["unreadChatIDs"])
        let unreadSubChatIDs = identifiers(from: result["unreadSubChatIDs"])
        return QwenDesktopSnapshot(
            quota: quota,
            unreadChatIDs: unreadChatIDs,
            unreadSubChatIDs: unreadSubChatIDs
        )
    }

    private static func identifiers(from rawValue: Any?) -> Set<String> {
        let rawIdentifiers = rawValue as? [Any] ?? []
        return Set(rawIdentifiers.compactMap { value -> String? in
            guard let chatID = value as? String,
                  !chatID.isEmpty,
                  chatID.utf8.count <= 256 else {
                return nil
            }
            return chatID
        })
    }
}

final class QwenDesktopBridge: @unchecked Sendable {
    private struct DevToolsTarget: Decodable {
        let webSocketDebuggerUrl: String?
    }

    private struct DevToolsVersion: Decodable {
        let webSocketDebuggerUrl: String?
    }

    private static let bundleIdentifier = "cn.qwenwork.desktop.mac"
    private static let maximumFixtureSize = 1 * 1024 * 1024
    private static let snapshotExpression = """
    new Promise((resolve) => {
        const id = 741852963;
        let completed = false;
        const finish = (value) => {
          if (completed) return;
          completed = true;
          resolve(value);
        };
        electronTRPC.onMessage((message) => {
          if (!message || message.id !== id) return;
          const data = message.result && message.result.data;
          const payload = data && data.json ? data.json : data;
          const quota = payload && payload.userQuota;
          finish(quota || null);
        });
        electronTRPC.sendMessage({
          method: "request",
          operation: {
            id,
            type: "query",
            path: "auth.getUsage",
            input: { json: null },
            context: {}
          }
        });
        setTimeout(() => finish(null), 5000);
      }).then((quota) => {
      const readIdentifierSet = (key) => {
        try {
          const parsed = JSON.parse(localStorage.getItem(key) || "[]");
          if (!Array.isArray(parsed)) return [];
          return parsed.filter((value) => (
            typeof value === "string"
              && value.length > 0
              && new TextEncoder().encode(value).length <= 256
          )).slice(0, 1000);
        } catch {
          return [];
        }
      };
      if (!quota) return { ok: false };
      return {
        ok: true,
        userQuota: {
          total: quota.total,
          used: quota.used,
          remaining: quota.remaining,
          percentage: quota.percentage,
          unit: quota.unit
        },
        unreadChatIDs: readIdentifierSet("agents:unseenChanges"),
        unreadSubChatIDs: readIdentifierSet("agents:subChatUnseenChanges")
      };
    })
    """

    static func fetchSnapshot() async throws -> QwenDesktopSnapshot {
        if let override = ProcessInfo.processInfo.environment[
            "QWEN_DESKTOP_SNAPSHOT_OVERRIDE"
        ], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            guard let attributes = try? FileManager.default.attributesOfItem(
                atPath: url.path
            ),
            let fileSize = attributes[.size] as? NSNumber,
            fileSize.intValue <= maximumFixtureSize,
            let data = try? Data(contentsOf: url),
            let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw QwenDesktopError.invalidResponse
            }
            return try QwenDesktopSnapshotParser.snapshot(from: result)
        }

        let value = try await evaluate(expression: snapshotExpression)
        guard value["ok"] as? Bool == true else {
            throw QwenDesktopError.invalidResponse
        }
        return try QwenDesktopSnapshotParser.snapshot(from: value)
    }

    static func openChat(_ chatID: String) async throws {
        guard !chatID.isEmpty, chatID.utf8.count <= 256 else {
            throw QwenDesktopError.invalidResponse
        }
        if ProcessInfo.processInfo.environment["QWEN_OPEN_CHAT_FIXTURE"] == "1" {
            return
        }
        let encodedData = try JSONSerialization.data(
            withJSONObject: [chatID],
            options: []
        )
        guard let encodedArray = String(data: encodedData, encoding: .utf8),
              encodedArray.count >= 2 else {
            throw QwenDesktopError.invalidResponse
        }
        let encodedChatID = String(encodedArray.dropFirst().dropLast())
        let expression = """
        desktopApi.openMainWindowWithChat(\(encodedChatID))
          .then(() => ({ ok: true }))
          .catch(() => ({ ok: false }))
        """
        let value = try await evaluate(expression: expression)
        guard value["ok"] as? Bool == true else {
            throw QwenDesktopError.bridgeUnavailable
        }
    }

    private static func evaluate(expression: String) async throws -> [String: Any] {
        let ports = try listeningPorts()
        guard !ports.isEmpty else {
            throw QwenDesktopError.bridgeUnavailable
        }
        let session = localSession()
        for port in ports {
            let targetURLs = await targetWebSocketURLs(port: port, session: session)
            for targetURL in targetURLs {
                do {
                    let responseText = try await evaluate(
                        expression: expression,
                        targetURL: targetURL,
                        session: session
                    )
                    guard let data = responseText.data(using: .utf8),
                          let message = try JSONSerialization.jsonObject(
                              with: data
                          ) as? [String: Any],
                          let result = message["result"] as? [String: Any],
                          result["exceptionDetails"] == nil,
                          let remoteObject = result["result"] as? [String: Any],
                          let value = remoteObject["value"] as? [String: Any] else {
                        continue
                    }
                    session.invalidateAndCancel()
                    return value
                } catch {
                    continue
                }
            }
        }
        session.invalidateAndCancel()
        throw QwenDesktopError.bridgeUnavailable
    }

    private static func evaluate(
        expression: String,
        targetURL: URL,
        session: URLSession
    ) async throws -> String {
        let socket = session.webSocketTask(with: targetURL)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }
        let request: [String: Any] = [
            "id": 1,
            "method": "Runtime.evaluate",
            "params": [
                "expression": expression,
                "awaitPromise": true,
                "returnByValue": true,
            ],
        ]
        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard let requestText = String(data: requestData, encoding: .utf8) else {
            throw QwenDesktopError.invalidResponse
        }
        try await socket.send(.string(requestText))

        for _ in 0..<12 {
            let message = try await withTimeout(seconds: 7) {
                try await socket.receive()
            }
            let responseText: String
            switch message {
            case let .string(text):
                responseText = text
            case let .data(data):
                guard let text = String(data: data, encoding: .utf8) else {
                    continue
                }
                responseText = text
            @unknown default:
                continue
            }
            guard let data = responseText.data(using: .utf8),
                  let response = try? JSONSerialization.jsonObject(
                      with: data
                  ) as? [String: Any],
                  (response["id"] as? NSNumber)?.intValue == 1 else {
                continue
            }
            return responseText
        }
        throw QwenDesktopError.timedOut
    }

    private static func listeningPorts() throws -> [Int] {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        )
        guard !applications.isEmpty else {
            throw QwenDesktopError.appNotRunning
        }
        var ports = Set<Int>()
        for application in applications {
            let process = Process()
            let outputPipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            process.arguments = [
                "-nP",
                "-a",
                "-p", String(application.processIdentifier),
                "-iTCP",
                "-sTCP:LISTEN",
            ]
            process.standardOutput = outputPipe
            process.standardError = FileHandle.nullDevice
            try? process.run()
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8),
                  let expression = try? NSRegularExpression(
                      pattern: #":(\d{2,5})\s+\(LISTEN\)"#
                  ) else {
                continue
            }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in expression.matches(in: text, range: range) {
                guard let portRange = Range(match.range(at: 1), in: text),
                      let port = Int(text[portRange]),
                      (1...65_535).contains(port) else {
                    continue
                }
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    private static func targetWebSocketURLs(
        port: Int,
        session: URLSession
    ) async -> [URL] {
        guard let versionURL = URL(
            string: "http://127.0.0.1:\(port)/json/version"
        ),
        let listURL = URL(string: "http://127.0.0.1:\(port)/json/list") else {
            return []
        }
        do {
            let (versionData, versionResponse) = try await session.data(from: versionURL)
            guard (versionResponse as? HTTPURLResponse)?.statusCode == 200,
                  (try? JSONDecoder().decode(
                      DevToolsVersion.self,
                      from: versionData
                  ).webSocketDebuggerUrl) != nil else {
                return []
            }
            let (listData, listResponse) = try await session.data(from: listURL)
            guard (listResponse as? HTTPURLResponse)?.statusCode == 200 else {
                return []
            }
            let targets = try JSONDecoder().decode([DevToolsTarget].self, from: listData)
            return targets.compactMap {
                guard let rawURL = $0.webSocketDebuggerUrl else { return nil }
                return URL(string: rawURL)
            }
        } catch {
            return []
        }
    }

    private static func localSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
                throw QwenDesktopError.timedOut
            }
            guard let result = try await group.next() else {
                throw QwenDesktopError.timedOut
            }
            group.cancelAll()
            return result
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
        CodexProjectNameResolver.projectName(for: canonicalProjectPath)
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

        let alignedBottomY = codexFrame.minY
        let targetY = min(
            max(visibleFrame.minY, alignedBottomY),
            visibleFrame.maxY - panelSize.height
        )
        return NSPoint(x: targetX, y: targetY)
    }
}

@MainActor
final class WindowModeModel: ObservableObject {
    @Published private(set) var mode: WindowDisplayMode = AppLayout.defaultWindowMode
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
        let activeTasks = tasks.filter {
            ActivityTaskPolicy.includes($0.displayState)
        }
        let visibleTasks: [CodexTask]
        if query.isEmpty {
            visibleTasks = activeTasks
        } else {
            visibleTasks = activeTasks.filter {
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
            errorMessage = "任务链接无效"
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
                remainingPercent: 100 - usedPercent
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
            let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.0.0"
            send([
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "local-ai-statusbar",
                        "title": "本机AI状态栏",
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

enum AgentQuotaState: Equatable {
    case loading
    case available(AgentQuotaDisplay, isStale: Bool)
    case unavailable(String)
}

private struct LocalAgentTaskLoadOutcome: Sendable {
    let sourcePath: String
    let tasks: [LocalAgentTask]
    let errorMessage: String?
}

@MainActor
final class QwenStore: ObservableObject {
    @Published private(set) var tasks: [LocalAgentTask] = []
    @Published private(set) var quotaState: AgentQuotaState = .loading
    @Published private(set) var errorMessage: String?
    @Published private(set) var sourcePath = ""

    private var refreshTimer: Timer?
    private var isRefreshInFlight = false
    private var lastSuccessfulQuota: AgentQuotaDisplay?

    init(refreshInterval: TimeInterval? = 20) {
        refresh()
        if let refreshInterval {
            refreshTimer = Timer.scheduledTimer(
                withTimeInterval: refreshInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            refreshTimer?.tolerance = min(3, refreshInterval / 10)
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refresh() {
        guard !isRefreshInFlight else { return }
        isRefreshInFlight = true
        Task { [weak self] in
            let snapshot: QwenDesktopSnapshot?
            let bridgeError: String?
            do {
                snapshot = try await QwenDesktopBridge.fetchSnapshot()
                bridgeError = nil
            } catch {
                snapshot = nil
                bridgeError = error.localizedDescription
            }
            let unreadChatIDs = snapshot?.unreadChatIDs ?? []
            let unreadSubChatIDs = snapshot?.unreadSubChatIDs ?? []
            let outcome = await Task.detached(priority: .utility) {
                do {
                    let loaded = try QwenTaskRepository.loadActiveTasks(
                        unreadChatIDs: unreadChatIDs,
                        unreadSubChatIDs: unreadSubChatIDs
                    )
                    return LocalAgentTaskLoadOutcome(
                        sourcePath: loaded.databaseURL.path,
                        tasks: loaded.tasks,
                        errorMessage: nil
                    )
                } catch {
                    return LocalAgentTaskLoadOutcome(
                        sourcePath: "",
                        tasks: [],
                        errorMessage: error.localizedDescription
                    )
                }
            }.value
            guard let self else { return }
            self.isRefreshInFlight = false
            if outcome.errorMessage == nil {
                if self.tasks != outcome.tasks {
                    self.tasks = outcome.tasks
                }
                self.sourcePath = outcome.sourcePath
            }
            self.errorMessage = outcome.errorMessage ?? bridgeError
            if let quota = snapshot?.quota {
                self.lastSuccessfulQuota = quota
                self.quotaState = .available(quota, isStale: false)
            } else if let lastSuccessfulQuota = self.lastSuccessfulQuota {
                self.quotaState = .available(lastSuccessfulQuota, isStale: true)
            } else {
                self.quotaState = .unavailable(
                    bridgeError ?? "QwenWorkCN 额度暂时不可用"
                )
            }
        }
    }

    func open(_ task: LocalAgentTask) {
        guard task.agent == .qwen else { return }
        Task { [weak self] in
            do {
                try await QwenDesktopBridge.openChat(task.navigationID)
                self?.errorMessage = nil
            } catch {
                self?.errorMessage = "已打开 QwenWorkCN，但暂时无法精确定位线程"
                Self.activateQwen()
            }
        }
    }

    private static func activateQwen() {
        let applications = NSRunningApplication.runningApplications(
            withBundleIdentifier: "cn.qwenwork.desktop.mac"
        )
        if let application = applications.first {
            application.activate(options: [.activateAllWindows])
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: "/Applications/QwenWorkCN.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}

@MainActor
final class KimiStore: ObservableObject {
    @Published private(set) var tasks: [LocalAgentTask] = []
    @Published private(set) var quotaState: UsageState = .loading
    @Published private(set) var errorMessage: String?
    @Published private(set) var sourcePath = ""

    private let usageClient = KimiUsageClient()
    private let taskQueue = DispatchQueue(
        label: "io.github.local-ai-statusbar.kimi-tasks",
        qos: .utility
    )
    private var taskRefreshTimer: Timer?
    private var quotaRefreshTimer: Timer?
    private var isTaskRefreshInFlight = false
    private var isQuotaRefreshInFlight = false
    private var lastSuccessfulWindows: [UsageWindowDisplay]?

    init(
        taskRefreshInterval: TimeInterval? = 10,
        quotaRefreshInterval: TimeInterval? = 60
    ) {
        refresh()
        if let taskRefreshInterval {
            taskRefreshTimer = Timer.scheduledTimer(
                withTimeInterval: taskRefreshInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshTasks()
                }
            }
            taskRefreshTimer?.tolerance = min(2, taskRefreshInterval / 10)
        }
        if let quotaRefreshInterval {
            quotaRefreshTimer = Timer.scheduledTimer(
                withTimeInterval: quotaRefreshInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshUsage()
                }
            }
            quotaRefreshTimer?.tolerance = min(5, quotaRefreshInterval / 10)
        }
    }

    deinit {
        taskRefreshTimer?.invalidate()
        quotaRefreshTimer?.invalidate()
    }

    func refresh() {
        refreshTasks()
        refreshUsage()
    }

    func refreshTasks() {
        guard !isTaskRefreshInFlight else { return }
        isTaskRefreshInFlight = true
        taskQueue.async {
            let outcome: LocalAgentTaskLoadOutcome
            do {
                let loaded = try KimiTaskRepository.loadActiveTasks()
                outcome = LocalAgentTaskLoadOutcome(
                    sourcePath: loaded.indexURL.path,
                    tasks: loaded.tasks,
                    errorMessage: nil
                )
            } catch {
                outcome = LocalAgentTaskLoadOutcome(
                    sourcePath: "",
                    tasks: [],
                    errorMessage: error.localizedDescription
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isTaskRefreshInFlight = false
                if outcome.errorMessage == nil {
                    if self.tasks != outcome.tasks {
                        self.tasks = outcome.tasks
                    }
                    self.sourcePath = outcome.sourcePath
                }
                self.errorMessage = outcome.errorMessage
            }
        }
    }

    func refreshUsage() {
        guard !isQuotaRefreshInFlight else { return }
        isQuotaRefreshInFlight = true
        usageClient.refresh { result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isQuotaRefreshInFlight = false
                switch result {
                case let .success(windows):
                    self.lastSuccessfulWindows = windows
                    self.quotaState = .available(windows, isStale: false)
                case let .failure(error):
                    if let lastSuccessfulWindows = self.lastSuccessfulWindows {
                        self.quotaState = .available(
                            lastSuccessfulWindows,
                            isStale: true
                        )
                    } else {
                        self.quotaState = .unavailable(error.localizedDescription)
                    }
                }
            }
        }
    }

    func open(_ task: LocalAgentTask) {
        guard task.agent == .kimi,
              let url = URL(string: "kimi-work://home") else {
            return
        }
        if !NSWorkspace.shared.open(url) {
            errorMessage = "无法打开 Kimi Agent 页面"
            return
        }
        errorMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.moonshot.kimichat"
            ).first?.activate(options: [.activateAllWindows])
        }
    }
}

@MainActor
final class AgentDiscoveryStore: ObservableObject {
    @Published private(set) var snapshots: [AgentProductSnapshot] = []

    private let registry: AgentAdapterRegistry
    private let catalog: any ApplicationCatalog
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?

    init(
        registry: AgentAdapterRegistry? = nil,
        catalog: (any ApplicationCatalog)? = nil,
        refreshInterval: TimeInterval? = 30
    ) {
        let usesSyntheticProducts =
            ProcessInfo.processInfo.environment[
                "LOCAL_AI_STATUSBAR_SYNTHETIC_AGENT_PRODUCTS"
            ] == "1"
        self.registry = registry ?? (
            usesSyntheticProducts ? .syntheticQA : .firstBatch
        )
        self.catalog = catalog ?? (
            usesSyntheticProducts
                ? SyntheticAgentProductApplicationCatalog()
                : LocalApplicationCatalog()
        )
        refresh()
        if let refreshInterval {
            refreshTimer = Timer.scheduledTimer(
                withTimeInterval: refreshInterval,
                repeats: true
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            refreshTimer?.tolerance = min(5, refreshInterval / 10)
        }
    }

    deinit {
        refreshTimer?.invalidate()
        refreshTask?.cancel()
    }

    func refresh() {
        let runtimeSnapshots = registry.runtimeSnapshots(
            using: catalog,
            preservingDataFrom: snapshots
        )
        if snapshots != runtimeSnapshots {
            snapshots = runtimeSnapshots
        }
        guard refreshTask == nil else { return }
        let registry = registry
        let catalog = catalog
        refreshTask = Task { [weak self] in
            let updatedSnapshots = await registry.snapshots(
                using: catalog
            )
            guard let self, !Task.isCancelled else { return }
            let currentSnapshots = registry.runtimeSnapshots(
                using: catalog,
                preservingDataFrom: updatedSnapshots
            )
            if snapshots != currentSnapshots {
                snapshots = currentSnapshots
            }
            refreshTask = nil
        }
    }

    func openApplication(productID: String) {
        guard let snapshot = snapshots.first(where: { $0.id == productID }),
              snapshot.presentation.canOpenApplication,
              let application = snapshot.application else {
            return
        }
        if let runningApplication = NSRunningApplication.runningApplications(
            withBundleIdentifier: application.bundleIdentifier
        ).first {
            runningApplication.activate(options: [.activateAllWindows])
            return
        }
        NSWorkspace.shared.openApplication(
            at: URL(fileURLWithPath: application.path),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
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
        .help("\(projectName)\n任务：\(task.title)\n状态：\(displayState.statusDescription)\n最近活动：\(TimeLabelFormatter.fullLabel(milliseconds: task.updatedMillis))")
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
            .accessibilityLabel("项目 \(group.name)，\(group.tasks.count) 个活动线程")

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
        .frame(
            minWidth: AppLayout.panelWidth,
            idealWidth: AppLayout.panelWidth,
            maxWidth: AppLayout.panelWidth,
            minHeight: AppLayout.minimumPanelHeight,
            idealHeight: AppLayout.idealPanelHeight
        )
        .background(.regularMaterial)
    }

    private var header: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 1) {
                    Text("本机AI状态栏")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(groups.count) 个项目 · \(visibleTaskCount) 个活动线程")
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
        .font(.system(size: 10.5))
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .help(usageHelpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(usageAccessibilityLabel)
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
                : "剩余用量每 60 秒刷新。不显示重置时间。"
        case let .unavailable(message):
            return message
        }
    }

    private var usageAccessibilityLabel: String {
        switch usageStore.state {
        case .loading:
            return "正在读取剩余用量"
        case let .available(windows, isStale):
            let details = windows.map { "\($0.label)剩余\($0.remainingPercent)%" }.joined(separator: "，")
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
                Text(searchText.isEmpty ? "当前没有活动线程" : "没有匹配的活动线程")
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
        .help("本机只读状态")
    }
}

struct ActivityRowModel: Identifiable, Equatable {
    let id: String
    let nativeID: String
    let agent: AgentKind
    let title: String
    let projectName: String
    let projectPath: String
    let updatedMillis: Int64
    let displayState: TaskDisplayState
}

struct ActivityProjectGroup: Identifiable {
    let id: String
    let name: String
    let tasks: [ActivityRowModel]

    var latestUpdate: Int64 {
        tasks.first?.updatedMillis ?? 0
    }

    static func grouped(_ tasks: [ActivityRowModel]) -> [ActivityProjectGroup] {
        Dictionary(grouping: tasks, by: \.projectPath).map { path, projectTasks in
            let sortedTasks = projectTasks.sorted {
                if $0.updatedMillis == $1.updatedMillis { return $0.id < $1.id }
                return $0.updatedMillis > $1.updatedMillis
            }
            return ActivityProjectGroup(
                id: path,
                name: sortedTasks.first?.projectName ?? "未归类",
                tasks: sortedTasks
            )
        }.sorted {
            if $0.latestUpdate == $1.latestUpdate { return $0.name < $1.name }
            return $0.latestUpdate > $1.latestUpdate
        }
    }
}

struct CompactActivityRowView: View {
    let task: ActivityRowModel
    let now: Date
    let openTask: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: openTask) {
            HStack(spacing: 6) {
                Circle()
                    .fill(task.displayState.tintColor)
                    .frame(width: 5, height: 5)

                Text(task.title)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 3)

                Text(task.displayState.badgeText ?? "活动")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(task.displayState.tintColor)
                    .fixedSize()
            }
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(
                isHovering ? Color.primary.opacity(0.055) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(
            "\(task.projectName)\n线程：\(task.title)\n状态：\(task.displayState.statusDescription)\n最近活动：\(TimeLabelFormatter.fullLabel(milliseconds: task.updatedMillis))"
        )
        .accessibilityLabel(
            "\(task.agent.displayName)，\(task.projectName)，线程 \(task.title)，\(task.displayState.statusDescription)"
        )
    }
}

struct CompactAgentSectionView: View {
    let agent: AgentKind
    let quotaLines: [CompactQuotaLine]
    let quotaTint: Color
    let quotaHelp: String
    let tasks: [ActivityRowModel]
    let now: Date
    let openTask: (String) -> Void

    private var groups: [ActivityProjectGroup] {
        ActivityProjectGroup.grouped(tasks)
    }

    private var usesExpandedQuotaLayout: Bool {
        quotaLines.contains { !$0.label.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: agent.symbolName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(agentTint)
                    .frame(width: 14)

                Text(agent.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Text("\(tasks.count)")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(tasks.isEmpty ? Color.secondary : agentTint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(
                        (tasks.isEmpty ? Color.secondary : agentTint).opacity(0.1),
                        in: Capsule()
                    )

                Spacer(minLength: 4)

                if !usesExpandedQuotaLayout, let quotaLine = quotaLines.first {
                    Text(quotaLine.value)
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(quotaTint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(quotaHelp)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)

            if usesExpandedQuotaLayout {
                VStack(spacing: 2) {
                    ForEach(quotaLines.indices, id: \.self) { index in
                        let line = quotaLines[index]
                        HStack(spacing: 6) {
                            Text(line.label)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 4)
                            Text(line.value)
                                .foregroundStyle(quotaTint)
                        }
                        .font(.system(size: 8.8, weight: .medium))
                        .lineLimit(1)
                    }
                }
                .padding(.leading, 29)
                .padding(.trailing, 9)
                .padding(.bottom, 6)
                .help(quotaHelp)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    "\(agent.displayName)额度，"
                        + quotaLines.map { "\($0.label)\($0.value)" }
                            .joined(separator: "，")
                )
            }

            if groups.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 9))
                    Text("无活动线程")
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 29)
                .frame(height: 26)
            } else {
                VStack(spacing: 5) {
                    ForEach(groups) { group in
                        VStack(spacing: 1) {
                            HStack(spacing: 4) {
                                Image(systemName: "folder.fill")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.tertiary)
                                Text(group.name)
                                    .font(.system(size: 9.3, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 19)

                            ForEach(group.tasks) { task in
                                CompactActivityRowView(task: task, now: now) {
                                    openTask(task.nativeID)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .background(
                            Color.primary.opacity(0.025),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 7)
            }
        }
        .background(Color.primary.opacity(0.018))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }

    private var agentTint: Color {
        switch agent {
        case .codex:
            return .blue
        case .qwen:
            return .purple
        case .kimi:
            return .indigo
        }
    }
}

struct DiscoveredProductSectionView: View {
    let snapshot: AgentProductSnapshot
    let openApplication: () -> Void

    @State private var isHovering = false

    var body: some View {
        let presentation = snapshot.presentation
        VStack(spacing: 0) {
            Button(action: openApplication) {
                HStack(spacing: 6) {
                    productIcon

                    Text(snapshot.descriptor.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(snapshot.activeTaskCount.map(String.init) ?? "—")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            snapshot.activeTaskCount == nil
                                ? Color.secondary : productTint
                        )
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            (
                                snapshot.activeTaskCount == nil
                                    ? Color.secondary : productTint
                            ).opacity(0.1),
                            in: Capsule()
                        )

                    Spacer(minLength: 4)

                    Text(snapshot.quotaSummary ?? "余额 —")
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(quotaHelpText)
                }
                .padding(.horizontal, 8)
                .frame(height: 30)
                .background(
                    isHovering && presentation.canOpenApplication
                        ? Color.primary.opacity(0.055) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!presentation.canOpenApplication)
            .onHover { isHovering = $0 }
            .help(helpText)
            .accessibilityLabel(
                "\(snapshot.descriptor.displayName)，"
                    + "\(presentation.statusText)，"
                    + "\(presentation.supportText)"
            )
            .accessibilityHint(
                presentation.canOpenApplication
                    ? "打开应用" : "当前未安装"
            )

            if snapshot.threads.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: threadPlaceholderSymbol)
                        .font(.system(size: 9))
                    Text(threadPlaceholderText)
                        .font(.system(size: 9.5))
                }
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 29)
                .frame(height: 26)
                .help(dataAvailabilityHelpText)
            } else {
                VStack(spacing: 1) {
                    ForEach(snapshot.threads) { thread in
                        Button(action: openApplication) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(
                                        thread.state == .running
                                            ? productTint : Color.secondary
                                    )
                                    .frame(width: 5, height: 5)

                                Text(thread.title)
                                    .font(.system(size: 10, weight: .regular))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)

                                Spacer(minLength: 3)

                                Text(thread.state.displayText)
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .foregroundStyle(
                                        thread.state == .running
                                            ? productTint : Color.secondary
                                    )
                                    .fixedSize()
                            }
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!presentation.canOpenApplication)
                        .help(
                            "\(snapshot.descriptor.displayName)\n"
                                + "线程：\(thread.title)\n"
                                + "状态：\(thread.state.displayText)\n"
                                + "最近活动："
                                + TimeLabelFormatter.fullLabel(
                                    milliseconds: thread.updatedMillis
                                )
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 7)
            }
        }
        .background(Color.primary.opacity(0.018))
        .overlay(alignment: .bottom) {
            Divider().opacity(0.35)
        }
    }

    @ViewBuilder
    private var productIcon: some View {
        if let brandMarkPath = snapshot.officialBrandMarkPath,
           let brandMark = NSImage(contentsOfFile: brandMarkPath) {
            Image(nsImage: brandMark)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else if let iconPath = snapshot.iconApplicationPath {
            let applicationIcon = NSWorkspace.shared.icon(forFile: iconPath)
            Image(nsImage: applicationIcon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(productTint)
                .frame(width: 16)
                .accessibilityHidden(true)
        }
    }

    private var productTint: Color {
        switch snapshot.descriptor.id {
        case "workbuddy":
            return .teal
        case "trae-work":
            return .cyan
        default:
            return .accentColor
        }
    }

    private var fallbackSymbol: String {
        switch snapshot.descriptor.id {
        case "workbuddy":
            return "sparkles"
        case "trae-work":
            return "triangle.fill"
        default:
            return "app.dashed"
        }
    }

    private var threadPlaceholderSymbol: String {
        snapshot.dataAvailability == .available
            ? "checkmark.circle" : "minus.circle"
    }

    private var threadPlaceholderText: String {
        snapshot.dataAvailability == .available
            ? "无活动线程" : "线程 —"
    }

    private var dataAvailabilityHelpText: String {
        switch snapshot.dataAvailability {
        case .available:
            return "当前没有公开接口返回的活动线程"
        case let .unavailable(message):
            return message
        }
    }

    private var quotaHelpText: String {
        if let quotaSummary = snapshot.quotaSummary {
            return "\(snapshot.descriptor.displayName) 余额：\(quotaSummary)"
        }
        return "\(snapshot.descriptor.displayName) 未开放可独立验证的余额接口"
    }

    private var helpText: String {
        let presentation = snapshot.presentation
        var details = [
            snapshot.descriptor.displayName,
            "状态：\(presentation.statusText)",
            "支持：\(presentation.supportText)",
            presentation.detailText,
            "数据来源：\(snapshot.descriptor.dataSourceDescription)",
            "隐私：\(snapshot.descriptor.privacyDescription)",
        ]
        if let application = snapshot.application {
            details.append(
                "本机应用：\(application.displayName) \(application.version)"
            )
        }
        return details.joined(separator: "\n")
    }
}

struct LocalAIStatusView: View {
    @ObservedObject var codexStore: TaskStore
    @ObservedObject var codexUsageStore: UsageStore
    @ObservedObject var qwenStore: QwenStore
    @ObservedObject var kimiStore: KimiStore
    @ObservedObject var discoveryStore: AgentDiscoveryStore
    @ObservedObject var windowMode: WindowModeModel

    private var codexTasks: [ActivityRowModel] {
        codexStore.groups(matching: "").flatMap { group in
            group.tasks.map { task in
                ActivityRowModel(
                    id: "codex:\(task.id)",
                    nativeID: task.id,
                    agent: .codex,
                    title: task.title,
                    projectName: group.name,
                    projectPath: task.canonicalProjectPath,
                    updatedMillis: task.updatedMillis,
                    displayState: task.displayState
                )
            }
        }
    }

    private var qwenTasks: [ActivityRowModel] {
        qwenStore.tasks.map { task in
            ActivityRowModel(
                id: "qwen:\(task.id)",
                nativeID: task.id,
                agent: .qwen,
                title: task.title,
                projectName: task.projectName,
                projectPath: task.projectPath,
                updatedMillis: task.updatedMillis,
                displayState: task.displayState
            )
        }
    }

    private var kimiTasks: [ActivityRowModel] {
        kimiStore.tasks.map { task in
            ActivityRowModel(
                id: "kimi:\(task.id)",
                nativeID: task.id,
                agent: .kimi,
                title: task.title,
                projectName: task.projectName,
                projectPath: task.projectPath,
                updatedMillis: task.updatedMillis,
                displayState: task.displayState
            )
        }
    }

    private var totalActiveCount: Int {
        codexTasks.count
            + qwenTasks.count
            + kimiTasks.count
            + discoveryStore.snapshots.compactMap(\.activeTaskCount)
                .reduce(0, +)
    }

    var body: some View {
        VStack(spacing: 0) {
            compactHeader

            ScrollView {
                LazyVStack(spacing: 0) {
                    CompactAgentSectionView(
                        agent: .codex,
                        quotaLines: codexQuota.lines,
                        quotaTint: codexQuota.tint,
                        quotaHelp: codexQuota.help,
                        tasks: codexTasks,
                        now: codexStore.now,
                        openTask: openCodexTask
                    )
                    CompactAgentSectionView(
                        agent: .qwen,
                        quotaLines: qwenQuota.lines,
                        quotaTint: qwenQuota.tint,
                        quotaHelp: qwenQuota.help,
                        tasks: qwenTasks,
                        now: codexStore.now,
                        openTask: openQwenTask
                    )
                    CompactAgentSectionView(
                        agent: .kimi,
                        quotaLines: kimiQuota.lines,
                        quotaTint: kimiQuota.tint,
                        quotaHelp: kimiQuota.help,
                        tasks: kimiTasks,
                        now: codexStore.now,
                        openTask: openKimiTask
                    )
                    ForEach(discoveryStore.snapshots) { snapshot in
                        DiscoveredProductSectionView(snapshot: snapshot) {
                            discoveryStore.openApplication(
                                productID: snapshot.id
                            )
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)

            compactFooter
        }
        .frame(
            minWidth: AppLayout.panelWidth,
            idealWidth: AppLayout.panelWidth,
            maxWidth: AppLayout.panelWidth,
            minHeight: AppLayout.minimumPanelHeight,
            idealHeight: AppLayout.idealPanelHeight
        )
        .background(.regularMaterial)
    }

    private var compactHeader: some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 0) {
                    Text("本机AI状态栏")
                        .font(.system(size: 13.5, weight: .semibold))
                    Text("\(totalActiveCount) 个活动线程 · 全局置顶")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 2)

                Button {
                    windowMode.select(
                        windowMode.mode == .pinned ? .docked : .pinned
                    )
                } label: {
                    Image(
                        systemName: windowMode.mode == .pinned
                            ? "rectangle.leadinghalf.inset.filled" : "pin.fill"
                    )
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 23, height: 23)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.055), in: Circle())
                .help(
                    windowMode.mode == .pinned
                        ? "吸附到 Codex 底边" : "切换为自由置顶"
                )

                Button(action: refreshAll) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .frame(width: 23, height: 23)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.055), in: Circle())
                .help("立即刷新全部 Agent 产品")
            }
            .contentShape(Rectangle())
            .gesture(headerDragGesture)

            if windowMode.mode == .docked {
                HStack(spacing: 5) {
                    Text("吸附")
                        .font(.system(size: 8.8, weight: .medium))
                        .foregroundStyle(.tertiary)
                    compactDockButton(side: .left)
                    compactDockButton(side: .right)
                    Spacer()
                    Text("底边对齐")
                        .font(.system(size: 8.8))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 9)
        .padding(.bottom, 7)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.4)
        }
    }

    private var headerDragGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if windowMode.mode == .pinned {
                    windowMode.dragPinnedWindow(
                        translation: value.translation,
                        ended: false
                    )
                }
            }
            .onEnded { value in
                if windowMode.mode == .pinned {
                    windowMode.dragPinnedWindow(
                        translation: value.translation,
                        ended: true
                    )
                } else if abs(value.translation.width) >= 36,
                          abs(value.translation.width) > abs(value.translation.height) {
                    windowMode.selectDockSide(
                        value.translation.width < 0 ? .left : .right
                    )
                }
            }
    }

    private func compactDockButton(side: DockSide) -> some View {
        let selected = windowMode.dockSide == side
        return Button {
            windowMode.selectDockSide(side)
        } label: {
            Text(side.label)
                .font(.system(size: 8.8, weight: .semibold))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 7)
                .frame(height: 19)
                .background(
                    selected
                        ? Color.accentColor.opacity(0.12)
                        : Color.primary.opacity(0.04),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private var compactFooter: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(overallStatusColor)
                .frame(width: 5, height: 5)
            Text(windowMode.statusText)
                .lineLimit(1)
            Spacer(minLength: 3)
            Text("自动刷新")
        }
        .font(.system(size: 8.8))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .overlay(alignment: .top) {
            Divider().opacity(0.4)
        }
    }

    private var overallStatusColor: Color {
        if codexStore.errorMessage != nil
            && qwenStore.errorMessage != nil
            && kimiStore.errorMessage != nil {
            return .orange
        }
        return .green
    }

    private var codexQuota: (
        lines: [CompactQuotaLine],
        tint: Color,
        help: String
    ) {
        quotaSummary(codexUsageStore.state, source: "Codex")
    }

    private var qwenQuota: (
        lines: [CompactQuotaLine],
        tint: Color,
        help: String
    ) {
        switch qwenStore.quotaState {
        case .loading:
            return (
                [CompactQuotaLine(label: "", value: "读取中")],
                .secondary,
                "正在读取 QwenWorkCN 剩余积分"
            )
        case let .available(quota, isStale):
            let value = quota.remainingValueText.map { "余\($0)分" }
                ?? "余\(quota.remainingPercent)%"
            return (
                [
                    CompactQuotaLine(
                        label: "",
                        value: isStale ? "\(value) · 延迟" : value
                    ),
                ],
                isStale ? .orange : quotaColor(quota.remainingPercent),
                isStale
                    ? "当前显示上次成功读取的 QwenWorkCN 剩余积分"
                    : "QwenWorkCN 剩余积分 \(value)"
            )
        case let .unavailable(message):
            return (
                [CompactQuotaLine(label: "", value: "额度不可用")],
                .orange,
                message
            )
        }
    }

    private var kimiQuota: (
        lines: [CompactQuotaLine],
        tint: Color,
        help: String
    ) {
        quotaSummary(
            kimiStore.quotaState,
            source: "Kimi",
            expanded: true,
            emphasizesLowBalance: false
        )
    }

    private func quotaSummary(
        _ state: UsageState,
        source: String,
        expanded: Bool = false,
        emphasizesLowBalance: Bool = true
    ) -> (lines: [CompactQuotaLine], tint: Color, help: String) {
        switch state {
        case .loading:
            return (
                [CompactQuotaLine(label: "", value: "读取中")],
                .secondary,
                "正在读取 \(source) 剩余额度"
            )
        case let .available(windows, isStale):
            let summary = windows.map {
                "\($0.label) \($0.remainingPercent)%"
            }.joined(separator: "，")
            let minimum = windows.map(\.remainingPercent).min() ?? 100
            let tintRole = QuotaTintPolicy.role(
                remainingPercent: minimum,
                isStale: isStale,
                emphasizesLowBalance: emphasizesLowBalance
            )
            return (
                expanded
                    ? CompactQuotaLineFormatter.expanded(
                        windows: windows,
                        isStale: isStale
                    )
                    : CompactQuotaLineFormatter.inline(
                        windows: windows,
                        isStale: isStale
                    ),
                quotaColor(for: tintRole),
                isStale
                    ? "当前显示上次成功读取的 \(source) 剩余额度"
                    : "\(source) 剩余额度：\(summary)"
            )
        case let .unavailable(message):
            return (
                [CompactQuotaLine(label: "", value: "额度不可用")],
                .orange,
                message
            )
        }
    }

    private func quotaColor(_ remainingPercent: Int) -> Color {
        quotaColor(
            for: QuotaTintPolicy.role(
                remainingPercent: remainingPercent,
                isStale: false,
                emphasizesLowBalance: true
            )
        )
    }

    private func quotaColor(for role: QuotaTintRole) -> Color {
        switch role {
        case .neutral:
            return .secondary
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }

    private func refreshAll() {
        codexStore.refresh()
        codexUsageStore.refresh()
        qwenStore.refresh()
        kimiStore.refresh()
        discoveryStore.refresh()
    }

    private func openCodexTask(_ id: String) {
        guard let task = codexStore.tasks.first(where: { $0.id == id }) else {
            return
        }
        codexStore.open(task)
    }

    private func openQwenTask(_ id: String) {
        guard let task = qwenStore.tasks.first(where: { $0.id == id }) else {
            return
        }
        qwenStore.open(task)
    }

    private func openKimiTask(_ id: String) {
        guard let task = kimiStore.tasks.first(where: { $0.id == id }) else {
            return
        }
        kimiStore.open(task)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let store = TaskStore()
    private let usageStore = UsageStore()
    private let qwenStore = QwenStore()
    private let kimiStore = KimiStore()
    private let discoveryStore = AgentDiscoveryStore()
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
        applyWindowMode(windowMode.mode)
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
        discoveryStore.stop()
    }

    private func createPanel() {
        let panel = NSPanel(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: AppLayout.panelWidth,
                height: AppLayout.idealPanelHeight
            ),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = "本机AI状态栏"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(
            width: AppLayout.panelWidth,
            height: AppLayout.minimumPanelHeight
        )
        panel.maxSize = NSSize(width: AppLayout.panelWidth, height: 1200)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.setFrameAutosaveName("LocalAIStatusBarPanelFrame")
        panel.contentView = NSHostingView(
            rootView: LocalAIStatusView(
                codexStore: store,
                codexUsageStore: usageStore,
                qwenStore: qwenStore,
                kimiStore: kimiStore,
                discoveryStore: discoveryStore,
                windowMode: windowMode
            )
        )

        if !panel.setFrameUsingName("LocalAIStatusBarPanelFrame"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: visible.minX + 12, y: visible.maxY - 12))
        } else if panel.frame.width != AppLayout.panelWidth {
            var frame = panel.frame
            frame.size.width = AppLayout.panelWidth
            panel.setFrame(frame, display: false)
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
            panel.isFloatingPanel = true
            panel.level = .statusBar
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
            updateWindowStatus("自由置顶 · 本机 Agent")
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
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.orderFrontRegardless()
            updateWindowStatus("等待 Codex · 仍全局置顶")
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
            panel.saveFrame(usingName: "LocalAIStatusBarPanelFrame")
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
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.orderFrontRegardless()

        let foregroundState: String
        if frontmostBundleID == "com.openai.codex" {
            foregroundState = "Codex 前台"
        } else if frontmostBundleID == ownBundleID {
            foregroundState = "正在操作"
        } else {
            foregroundState = "其他程序前台"
        }
        recordWindowLayerState("always-on-top", frontmostBundleID: frontmostBundleID)
        updateWindowStatus("吸附\(windowMode.dockSide.label) · \(foregroundState)")
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
            button.image = NSImage(
                systemSymbolName: "waveform.path.ecg.rectangle",
                accessibilityDescription: "本机AI状态栏"
            )
            button.toolTip = "本机AI状态栏"
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "显示状态栏", action: #selector(showPanel), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "刷新全部产品", action: #selector(refreshTasks), keyEquivalent: "r"))
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
        qwenStore.refresh()
        kimiStore.refresh()
        discoveryStore.refresh()
        if windowMode.mode == .docked {
            dockToCodexWindow()
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshTasks() {
        store.refresh()
        usageStore.refresh()
        qwenStore.refresh()
        kimiStore.refresh()
        discoveryStore.refresh()
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
            let panelSize = NSSize(width: 240, height: 680)
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
                    "primary": ["usedPercent": 35, "windowDurationMins": 300],
                    "secondary": ["usedPercent": 90, "windowDurationMins": 10_080],
                ],
            ]
            let usageWindows = try UsageSnapshotParser.windows(from: usageFixture)
            guard usageWindows == [
                UsageWindowDisplay(label: "5 小时", remainingPercent: 65),
                UsageWindowDisplay(label: "每周", remainingPercent: 10),
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

            guard ActivityTaskPolicy.includes(.running),
                  ActivityTaskPolicy.includes(.needsAction),
                  ActivityTaskPolicy.includes(.needsReview),
                  !ActivityTaskPolicy.includes(.idle) else {
                fputs("SELF_TEST_FAILED active task policy\n", stderr)
                return 23
            }

            let qwenQuota = try QwenUsageSnapshotParser.quota(from: [
                "json": [
                    "userQuota": [
                        "total": 1_000.0,
                        "used": 275.5,
                        "remaining": 724.5,
                        "percentage": 27.55,
                        "unit": "credits",
                    ],
                ],
            ])
            guard qwenQuota == AgentQuotaDisplay(
                label: "积分",
                remainingPercent: 72,
                remainingValueText: "724.5"
            ) else {
                fputs("SELF_TEST_FAILED Qwen quota parsing\n", stderr)
                return 24
            }

            let kimiUsageFixture = """
            \u{001B}[1mPlan usage\u{001B}[0m
              Weekly limit  [##################--]  90% used
              5h limit      [########------------]  40% used
            """
            guard KimiUsageTextParser.windows(from: kimiUsageFixture) == [
                UsageWindowDisplay(label: "每周", remainingPercent: 10),
                UsageWindowDisplay(label: "5 小时", remainingPercent: 60),
            ] else {
                fputs("SELF_TEST_FAILED Kimi usage parsing\n", stderr)
                return 25
            }
            guard CompactQuotaLineFormatter.expanded(
                windows: [
                    UsageWindowDisplay(label: "总量", remainingPercent: 22),
                    UsageWindowDisplay(label: "5 小时", remainingPercent: 60),
                    UsageWindowDisplay(label: "每周", remainingPercent: 10),
                ],
                isStale: false
            ) == [
                CompactQuotaLine(label: "总量", value: "余 22%"),
                CompactQuotaLine(label: "Code 5h", value: "余 60%"),
                CompactQuotaLine(label: "Code 7天", value: "余 10%"),
            ] else {
                fputs("SELF_TEST_FAILED Kimi quota line layout\n", stderr)
                return 34
            }
            guard QuotaTintPolicy.role(
                remainingPercent: 0,
                isStale: false,
                emphasizesLowBalance: false
            ) == .neutral,
            QuotaTintPolicy.role(
                remainingPercent: 0,
                isStale: true,
                emphasizesLowBalance: false
            ) == .warning,
            QuotaTintPolicy.role(
                remainingPercent: 10,
                isStale: false,
                emphasizesLowBalance: true
            ) == .critical else {
                fputs("SELF_TEST_FAILED Kimi quota tint policy\n", stderr)
                return 35
            }

            let sanitizedEnvironment = KimiProcessEnvironment.sanitized([
                "HOME": "/tmp/synthetic-home",
                "PATH": "/usr/bin:/bin",
                "__CF_USER_TEXT_ENCODING": "synthetic",
                "CODEX_THREAD_ID": "synthetic-thread",
                "OPENAI_API_KEY": "synthetic-key",
                "SERVICE_TOKEN": "synthetic-token",
                "DATABASE_URL": "synthetic-database",
                "SSH_AUTH_SOCK": "/tmp/synthetic-auth",
            ])
            guard sanitizedEnvironment["HOME"] == "/tmp/synthetic-home",
                  sanitizedEnvironment["PATH"] == "/usr/bin:/bin",
                  sanitizedEnvironment["__CF_USER_TEXT_ENCODING"] == "synthetic",
                  sanitizedEnvironment["CODEX_THREAD_ID"] == nil,
                  sanitizedEnvironment["OPENAI_API_KEY"] == nil,
                  sanitizedEnvironment["SERVICE_TOKEN"] == nil,
                  sanitizedEnvironment["DATABASE_URL"] == nil,
                  sanitizedEnvironment["SSH_AUTH_SOCK"] == nil else {
                fputs("SELF_TEST_FAILED Kimi process environment filtering\n", stderr)
                return 33
            }

            let qwenRunning = QwenTaskStatusParser.runtimeState(
                taskStatus: "running",
                streamID: nil
            )
            let qwenWaiting = QwenTaskStatusParser.runtimeState(
                taskStatus: "waiting_for_user",
                streamID: nil
            )
            let qwenCompleted = QwenTaskStatusParser.runtimeState(
                taskStatus: "completed",
                streamID: nil
            )
            guard qwenRunning == .running,
                  qwenWaiting == .needsAction,
                  qwenCompleted == .idle else {
                fputs("SELF_TEST_FAILED Qwen task state parsing\n", stderr)
                return 26
            }

            let kimiRunningFixture = Data("""
            {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"step-1"}}
            """.utf8)
            let kimiCompletedFixture = Data("""
            {"type":"context.append_loop_event","event":{"type":"step.begin","uuid":"step-1"}}
            {"type":"context.append_loop_event","event":{"type":"step.end","uuid":"step-1"}}
            """.utf8)
            guard KimiWireStateParser.runtimeState(from: kimiRunningFixture) == .running,
                  KimiWireStateParser.runtimeState(from: kimiCompletedFixture) == .idle else {
                fputs("SELF_TEST_FAILED Kimi task state parsing\n", stderr)
                return 27
            }

            let qwenTasks = try QwenTaskRepository.loadActiveTasks().tasks
            guard qwenTasks.count == 2,
                  qwenTasks.contains(where: {
                      $0.id == "qwen-sub-running"
                          && $0.title == "千问运行线程"
                          && $0.projectName == "千问中文项目"
                          && $0.displayState == .running
                  }),
                  qwenTasks.contains(where: {
                      $0.id == "qwen-sub-review"
                          && $0.title == "千问待查看线程"
                          && $0.projectName == "千问中文项目"
                          && $0.displayState == .needsReview
                  }),
                  !qwenTasks.contains(where: { $0.id == "qwen-sub-idle" }) else {
                fputs("SELF_TEST_FAILED Qwen active task repository\n", stderr)
                return 30
            }

            let kimiTasks = try KimiTaskRepository.loadActiveTasks().tasks
            guard kimiTasks.count == 4,
                  kimiTasks.contains(where: {
                      $0.id == "kimi-running"
                          && $0.title == "Kimi 中文运行线程"
                          && $0.projectName == "Kimi中文项目"
                          && $0.displayState == .running
                  }),
                  kimiTasks.contains(where: {
                      $0.id == "kimi-work:synthetic-work-running"
                          && $0.title == "Kimi Work 中文运行线程"
                          && $0.projectName == "Kimi Work"
                          && $0.displayState == .running
                  }),
                  kimiTasks.contains(where: {
                      $0.id == "kimi-work:synthetic-work-blocked"
                          && $0.title == "Kimi Work 中文待处理线程"
                          && $0.projectName == "Kimi Work"
                          && $0.displayState == .needsAction
                  }),
                  kimiTasks.contains(where: {
                      $0.id
                          == "kimi-work:synthetic-work-completed-unread"
                          && $0.title == "Kimi Work 待查看"
                          && $0.projectName == "Kimi Work"
                          && $0.displayState == .needsReview
                  }),
                  !kimiTasks.contains(where: {
                      $0.id == "kimi-work:synthetic-work-completed-read"
                  }) else {
                fputs("SELF_TEST_FAILED Kimi active task repository\n", stderr)
                return 31
            }

            let projectMetadataFixture = Data("""
            This directory is a local mirror of the ChatGPT project “中文项目名称”.
            """.utf8)
            guard CodexProjectNameResolver.projectName(
                fromAgentInstructions: projectMetadataFixture
            ) == "中文项目名称" else {
                fputs("SELF_TEST_FAILED Codex Chinese project name\n", stderr)
                return 32
            }

            guard AppLayout.panelWidth == 240,
                  AppLayout.defaultWindowMode == .pinned,
                  AppLayout.alwaysOnTop else {
                fputs("SELF_TEST_FAILED compact always-on-top layout\n", stderr)
                return 28
            }

            guard leftOrigin.y == codexFrame.minY,
                  rightOrigin.y == codexFrame.minY else {
                fputs("SELF_TEST_FAILED bottom-aligned docking\n", stderr)
                return 29
            }

            let unreadUpdateCount = tasks.filter(\.hasUnreadUpdate).count
            print("SELF_TEST_OK count=\(tasks.count)\(titleOverrideStatus)\(unreadOverrideStatus)\(readOverrideStatus)\(runtimeOverrideStatus)\(actionOverrideStatus)\(incrementalRuntimeStatus) usage=ok unread_state=ok runtime_state=ok display_state=ok active_policy=ok qwen_usage=ok kimi_usage=ok kimi_quota_lines=ok kimi_quota_tint=ok kimi_environment=ok qwen_state=ok kimi_state=ok qwen_repository=ok kimi_repository=ok kimi_work_repository=ok compact_layout=ok bottom_dock=ok unread_update_count=\(unreadUpdateCount)")
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
                    UsageWindowDisplay(label: "5 小时", remainingPercent: 65),
                    UsageWindowDisplay(label: "每周", remainingPercent: 10),
                  ] else {
                fputs("USAGE_SELF_TEST_FAILED unexpected values\n", stderr)
                return 11
            }
            print(expectFixtureValues ? "USAGE_SELF_TEST_OK windows=2" : "USAGE_PROBE_OK windows=\(windows.count)")
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
                return windows.count == 2 && !isStale
            }
            return false
        }) else {
            fputs("USAGE_RESILIENCE_SELF_TEST_FAILED initial success\n", stderr)
            return 20
        }

        store.refresh()
        guard waitUntil(timeout: 5, condition: {
            if case let .available(windows, isStale) = store.state {
                return windows.count == 2 && isStale
            }
            return false
        }) else {
            fputs("USAGE_RESILIENCE_SELF_TEST_FAILED stale fallback\n", stderr)
            return 21
        }

        guard waitUntil(timeout: 5, condition: {
            if case let .available(windows, isStale) = store.state {
                return windows.count == 2 && !isStale
            }
            return false
        }) else {
            fputs("USAGE_RESILIENCE_SELF_TEST_FAILED automatic retry\n", stderr)
            return 22
        }

        print("USAGE_RESILIENCE_SELF_TEST_OK stale=ok retry=ok")
        return 0
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

enum QwenBridgeSelfTest {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<QwenDesktopSnapshot, Error>?

        func store(_ newValue: Result<QwenDesktopSnapshot, Error>) {
            lock.lock()
            result = newValue
            lock.unlock()
        }

        func load() -> Result<QwenDesktopSnapshot, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    static func run(expectFixtureValues: Bool = true) -> Int32 {
        let resultBox = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                resultBox.store(.success(try await QwenDesktopBridge.fetchSnapshot()))
            } catch {
                resultBox.store(.failure(error))
            }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 12) == .success else {
            fputs("QWEN_BRIDGE_SELF_TEST_FAILED timeout\n", stderr)
            return 40
        }
        switch resultBox.load() {
        case let .success(snapshot):
            if expectFixtureValues {
                guard snapshot.quota == AgentQuotaDisplay(
                    label: "积分",
                    remainingPercent: 72,
                    remainingValueText: "724.5"
                ),
                snapshot.unreadChatIDs == Set(["qwen-chat-review"]),
                snapshot.unreadSubChatIDs == Set(["qwen-sub-review"]) else {
                    fputs("QWEN_BRIDGE_SELF_TEST_FAILED unexpected values\n", stderr)
                    return 41
                }
                print(
                    "QWEN_BRIDGE_SELF_TEST_OK unread_chat=1 unread_subchat=1 quota=ok"
                )
            } else {
                print(
                    "QWEN_BRIDGE_PROBE_OK unread_chat=\(snapshot.unreadChatIDs.count) unread_subchat=\(snapshot.unreadSubChatIDs.count) quota=ok"
                )
            }
            return 0
        case let .failure(error):
            fputs(
                "QWEN_BRIDGE_SELF_TEST_FAILED \(error.localizedDescription)\n",
                stderr
            )
            return 42
        case nil:
            fputs("QWEN_BRIDGE_SELF_TEST_FAILED no result\n", stderr)
            return 43
        }
    }
}

enum KimiUsageSelfTest {
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
        let client = KimiUsageClient()
        let resultBox = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        client.refresh { result in
            resultBox.store(result)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 22) == .success else {
            fputs("KIMI_USAGE_SELF_TEST_FAILED timeout\n", stderr)
            return 50
        }
        switch resultBox.load() {
        case let .success(windows):
            if expectFixtureValues {
                guard windows == [
                    UsageWindowDisplay(label: "总量", remainingPercent: 22),
                    UsageWindowDisplay(label: "5 小时", remainingPercent: 60),
                    UsageWindowDisplay(label: "每周", remainingPercent: 10),
                ] else {
                    fputs("KIMI_USAGE_SELF_TEST_FAILED unexpected values\n", stderr)
                    return 51
                }
                print("KIMI_USAGE_SELF_TEST_OK windows=3")
            } else {
                print("KIMI_USAGE_PROBE_OK windows=\(windows.count)")
            }
            return 0
        case let .failure(error):
            fputs(
                "KIMI_USAGE_SELF_TEST_FAILED \(error.localizedDescription)\n",
                stderr
            )
            return 52
        case nil:
            fputs("KIMI_USAGE_SELF_TEST_FAILED no result\n", stderr)
            return 53
        }
    }
}

enum LiveActivityProbe {
    private final class QwenResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Int, Error>?

        func store(_ newValue: Result<Int, Error>) {
            lock.lock()
            result = newValue
            lock.unlock()
        }

        func load() -> Result<Int, Error>? {
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    static func run() -> Int32 {
        do {
            let codexCount = try TaskRepository.loadTasks().tasks.filter {
                ActivityTaskPolicy.includes($0.displayState)
            }.count
            let kimiCount = try KimiTaskRepository.loadActiveTasks().tasks.count

            let qwenBox = QwenResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let snapshot = try await QwenDesktopBridge.fetchSnapshot()
                    let count = try QwenTaskRepository.loadActiveTasks(
                        unreadChatIDs: snapshot.unreadChatIDs,
                        unreadSubChatIDs: snapshot.unreadSubChatIDs
                    ).tasks.count
                    qwenBox.store(.success(count))
                } catch {
                    qwenBox.store(.failure(error))
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 12) == .success,
                  case let .success(qwenCount) = qwenBox.load() else {
                fputs("ACTIVITY_PROBE_FAILED source=qwen\n", stderr)
                return 61
            }
            print(
                "ACTIVITY_PROBE_OK codex=\(codexCount) qwen=\(qwenCount) kimi=\(kimiCount)"
            )
            return 0
        } catch {
            fputs("ACTIVITY_PROBE_FAILED source=local\n", stderr)
            return 60
        }
    }
}

enum LiveNavigationProbe {
    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var succeeded: Bool?

        func store(_ newValue: Bool) {
            lock.lock()
            succeeded = newValue
            lock.unlock()
        }

        func load() -> Bool? {
            lock.lock()
            defer { lock.unlock() }
            return succeeded
        }
    }

    static func run(agent: String) -> Int32 {
        switch agent {
        case AgentKind.codex.rawValue:
            do {
                guard let task = try TaskRepository.loadTasks().tasks.first(
                    where: { ActivityTaskPolicy.includes($0.displayState) }
                ) else {
                    print("NAVIGATION_PROBE_SKIPPED agent=codex reason=no_active")
                    return 0
                }
                guard let deepLink = task.deepLink,
                      NSWorkspace.shared.open(deepLink) else {
                    fputs("NAVIGATION_PROBE_FAILED agent=codex\n", stderr)
                    return 70
                }
                print("NAVIGATION_PROBE_OK agent=codex exact=true")
                return 0
            } catch {
                fputs("NAVIGATION_PROBE_FAILED agent=codex\n", stderr)
                return 71
            }
        case AgentKind.qwen.rawValue:
            let resultBox = ResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                do {
                    let snapshot = try await QwenDesktopBridge.fetchSnapshot()
                    guard let task = try QwenTaskRepository.loadActiveTasks(
                        unreadChatIDs: snapshot.unreadChatIDs,
                        unreadSubChatIDs: snapshot.unreadSubChatIDs
                    ).tasks.first else {
                        resultBox.store(false)
                        semaphore.signal()
                        return
                    }
                    try await QwenDesktopBridge.openChat(task.navigationID)
                    resultBox.store(true)
                } catch {
                    resultBox.store(false)
                }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 12) == .success else {
                fputs("NAVIGATION_PROBE_FAILED agent=qwen\n", stderr)
                return 72
            }
            guard resultBox.load() == true else {
                print("NAVIGATION_PROBE_SKIPPED agent=qwen reason=no_active_or_bridge")
                return 0
            }
            print("NAVIGATION_PROBE_OK agent=qwen exact=true")
            return 0
        default:
            fputs("NAVIGATION_PROBE_FAILED agent=unsupported\n", stderr)
            return 73
        }
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
        if CommandLine.arguments.contains("--qwen-bridge-self-test") {
            Darwin.exit(QwenBridgeSelfTest.run())
        }
        if CommandLine.arguments.contains("--qwen-bridge-probe") {
            Darwin.exit(QwenBridgeSelfTest.run(expectFixtureValues: false))
        }
        if CommandLine.arguments.contains("--kimi-usage-self-test") {
            Darwin.exit(KimiUsageSelfTest.run())
        }
        if CommandLine.arguments.contains("--kimi-usage-probe") {
            Darwin.exit(KimiUsageSelfTest.run(expectFixtureValues: false))
        }
        if CommandLine.arguments.contains("--activity-probe") {
            Darwin.exit(LiveActivityProbe.run())
        }
        if let navigationIndex = CommandLine.arguments.firstIndex(
            of: "--navigation-probe"
        ),
        CommandLine.arguments.indices.contains(navigationIndex + 1) {
            Darwin.exit(
                LiveNavigationProbe.run(
                    agent: CommandLine.arguments[navigationIndex + 1]
                )
            )
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
