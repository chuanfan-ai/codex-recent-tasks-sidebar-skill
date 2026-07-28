import Darwin
import Foundation

private struct SyntheticApplicationCatalog: ApplicationCatalog {
    let applicationsByPath: [String: InstalledApplicationMetadata]
    let runningBundleIdentifiers: Set<String>

    func application(atCandidatePath path: String) -> InstalledApplicationMetadata? {
        applicationsByPath[path]
    }

    func isRunning(bundleIdentifier: String) -> Bool {
        runningBundleIdentifiers.contains(bundleIdentifier)
    }
}

private struct ThrowingAdapter: LocalAgentAdapter {
    let descriptor = AgentProductDescriptor(
        id: "synthetic-failure",
        displayName: "Synthetic Failure",
        applicationPaths: ["/Applications/Synthetic Failure.app"],
        bundleIdentifiers: ["test.synthetic.failure"],
        supportLevel: .discovered,
        capabilities: .discoveryOnly,
        dataSourceDescription: "测试故障",
        privacyDescription: "不读取用户内容"
    )

    func inspect(using catalog: any ApplicationCatalog) throws -> AgentProductSnapshot {
        throw AgentAdapterError.inspectionFailed("synthetic")
    }
}

@main
private struct AgentAdapterContractTests {
    static func main() {
        let workBuddy = WorkBuddyAdapter()
        let traeWork = TraeWorkAdapter()

        guard workBuddy.descriptor.id == "workbuddy",
              workBuddy.descriptor.displayName == "WorkBuddy",
              workBuddy.descriptor.applicationPaths == [
                  "/Applications/WorkBuddy.app",
              ],
              workBuddy.descriptor.bundleIdentifiers == [
                  "com.workbuddy.workbuddy",
              ],
              workBuddy.descriptor.supportLevel == .discovered,
              workBuddy.descriptor.capabilities == .discoveryOnly else {
            fail("WorkBuddy descriptor")
        }

        guard traeWork.descriptor.id == "trae-work",
              traeWork.descriptor.displayName == "TRAE Work",
              traeWork.descriptor.applicationPaths == [
                  "/Applications/TRAE SOLO.app",
              ],
              traeWork.descriptor.bundleIdentifiers == [
                  "com.trae.solo.app",
              ],
              !traeWork.descriptor.applicationPaths.contains(
                  "/Applications/TRAE.app"
              ),
              traeWork.descriptor.supportLevel == .discovered,
              traeWork.descriptor.capabilities == .discoveryOnly else {
            fail("TRAE Work descriptor")
        }

        let installedCatalog = SyntheticApplicationCatalog(
            applicationsByPath: [
                "/Applications/WorkBuddy.app": InstalledApplicationMetadata(
                    path: "/Applications/WorkBuddy.app",
                    bundleIdentifier: "com.workbuddy.workbuddy",
                    displayName: "WorkBuddy",
                    version: "5.3.5"
                ),
                "/Applications/TRAE SOLO.app": InstalledApplicationMetadata(
                    path: "/Applications/TRAE SOLO.app",
                    bundleIdentifier: "com.trae.solo.app",
                    displayName: "TRAE SOLO",
                    version: "0.1.40"
                ),
            ],
            runningBundleIdentifiers: [
                "com.workbuddy.workbuddy",
                "com.trae.solo.app",
            ]
        )

        let workBuddySnapshot = inspect(workBuddy, catalog: installedCatalog)
        let traeWorkSnapshot = inspect(traeWork, catalog: installedCatalog)
        guard workBuddySnapshot.isInstalled,
              workBuddySnapshot.isRunning,
              workBuddySnapshot.application?.version == "5.3.5",
              traeWorkSnapshot.isInstalled,
              traeWorkSnapshot.isRunning,
              traeWorkSnapshot.application?.displayName == "TRAE SOLO",
              workBuddySnapshot.activeTaskCount == nil,
              workBuddySnapshot.quotaSummary == nil,
              traeWorkSnapshot.activeTaskCount == nil,
              traeWorkSnapshot.quotaSummary == nil else {
            fail("metadata-only discovery")
        }

        let traeIDEOnlyCatalog = SyntheticApplicationCatalog(
            applicationsByPath: [
                "/Applications/TRAE.app": InstalledApplicationMetadata(
                    path: "/Applications/TRAE.app",
                    bundleIdentifier: "com.trae.app",
                    displayName: "TRAE",
                    version: "2.0"
                ),
            ],
            runningBundleIdentifiers: ["com.trae.app"]
        )
        guard !inspect(traeWork, catalog: traeIDEOnlyCatalog).isInstalled else {
            fail("TRAE IDE false positive")
        }

        let registry = AgentAdapterRegistry(
            adapters: [ThrowingAdapter(), workBuddy, traeWork]
        )
        let snapshots = registry.snapshots(using: installedCatalog)
        guard snapshots.count == 3,
              snapshots[0].health == .inspectionFailed,
              snapshots[0].activeTaskCount == nil,
              snapshots[0].quotaSummary == nil,
              snapshots[1] == workBuddySnapshot,
              snapshots[2] == traeWorkSnapshot else {
            fail("adapter failure isolation")
        }

        print(
            "AGENT_ADAPTER_CONTRACT_OK products=2 metadata_only=ok "
                + "trae_ide_excluded=ok isolation=ok"
        )
    }

    private static func inspect(
        _ adapter: some LocalAgentAdapter,
        catalog: any ApplicationCatalog
    ) -> AgentProductSnapshot {
        do {
            return try adapter.inspect(using: catalog)
        } catch {
            fail("unexpected inspection failure")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("AGENT_ADAPTER_CONTRACT_FAILED \(message)\n", stderr)
        Darwin.exit(1)
    }
}
