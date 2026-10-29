import CMUXAgentLaunch
import CmuxFoundation
@testable import CmuxComputerUse
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the real hook ingress with isolated preferences and one synthetic session.
@MainActor
final class ComputerUseToolOnboardingFixture {
    let persistence: ComputerUseOnboardingFixture
    let workspaceID = UUID()
    let surfaceID = UUID()
    let sessionID = "synthetic-computer-use-session"
    let runtime: ComputerUseRuntimeService
    let liveIndex: SharedLiveAgentIndex
    let usesProductionPresenter: Bool
    var featureEnabled = true
    var presentations: [ComputerUseOnboardingWindowController.StartingPoint] = []
    let helperLaunches = AsyncStream<Void>.makeStream()

    lazy var coordinator: ComputerUseUXCoordinator = {
        let catalog = SettingCatalog()
        return ComputerUseUXCoordinator(
            liveAgentIndex: liveIndex,
            stateRepository: ComputerUseStateRepository(authenticationKey: runtime.stateAuthenticationKey),
            stateDirectoryURL: persistence.paths.stateDirectoryURL,
            configStore: JSONConfigStore(fileURL: persistence.root.appendingPathComponent("cmux.json")),
            enabledKey: catalog.computerUse.enabled,
            showInMenuBarKey: catalog.computerUse.showInMenuBar,
            liveSettingRepository: ComputerUseLiveSettingRepository(
                fileURL: persistence.root.appendingPathComponent("live/enabled")
            ),
            runtimeService: runtime,
            userDefaults: persistence.defaults,
            workspaceTitle: { _ in "Synthetic workspace" },
            featureEnabled: { [weak self] in self?.featureEnabled == true },
            onboardingCoordinator: usesProductionPresenter ? nil : ComputerUseOnboardingCoordinator(
                runtimeService: runtime,
                presenter: { [weak self] point, _ in self?.presentations.append(point) }
            ),
            ownsSurface: { [weak self] surfaceID, workspaceID in
                surfaceID == self?.surfaceID && workspaceID == self?.workspaceID
            }
        )
    }()

    init(
        hasLiveSession: Bool = true,
        usesProductionPresenter: Bool = false,
        simulatesFailedHelperLaunch: Bool = false
    ) throws {
        self.usesProductionPresenter = usesProductionPresenter
        persistence = try ComputerUseOnboardingFixture()
        // Never use the test host's real helper or touch the user's TCC grants.
        let bundleURL = persistence.root.appendingPathComponent("Fixture.bundle")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": "com.cmuxterm.tests.computer-use"],
            format: .xml,
            options: 0
        )
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        if simulatesFailedHelperLaunch {
            let helper = contents.appendingPathComponent("Library/cmux Computer Use.app/Contents")
            let executable = helper.appendingPathComponent("MacOS/cmux-cua")
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("synthetic helper; never executed".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            try info.write(to: helper.appendingPathComponent("Info.plist"))
        }
        runtime = ComputerUseRuntimeService(
            bundle: try #require(Bundle(url: bundleURL)),
            paths: persistence.paths,
            userDefaults: persistence.defaults,
            // Freeze launch backoff so recovery must come from the hook.
            uptime: { 100 },
            isDisabledByPolicy: { false },
            // No helper runs here, so every status refresh would otherwise wait
            // out the full production deadline (5 s per first tool call).
            permissionStatusDeadline: .zero,
            helperTrust: ComputerUseHelperTrust(isSigned: { _ in true }, installedCandidates: { [] })
        )
        runtime.helperLauncher = { [helperLaunches] _, _ in
            helperLaunches.continuation.yield(())
            return nil
        }
        runtime.helperRegistrar = { _ in }
        let pid = ProcessInfo.processInfo.processIdentifier
        let identity = try #require(AgentPIDProcessIdentity(pid: pid))
        let hookDirectory = persistence.root.appendingPathComponent("hooks")
        let index = RestorableAgentSessionIndex.load(
            homeDirectory: persistence.root.path,
            fileManager: .default,
            registry: CmuxVaultAgentRegistry(registrations: []),
            detectedSnapshots: [
                .init(workspaceId: workspaceID, panelId: surfaceID): (
                    snapshot: SessionRestorableAgentSnapshot(kind: .codex, sessionId: sessionID),
                    updatedAt: 1,
                    processIDs: [Int(pid)],
                    agentProcessIDs: [Int(pid)],
                    sessionIDSource: .explicit
                )
            ],
            environment: ["CMUX_AGENT_HOOK_STATE_DIR": hookDirectory.path],
            processArgumentsProvider: { _ in nil },
            processPresenceProvider: { $0 == Int(pid) ? .present : .absent },
            processIdentityProvider: { $0 == Int(pid) ? identity : nil }
        )
        #expect(index.liveEntries().count == 1)
        let loadedIndex = hasLiveSession ? index : .empty
        liveIndex = SharedLiveAgentIndex(
            indexLoader: {
                (loadedIndex, [], [], [])
            },
            hookStoreDirectoryProvider: { hookDirectory.path }
        )
    }

    func enable() async throws {
        #expect(liveIndex.index == nil)
        await runtime.setEnabled(true)
        #expect(runtime.permissionPhase == .onboardingRequired)
    }

    func send(
        _ tool: String?,
        hook: WorkstreamEvent.HookEventName = .preToolUse,
        surface: UUID? = nil,
        session: String? = nil
    ) async {
        await coordinator.handleWorkstreamEvent(WorkstreamEvent(
            sessionId: session ?? sessionID,
            hookEventName: hook,
            source: "codex",
            workspaceId: workspaceID.uuidString,
            surfaceId: (surface ?? surfaceID).uuidString,
            toolName: tool
        ))
    }

    func remove() {
        coordinator.teardownForTermination()
        helperLaunches.continuation.finish()
        persistence.remove()
    }
}
