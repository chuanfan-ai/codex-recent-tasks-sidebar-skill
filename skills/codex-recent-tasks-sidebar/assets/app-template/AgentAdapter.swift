import AppKit
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
}

struct AgentProductDescriptor: Equatable, Sendable {
    let id: String
    let displayName: String
    let applicationPaths: [String]
    let bundleIdentifiers: [String]
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
    let activeTaskCount: Int?
    let quotaSummary: String?
    let diagnostic: String?

    var id: String { descriptor.id }
    var isInstalled: Bool { application != nil }
    var isRunning: Bool { health == .running }
    var presentation: AgentProductPresentation {
        let statusText: String
        let detailText: String
        switch health {
        case .notInstalled:
            statusText = "未安装"
            detailText = "未在已验证路径发现"
        case .detected:
            statusText = "已安装"
            detailText = "仅识别应用元数据；任务与额度不读取"
        case .running:
            statusText = "运行中"
            detailText = "仅识别应用元数据；任务与额度不读取"
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
            activeTaskCount: nil,
            quotaSummary: nil,
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

protocol LocalAgentAdapter: Sendable {
    var descriptor: AgentProductDescriptor { get }
    func inspect(
        using catalog: any ApplicationCatalog
    ) throws -> AgentProductSnapshot
}

struct WorkBuddyAdapter: LocalAgentAdapter {
    let descriptor = AgentProductDescriptor(
        id: "workbuddy",
        displayName: "WorkBuddy",
        applicationPaths: ["/Applications/WorkBuddy.app"],
        bundleIdentifiers: ["com.workbuddy.workbuddy"],
        supportLevel: .discovered,
        capabilities: .discoveryOnly,
        dataSourceDescription: "应用包标识、版本与运行状态",
        privacyDescription: "不读取任务、日志、数据库、账号或会话内容"
    )

    func inspect(
        using catalog: any ApplicationCatalog
    ) throws -> AgentProductSnapshot {
        inspectDiscoveryOnlyProduct(descriptor, using: catalog)
    }
}

struct TraeWorkAdapter: LocalAgentAdapter {
    let descriptor = AgentProductDescriptor(
        id: "trae-work",
        displayName: "TRAE Work",
        applicationPaths: ["/Applications/TRAE SOLO.app"],
        bundleIdentifiers: ["com.trae.solo.app"],
        supportLevel: .discovered,
        capabilities: .discoveryOnly,
        dataSourceDescription: "应用包标识、版本与运行状态",
        privacyDescription: "不读取任务、日志、数据库、账号或会话内容"
    )

    func inspect(
        using catalog: any ApplicationCatalog
    ) throws -> AgentProductSnapshot {
        inspectDiscoveryOnlyProduct(descriptor, using: catalog)
    }
}

struct AgentAdapterRegistry {
    let adapters: [any LocalAgentAdapter]

    static let firstBatch = AgentAdapterRegistry(
        adapters: [WorkBuddyAdapter(), TraeWorkAdapter()]
    )

    func snapshots(
        using catalog: any ApplicationCatalog
    ) -> [AgentProductSnapshot] {
        adapters.map { adapter in
            do {
                return try adapter.inspect(using: catalog)
            } catch {
                return .inspectionFailed(descriptor: adapter.descriptor)
            }
        }
    }
}

private func inspectDiscoveryOnlyProduct(
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
            activeTaskCount: nil,
            quotaSummary: nil,
            diagnostic: nil
        )
    }

    let isRunning = catalog.isRunning(
        bundleIdentifier: application.bundleIdentifier
    )
    return AgentProductSnapshot(
        descriptor: descriptor,
        application: application,
        health: isRunning ? .running : .detected,
        activeTaskCount: nil,
        quotaSummary: nil,
        diagnostic: nil
    )
}
