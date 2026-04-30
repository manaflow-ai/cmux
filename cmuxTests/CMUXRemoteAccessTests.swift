import XCTest
#if canImport(HummingbirdTesting)
import Hummingbird
import HummingbirdTesting
#endif

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CMUXRemoteAccessTests: XCTestCase {
    func testTokenStoreGeneratesPersistsAndRotatesToken() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-token-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileURL = tempDir.appendingPathComponent("remote-token", isDirectory: false)
        let first = try RemoteAccessTokenStore.loadOrCreateToken(fileURL: fileURL)
        XCTAssertGreaterThanOrEqual(first.count, 32)
        XCTAssertEqual(try RemoteAccessTokenStore.loadToken(fileURL: fileURL), first)

        let second = try RemoteAccessTokenStore.loadOrCreateToken(fileURL: fileURL)
        XCTAssertEqual(second, first)

        let rotated = try RemoteAccessTokenStore.rotateToken(fileURL: fileURL)
        XCTAssertNotEqual(rotated, first)
        XCTAssertEqual(try RemoteAccessTokenStore.loadToken(fileURL: fileURL), rotated)
    }

    #if canImport(Hummingbird)
    @MainActor
    func testRemoteServerRunnerThrowMarksFailedAndNotRunning() async {
        let probe = RemoteServerLifecycleProbe()
        let port = RemoteAccessSettings.defaultPort
        let server = makeLifecycleServer { port, _, _ in
            await probe.recordRunnerCall(port: port)
            throw RemoteServerLifecycleError.runnerFailed
        }

        server.start(port: port)

        await waitForRemoteServer(server, matching: { isFailed($0, port: port, message: RemoteServerLifecycleError.runnerFailed.localizedDescription) })
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(await probe.runnerCallCount, 1)
    }

    @MainActor
    func testRemoteServerStopFromRunningWaitsForRunnerCompletion() async {
        let probe = RemoteServerLifecycleProbe()
        let port = RemoteAccessSettings.defaultPort
        let server = makeLifecycleServer { port, _, onRunning in
            try await probe.runBlockingFirstRunnerUntilShutdownReleased(port: port, onRunning: onRunning)
        }

        server.start(port: port)

        await waitForRemoteServer(server, matching: { isRunning($0, port: port) })
        XCTAssertTrue(server.isRunning)

        server.stop()
        await probe.waitForCancellationObservedCount(1)

        XCTAssertTrue(isStopping(server.state, port: port))
        XCTAssertFalse(isStopped(server.state))
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(await probe.runnerCallCount, 1)

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(isStopping(server.state, port: port))
        XCTAssertFalse(isStopped(server.state))

        await probe.releaseShutdown()
        await waitForRemoteServer(server, matching: { isStopped($0) })
    }

    @MainActor
    func testRemoteServerTokenBootstrapFailureMarksFailedAndDoesNotInvokeRunner() async {
        let probe = RemoteServerLifecycleProbe()
        let port = RemoteAccessSettings.defaultPort
        let server = makeLifecycleServer(
            tokenBootstrap: { throw RemoteServerLifecycleError.tokenBootstrapFailed },
            runner: { port, _, _ in
                await probe.recordRunnerCall(port: port)
            }
        )

        server.start(port: port)

        XCTAssertTrue(isFailed(server.state, port: port, message: RemoteServerLifecycleError.tokenBootstrapFailed.localizedDescription))
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(await probe.runnerCallCount, 0)
    }

    @MainActor
    func testRemoteServerStartDuringBlockedShutdownRestartsAfterFirstRunnerReturns() async {
        let probe = RemoteServerLifecycleProbe()
        let firstPort = RemoteAccessSettings.defaultPort
        let secondPort = RemoteAccessSettings.defaultPort + 1
        let server = makeLifecycleServer { port, _, onRunning in
            try await probe.runBlockingFirstRunnerUntilShutdownReleased(port: port, onRunning: onRunning)
        }

        server.start(port: firstPort)
        await probe.waitForRunnerCallCount(1)
        await waitForRemoteServer(server, matching: { isRunning($0, port: firstPort) })

        server.start(port: secondPort)
        await probe.waitForCancellationObservedCount(1)

        XCTAssertTrue(isRestarting(server.state, fromPort: firstPort, toPort: secondPort))
        XCTAssertFalse(server.isRunning)
        XCTAssertEqual(await probe.runnerCallCount, 1)
        XCTAssertEqual(await probe.runnerPorts, [firstPort])

        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(await probe.runnerCallCount, 1)
        XCTAssertTrue(isRestarting(server.state, fromPort: firstPort, toPort: secondPort))

        await probe.releaseShutdown()
        await probe.waitForRunnerCallCount(2)
        await waitForRemoteServer(server, matching: { isRunning($0, port: secondPort) })

        XCTAssertFalse(await probe.secondRunnerStartedBeforeFirstRunnerReturn)
        XCTAssertTrue(server.isRunning)
        XCTAssertEqual(await probe.runnerCallCount, 2)
        XCTAssertEqual(await probe.runnerPorts, [firstPort, secondPort])

        server.stop()
        await waitForRemoteServer(server, matching: { isStopped($0) })
    }
    #endif

    func testTokenStoreErrorDescriptionsAreUserReadable() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-token-error-tests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = tempDir.appendingPathComponent("remote-token", isDirectory: false)

        do {
            try RemoteAccessTokenStore.saveToken("short", fileURL: fileURL)
            XCTFail("Expected malformed token save to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Remote access token is empty or malformed.")
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }

    func testTokenVerificationRejectsMissingMalformedAndWrongTokens() throws {
        let expected = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"

        XCTAssertTrue(RemoteAccessTokenStore.verify(candidate: expected, expected: expected))
        XCTAssertFalse(RemoteAccessTokenStore.verify(candidate: "", expected: expected))
        XCTAssertFalse(RemoteAccessTokenStore.verify(candidate: "short", expected: expected))
        XCTAssertFalse(RemoteAccessTokenStore.verify(candidate: "\(expected)!", expected: expected))
        XCTAssertFalse(RemoteAccessTokenStore.verify(candidate: "abcdefghijklmnopqrstuvwxyzABCDEF1234567891", expected: expected))

        let overlongAllowedToken = String(repeating: "A", count: 4096)
        XCTAssertFalse(RemoteAccessTokenStore.verify(candidate: overlongAllowedToken, expected: expected))
    }

    func testRPCRejectsMissingAndBadToken() async {
        let handler = makeHandler(expectedToken: "abcdefghijklmnopqrstuvwxyzABCDEF1234567890")
        let body = Data(#"{"id":"req-1","method":"system.ping","params":{}}"#.utf8)

        let missing = await handler.handle(body: body, authorizationHeader: nil)
        XCTAssertEqual(missing.statusCode, 401)
        XCTAssertTrue(missing.body.contains(#""code":"unauthorized""#))

        let bad = await handler.handle(body: body, authorizationHeader: "Bearer wrongabcdefghijklmnopqrstuvwxyz123456")
        XCTAssertEqual(bad.statusCode, 401)
        XCTAssertTrue(bad.body.contains(#""id":"req-1""#))
    }

    func testRPCRejectsOverlongBearerTokenAndDoesNotDispatch() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let overlongAllowedToken = String(repeating: "A", count: 4096)
        nonisolated(unsafe) var didDispatch = false
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { _ in
                didDispatch = true
                return #"{"ok":false}"#
            }
        )

        let response = await handler.handle(
            body: Data(#"{"id":"req-overlong","method":"system.ping","params":{}}"#.utf8),
            authorizationHeader: "Bearer \(overlongAllowedToken)"
        )

        XCTAssertEqual(response.statusCode, 401)
        XCTAssertTrue(response.body.contains(#""code":"unauthorized""#))
        XCTAssertTrue(response.body.contains(#""id":"req-overlong""#))
        XCTAssertFalse(didDispatch)
    }

    func testRPCRejectsInvalidJSONWithValidToken() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)

        let response = await handler.handle(
            body: Data("{".utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 400)
        XCTAssertTrue(response.body.contains(#""code":"parse_error""#))
    }

    func testRPCRejectsDisallowedMethod() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)

        let response = await handler.handle(
            body: Data(#"{"id":"req-2","method":"debug.type","params":{}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 403)
        XCTAssertTrue(response.body.contains(#""code":"method_not_allowed""#))
        XCTAssertTrue(response.body.contains(#""id":"req-2""#))
    }

    func testRPCForwardsAllowedMethodAndPreservesResponseShape() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        nonisolated(unsafe) var forwardedLine: String?
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { line in
                forwardedLine = line
                return #"{"id":"req-3","ok":true,"result":{"pong":true}}"#
            }
        )

        let response = await handler.handle(
            body: Data(#"{"id":"req-3","method":"system.ping","params":{}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, #"{"id":"req-3","ok":true,"result":{"pong":true}}"#)
        XCTAssertNotNil(forwardedLine)
        XCTAssertTrue(forwardedLine?.contains(#""method":"system.ping""#) == true)
    }

    func testRPCDefaultsMissingParamsToObject() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        nonisolated(unsafe) var forwardedLine: String?
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { line in
                forwardedLine = line
                return #"{"id":null,"ok":true,"result":{"pong":true}}"#
            }
        )

        let response = await handler.handle(
            body: Data(#"{"method":"system.ping"}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(forwardedLine?.contains(#""params":{}"#) == true)
    }

    func testRPCCapabilitiesAreRemoteSpecificAndDoNotDispatch() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        nonisolated(unsafe) var didDispatch = false
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { _ in
                didDispatch = true
                return #"{"ok":false}"#
            }
        )

        let response = await handler.handle(
            body: Data(#"{"id":"req-4","method":"system.capabilities","params":{}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertFalse(didDispatch)

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(response.body.utf8)) as? [String: Any])
        XCTAssertEqual(object["id"] as? String, "req-4")
        XCTAssertEqual(object["ok"] as? Bool, true)

        let result = try XCTUnwrap(object["result"] as? [String: Any])
        XCTAssertEqual(result["protocol"] as? String, "cmux-remote-http")
        XCTAssertEqual(result["version"] as? Int, 1)

        let methods = try XCTUnwrap(result["methods"] as? [String])
        XCTAssertEqual(methods, CMUXRemoteRPCHandler.remoteAllowedMethods)
        XCTAssertFalse(methods.contains("auth.login"))
        XCTAssertFalse(methods.contains("vm.create"))
        XCTAssertFalse(methods.contains("window.focus"))
        XCTAssertFalse(methods.contains("debug.type"))
    }

    #if canImport(HummingbirdTesting)
    func testRPCPreflightReturnsCORSHeadersForBrowserClients() async throws {
        let handler = makeHandler(expectedToken: "abcdefghijklmnopqrstuvwxyzABCDEF1234567890")
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/rpc",
                method: .options,
                headers: [.origin: "http://localhost:5173"]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
                XCTAssertEqual(response.headers[.accessControlMaxAge], "600")
                XCTAssertTrue(response.headers[.accessControlAllowHeaders]?.contains("authorization") == true)
                XCTAssertTrue(response.headers[.accessControlAllowHeaders]?.contains("content-type") == true)
                XCTAssertTrue(response.headers[.accessControlAllowMethods]?.contains("POST") == true)
                XCTAssertTrue(response.headers[.accessControlAllowMethods]?.contains("OPTIONS") == true)
            }
        }
    }

    func testRPCPostAddsCORSHeadersToAuthenticatedAndErrorResponses() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let overlongAllowedToken = String(repeating: "A", count: 4096)
        nonisolated(unsafe) var didDispatchOverlongToken = false
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { line in
                if line.contains(#""id":"req-7""#) {
                    didDispatchOverlongToken = true
                }
                return #"{"id":"req-5","ok":true,"result":{"pong":true}}"#
            }
        )
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/rpc",
                method: .post,
                headers: [
                    .origin: "http://localhost:5173",
                    .authorization: "Bearer \(token)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"id":"req-5","method":"system.ping","params":{}}"#)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
            }

            try await client.execute(
                uri: "/rpc",
                method: .post,
                headers: [
                    .origin: "http://localhost:5173",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"id":"req-6","method":"system.ping","params":{}}"#)
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
            }

            try await client.execute(
                uri: "/rpc",
                method: .post,
                headers: [
                    .origin: "http://localhost:5173",
                    .authorization: "Bearer \(overlongAllowedToken)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"id":"req-7","method":"system.ping","params":{}}"#)
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
                XCTAssertFalse(didDispatchOverlongToken)
            }
        }
    }
    #endif

    private func makeHandler(expectedToken: String) -> CMUXRemoteRPCHandler {
        CMUXRemoteRPCHandler(
            loadToken: { expectedToken },
            dispatch: { _ in
                XCTFail("Dispatcher should not be called")
                return #"{"ok":false}"#
            }
        )
    }

    #if canImport(Hummingbird)
    @MainActor
    private func makeLifecycleServer(
        tokenBootstrap: @escaping CMUXRemoteServer.TokenBootstrap = {},
        runner: @escaping CMUXRemoteServer.ApplicationRunner
    ) -> CMUXRemoteServer {
        CMUXRemoteServer(
            tokenBootstrap: tokenBootstrap,
            runApplication: runner
        )
    }

    @MainActor
    private func waitForRemoteServer(
        _ server: CMUXRemoteServer,
        matching predicate: (RemoteAccessServerState) -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if predicate(server.state) {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for remote server state. Current state: \(server.state)", file: file, line: line)
    }

    private func isStopped(_ state: RemoteAccessServerState) -> Bool {
        if case .stopped = state {
            return true
        }
        return false
    }

    private func isRunning(_ state: RemoteAccessServerState) -> Bool {
        if case .running = state {
            return true
        }
        return false
    }

    private func isRunning(_ state: RemoteAccessServerState, port expectedPort: Int) -> Bool {
        if case .running(let port) = state {
            return port == expectedPort
        }
        return false
    }

    private func isStopping(_ state: RemoteAccessServerState, port expectedPort: Int) -> Bool {
        if case .stopping(let port) = state {
            return port == expectedPort
        }
        return false
    }

    private func isRestarting(_ state: RemoteAccessServerState, fromPort expectedFromPort: Int, toPort expectedToPort: Int) -> Bool {
        if case .restarting(let fromPort, let toPort) = state {
            return fromPort == expectedFromPort && toPort == expectedToPort
        }
        return false
    }

    private func isFailed(_ state: RemoteAccessServerState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    private func isFailed(_ state: RemoteAccessServerState, port expectedPort: Int, message expectedMessage: String) -> Bool {
        if case .failed(let port, let message) = state {
            return port == expectedPort && message == expectedMessage
        }
        return false
    }
    #endif
}

#if canImport(Hummingbird)
private enum RemoteServerLifecycleError: LocalizedError {
    case runnerFailed
    case tokenBootstrapFailed

    var errorDescription: String? {
        switch self {
        case .runnerFailed:
            return "Remote server runner failed."
        case .tokenBootstrapFailed:
            return "Remote access token bootstrap failed."
        }
    }
}

private actor RemoteServerLifecycleProbe {
    private(set) var runnerCallCount = 0
    private(set) var runnerPorts: [Int] = []
    private(set) var secondRunnerStartedBeforeFirstRunnerReturn = false
    private var runnerCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var cancellationObservedCount = 0
    private var cancellationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var shutdownContinuation: CheckedContinuation<Void, Never>?
    private var shutdownReleased = false
    private var firstRunnerReturned = false

    @discardableResult
    func recordRunnerCall(port: Int) -> Int {
        runnerCallCount += 1
        runnerPorts.append(port)
        if runnerCallCount == 2 && !firstRunnerReturned {
            secondRunnerStartedBeforeFirstRunnerReturn = true
        }
        resumeSatisfiedRunnerWaiters()
        return runnerCallCount
    }

    func runBlockingFirstRunnerUntilShutdownReleased(
        port: Int,
        onRunning: @escaping @Sendable () async -> Void
    ) async throws {
        let call = recordRunnerCall(port: port)
        await onRunning()

        await waitUntilRunnerTaskIsCancelled()
        recordCancellationObserved()

        guard call == 1 else {
            return
        }

        await waitForShutdownRelease()
        firstRunnerReturned = true
    }

    func waitForRunnerCallCount(_ count: Int) async {
        if runnerCallCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            runnerCallWaiters.append((count, continuation))
        }
    }

    func waitForCancellationObservedCount(_ count: Int) async {
        if cancellationObservedCount >= count {
            return
        }
        await withCheckedContinuation { continuation in
            cancellationWaiters.append((count, continuation))
        }
    }

    func releaseShutdown() {
        shutdownReleased = true
        shutdownContinuation?.resume()
        shutdownContinuation = nil
    }

    private func waitUntilRunnerTaskIsCancelled() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: 10_000_000)
            } catch is CancellationError {
                break
            } catch {
                break
            }
        }
    }

    private func recordCancellationObserved() {
        cancellationObservedCount += 1
        resumeSatisfiedCancellationWaiters()
    }

    private func waitForShutdownRelease() async {
        if shutdownReleased {
            return
        }
        await withCheckedContinuation { continuation in
            shutdownContinuation = continuation
        }
    }

    private func resumeSatisfiedRunnerWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in runnerCallWaiters {
            if runnerCallCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        runnerCallWaiters = remaining
    }

    private func resumeSatisfiedCancellationWaiters() {
        var remaining: [(Int, CheckedContinuation<Void, Never>)] = []
        for waiter in cancellationWaiters {
            if cancellationObservedCount >= waiter.0 {
                waiter.1.resume()
            } else {
                remaining.append(waiter)
            }
        }
        cancellationWaiters = remaining
    }
}
#endif
