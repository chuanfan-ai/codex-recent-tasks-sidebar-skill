import AppKit
import CryptoKit
import Darwin
import Foundation

enum AgentSupportLevel: String, Equatable, Sendable {
    case full
    case partial
    case discovered

    var displayName: String {
        switch self {
        case .full:
            return "完整支持"
        case .partial:
            return "部分支持"
        case .discovered:
            return "已发现 · 待适配"
        }
    }
}

struct AgentProductCapabilities: Equatable, Sendable {
    let monitorsTasks: Bool
    let monitorsQuota: Bool
    let opensExactTask: Bool
    let opensApplication: Bool

    static let discoveryOnly = AgentProductCapabilities(
        monitorsTasks: false,
        monitorsQuota: false,
        opensExactTask: false,
        opensApplication: true
    )

    static let publicSessionSummary = AgentProductCapabilities(
        monitorsTasks: true,
        monitorsQuota: false,
        opensExactTask: false,
        opensApplication: true
    )
}

struct AgentProductDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let applicationPaths: [String]
    let bundleIdentifiers: [String]
    let brandMarkRelativePaths: [String]
    let supportLevel: AgentSupportLevel
    let capabilities: AgentProductCapabilities
    let dataSourceDescription: String
    let privacyDescription: String
}

struct InstalledApplicationMetadata: Equatable, Sendable {
    let path: String
    let bundleIdentifier: String
    let displayName: String
    let version: String
}

enum AgentProductHealth: Equatable, Sendable {
    case notInstalled
    case detected
    case running
    case inspectionFailed
}

enum AgentProductThreadState: Equatable, Sendable {
    case running
    case recent

    var displayText: String {
        switch self {
        case .running:
            return "运行中"
        case .recent:
            return "最近"
        }
    }
}

struct AgentProductThread: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let updatedMillis: Int64
    let state: AgentProductThreadState
}

enum AgentProductDataAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

struct AgentProductDataSnapshot: Equatable, Sendable {
    let threads: [AgentProductThread]
    let quotaSummary: String?
    let availability: AgentProductDataAvailability
}

struct AgentProductPresentation: Equatable, Sendable {
    let statusText: String
    let supportText: String
    let detailText: String
    let canOpenApplication: Bool
}

struct AgentProductSnapshot: Identifiable, Equatable, Sendable {
    let descriptor: AgentProductDescriptor
    let application: InstalledApplicationMetadata?
    let health: AgentProductHealth
    let threads: [AgentProductThread]
    let quotaSummary: String?
    let dataAvailability: AgentProductDataAvailability
    let diagnostic: String?

    var id: String { descriptor.id }
    var isInstalled: Bool { application != nil }
    var isRunning: Bool { health == .running }
    var iconApplicationPath: String? { application?.path }
    var officialBrandMarkPath: String? {
        guard let application else { return nil }
        let applicationURL = URL(fileURLWithPath: application.path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let applicationPrefix = applicationURL.path + "/"
        for relativePath in descriptor.brandMarkRelativePaths {
            guard !relativePath.hasPrefix("/") else { continue }
            let candidateURL = applicationURL
                .appendingPathComponent(relativePath)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            guard candidateURL.path.hasPrefix(applicationPrefix) else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: candidateURL.path,
                isDirectory: &isDirectory
            ),
            !isDirectory.boolValue,
            ["svg", "png"].contains(
                candidateURL.pathExtension.lowercased()
            ),
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: candidateURL.path
            ),
            let fileSize = attributes[.size] as? NSNumber,
            (1...(256 * 1_024)).contains(fileSize.intValue) else {
                continue
            }
            return candidateURL.path
        }
        return nil
    }

    var activeTaskCount: Int? {
        guard dataAvailability == .available else { return nil }
        return threads.lazy.filter { $0.state == .running }.count
    }

    var presentation: AgentProductPresentation {
        let statusText: String
        let detailText: String
        switch health {
        case .notInstalled:
            statusText = "未安装"
            detailText = "未在已验证路径发现"
        case .detected:
            statusText = "已安装"
            detailText = "应用未运行；线程与余额未读取"
        case .running:
            statusText = "运行中"
            switch dataAvailability {
            case .available:
                detailText = "已读取 \(threads.count) 个公开会话摘要；余额接口未开放"
            case let .unavailable(message):
                detailText = message
            }
        case .inspectionFailed:
            statusText = "检查失败"
            detailText = diagnostic ?? "应用元数据检查失败"
        }
        return AgentProductPresentation(
            statusText: statusText,
            supportText: descriptor.supportLevel.displayName,
            detailText: detailText,
            canOpenApplication: isInstalled
                && descriptor.capabilities.opensApplication
                && health != .inspectionFailed
        )
    }

    static func inspectionFailed(
        descriptor: AgentProductDescriptor
    ) -> AgentProductSnapshot {
        AgentProductSnapshot(
            descriptor: descriptor,
            application: nil,
            health: .inspectionFailed,
            threads: [],
            quotaSummary: nil,
            dataAvailability: .unavailable("应用元数据检查失败"),
            diagnostic: "应用元数据检查失败"
        )
    }
}

