import XCTest
#if canImport(HummingbirdTesting)
import Hummingbird
import HummingbirdTesting
import HTTPTypes
#endif

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CMUXRemoteAccessTests: XCTestCase {
    func testRemoteAccessBindModeAndPairingURLHelpers() {
        XCTAssertEqual(RemoteAccessSettings.normalizedBindMode("localhost"), .localhost)
        XCTAssertEqual(RemoteAccessSettings.normalizedBindMode("lan"), .lan)
        XCTAssertEqual(RemoteAccessSettings.normalizedBindMode("invalid"), .localhost)
        XCTAssertEqual(RemoteAccessSettings.bindHost(for: .localhost), "127.0.0.1")
        XCTAssertEqual(RemoteAccessSettings.bindHost(for: .lan), "0.0.0.0")

        let url = RemoteAccessSettings.pairingURLString(
            host: "192.168.1.10",
            port: 8765,
            token: "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        )
        XCTAssertEqual(url, "http://192.168.1.10:8765/remote#token=abcdefghijklmnopqrstuvwxyzABCDEF1234567890")
        XCTAssertFalse(url.contains("?token="))
    }

    func testRemoteAccessLANAddressFilteringPrefersPrivateIPv4() {
        let addresses = RemoteAccessSettings.lanIPv4Addresses(interfaces: [
            .init(name: "lo0", address: "127.0.0.1", isUp: true, isLoopback: true),
            .init(name: "en2", address: "169.254.1.4", isUp: true, isLoopback: false),
            .init(name: "en3", address: "203.0.113.10", isUp: true, isLoopback: false),
            .init(name: "en0", address: "192.168.1.4", isUp: true, isLoopback: false),
            .init(name: "en1", address: "10.0.0.8", isUp: false, isLoopback: false),
        ])

        XCTAssertEqual(addresses, ["192.168.1.4", "203.0.113.10"])
    }

    func testRemoteAccessLANAddressRankingPrefersPhysicalPrivateInterfaces() {
        let addresses = RemoteAccessSettings.lanIPv4Addresses(interfaces: [
            .init(name: "bridge100", address: "192.168.64.1", isUp: true, isLoopback: false),
            .init(name: "utun4", address: "10.7.0.2", isUp: true, isLoopback: false),
            .init(name: "vmnet8", address: "172.16.4.1", isUp: true, isLoopback: false),
            .init(name: "en0", address: "192.168.1.20", isUp: true, isLoopback: false),
            .init(name: "en7", address: "10.0.0.20", isUp: true, isLoopback: false),
            .init(name: "bridge101", address: "192.168.64.1", isUp: true, isLoopback: false),
        ])

        XCTAssertEqual(addresses, [
            "192.168.1.20",
            "10.0.0.20",
            "192.168.64.1",
            "10.7.0.2",
            "172.16.4.1",
        ])
    }

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

        try RemoteAccessTokenStore.deleteToken(fileURL: fileURL)
        XCTAssertNil(try RemoteAccessTokenStore.loadToken(fileURL: fileURL))
    }

    #if canImport(Hummingbird)
    @MainActor
    func testRemoteServerRunnerThrowMarksFailedAndNotRunning() async {
        let probe = RemoteServerLifecycleProbe()
        let port = RemoteAccessSettings.defaultPort
        let server = makeLifecycleServer { _, port, _, _ in
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
        let server = makeLifecycleServer { _, port, _, onRunning in
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
            runner: { _, port, _, _ in
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
        let server = makeLifecycleServer { _, port, _, onRunning in
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

    func testRPCMarksSuccessfulRemoteMutationsForEvents() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { _ in
                #"{"id":"req-mutate","ok":true,"result":{}}"#
            }
        )

        let response = await handler.handle(
            body: Data(#"{"id":"req-mutate","method":"surface.send_text","params":{"text":"pwd"}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.eventReason, .remoteMutation)
    }

    func testRPCForwardsRemoteCreationMethodsAndMarksSuccessfulMutations() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        nonisolated(unsafe) var forwardedLines: [String] = []
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { line in
                forwardedLines.append(line)
                return #"{"id":"req-create","ok":true,"result":{"workspace_id":"workspace-1","surface_id":"surface-1"}}"#
            }
        )

        let workspaceResponse = await handler.handle(
            body: Data(#"{"id":"req-create-workspace","method":"workspace.create","params":{}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )
        let surfaceResponse = await handler.handle(
            body: Data(#"{"id":"req-create-surface","method":"surface.create","params":{"workspace_id":"workspace-1","type":"terminal"}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(workspaceResponse.statusCode, 200)
        XCTAssertEqual(workspaceResponse.eventReason, .remoteMutation)
        XCTAssertEqual(surfaceResponse.statusCode, 200)
        XCTAssertEqual(surfaceResponse.eventReason, .remoteMutation)

        let methods = try forwardedLines.map { line in
            try XCTUnwrap(jsonObject(from: line)["method"] as? String)
        }
        XCTAssertEqual(methods, ["workspace.create", "surface.create"])
    }

    func testRPCForwardsRemoteSurfaceHealthWithoutMutationEvent() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        nonisolated(unsafe) var forwardedLine: String?
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { line in
                forwardedLine = line
                return #"{"id":"req-health","ok":true,"result":{"surfaces":[]}}"#
            }
        )

        let response = await handler.handle(
            body: Data(#"{"id":"req-health","method":"surface.health","params":{"workspace_id":"workspace-1","surface_id":"surface-1"}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.eventReason)
        XCTAssertTrue(forwardedLine?.contains(#""method":"surface.health""#) == true)
    }

    func testRPCDoesNotMarkFailedRemoteMutationsForEvents() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { _ in
                #"{"id":"req-mutate","ok":false,"error":{"code":"workspace_not_found"}}"#
            }
        )

        let response = await handler.handle(
            body: Data(#"{"id":"req-mutate","method":"surface.send_key","params":{"key":"enter"}}"#.utf8),
            authorizationHeader: "Bearer \(token)"
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNil(response.eventReason)
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

    func testSnapshotRejectsMissingAndBadTokenWithoutDispatching() async {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        nonisolated(unsafe) var dispatchCount = 0
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { _ in
                dispatchCount += 1
                return #"{"ok":false}"#
            }
        )

        let missing = await handler.handleSnapshot(authorizationHeader: nil)
        XCTAssertEqual(missing.statusCode, 401)
        XCTAssertTrue(missing.body.contains(#""code":"unauthorized""#))

        let bad = await handler.handleSnapshot(authorizationHeader: "Bearer wrongabcdefghijklmnopqrstuvwxyz123456")
        XCTAssertEqual(bad.statusCode, 401)
        XCTAssertTrue(bad.body.contains(#""code":"unauthorized""#))

        XCTAssertEqual(dispatchCount, 0)
    }

    func testSnapshotDispatchesSystemTreeOnceAndPreservesResponseBody() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let dispatcherBody = #"{"id":"snapshot-1","ok":true,"result":{"windows":[]}}"#
        nonisolated(unsafe) var forwardedLines: [String] = []
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { line in
                forwardedLines.append(line)
                return dispatcherBody
            }
        )

        let response = await handler.handleSnapshot(authorizationHeader: "Bearer \(token)")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.body, dispatcherBody)
        XCTAssertEqual(forwardedLines.count, 1)

        let line = try XCTUnwrap(forwardedLines.first)
        XCTAssertFalse(line.contains("\n"))

        let object = try jsonObject(from: line)
        XCTAssertEqual(object["method"] as? String, "system.tree")
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(params["all_windows"] as? Bool, true)
        XCTAssertEqual(params.count, 1)
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
        XCTAssertTrue(methods.contains("workspace.create"))
        XCTAssertTrue(methods.contains("surface.create"))
        XCTAssertTrue(methods.contains("surface.health"))
        XCTAssertFalse(methods.contains("auth.login"))
        XCTAssertFalse(methods.contains("vm.create"))
        XCTAssertFalse(methods.contains("window.focus"))
        XCTAssertFalse(methods.contains("debug.type"))
    }

    #if canImport(HummingbirdTesting)
    func testRemoteEventHubStreamsHelloAndCoalescedSnapshotChanged() async {
        let hub = CMUXRemoteEventHub(
            configuration: .init(
                coalesceNanoseconds: 1_000_000,
                keepaliveNanoseconds: nil,
                finishAfterInitialFrame: false
            )
        )
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()

        let hello = await iterator.next()
        XCTAssertTrue(hello?.contains("event: hello") == true)
        XCTAssertTrue(hello?.contains("retry: 2000") == true)

        await hub.publishSnapshotChanged(reason: .workspace)
        await hub.publishSnapshotChanged(reason: .surface)

        let event = await iterator.next()
        XCTAssertTrue(event?.contains("event: snapshot_changed") == true)
        XCTAssertTrue(event?.contains(#""workspace""#) == true)
        XCTAssertTrue(event?.contains(#""surface""#) == true)
    }

    func testRemoteEventHubDoesNotRetainFinishedEventSubscribers() async {
        let hub = CMUXRemoteEventHub(
            configuration: .init(
                coalesceNanoseconds: 1_000_000,
                keepaliveNanoseconds: nil,
                finishAfterInitialFrame: true
            )
        )
        let stream = await hub.subscribe()
        var iterator = stream.makeAsyncIterator()

        let hello = await iterator.next()
        XCTAssertTrue(hello?.contains("event: hello") == true)
        XCTAssertNil(await iterator.next())
        XCTAssertEqual(await hub.subscriberCountForTesting(), 0)

        await hub.publishSnapshotChanged(reason: .workspace)
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(await hub.subscriberCountForTesting(), 0)
    }

    func testRemoteStaticHTMLRoutesAreServedWithoutAuthOrDispatch() async throws {
        let probe = RemoteStaticRouteProbe()
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: probe.handler)

        try await app.test(.router) { client in
            for uri in ["/", "/remote"] {
                try await client.execute(uri: uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    assertContentType(response.headers[.contentType], is: "text/html")
                }
            }
        }

        XCTAssertEqual(probe.dispatchCount, 0)
    }

    func testRemoteStaticAssetRoutesAreServedWithExpectedContentTypesWithoutDispatch() async throws {
        let probe = RemoteStaticRouteProbe()
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: probe.handler)

        let routes: [(uri: String, contentType: String)] = [
            ("/remote/assets/app.js", "application/javascript"),
            ("/remote/assets/style.css", "text/css"),
            ("/remote/manifest.webmanifest", "application/manifest+json"),
            ("/remote/icon.svg", "image/svg+xml"),
            ("/remote/icon-maskable.svg", "image/svg+xml"),
        ]

        try await app.test(.router) { client in
            for route in routes {
                try await client.execute(uri: route.uri, method: .get) { response in
                    XCTAssertEqual(response.status, .ok)
                    assertContentType(response.headers[.contentType], is: route.contentType)
                }
            }
        }

        XCTAssertEqual(probe.dispatchCount, 0)
    }

    func testRemoteStringsJSONRouteIsServedWithoutAuthAndContainsCoreLabels() async throws {
        let probe = RemoteStaticRouteProbe()
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: probe.handler)

        try await app.test(.router) { client in
            try await client.execute(uri: "/remote/strings.json", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                assertContentType(response.headers[.contentType], is: "application/json")

                let body = String(buffer: response.body)
                let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])

                XCTAssertFalse((object["appTitle"] as? String)?.isEmpty ?? true)
                XCTAssertFalse((object["connectButton"] as? String)?.isEmpty ?? true)
                XCTAssertFalse((object["noTerminalSelected"] as? String)?.isEmpty ?? true)
            }
        }

        XCTAssertEqual(probe.dispatchCount, 0)
    }

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
                assertCORSHeaderList(response.headers[.accessControlAllowHeaders], includes: ["Authorization", "Content-Type"])
                assertCORSAllowMethods(response.headers[.accessControlAllowMethods], include: ["GET", "POST", "OPTIONS"])
            }
        }
    }

    func testSnapshotPreflightReturnsCORSHeadersForBrowserClients() async throws {
        let handler = makeHandler(expectedToken: "abcdefghijklmnopqrstuvwxyzABCDEF1234567890")
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/snapshot",
                method: .options,
                headers: [.origin: "http://localhost:5173"]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
                XCTAssertEqual(response.headers[.accessControlMaxAge], "600")
                assertCORSHeaderList(response.headers[.accessControlAllowHeaders], includes: ["Authorization"])
                assertCORSAllowMethods(response.headers[.accessControlAllowMethods], include: ["GET", "POST", "OPTIONS"])
            }
        }
    }

    func testEventsRejectMissingAndBadTokens() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)

        try await app.test(.router) { client in
            try await client.execute(uri: "/events", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertTrue(String(buffer: response.body).contains(#""code":"unauthorized""#))
            }

            try await client.execute(uri: "/events?token=wrongabcdefghijklmnopqrstuvwxyz123456", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertTrue(String(buffer: response.body).contains(#""code":"unauthorized""#))
            }
        }
    }

    func testEventsAcceptQueryTokenAndStreamHelloFrame() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)
        let eventHub = CMUXRemoteEventHub(
            configuration: .init(
                coalesceNanoseconds: 1_000_000,
                keepaliveNanoseconds: nil,
                finishAfterInitialFrame: true
            )
        )
        let app = CMUXRemoteServer.makeApplication(
            port: RemoteAccessSettings.defaultPort,
            handler: handler,
            eventHub: eventHub
        )

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/events?token=\(token)",
                method: .get,
                headers: [.origin: "http://localhost:5173"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                assertContentType(response.headers[.contentType], is: "text/event-stream")
                XCTAssertEqual(response.headers[.cacheControl], "no-cache")
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                let body = String(buffer: response.body)
                XCTAssertTrue(body.contains("event: hello"))
                XCTAssertTrue(body.contains(#""ok":true"#))
            }
        }
    }

    func testEventsAcceptAuthorizationHeaderAndStreamHelloFrame() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)
        let eventHub = CMUXRemoteEventHub(
            configuration: .init(
                coalesceNanoseconds: 1_000_000,
                keepaliveNanoseconds: nil,
                finishAfterInitialFrame: true
            )
        )
        let app = CMUXRemoteServer.makeApplication(
            port: RemoteAccessSettings.defaultPort,
            handler: handler,
            eventHub: eventHub
        )

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/events",
                method: .get,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                assertContentType(response.headers[.contentType], is: "text/event-stream")
                XCTAssertTrue(String(buffer: response.body).contains("event: hello"))
            }
        }
    }

    func testEventSessionCookieAuthenticatesEvents() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)
        let eventHub = CMUXRemoteEventHub(
            configuration: .init(
                coalesceNanoseconds: 1_000_000,
                keepaliveNanoseconds: nil,
                finishAfterInitialFrame: true
            )
        )
        let app = CMUXRemoteServer.makeApplication(
            port: RemoteAccessSettings.defaultPort,
            handler: handler,
            eventHub: eventHub
        )
        let setCookieName = HTTPField.Name("Set-Cookie")!

        try await app.test(.router) { client in
            var cookieHeader = ""
            try await client.execute(
                uri: "/events/session",
                method: .post,
                headers: [.authorization: "Bearer \(token)"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                cookieHeader = response.headers[setCookieName] ?? ""
                XCTAssertTrue(cookieHeader.contains(CMUXRemoteRPCHandler.eventCookieName))
                XCTAssertTrue(cookieHeader.contains("HttpOnly"))
                XCTAssertTrue(cookieHeader.contains("SameSite=Strict"))
                XCTAssertTrue(cookieHeader.contains("Max-Age=\(CMUXRemoteRPCHandler.eventCookieMaxAgeSeconds)"))
            }

            try await client.execute(
                uri: "/events",
                method: .get,
                headers: [.cookie: cookieHeader]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                assertContentType(response.headers[.contentType], is: "text/event-stream")
                XCTAssertTrue(String(buffer: response.body).contains("event: hello"))
            }

            try await client.execute(uri: "/events/session", method: .delete) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }

            try await client.execute(
                uri: "/events/session",
                method: .delete,
                headers: [.cookie: cookieHeader]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue((response.headers[setCookieName] ?? "").contains("Max-Age=0"))
            }
        }
    }

    func testLANEventsRejectQueryTokenButAcceptCookie() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)
        let eventHub = CMUXRemoteEventHub(
            configuration: .init(
                coalesceNanoseconds: 1_000_000,
                keepaliveNanoseconds: nil,
                finishAfterInitialFrame: true
            )
        )
        let app = CMUXRemoteServer.makeApplication(
            port: RemoteAccessSettings.defaultPort,
            bindMode: .lan,
            handler: handler,
            eventHub: eventHub
        )

        try await app.test(.router) { client in
            try await client.execute(uri: "/events?token=\(token)", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }

            try await client.execute(
                uri: "/events",
                method: .get,
                headers: [.cookie: "\(CMUXRemoteRPCHandler.eventCookieName)=\(token)"]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(String(buffer: response.body).contains("event: hello"))
            }
        }
    }

    func testRPCAndSnapshotRejectCookieOnlyAuth() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = makeHandler(expectedToken: token)
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)
        let cookie = "\(CMUXRemoteRPCHandler.eventCookieName)=\(token)"

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/rpc",
                method: .post,
                headers: [.cookie: cookie, .contentType: "application/json"],
                body: ByteBuffer(string: #"{"id":"req-cookie","method":"system.ping","params":{}}"#)
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }

            try await client.execute(uri: "/snapshot", method: .get, headers: [.cookie: cookie]) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testEventsPreflightReturnsCORSHeadersForBrowserClients() async throws {
        let handler = makeHandler(expectedToken: "abcdefghijklmnopqrstuvwxyzABCDEF1234567890")
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/events",
                method: .options,
                headers: [.origin: "http://localhost:5173"]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
                XCTAssertEqual(response.headers[.accessControlMaxAge], "600")
                assertCORSHeaderList(response.headers[.accessControlAllowHeaders], includes: ["Authorization"])
                assertCORSAllowMethods(response.headers[.accessControlAllowMethods], include: ["GET", "POST", "OPTIONS"])
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

    func testRPCRejectsOversizedBodyBeforeParsingOrAuth() async throws {
        nonisolated(unsafe) var didLoadToken = false
        nonisolated(unsafe) var didDispatch = false
        let handler = CMUXRemoteRPCHandler(
            loadToken: {
                didLoadToken = true
                return "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
            },
            dispatch: { _ in
                didDispatch = true
                return #"{"ok":false}"#
            }
        )
        let body = Data(repeating: 123, count: CMUXRemoteRPCHandler.maxBodyBytes + 1)

        let response = await handler.handle(body: body, authorizationHeader: nil)
        XCTAssertEqual(response.statusCode, 413)
        XCTAssertTrue(response.body.contains(#""code":"content_too_large""#))
        XCTAssertTrue(response.body.contains(#""id":null"#))
        XCTAssertFalse(didLoadToken)
        XCTAssertFalse(didDispatch)
    }

    func testCORSRejectsUnexpectedOrigins() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { _ in
                #"{"id":"req-cors","ok":true,"result":{"pong":true}}"#
            }
        )
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/rpc",
                method: .options,
                headers: [.origin: "https://evil.example"]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertNil(response.headers[.accessControlAllowOrigin])
                XCTAssertNil(response.headers[.accessControlAllowCredentials])
            }

            try await client.execute(
                uri: "/rpc",
                method: .post,
                headers: [
                    .origin: "https://evil.example",
                    .authorization: "Bearer \(token)",
                    .contentType: "application/json",
                ],
                body: ByteBuffer(string: #"{"id":"req-cors","method":"system.ping","params":{}}"#)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertNil(response.headers[.accessControlAllowOrigin])
                XCTAssertNil(response.headers[.accessControlAllowCredentials])
            }
        }
    }

    func testSnapshotGetAddsCORSHeadersToAuthenticatedAndErrorResponses() async throws {
        let token = "abcdefghijklmnopqrstuvwxyzABCDEF1234567890"
        let handler = CMUXRemoteRPCHandler(
            loadToken: { token },
            dispatch: { _ in
                #"{"id":"snapshot-2","ok":true,"result":{"windows":[]}}"#
            }
        )
        let app = CMUXRemoteServer.makeApplication(port: RemoteAccessSettings.defaultPort, handler: handler)

        try await app.test(.router) { client in
            try await client.execute(
                uri: "/snapshot",
                method: .get,
                headers: [
                    .origin: "http://localhost:5173",
                    .authorization: "Bearer \(token)",
                ]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
            }

            try await client.execute(
                uri: "/snapshot",
                method: .get,
                headers: [.origin: "http://localhost:5173"]
            ) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "http://localhost:5173")
                XCTAssertEqual(response.headers[.accessControlAllowCredentials], "true")
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

    private func jsonObject(from string: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(string.utf8)) as? [String: Any])
    }

    private func assertCORSAllowMethods(
        _ value: String?,
        include expectedMethods: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for method in expectedMethods {
            XCTAssertTrue(value?.contains(method) == true, "Missing \(method) in Access-Control-Allow-Methods", file: file, line: line)
        }
    }

    private func assertCORSHeaderList(
        _ value: String?,
        includes expectedHeaders: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let lowercased = value?.lowercased()
        for header in expectedHeaders {
            XCTAssertTrue(lowercased?.contains(header.lowercased()) == true, "Missing \(header) in Access-Control-Allow-Headers", file: file, line: line)
        }
    }

    private func assertContentType(
        _ value: String?,
        is expectedMediaType: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let mediaType = value?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        XCTAssertEqual(mediaType, expectedMediaType, file: file, line: line)
    }

    private func assertStringDictionary(
        _ object: [String: Any],
        containsAnyKey expectedKeys: [String],
        named label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matchingValue = expectedKeys.compactMap { object[$0] as? String }.first
        XCTAssertTrue(
            matchingValue?.isEmpty == false,
            "Expected \(label) string under one of keys: \(expectedKeys.joined(separator: ", "))",
            file: file,
            line: line
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

#if canImport(HummingbirdTesting)
private final class RemoteStaticRouteProbe: @unchecked Sendable {
    nonisolated(unsafe) private(set) var dispatchCount = 0

    lazy var handler = CMUXRemoteRPCHandler(
        loadToken: { "abcdefghijklmnopqrstuvwxyzABCDEF1234567890" },
        dispatch: { [self] _ in
            dispatchCount += 1
            return #"{"ok":false}"#
        }
    )
}
#endif
