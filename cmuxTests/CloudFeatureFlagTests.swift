import CmuxCloud
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudFeatureFlagTests {

    #if DEBUG
    @Test("A Debug Cloud override enables the remote-disabled availability observer immediately")
    func dogfoodOverrideReopensCloud() throws {
        let suite = "cmux.cloud.dogfood.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let definition = CmuxFeatureFlags.cloudMachinesFlag
        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in false })
        flags.applyLoadedFlags()
        var transitions: [Bool] = []
        let observer = CloudFeatureAvailabilityObserver(
            isEnabled: { flags.isCloudMachinesEnabled },
            didChange: { transitions.append($0) }
        )
        #expect(transitions == [false])

        flags.setOverride(true, for: definition)
        #expect(flags.isCloudMachinesEnabled)
        #expect(flags.overrideValue(for: definition) == true)
        #expect(transitions == [false, true])

        flags.setOverride(nil, for: definition)
        #expect(!flags.isCloudMachinesEnabled)
        #expect(transitions == [false, true, false])
        withExtendedLifetime(observer) {}
    }
    #endif
    @Test("Agent inbox quick view defaults off")
    func agentInboxQuickViewDefaultsOff() throws {
        let suite = "cmux.agentInbox.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let flags = CmuxFeatureFlags(
            defaults: defaults,
            overrideCapability: .init(bundleIdentifier: "com.cmuxterm.app", isDebugBuild: false),
            remoteFlagValueProvider: { _ in nil }
        )
        flags.applyLoadedFlags()
        #expect(!flags.isAgentInboxQuickViewEnabled)
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "agent-inbox-quick-view-enabled-release" })
        #expect(definition.defaultWhenUnavailable == false)
    }

    @Test("Stable Cloud defaults off and only follows remote values")
    func remoteResolution() throws {
        let suite = "cmux.cloud.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "cloud-machines-enabled-release" })
        #expect(definition.defaultWhenUnavailable == true)
        let unavailableDefault = true
        for remote in [nil, false, true] as [Bool?] {
            defaults.removePersistentDomain(forName: suite)
            let flags = CmuxFeatureFlags(
                defaults: defaults,
                overrideCapability: .init(bundleIdentifier: "com.cmuxterm.app", isDebugBuild: false),
                remoteFlagValueProvider: { _ in remote }
            )
            flags.applyLoadedFlags()
            #expect(flags.effectiveValue(for: definition) == (remote ?? unavailableDefault))
            flags.setOverride(true, for: definition)
            #expect(flags.effectiveValue(for: definition) == (remote ?? unavailableDefault))
            flags.setOverride(false, for: definition)
            #expect(flags.effectiveValue(for: definition) == (remote ?? unavailableDefault))
        }
    }

    @Test("A cancelled keyed operation cannot erase its replacement after re-enable")
    func lateKeyedCompletion() async {
        let center = NotificationCenter()
        let controller = CloudWorkspaceOperationController(isAvailable: { true }, notificationCenter: center)
        let oldStarted = AsyncStream<Void>.makeStream()
        let oldFinished = AsyncStream<Void>.makeStream()
        let newStarted = AsyncStream<Void>.makeStream()
        var oldResume: CheckedContinuation<Void, Never>?
        var newResume: CheckedContinuation<Void, Never>?
        #expect(controller.start(key: "restore") {
            await withCheckedContinuation { continuation in
                oldResume = continuation
                oldStarted.continuation.yield(())
            }
            oldFinished.continuation.yield(())
        })
        var oldStart = oldStarted.stream.makeAsyncIterator()
        _ = await oldStart.next()
        controller.cancelAll()
        #expect(controller.start(key: "restore") {
            await withCheckedContinuation { continuation in
                newResume = continuation
                newStarted.continuation.yield(())
            }
        })
        var newStart = newStarted.stream.makeAsyncIterator()
        _ = await newStart.next()
        oldResume?.resume()
        var oldEnd = oldFinished.stream.makeAsyncIterator()
        _ = await oldEnd.next()
        #expect(controller.start(key: "restore", {}) == false)
        newResume?.resume()
        await controller.waitForPendingOperations()
        #expect(controller.start(key: "restore", {}))
        await controller.waitForPendingOperations()
    }
    @Test("Cloud cached values survive restart and an unavailable payload clears a cached true")
    func cachedResolution() throws {
        let suite = "cmux.cloud.cache.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "cloud-machines-enabled-release" })
        var remote: Bool? = true
        let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in remote })
        flags.applyLoadedFlags()
        let restored = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in nil })
        #expect(restored.effectiveValue(for: definition))
        remote = nil
        flags.applyLoadedFlags()
        let unavailableDefault = true
        #expect(flags.effectiveValue(for: definition) == unavailableDefault)
        restored.applyLoadedFlags()
        #expect(restored.effectiveValue(for: definition) == unavailableDefault)
    }

    @Test("The shared availability observer delivers each remote/activation transition once")
    func availabilityTransitions() {
        let center = NotificationCenter()
        var enabled = false
        var transitions: [Bool] = []
        var observer: CloudFeatureAvailabilityObserver? = CloudFeatureAvailabilityObserver(
            notificationCenter: center,
            isEnabled: { enabled },
            didChange: { transitions.append($0) }
        )
        #expect(transitions == [false])
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        enabled = true
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        center.post(name: RightSidebarBetaFeatureSettings.didChangeNotification, object: nil)
        enabled = false
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        #expect(transitions == [false, true, false])
        withExtendedLifetime(observer) {}
        observer = nil
        enabled = true
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        #expect(transitions == [false, true, false])
    }

    @Test("Cloud tab availability does not depend on the activation marker")
    func tabAvailabilityBeforeActivation() throws {
        let suite = "cmux.cloud.availability.beforeActivation.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudActivationCoordinator.activationKey)
        let policy = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { _, _ in nil })
        #expect(CloudMachinesFeature.isAvailable(policy: policy, remoteEnabled: true))
        #expect(!CloudMachinesFeature.isEnabled(defaults: defaults, policy: policy, remoteEnabled: true))
    }

    @Test("Cloud activation moves from disabled through setup to success once")
    func activationSuccess() async throws {
        let suite = "cmux.cloud.activation.success.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudActivationCoordinator.activationKey)
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var prepareCalls = 0
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            isAvailable: { true },
            prepare: {
                prepareCalls += 1
                started.continuation.yield(())
                await withCheckedContinuation { continuation in release = continuation }
            }
        )

        #expect(coordinator.state == .disabled)
        coordinator.enable()
        #expect(coordinator.state == .enabled)
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        #expect(defaults.bool(forKey: CloudActivationCoordinator.activationKey))
        release?.resume()
        await coordinator.activationTask?.value
        await coordinator.cleanupTask?.value
        #expect(coordinator.state == .enabled)
        #expect(prepareCalls == 1)
        #expect(defaults.bool(forKey: CloudActivationCoordinator.activationKey))
    }

    @Test("Cloud activation exposes a retryable failure and reuses the same setup owner")
    func activationFailureRetry() async throws {
        let suite = "cmux.cloud.activation.retry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudActivationCoordinator.activationKey)
        var prepareCalls = 0
        var cleanupCalls = 0
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            isAvailable: { true },
            prepare: {
                prepareCalls += 1
                if prepareCalls == 1 {
                    throw VMClientError.backendUnreachable(url: "https://cloud.invalid", detail: "fixture")
                }
            },
            cleanup: { cleanupCalls += 1 }
        )

        coordinator.enable()
        await coordinator.activationTask?.value
        await coordinator.cleanupTask?.value
        #expect(coordinator.state == .failed(.serviceUnavailable))
        #expect(!defaults.bool(forKey: CloudActivationCoordinator.activationKey))
        #expect(cleanupCalls == 1)

        coordinator.retry()
        await coordinator.activationTask?.value
        await coordinator.cleanupTask?.value
        #expect(coordinator.state == .enabled)
        #expect(prepareCalls == 2)
    }

    @Test("Cloud activation cancellation is recoverable and unavailable Cloud never starts setup")
    func activationCancellationAndUnavailable() async throws {
        let suite = "cmux.cloud.activation.cancel.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: CloudActivationCoordinator.activationKey)
        let started = AsyncStream<Void>.makeStream()
        var release: CheckedContinuation<Void, Never>?
        var prepareCalls = 0
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            isAvailable: { true },
            prepare: {
                prepareCalls += 1
                started.continuation.yield(())
                await withCheckedContinuation { continuation in release = continuation }
            }
        )
        coordinator.enable()
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        coordinator.cancel()
        release?.resume()
        await coordinator.activationTask?.value
        await coordinator.cleanupTask?.value
        #expect(coordinator.state == .cancelled)
        #expect(!defaults.bool(forKey: CloudActivationCoordinator.activationKey))
        #expect(prepareCalls == 1)

        var unavailableCalls = 0
        let unavailable = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            isAvailable: { false },
            prepare: { unavailableCalls += 1 }
        )
        #expect(unavailable.state == .unavailable)
        unavailable.enable()
        #expect(unavailable.state == .unavailable)
        #expect(unavailableCalls == 0)
    }

    @Test("An existing Cloud activation opens directly without repeating setup")
    func existingActivation() throws {
        let suite = "cmux.cloud.activation.existing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: CloudActivationCoordinator.activationKey)
        var prepareCalls = 0
        let coordinator = CloudActivationCoordinator(
            defaults: defaults,
            notificationCenter: NotificationCenter(),
            isAvailable: { true },
            prepare: { prepareCalls += 1 }
        )

        #expect(coordinator.state == .enabled)
        coordinator.enable()
        #expect(coordinator.state == .enabled)
        #expect(prepareCalls == 0)
    }

    @Test("Closing Cloud ignores late creates without deleting the machine or publishing a result")
    func createSuspensionPreservesMachine() {
        var deletes: [String] = []
        var notices: [MachineCreateNotice] = []
        var cancellations = 0
        var finish: (@MainActor (CloudVMActionLauncher.Completion) -> Void)?
        let coordinator = MachineCreateCoordinator(
            notifier: { notices.append($0) },
            notificationCenter: NotificationCenter(),
            cancelCreatedMachine: { deletes.append($0) }
        )
        let request = MachineCreateRequest(mode: .newMachine, kind: .desktop, name: "fixture", arguments: ["vm", "new"])
        #expect(coordinator.start(request, cancellableLaunch: { _, _, completion in
            finish = completion
            return CloudVMActionLauncher.CancellationHandle { cancellations += 1 }
        }))
        coordinator.cancelAllForAuthTransition(cleanupCreatedMachines: false)
        finish?(CloudVMActionLauncher.Completion(terminationStatus: 0, output: "OK machine=fixture", workspaceId: UUID(), machineId: "fixture"))
        #expect(cancellations == 1)
        #expect(coordinator.operations.isEmpty)
        #expect(coordinator.lastFinished == nil)
        #expect(deletes.isEmpty)
        #expect(notices.isEmpty)
    }

    @Test("A list begun before disable cannot replace saved catalog identities")
    func staleDiscoveryIsDiscarded() async {
        let center = NotificationCenter()
        let catalog = SurfaceCatalog()
        let started = CloudLinkFirstValue<Bool>()
        let released = CloudLinkFirstValue<Bool>()
        var enabled = true
        var block = false
        var lists = 0
        let registry = CmuxTuiSurfaceProviderRegistry(
            links: CloudMachineLinkManager(clientURL: nil, hostThemeColors: { nil }),
            isCloudEnabled: { enabled },
            allowsBackgroundWork: { false },
            listPage: {
                lists += 1
                if block {
                    started.resolve(true)
                    _ = await released.result
                    return VMListPage(vms: [], limits: nil)
                }
                return VMListPage(vms: [VMSummary(id: "saved", provider: "freestyle", status: "running", image: "fixture", createdAt: 0, base: nil)], limits: nil)
            },
            refreshProvider: { _, _ in true },
            closeTransports: {},
            notificationCenter: center
        )
        registry.start(catalog: catalog)
        let original = await registry.providerRefreshingIfMissing(machineID: "saved")
        #expect(original != nil)
        block = true
        let pending = Task { await registry.refresh(force: true) }
        _ = await started.result
        enabled = false
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        released.resolve(true)
        #expect(await pending.value == false)
        #expect(registry.provider(machineID: "saved") === original)
        #expect(catalog.snapshot.machines.map(\.id) == [.cloud("saved")])
        #expect(await registry.providerRefreshingIfMissing(machineID: "other") == nil)
        #expect(lists == 2)
        enabled = true
        block = false
        center.post(name: .cmuxFeatureFlagsDidChange, object: nil)
        #expect(await registry.refresh(force: true))
        #expect(registry.provider(machineID: "saved") === original)
        await registry.accessDidEnd()
    }

}