enum AgentAdapterError: LocalizedError {
    case inspectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .inspectionFailed:
            return "应用元数据检查失败"
        }
    }
}

protocol ApplicationCatalog: Sendable {
    func application(atCandidatePath path: String) -> InstalledApplicationMetadata?
    func isRunning(bundleIdentifier: String) -> Bool
}

struct LocalApplicationCatalog: ApplicationCatalog {
    func application(atCandidatePath path: String) -> InstalledApplicationMetadata? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ),
        isDirectory.boolValue,
        let bundle = Bundle(url: url),
        let bundleIdentifier = bundle.bundleIdentifier,
        !bundleIdentifier.isEmpty else {
            return nil
        }

        let displayName = (
            bundle.object(
                forInfoDictionaryKey: "CFBundleDisplayName"
            ) as? String
        ) ?? (
            bundle.object(
                forInfoDictionaryKey: "CFBundleName"
            ) as? String
        ) ?? url.deletingPathExtension().lastPathComponent
        let version = (
            bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String
        ) ?? ""

        return InstalledApplicationMetadata(
            path: url.path,
            bundleIdentifier: bundleIdentifier,
            displayName: displayName,
            version: version
        )
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).isEmpty
    }
}

protocol AgentProductDataSource: Sendable {
    func load(
        for application: InstalledApplicationMetadata
    ) async throws -> AgentProductDataSnapshot
}

struct UnavailableAgentProductDataSource: AgentProductDataSource {
    let message: String

    func load(
        for application: InstalledApplicationMetadata
    ) async throws -> AgentProductDataSnapshot {
        AgentProductDataSnapshot(
            threads: [],
            quotaSummary: nil,
            availability: .unavailable(message)
        )
    }
}

struct FixedAgentProductDataSource: AgentProductDataSource {
    let snapshot: AgentProductDataSnapshot

    func load(
        for application: InstalledApplicationMetadata
    ) async throws -> AgentProductDataSnapshot {
        snapshot
    }
}

protocol LocalAgentAdapter: Sendable {
    var descriptor: AgentProductDescriptor { get }
    func inspect(
        using catalog: any ApplicationCatalog
    ) async throws -> AgentProductSnapshot
}

struct WorkBuddyAdapter: LocalAgentAdapter {
    let descriptor = AgentProductDescriptor(
        id: "workbuddy",
        displayName: "WorkBuddy",
        applicationPaths: ["/Applications/WorkBuddy.app"],
        bundleIdentifiers: ["com.workbuddy.workbuddy"],
        brandMarkRelativePaths: [
            "Contents/Resources/app.asar.unpacked/cli/dist/web-ui/logo.svg",
        ],
        supportLevel: .partial,
        capabilities: .publicSessionSummary,
        dataSourceDescription: "应用元数据 + CodeBuddy 公开 REST 会话摘要",
        privacyDescription: "不读取日志、数据库、账号、凭证或会话正文"
    )

    private let dataSource: any AgentProductDataSource

    init(
        dataSource: any AgentProductDataSource =
            WorkBuddyPublicSessionDataSource()
    ) {
        self.dataSource = dataSource
    }

    func inspect(
        using catalog: any ApplicationCatalog
    ) async throws -> AgentProductSnapshot {
        await inspectProduct(
            descriptor,
            using: catalog,
            dataSource: dataSource
        )
    }
}

struct TraeWorkAdapter: LocalAgentAdapter {
    let descriptor = AgentProductDescriptor(
        id: "trae-work",
        displayName: "TRAE Work",
        applicationPaths: ["/Applications/TRAE SOLO.app"],
        bundleIdentifiers: ["com.trae.solo.app"],
        brandMarkRelativePaths: [
            "Contents/Resources/app/out/media/trae-logo.svg",
        ],
        supportLevel: .discovered,
        capabilities: .discoveryOnly,
        dataSourceDescription: "应用包标识、版本与运行状态",
        privacyDescription: "不读取任务、日志、数据库、账号或会话内容"
    )

