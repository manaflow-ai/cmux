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
    @Test("Cloud defaults off and follows remote values before local overrides")
    func remoteResolution() throws {
        let suite = "cmux.cloud.flag.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let definition = try #require(CmuxFeatureFlags.allFlags.first { $0.key == "cloud-machines-enabled-release" })
        #expect(definition.defaultWhenUnavailable == false)
        for remote in [nil, false, true] as [Bool?] {
            defaults.removePersistentDomain(forName: suite)
            let flags = CmuxFeatureFlags(defaults: defaults, remoteFlagValueProvider: { _ in remote })
            flags.applyLoadedFlags()
            #expect(flags.effectiveValue(for: definition) == (remote ?? false))
            flags.setOverride(true, for: definition)
            #expect(flags.effectiveValue(for: definition) == (remote ?? true))
            flags.setOverride(false, for: definition)
            #expect(flags.effectiveValue(for: definition) == (remote ?? false))
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
}
