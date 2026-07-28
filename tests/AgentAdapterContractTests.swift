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

private struct SyntheticProductDataSource: AgentProductDataSource {
    let snapshot: AgentProductDataSnapshot

    func load(
        for application: InstalledApplicationMetadata
    ) async throws -> AgentProductDataSnapshot {
        snapshot
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

    func inspect(
        using catalog: any ApplicationCatalog
    ) async throws -> AgentProductSnapshot {
        throw AgentAdapterError.inspectionFailed("synthetic")
    }
}

@main
private struct AgentAdapterContractTests {
    static func main() async {
        let workBuddyThreads = [
            AgentProductThread(
                id: "workbuddy-session-current",
                title: "WorkBuddy 当前任务",
                updatedMillis: 4_102_444_800_000,
                state: .running
            ),
            AgentProductThread(
                id: "workbuddy-session-recent",
                title: "WorkBuddy 最近任务",
                updatedMillis: 4_102_444_700_000,
                state: .recent
            ),
        ]
        let workBuddy = WorkBuddyAdapter(
            dataSource: SyntheticProductDataSource(
                snapshot: AgentProductDataSnapshot(
                    threads: workBuddyThreads,
                    quotaSummary: nil,
                    availability: .available
                )
            )
        )
        let traeWork = TraeWorkAdapter(
            dataSource: SyntheticProductDataSource(
                snapshot: AgentProductDataSnapshot(
                    threads: [],
                    quotaSummary: nil,
                    availability: .unavailable(
                        "上游未开放可独立验证的线程与余额接口"
                    )
                )
            )
        )

        guard workBuddy.descriptor.id == "workbuddy",
              workBuddy.descriptor.displayName == "WorkBuddy",
              workBuddy.descriptor.applicationPaths == [
                  "/Applications/WorkBuddy.app",
              ],
              workBuddy.descriptor.bundleIdentifiers == [
                  "com.workbuddy.workbuddy",
              ],
              workBuddy.descriptor.supportLevel == .partial,
              workBuddy.descriptor.capabilities.monitorsTasks,
              !workBuddy.descriptor.capabilities.monitorsQuota,
              !workBuddy.descriptor.capabilities.opensExactTask,
              workBuddy.descriptor.capabilities.opensApplication else {
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

        let workBuddySnapshot = await inspect(
            workBuddy,
            catalog: installedCatalog
        )
        let traeWorkSnapshot = await inspect(
            traeWork,
            catalog: installedCatalog
        )
        guard workBuddySnapshot.isInstalled,
              workBuddySnapshot.isRunning,
              workBuddySnapshot.application?.version == "5.3.5",
              workBuddySnapshot.iconApplicationPath
                  == "/Applications/WorkBuddy.app",
              traeWorkSnapshot.isInstalled,
              traeWorkSnapshot.isRunning,
              traeWorkSnapshot.application?.displayName == "TRAE SOLO",
              traeWorkSnapshot.iconApplicationPath
                  == "/Applications/TRAE SOLO.app",
              workBuddySnapshot.activeTaskCount == 1,
              workBuddySnapshot.threads == workBuddyThreads,
              workBuddySnapshot.quotaSummary == nil,
              traeWorkSnapshot.activeTaskCount == nil,
              traeWorkSnapshot.quotaSummary == nil,
              traeWorkSnapshot.dataAvailability == .unavailable(
                  "上游未开放可独立验证的线程与余额接口"
              ) else {
            fail("verified product data")
        }
        guard workBuddySnapshot.presentation == AgentProductPresentation(
            statusText: "运行中",
            supportText: "部分支持",
            detailText: "已读取 2 个公开会话摘要；余额接口未开放",
            canOpenApplication: true
        ),
        traeWorkSnapshot.presentation.statusText == "运行中",
        traeWorkSnapshot.presentation.canOpenApplication else {
            fail("safe product presentation")
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
        let traeIDEOnlySnapshot = await inspect(
            traeWork,
            catalog: traeIDEOnlyCatalog
        )
        guard !traeIDEOnlySnapshot.isInstalled,
              traeIDEOnlySnapshot.presentation == AgentProductPresentation(
                  statusText: "未安装",
                  supportText: "已发现 · 待适配",
                  detailText: "未在已验证路径发现",
                  canOpenApplication: false
              ) else {
            fail("TRAE IDE false positive")
        }

        let registry = AgentAdapterRegistry(
            adapters: [ThrowingAdapter(), workBuddy, traeWork]
        )
        let snapshots = await registry.snapshots(using: installedCatalog)
        guard snapshots.count == 3,
              snapshots[0].health == .inspectionFailed,
              snapshots[0].activeTaskCount == nil,
              snapshots[0].quotaSummary == nil,
              snapshots[0].presentation.statusText == "检查失败",
              !snapshots[0].presentation.canOpenApplication,
              snapshots[1] == workBuddySnapshot,
              snapshots[2] == traeWorkSnapshot else {
            fail("adapter failure isolation")
        }
        guard AgentAdapterRegistry.firstBatch.adapters.map(
            \.descriptor.id
        ) == ["workbuddy", "trae-work"] else {
            fail("first-batch order")
        }

        let sidecarPayload = Data(
            """
            {
              "jsonrpc": "2.0",
              "id": 1,
              "result": [
                {
                  "acpEndpoint": "http://127.0.0.1:55174/api/v1/acp"
                },
                {
                  "acpEndpoint": "https://outside.example/api/v1/acp"
                },
                {
                  "acpEndpoint": "http://127.0.0.1:55175/internal/acp"
                }
              ]
            }
            """.utf8
        )
        guard WorkBuddySidecarResponseParser.sessionListURLs(
            from: sidecarPayload
        ) == [
            URL(
                string:
                    "http://127.0.0.1:55174/api/v1/sessions?cwd=*"
            )!,
        ] else {
            fail("WorkBuddy loopback endpoint validation")
        }

        let nowMillis: Int64 = 4_102_444_800_000
        let sessionPayload = Data(
            """
            {
              "data": {
                "sessions": [
                  {
                    "id": "current",
                    "name": "  当前任务  ",
                    "updatedAt": 4102444800000,
                    "isCurrent": true
                  },
                  {
                    "id": "recent",
                    "name": "最近任务",
                    "updatedAt": 4102444700000,
                    "isCurrent": false
                  },
                  {
                    "id": "old",
                    "name": "过期任务",
                    "updatedAt": 4102200000000,
                    "isCurrent": false
                  },
                  {
                    "id": "blank",
                    "name": "   ",
                    "updatedAt": 4102444800000,
                    "isCurrent": true
                  }
                ]
              }
            }
            """.utf8
        )
        guard WorkBuddySessionListParser.threads(
            from: sessionPayload,
            nowMillis: nowMillis
        ) == [
            AgentProductThread(
                id: "current",
                title: "当前任务",
                updatedMillis: 4_102_444_800_000,
                state: .running
            ),
            AgentProductThread(
                id: "recent",
                title: "最近任务",
                updatedMillis: 4_102_444_700_000,
                state: .recent
            ),
        ] else {
            fail("WorkBuddy public session parsing")
        }

        print(
            "AGENT_ADAPTER_CONTRACT_OK products=2 official_icons=ok "
                + "workbuddy_public_sessions=ok trae_ide_excluded=ok "
                + "isolation=ok presentation=ok"
        )
    }

    private static func inspect(
        _ adapter: some LocalAgentAdapter,
        catalog: any ApplicationCatalog
    ) async -> AgentProductSnapshot {
        do {
            return try await adapter.inspect(using: catalog)
        } catch {
            fail("unexpected inspection failure")
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("AGENT_ADAPTER_CONTRACT_FAILED \(message)\n", stderr)
        Darwin.exit(1)
    }
}