    private let dataSource: any AgentProductDataSource

    init(
        dataSource: any AgentProductDataSource =
            UnavailableAgentProductDataSource(
                message: "上游未开放可独立验证的线程与余额接口"
            )
    ) {
        self.dataSource = dataSource
    }

    func inspect(
        using catalog: any ApplicationCatalog
    ) async throws -> AgentProductSnapshot {
        await inspectProduct(
            descriptor,
            using: catalog,
            dataSource: dataSource
        )
    }
}

struct AgentAdapterRegistry: Sendable {
    let adapters: [any LocalAgentAdapter]

    static let firstBatch = AgentAdapterRegistry(
        adapters: [WorkBuddyAdapter(), TraeWorkAdapter()]
    )

    static let syntheticQA = AgentAdapterRegistry(
        adapters: [
            WorkBuddyAdapter(
                dataSource: FixedAgentProductDataSource(
                    snapshot: AgentProductDataSnapshot(
                        threads: [
                            AgentProductThread(
                                id: "synthetic-workbuddy-running",
                                title: "WorkBuddy 合成运行线程",
                                updatedMillis: 4_102_444_800_000,
                                state: .running
                            ),
                            AgentProductThread(
                                id: "synthetic-workbuddy-recent",
                                title: "WorkBuddy 合成最近线程",
                                updatedMillis: 4_102_444_700_000,
                                state: .recent
                            ),
                        ],
                        quotaSummary: "余 72%",
                        availability: .available
                    )
                )
            ),
            TraeWorkAdapter(
                dataSource: FixedAgentProductDataSource(
                    snapshot: AgentProductDataSnapshot(
                        threads: [
                            AgentProductThread(
                                id: "synthetic-trae-running",
                                title: "TRAE Work 合成运行线程",
                                updatedMillis: 4_102_444_800_000,
                                state: .running
                            ),
                        ],
                        quotaSummary: "余 64%",
                        availability: .available
                    )
                )
            ),
        ]
    )

    func runtimeSnapshots(
        using catalog: any ApplicationCatalog,
        preservingDataFrom previousSnapshots: [AgentProductSnapshot]
    ) -> [AgentProductSnapshot] {
        let previousByID = Dictionary(
            uniqueKeysWithValues: previousSnapshots.map {
                ($0.id, $0)
            }
        )
        return adapters.map { adapter in
            let runtimeSnapshot = inspectProductRuntime(
                adapter.descriptor,
                using: catalog
            )
            guard runtimeSnapshot.health == .running,
                  let previous = previousByID[runtimeSnapshot.id],
                  previous.health == .running,
                  previous.application == runtimeSnapshot.application else {
                return runtimeSnapshot
            }
            return AgentProductSnapshot(
                descriptor: runtimeSnapshot.descriptor,
                application: runtimeSnapshot.application,
                health: .running,
                threads: previous.threads,
                quotaSummary: previous.quotaSummary,
                dataAvailability: previous.dataAvailability,
                diagnostic: previous.diagnostic
            )
        }
    }

    func snapshots(
        using catalog: any ApplicationCatalog
    ) async -> [AgentProductSnapshot] {
        var results: [AgentProductSnapshot] = []
        results.reserveCapacity(adapters.count)
        for adapter in adapters {
            do {
                results.append(try await adapter.inspect(using: catalog))
            } catch {
                results.append(
                    .inspectionFailed(descriptor: adapter.descriptor)
                )
            }
        }
        return results
    }
}

private func inspectProductRuntime(
    _ descriptor: AgentProductDescriptor,
    using catalog: any ApplicationCatalog
) -> AgentProductSnapshot {
    let application = descriptor.applicationPaths.lazy.compactMap {
        catalog.application(atCandidatePath: $0)
    }.first {
        descriptor.bundleIdentifiers.contains($0.bundleIdentifier)
    }

    guard let application else {
        return AgentProductSnapshot(
            descriptor: descriptor,
            application: nil,
            health: .notInstalled,
            threads: [],
            quotaSummary: nil,
            dataAvailability: .unavailable("应用未安装"),
            diagnostic: nil
        )
    }

    guard catalog.isRunning(
        bundleIdentifier: application.bundleIdentifier
    ) else {
        return AgentProductSnapshot(
            descriptor: descriptor,
            application: application,
            health: .detected,
            threads: [],
            quotaSummary: nil,
            dataAvailability: .unavailable("应用未运行"),
            diagnostic: nil
        )
    }

    return AgentProductSnapshot(
        descriptor: descriptor,
        application: application,
        health: .running,
        threads: [],
        quotaSummary: nil,
        dataAvailability: .unavailable("会话数据刷新中"),
        diagnostic: nil
    )
}

