import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the MDM `SocketControlMode` policy at its runtime seams:
/// the mode the listener actually resolves, the transition observer that
/// re-resolves it (at construction for a profile installed before launch, once
/// per mid-session push, and again on the lift), and the `cmux.json` importer,
/// which must not write a setting the profile owns.
@MainActor
struct ManagedPolicySocketControlModeTests {
    private static let backupsKey = "cmux.settingsFile.backups.v1"
    private static let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"

    // MARK: - Resolved listener mode

    @Test func theListenerRunsTheForcedModeRatherThanTheUsersChoice() throws {
        let suiteName = "ManagedPolicySocketControlModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SocketControlMode.allowAll.rawValue, forKey: SocketControlSettings.appStorageKey)

        #expect(CmuxSettingsFileStore.configuredSocketMode(defaults: defaults) == .allowAll)
        #expect(
            CmuxSettingsFileStore.liveSocketAccessMode(
                defaults: defaults,
                managedMode: .cmuxOnly
            ) == .cmuxOnly
        )
        #expect(
            CmuxSettingsFileStore.liveSocketAccessMode(
                defaults: defaults,
                managedMode: .off
            ) == .off
        )
    }

    @Test func anUnmanagedMacStillHonorsTheUsersChoice() throws {
        let suiteName = "ManagedPolicySocketControlModeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(SocketControlMode.automation.rawValue, forKey: SocketControlSettings.appStorageKey)

        #expect(
            CmuxSettingsFileStore.liveSocketAccessMode(
                defaults: defaults,
                managedMode: nil
            ) == .automation
        )
    }

    // MARK: - Transition observer

    @Test func aProfileForcedBeforeLaunchReresolvesTheListenerAtConstruction() {
        let policy = ManagedSocketModeFlag()
        policy.current = SocketControlModePolicy(forcedRawValue: "cmuxonly")
        let recorder = SocketEnforcementRecorder()
        let observer = makeObserver(policy: policy, recorder: recorder)

        #expect(recorder.count == 1)

        // Re-evaluating an unchanged state is not a transition.
        observer.reevaluate()
        #expect(recorder.count == 1)
        withExtendedLifetime(observer) {}
    }

    @Test func anUnmanagedMacDoesNotReresolveTheListenerAtConstruction() {
        let policy = ManagedSocketModeFlag()
        let recorder = SocketEnforcementRecorder()
        let observer = makeObserver(policy: policy, recorder: recorder)

        #expect(recorder.count == 0)
        withExtendedLifetime(observer) {}
    }

    @Test func aMidSessionPushEnforcesOnceAndTheLiftEnforcesAgain() {
        let center = NotificationCenter()
        let policy = ManagedSocketModeFlag()
        let recorder = SocketEnforcementRecorder()
        let observer = makeObserver(center: center, policy: policy, recorder: recorder)
        let token = center.addObserver(
            forName: ManagedDevicePolicy.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordChangeSignal() }
        defer { center.removeObserver(token) }
        #expect(recorder.count == 0)

        policy.current = SocketControlModePolicy(forcedRawValue: "cmuxonly")
        observer.reevaluate()
        #expect(recorder.count == 1)
        #expect(recorder.changeSignals == 1)

        observer.reevaluate()
        #expect(recorder.count == 1)
        #expect(recorder.changeSignals == 1)

        // The lift is a transition too: the listener returns to the user's
        // own mode, which also drops clients admitted under the forced one.
        policy.current = SocketControlModePolicy(forcedRawValue: nil)
        observer.reevaluate()
        #expect(recorder.count == 2)
        #expect(recorder.changeSignals == 2)
        withExtendedLifetime(observer) {}
    }

    @Test func narrowingTheForcedModeMidSessionIsItsOwnTransition() {
        let policy = ManagedSocketModeFlag()
        policy.current = SocketControlModePolicy(forcedRawValue: "cmuxonly")
        let recorder = SocketEnforcementRecorder()
        let observer = makeObserver(policy: policy, recorder: recorder)
        #expect(recorder.count == 1)

        policy.current = SocketControlModePolicy(forcedRawValue: "off")
        observer.reevaluate()
        #expect(recorder.count == 2)
        withExtendedLifetime(observer) {}
    }

    // MARK: - cmux.json importer

    @Test func theImporterSkipsTheSocketModeWhileTheProfileOwnsIt() throws {
        let defaults = UserDefaults.standard
        let key = SocketControlModePolicy.userDefaultsKey
        let preservedKeys = [key, Self.backupsKey, Self.importedManagedDefaultsKey]
        let previousValues = preservedKeys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (preservedKey, value) in previousValues {
                if let value {
                    defaults.set(value, forKey: preservedKey)
                } else {
                    defaults.removeObject(forKey: preservedKey)
                }
            }
        }
        preservedKeys.forEach { defaults.removeObject(forKey: $0) }

        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ManagedPolicySocketControlModeTests.\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        // The scenario the policy exists for: something with write access to
        // cmux.json tries to open the socket to every local process.
        try Data("""
        {
          "automation": {
            "socketControlMode": "allowall"
          }
        }
        """.utf8).write(to: settingsFileURL)

        let unforcedStore = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { _ in false }
        )
        try withExtendedLifetime(unforcedStore) {
            #expect(defaults.string(forKey: key) == SocketControlMode.allowAll.rawValue)
        }
        preservedKeys.forEach { defaults.removeObject(forKey: $0) }

        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            notificationCenter: NotificationCenter(),
            startWatching: false,
            isUserDefaultsKeyForcedByProfile: { $0 == key }
        )
        try withExtendedLifetime(store) {
            #expect(defaults.object(forKey: key) == nil)
            store.reload()
            #expect(defaults.object(forKey: key) == nil)
        }
    }

    // MARK: - Helpers

    private func makeObserver(
        center: NotificationCenter = NotificationCenter(),
        policy: ManagedSocketModeFlag,
        recorder: SocketEnforcementRecorder
    ) -> ManagedPolicyEnforcementObserver {
        ManagedPolicyEnforcementObserver(
            notificationCenter: center,
            isBrowserDisabledByPolicy: { false },
            browserURLAllowlistPolicy: { BrowserURLAllowlistPolicy(managedPatterns: nil) },
            socketControlModePolicy: { policy.current },
            isRemoteControlDisabledByPolicy: { false },
            isCloudDisabledByPolicy: { false },
            isIrohDisabledByPolicy: { false },
            enforceBrowserPolicy: {},
            enforceBrowserURLAllowlistPolicy: {},
            enforceSocketControlModePolicy: { recorder.record() },
            enforceRemoteControlPolicy: {}
        )
    }
}

/// Counts socket-listener re-resolutions and managed-policy change signals.
private final class SocketEnforcementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var enforcementCount = 0
    private var changeSignalCount = 0

    var count: Int { lock.withLock { enforcementCount } }
    var changeSignals: Int { lock.withLock { changeSignalCount } }

    func record() { lock.withLock { enforcementCount += 1 } }
    func recordChangeSignal() { lock.withLock { changeSignalCount += 1 } }
}

/// A socket-mode policy the tests swap mid-scenario, standing in for an MDM
/// profile pushed, narrowed, or removed while the app runs.
private final class ManagedSocketModeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = SocketControlModePolicy(forcedRawValue: nil)

    var current: SocketControlModePolicy {
        get { lock.withLock { policy } }
        set { lock.withLock { policy = newValue } }
    }
}
