import CmuxConversation
import CmuxConversationHost
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct NativeConversationServiceTests {
    @Test func concurrentRequestsShareOneOffMainActorLoad() async throws {
        let fixture = try await CloudRefreshFixture.make()
        defer { fixture.session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ConversationBrokerLoadGate()
        let service = NativeConversationService(auth: fixture.auth, directory: root, loadBroker: { try await gate.load($0) })
        let first = Task { try await service.currentRuntime() }
        let second = Task { try await service.currentRuntime() }
        await gate.waitUntilStarted()
        #expect(!service.hasRuntime)
        await gate.release()
        let a = try await first.value
        let b = try await second.value
        #expect(a.0 === b.0)
        #expect(await gate.loadCount == 1)
        #expect(service.isCurrent(a.1))
        await service.shutdown()
        #expect(!service.hasRuntime)
        await #expect(throws: (any Error).self) { _ = try await service.currentRuntime() }
    }

    @Test func accountChangeCannotPublishAnOlderLoadingRuntime() async throws {
        let fixture = try await CloudRefreshFixture.make(authClient: CloudReadIdentityAuthClient())
        defer { fixture.session.invalidateAndCancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = ConversationBrokerLoadGate()
        let service = NativeConversationService(auth: fixture.auth, directory: root, loadBroker: { try await gate.load($0) })
        let oldRequest = Task { try await service.currentRuntime() }
        await gate.waitUntilStarted()
        try await fixture.auth.signInWithPassword(email: "replacement@example.test", password: "fixture")
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await oldRequest.value }
        let replacement = try await service.currentRuntime()
        #expect(service.isCurrent(replacement.1))
        #expect(replacement.1.accountID == "replacement")
        #expect(await gate.loadCount == 2)
        let directories = await gate.loadedDirectories
        #expect(Set(directories).count == 2)
        await service.shutdown()
    }
}

private actor ConversationBrokerLoadGate {
    private(set) var loadCount = 0
    private(set) var loadedDirectories: [URL] = []
    private var held = true
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func load(_ directory: URL) async throws -> ConversationBroker {
        loadCount += 1
        loadedDirectories.append(directory)
        let started = startWaiters
        startWaiters.removeAll()
        for waiter in started { waiter.resume() }
        if held { await withCheckedContinuation { loadWaiters.append($0) } }
        return try ConversationBroker(directory: directory, adapters: [])
    }

    func waitUntilStarted() async {
        if loadCount > 0 { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release() {
        held = false
        let waiting = loadWaiters
        loadWaiters.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}