struct SyntheticAgentProductApplicationCatalog: ApplicationCatalog {
    func application(
        atCandidatePath path: String
    ) -> InstalledApplicationMetadata? {
        switch path {
        case "/Applications/WorkBuddy.app":
            return InstalledApplicationMetadata(
                path: path,
                bundleIdentifier: "com.workbuddy.workbuddy",
                displayName: "WorkBuddy",
                version: "5.3.5"
            )
        case "/Applications/TRAE SOLO.app":
            return InstalledApplicationMetadata(
                path: path,
                bundleIdentifier: "com.trae.solo.app",
                displayName: "TRAE SOLO",
                version: "0.1.40"
            )
        default:
            return nil
        }
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        [
            "com.workbuddy.workbuddy",
            "com.trae.solo.app",
        ].contains(bundleIdentifier)
    }
}

enum KimiWorkActivityState: Equatable, Sendable {
    case running
    case needsAction
    case needsReview
}

struct KimiWorkActivityRecord: Equatable, Sendable {
    let conversationKey: String
    let title: String?
    let state: KimiWorkActivityState
}

enum KimiWorkStatusParser {
    private static let maximumStatusBytes = 512 * 1_024
    private static let maximumTitleBytes = 1_024 * 1_024
    private static let maximumSourceRecords = 500
    private static let maximumActiveRecords = 64

    static func activeRecords(
        statusData: Data?,
        unreadData: Data?,
        titleData: Data?
    ) -> [KimiWorkActivityRecord]? {
        let statuses = stringDictionary(
            from: statusData,
            maximumBytes: maximumStatusBytes
        )
        let unreadKeys = stringArray(
            from: unreadData,
            maximumBytes: maximumStatusBytes
        )
        guard statuses != nil || unreadKeys != nil else {
            return nil
        }

        let titles = stringDictionary(
            from: titleData,
            maximumBytes: maximumTitleBytes
        ) ?? [:]
        let unreadSet = Set((unreadKeys ?? []).filter(validKey))
        let candidateKeys = Set((statuses ?? [:]).keys.filter(validKey))
            .union(unreadSet)

        let records = candidateKeys.compactMap {
            key -> KimiWorkActivityRecord? in
            let state: KimiWorkActivityState
            switch statuses?[key] {
            case "running":
                state = .running
            case "blocked":
                state = .needsAction
            case "completed" where unreadSet.contains(key):
                state = .needsReview
            case nil where unreadSet.contains(key):
                state = .needsReview
            default:
                return nil
            }
            return KimiWorkActivityRecord(
                conversationKey: key,
                title: normalizedTitle(titles[key]),
                state: state
            )
        }
        return records.sorted {
            let leftPriority = priority($0.state)
            let rightPriority = priority($1.state)
            if leftPriority != rightPriority {
                return leftPriority < rightPriority
            }
            return $0.conversationKey < $1.conversationKey
        }.prefix(maximumActiveRecords).map { $0 }
    }

    private static func stringDictionary(
        from data: Data?,
        maximumBytes: Int
    ) -> [String: String]? {
        guard let data else { return nil }
        guard data.count <= maximumBytes,
              let values = try? JSONDecoder().decode(
                  [String: String].self,
                  from: data
              ) else {
            return nil
        }
        var limitedValues: [String: String] = [:]
        for (key, value) in values.prefix(maximumSourceRecords) {
            limitedValues[key] = value
        }
        return limitedValues
    }

    private static func stringArray(
        from data: Data?,
        maximumBytes: Int
    ) -> [String]? {
        guard let data else { return nil }
        guard data.count <= maximumBytes,
              let values = try? JSONDecoder().decode(
                  [String].self,
                  from: data
              ) else {
            return nil
        }
        return Array(values.prefix(maximumSourceRecords))
    }

