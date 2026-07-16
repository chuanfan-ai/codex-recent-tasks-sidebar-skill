import AppKit
import Darwin
import Foundation
import SwiftUI

struct CodexTask: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let cwd: String
    let gitBranch: String
    let updatedMillis: Int64

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case cwd
        case gitBranch = "git_branch"
        case updatedMillis = "updated_ms"
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
      CAST(COALESCE(NULLIF(updated_at_ms, 0), updated_at * 1000) AS INTEGER) AS updated_ms
    FROM threads
    WHERE archived = 0
      AND COALESCE(thread_source, '') <> 'subagent'
      AND COALESCE(source, '') NOT LIKE '{"subagent"%'
      AND (agent_path IS NULL OR agent_path = '')
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
            let tasks = data.isEmpty ? [] : try JSONDecoder().decode([CodexTask].self, from: data)
            return (databaseURL, tasks)
        } catch {
            throw TaskRepositoryError.invalidData(error.localizedDescription)
        }
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

    init() {
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    func refresh() {
        now = Date()
        do {
            let result = try TaskRepository.loadTasks()
            tasks = result.tasks
            databasePath = result.databaseURL.path
            errorMessage = nil
            lastRefresh = Date()
        } catch {
            errorMessage = error.localizedDescription
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
    }
}

struct RecentTaskRowView: View {
    let projectName: String
    let task: CodexTask
    let now: Date
    let openTask: () -> Void

    @State private var isHovering = false

    var body: some View {
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

                Text(TimeLabelFormatter.shortLabel(milliseconds: task.updatedMillis, now: now))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.11), in: Capsule())
                    .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(projectName)\n任务：\(task.title)\n最近活动：\(TimeLabelFormatter.fullLabel(milliseconds: task.updatedMillis))\nThread ID：\(task.id)")
        .accessibilityLabel("\(projectName)，任务 \(task.title)，最近活动 \(TimeLabelFormatter.shortLabel(milliseconds: task.updatedMillis, now: now))")
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

                Button(action: store.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.06), in: Circle())
                .help("立即刷新")
                .accessibilityLabel("立即刷新任务")
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
            Text("近 48 小时 · 30 秒刷新")
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
        panel.contentView = NSHostingView(rootView: TaskListView(store: store, windowMode: windowMode))

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
        menu.addItem(NSMenuItem(title: "刷新任务", action: #selector(refreshTasks), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item
    }

    @objc private func showPanel() {
        guard let panel else { return }
        store.refresh()
        if windowMode.mode == .docked {
            dockToCodexWindow()
        }
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshTasks() {
        store.refresh()
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

            print("SELF_TEST_OK count=\(tasks.count) database=\(result.databaseURL.path)")
            return 0
        } catch {
            fputs("SELF_TEST_FAILED \(error.localizedDescription)\n", stderr)
            return 1
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

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
