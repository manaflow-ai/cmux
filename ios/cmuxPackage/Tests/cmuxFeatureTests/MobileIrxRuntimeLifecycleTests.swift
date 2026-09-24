import Foundation
import Testing
import CmuxAuthRuntime
import CmuxMobileShellModel
@testable import CmuxIrxTransport
@testable import cmuxFeature

@Suite(.timeLimit(.minutes(1)))
struct MobileIrxRuntimeLifecycleTests {
    @Test
    func endpointReadyPublishesRuntimeChanges() async {
        let composition = await makeComposition()
        let updates = await composition.changes()
        var initial = updates.makeAsyncIterator()
        _ = await initial.next()
        await composition.recordEndpointReady(cached: false)
        let observed = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = updates.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }

        #expect(observed)
    }

    @Test(arguments: [false, true])
    func nextScopeDoesNotWaitForOldSocketClose(signOutHook: Bool) async throws {
        let composition = await makeComposition()
        let previous = scope(generation: 1)
        let next = scope(generation: 2)
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Void>.makeStream()
        let socket = BlockedCloseSocket(started: started.continuation, release: release.stream)
        let device = V2DeviceDescriptor(
            endpointID: String(repeating: "a", count: 64),
            identity: V2Identity(appNamespace: "dev.cmux.tests", buildTag: "test",
                deviceID: "device", environment: "test", projectID: "project",
                teamID: "team", userID: "user"),
            identityGeneration: 1,
            metadata: V2DeviceMetadata(appVersion: "1", capabilities: [], displayName: "Test",
                pairingEnabled: true, platform: .ios, relayURLs: [])
        )
        let control = V2ControlService(
            configuration: try V2ControlConfiguration(baseURL: URL(string: "https://example.test")!, device: device),
            dependencies: V2ControlDependencies(connect: { _ in socket },
                http: { _ in throw V2ControlFailure.stopped }, stackAccessToken: { _ in "test" },
                sign: { _ in Data() }),
            store: V2FileStateStore(rootDirectory: composition.configuration.stateDirectory,
                fileManager: FileManager())
        )
        await control.installLifecycleTestSocket(socket)
        await composition.installLifecycleTestRuntime(scope: previous, control: control)
        // Match the serial auth-scope observer while native cleanup ignores cancellation.
        let transition = Task {
            if signOutHook { await composition.handleSignOut(ifCurrent: previous) }
            else { await composition.activate(nil) }
            await composition.activate(next)
            completed.continuation.yield(())
        }
        let closeStarted = await receivesEvent(started.stream)
        let transitionCompleted = await receivesEvent(completed.stream)
        let activeBeforeRelease = await composition.activeScope
        release.continuation.yield(())
        release.continuation.finish()
        await transition.value
        #expect(closeStarted)
        #expect(transitionCompleted)
        #expect(activeBeforeRelease == next)
        // Late completion of the old teardown must leave the new authority intact.
        #expect(await composition.activeScope == next)
        await composition.handleSignOut(ifCurrent: next)
    }

    private func receivesEvent(_ stream: AsyncStream<Void>) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                return await iterator.next() != nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(1))
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    private func scope(generation: UInt64) -> AuthenticatedTeamScope {
        AuthenticatedTeamScope(session: AuthenticatedSessionIdentity(generation: generation, accountID: "user"),
            teamID: "team", generation: generation)
    }

    @MainActor
    private func makeComposition() -> MobileIrxRuntimeComposition {
        MobileIrxRuntimeComposition(
            configuration: MobileIrohV2Configuration(
                baseURL: URL(string: "https://example.test")!,
                environment: "test",
                projectID: "test-project",
                appNamespace: "dev.cmux.tests",
                buildTag: "test",
                appVersion: "1.0",
                displayName: "Test",
                stateDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent("cmux-iroh-runtime-tests-\(UUID().uuidString)")
            ),
            macListAuthState: MobileMacListAuthState()
        )
    }
}

private struct BlockedCloseSocket: V2ControlSocket {
    let started: AsyncStream<Void>.Continuation
    let release: AsyncStream<Void>
    func send(_ data: Data) async throws {}
    func receive() async throws -> Data { throw V2ControlFailure.stopped }
    func ping() async throws {}
    func close() async {
        started.yield(())
        for await _ in release { return }
    }
}

private extension V2ControlService {
    func installLifecycleTestSocket(_ socket: any V2ControlSocket) { self.socket = socket }
}

private extension MobileIrxRuntimeComposition {
    func installLifecycleTestRuntime(scope: AuthenticatedTeamScope, control: V2ControlService) {
        activeScope = scope
        self.control = control
    }
}