    private static func validKey(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 512
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private static func normalizedTitle(_ rawValue: String?) -> String? {
        guard let rawValue, rawValue.utf8.count <= 2_048 else {
            return nil
        }
        let title = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return title.isEmpty ? nil : String(title.prefix(160))
    }

    private static func priority(_ state: KimiWorkActivityState) -> Int {
        switch state {
        case .needsAction:
            return 0
        case .running:
            return 1
        case .needsReview:
            return 2
        }
    }
}

enum WorkBuddySidecarResponseParser {
    static func sessionListURLs(from data: Data) -> [URL] {
        guard data.count <= 256 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let result = root["result"] as? [[String: Any]] else {
            return []
        }

        var seenPorts = Set<Int>()
        var urls: [URL] = []
        for item in result.prefix(16) {
            guard let rawEndpoint = item["acpEndpoint"] as? String,
                  rawEndpoint.utf8.count <= 256,
                  var components = URLComponents(string: rawEndpoint),
                  components.scheme == "http",
                  components.host == "127.0.0.1",
                  components.path == "/api/v1/acp",
                  let port = components.port,
                  (1_024...65_535).contains(port),
                  seenPorts.insert(port).inserted else {
                continue
            }
            components.path = "/api/v1/sessions"
            components.percentEncodedQuery = "cwd=*"
            components.fragment = nil
            if let url = components.url {
                urls.append(url)
            }
        }
        return urls.sorted {
            ($0.port ?? 0) < ($1.port ?? 0)
        }
    }
}

enum WorkBuddySessionListParser {
    private static let recentWindowMillis: Int64 = 48 * 60 * 60 * 1_000
    private static let maximumThreads = 12

    static func threads(
        from data: Data,
        nowMillis: Int64
    ) -> [AgentProductThread]? {
        guard data.count <= 512 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let sessions = payload["sessions"] as? [[String: Any]] else {
            return nil
        }

        let cutoff = nowMillis - recentWindowMillis
        var threads: [AgentProductThread] = []
        for session in sessions.prefix(500) {
            guard let rawID = session["id"] as? String,
                  !rawID.isEmpty,
                  rawID.utf8.count <= 256,
                  let rawTitle = session["name"] as? String,
                  rawTitle.utf8.count <= 2_048,
                  let updatedMillis = int64(session["updatedAt"]),
                  updatedMillis > 0 else {
                continue
            }
            let title = rawTitle.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !title.isEmpty else { continue }
            let isCurrent = session["isCurrent"] as? Bool ?? false
            guard isCurrent || updatedMillis >= cutoff else { continue }
            threads.append(
                AgentProductThread(
                    id: rawID,
                    title: String(title.prefix(160)),
                    updatedMillis: updatedMillis,
                    state: isCurrent ? .running : .recent
                )
            )
        }
        return threads.sorted {
            if $0.state != $1.state {
                return $0.state == .running
            }
            if $0.updatedMillis != $1.updatedMillis {
                return $0.updatedMillis > $1.updatedMillis
            }
            return $0.id < $1.id
        }.prefix(maximumThreads).map { $0 }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            return number.int64Value
        }
        if let text = value as? String {
            return Int64(text)
        }
        return nil
    }
}

private enum WorkBuddyPublicSessionError: LocalizedError, Sendable {
    case sidecarProtocol
    case endpointUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .sidecarProtocol:
            return "WorkBuddy 本机只读会话通道不可用"
        case .endpointUnavailable:
            return "WorkBuddy 公开会话接口暂不可用"
        case .invalidResponse:
            return "WorkBuddy 公开会话接口返回异常"
        }
    }
}

private struct WorkBuddySidecarClient: Sendable {
    private static let maximumResponseBytes = 256 * 1024

    func sessionListResponse() throws -> Data? {
        let socketPath = Self.controlSocketPath()
        guard Self.isOwnedPrivateSocket(at: socketPath) else {
            return nil
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw WorkBuddyPublicSessionError.sidecarProtocol
        }
        defer { Darwin.close(descriptor) }

        var timeout = timeval(tv_sec: 0, tv_usec: 450_000)
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &timeout) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                $0,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path)
        else {
            throw WorkBuddyPublicSessionError.sidecarProtocol
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: CChar.self,
                capacity: pathBytes.count
            ) { destination in
                for (index, byte) in pathBytes.enumerated() {
                    destination[index] = byte
                }
            }
        }
        let addressLength = socklen_t(
            MemoryLayout<sa_family_t>.size + pathBytes.count
        )
        address.sun_len = UInt8(min(Int(addressLength), 255))
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(
                to: sockaddr.self,
                capacity: 1
            ) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED {
                return nil
            }
            throw WorkBuddyPublicSessionError.sidecarProtocol
        }

        let request = Data(
            """
            {"jsonrpc":"2.0","id":1,"method":"session.list"}

            """.utf8
        )
        try sendAll(request, to: descriptor)
        return try receiveLine(from: descriptor)
    }

    private func sendAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var sentBytes = 0
            while sentBytes < data.count {
                let result = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: sentBytes),
                    data.count - sentBytes,
                    0
                )
                guard result > 0 else {
                    throw WorkBuddyPublicSessionError.sidecarProtocol
                }
                sentBytes += result
            }
        }
    }

    private func receiveLine(from descriptor: Int32) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 8 * 1024)
        while response.count < Self.maximumResponseBytes {
            let count = Darwin.recv(
                descriptor,
                &buffer,
                buffer.count,
                0
            )
            guard count > 0 else {
                throw WorkBuddyPublicSessionError.sidecarProtocol
            }
            response.append(buffer, count: count)
            if let newline = response.firstIndex(of: 0x0A) {
                return Data(response[..<newline])
            }
        }
        throw WorkBuddyPublicSessionError.sidecarProtocol
    }

    private static func controlSocketPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let configPath = URL(
            fileURLWithPath: home,
            isDirectory: true
        ).appendingPathComponent(".workbuddy", isDirectory: true).path
        let instanceToken = String(sha1(configPath).prefix(12))
        let userToken = String(sha1(String(Darwin.getuid())).prefix(6))
        let temporaryRoot = URL(
            fileURLWithPath: NSTemporaryDirectory(),
            isDirectory: true
        ).standardizedFileURL
        return temporaryRoot
            .appendingPathComponent("wb-\(userToken)", isDirectory: true)
            .appendingPathComponent(instanceToken, isDirectory: true)
            .appendingPathComponent("sidecar.sock", isDirectory: false)
            .path
    }

    private static func isOwnedPrivateSocket(at path: String) -> Bool {
        let fileManager = FileManager.default
        let parentPath = URL(fileURLWithPath: path)
            .deletingLastPathComponent().path
        guard let parentAttributes = try? fileManager
            .attributesOfItem(atPath: parentPath),
            let ownerID = parentAttributes[.ownerAccountID] as? NSNumber,
            ownerID.uint32Value == Darwin.getuid(),
            let permissions = parentAttributes[.posixPermissions] as? NSNumber,
            permissions.intValue & 0o077 == 0,
            let socketAttributes = try? fileManager
                .attributesOfItem(atPath: path),
            socketAttributes[.type] as? FileAttributeType == .typeSocket else {
            return false
        }
        return true
    }

    private static func sha1(_ value: String) -> String {
        Insecure.SHA1.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private struct WorkBuddyEndpointFetchResult: Sendable {
    let succeeded: Bool
    let threads: [AgentProductThread]
}

private final class WorkBuddyLoopbackSessionDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct WorkBuddyPublicSessionDataSource: AgentProductDataSource {
    private static let maximumEndpoints = 6
    private static let verifiedApplicationVersionPrefix = "5.3.5"

    func load(
        for application: InstalledApplicationMetadata
    ) async throws -> AgentProductDataSnapshot {
        guard application.version.hasPrefix(
            Self.verifiedApplicationVersionPrefix
        ) else {
            return AgentProductDataSnapshot(
                threads: [],
                quotaSummary: nil,
                availability: .unavailable(
                    "当前 WorkBuddy 版本尚未通过只读会话适配验证"
                )
            )
        }
        let sidecarResponse = try await Task.detached(priority: .utility) {
            try WorkBuddySidecarClient().sessionListResponse()
        }.value
        guard let sidecarResponse else {
            return AgentProductDataSnapshot(
                threads: [],
                quotaSummary: nil,
                availability: .unavailable(
                    "WorkBuddy 本机只读会话通道暂不可用"
                )
            )
        }

        let sessionListURLs =
            WorkBuddySidecarResponseParser.sessionListURLs(
                from: sidecarResponse
            )
        guard !sessionListURLs.isEmpty else {
            return AgentProductDataSnapshot(
                threads: [],
                quotaSummary: nil,
                availability: .unavailable(
                    "WorkBuddy 本机只读会话通道返回异常"
                )
            )
        }

        let results = await withTaskGroup(
            of: WorkBuddyEndpointFetchResult.self,
            returning: [WorkBuddyEndpointFetchResult].self
        ) { group in
            for url in sessionListURLs.prefix(Self.maximumEndpoints) {
                group.addTask {
                    await Self.fetchThreads(from: url)
                }
            }
            var values: [WorkBuddyEndpointFetchResult] = []
            for await result in group {
                values.append(result)
            }
            return values
        }
        guard results.contains(where: \.succeeded) else {
            return AgentProductDataSnapshot(
                threads: [],
                quotaSummary: nil,
                availability: .unavailable(
                    "WorkBuddy 公开会话接口暂不可用"
                )
            )
        }

        return AgentProductDataSnapshot(
            threads: Self.mergedThreads(
                results.flatMap(\.threads)
            ),
            quotaSummary: nil,
            availability: .available
        )
    }

    private static func fetchThreads(
        from url: URL
    ) async -> WorkBuddyEndpointFetchResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("1", forHTTPHeaderField: "X-CodeBuddy-Request")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 0.8

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 0.8
        configuration.timeoutIntervalForResource = 1.0
        let session = URLSession(
            configuration: configuration,
            delegate: WorkBuddyLoopbackSessionDelegate(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  httpResponse.url?.scheme == "http",
                  httpResponse.url?.host == "127.0.0.1",
                  httpResponse.url?.port == url.port else {
                return WorkBuddyEndpointFetchResult(
                    succeeded: false,
                    threads: []
                )
            }
            var data = Data()
            data.reserveCapacity(32 * 1024)
            for try await byte in bytes {
                guard data.count < 512 * 1024 else {
                    return WorkBuddyEndpointFetchResult(
                        succeeded: false,
                        threads: []
                    )
                }
                data.append(byte)
            }
            guard let threads = WorkBuddySessionListParser.threads(
                from: data,
                nowMillis: Int64(
                    Date().timeIntervalSince1970 * 1_000
                )
            ) else {
                return WorkBuddyEndpointFetchResult(
                    succeeded: false,
                    threads: []
                )
            }
            return WorkBuddyEndpointFetchResult(
                succeeded: true,
                threads: threads
            )
        } catch {
            return WorkBuddyEndpointFetchResult(
                succeeded: false,
                threads: []
            )
        }
    }

    private static func mergedThreads(
        _ threads: [AgentProductThread]
    ) -> [AgentProductThread] {
        var byID: [String: AgentProductThread] = [:]
        for thread in threads {
            guard let existing = byID[thread.id] else {
                byID[thread.id] = thread
                continue
            }
            let preferred = thread.updatedMillis >= existing.updatedMillis
                ? thread : existing
            byID[thread.id] = AgentProductThread(
                id: thread.id,
                title: preferred.title,
                updatedMillis: max(
                    thread.updatedMillis,
                    existing.updatedMillis
                ),
                state: thread.state == .running
                    || existing.state == .running ? .running : .recent
            )
        }
        return byID.values.sorted {
            if $0.state != $1.state {
                return $0.state == .running
            }
            if $0.updatedMillis != $1.updatedMillis {
                return $0.updatedMillis > $1.updatedMillis
            }
            return $0.id < $1.id
        }.prefix(12).map { $0 }
    }
}

private func inspectProduct(
    _ descriptor: AgentProductDescriptor,
    using catalog: any ApplicationCatalog,
    dataSource: any AgentProductDataSource
) async -> AgentProductSnapshot {
    let runtimeSnapshot = inspectProductRuntime(
        descriptor,
        using: catalog
    )
    guard runtimeSnapshot.health == .running,
          let application = runtimeSnapshot.application else {
        return runtimeSnapshot
    }

    let dataSnapshot: AgentProductDataSnapshot
    do {
        dataSnapshot = try await dataSource.load(for: application)
    } catch {
        dataSnapshot = AgentProductDataSnapshot(
            threads: [],
            quotaSummary: nil,
            availability: .unavailable("公开只读接口暂不可用")
        )
    }
    return AgentProductSnapshot(
        descriptor: descriptor,
        application: application,
        health: .running,
        threads: dataSnapshot.threads,
        quotaSummary: dataSnapshot.quotaSummary,
        dataAvailability: dataSnapshot.availability,
        diagnostic: nil
    )
}
