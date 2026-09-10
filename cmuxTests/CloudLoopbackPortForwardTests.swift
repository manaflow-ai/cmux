import Foundation
import Network
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A loopback client, a fake hub that speaks the cmux-tui SOCKS5 subset and
/// echoes the tunneled bytes, and the real forward in between. This is the
/// Ports pane's transport end to end, minus WireGuard.
@Suite(.timeLimit(.minutes(2)))
struct CloudLoopbackPortForwardTests {
    /// The hub's SOCKS5 server side (greeting, CONNECT with a literal IP, reply),
    /// then an echo of everything that follows. `replyCode` other than success
    /// refuses the CONNECT the way the hub refuses an unroutable target.
    final class FakeSocksHub: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "cmux.tests.fake-socks-hub")
        private let lock = NSLock()
        private var targets: [CloudPortForwardTarget] = []
        private var _replyCode: UInt8 = SocksV5Client.replySucceeded
        private var _silent = false
        let accepted = CloudLinkFirstValue<Bool>()
        private var _closesAfterReplyHeader = false
        private(set) var port: UInt16 = 0

        var connectTargets: [CloudPortForwardTarget] { lock.withLock { targets } }
        var replyCode: UInt8 {
            get { lock.withLock { _replyCode } }
            set { lock.withLock { _replyCode = newValue } }
        }
        /// Accept the socket and never answer, like a hub that hung.
        var silent: Bool {
            get { lock.withLock { _silent } }
            set { lock.withLock { _silent = newValue } }
        }
        /// Send only the four-byte reply header, then close (a refusal with
        /// no bound address).
        var closesAfterReplyHeader: Bool {
            get { lock.withLock { _closesAfterReplyHeader } }
            set { lock.withLock { _closesAfterReplyHeader = newValue } }
        }
        /// A unix socket path when the hub listens the way the real one does,
        /// else a loopback TCP port.
        private let unixSocketPath: String?
        var endpoint: NWEndpoint {
            if let unixSocketPath { return .unix(path: unixSocketPath) }
            return .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        }

        init(unixSocketPath: String? = nil) throws {
            self.unixSocketPath = unixSocketPath
            let parameters = NWParameters.tcp
            if let unixSocketPath {
                parameters.requiredLocalEndpoint = .unix(path: unixSocketPath)
            } else {
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            }
            listener = try NWListener(using: parameters)
        }

        func start() async throws {
            let bound = CloudLinkFirstValue<UInt16>()
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: bound.resolve(listener.port?.rawValue ?? 0)
                case .failed, .cancelled: bound.resolve(nil)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { await self?.serve(connection) }
            }
            listener.start(queue: queue)
            guard let port = await bound.result, unixSocketPath != nil || port != 0 else {
                throw NSError(domain: "FakeSocksHub", code: 1, userInfo: [NSLocalizedDescriptionKey: "listener did not bind"])
            }
            self.port = port
        }

        func stop() {
            listener.cancel()
            if let unixSocketPath { try? FileManager.default.removeItem(atPath: unixSocketPath) }
        }

        private func serve(_ connection: NWConnection) async {
            do {
                try await connection.startAndWaitUntilReady(queue: queue)
                accepted.resolve(true)
                if silent { return }
                let greeting = try await connection.receiveExactly(3)
                guard greeting == SocksV5Client.greeting else { throw NSError(domain: "FakeSocksHub", code: 2) }
                try await connection.sendAll(Data([SocksV5Client.version, SocksV5Client.methodNoAuthentication]))
                let head = try await connection.receiveExactly(4)
                let addressLength = head[3] == SocksV5Client.addressTypeIPv4 ? 4 : 16
                let rest = try await connection.receiveExactly(addressLength + 2)
                let host: String
                if addressLength == 4 {
                    host = rest.prefix(4).map(String.init).joined(separator: ".")
                } else {
                    host = IPv6Address(Data(rest.prefix(16)))?.debugDescription ?? "?"
                }
                let port = Int(rest[addressLength]) << 8 | Int(rest[addressLength + 1])
                lock.withLock { targets.append(CloudPortForwardTarget(host: host, port: port)) }
                let code = replyCode
                if closesAfterReplyHeader {
                    try await connection.sendAll(Data([SocksV5Client.version, code, 0x00, SocksV5Client.addressTypeIPv4]))
                    connection.cancel()
                    return
                }
                try await connection.sendAll(Data([SocksV5Client.version, code, 0x00, SocksV5Client.addressTypeIPv4, 0, 0, 0, 0, 0, 0]))
                guard code == SocksV5Client.replySucceeded else {
                    connection.cancel()
                    return
                }
                while true {
                    let (data, isComplete) = try await connection.receiveChunk()
                    if let data, !data.isEmpty { try await connection.sendAll(data) }
                    if isComplete {
                        try await connection.finishSending()
                        break
                    }
                }
            } catch {
                connection.cancel()
            }
        }
    }

    /// Counts claims and releases so a test can assert the hub lease follows
    /// each tunneled connection exactly.
    final class FakeHubDialer: CloudHubDialing, @unchecked Sendable {
        struct Unavailable: Error {}
        private let lock = NSLock()
        private var _claims = 0
        private var _releases = 0
        private var _endpoint: NWEndpoint
        var unavailable = false

        init(endpoint: NWEndpoint) { _endpoint = endpoint }

        var claims: Int { lock.withLock { _claims } }
        var releases: Int { lock.withLock { _releases } }
        var endpoint: NWEndpoint {
            get { lock.withLock { _endpoint } }
            set { lock.withLock { _endpoint = newValue } }
        }

        func claimHubSocket() async throws -> CloudHubSocketClaim {
            if unavailable { throw Unavailable() }
            lock.withLock { _claims += 1 }
            return CloudHubSocketClaim(endpoint: endpoint) { [self] in
                lock.withLock { _releases += 1 }
            }
        }
    }

    private static func client(port: UInt16) async throws -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        try await connection.startAndWaitUntilReady(queue: DispatchQueue(label: "cmux.tests.forward-client"))
        return connection
    }

    private static func waitUntil(timeout: Duration = .seconds(10), _ predicate: @Sendable () async -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }

    @Test("bytes sent to the local port come back through the hub from the VM target")
    func relaysBothWays() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let dialer = FakeHubDialer(endpoint: hub.endpoint)
        let target = CloudPortForwardTarget(host: "10.16.179.2", port: 3000)
        let forward = try CloudLoopbackPortForward(target: target, dialer: dialer)
        let localPort = try await forward.start()
        #expect(localPort != 0)
        #expect(await forward.localURLString == "http://127.0.0.1:\(localPort)")
        #expect(dialer.claims == 0, "an idle forward holds no hub lease")

        let client = try await Self.client(port: localPort)
        try await client.sendAll(Data("GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        let echoed = try await client.receiveExactly(16)
        #expect(String(decoding: echoed, as: UTF8.self) == "GET / HTTP/1.1\r\n")
        #expect(hub.connectTargets == [target])
        #expect(dialer.claims == 1)

        try await client.finishSending()
        let (_, isComplete) = try await client.receiveChunk()
        _ = isComplete
        client.cancel()
        #expect(await Self.waitUntil { dialer.releases == 1 }, "the lease is released when the connection ends")
        #expect(await Self.waitUntil { await forward.activeConnectionCount == 0 })
        await forward.stop()
    }

    @Test("an IPv6 private address is forwarded as a literal target")
    func ipv6Target() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let dialer = FakeHubDialer(endpoint: hub.endpoint)
        let target = CloudPortForwardTarget(host: "fd60:1e5e:6720::3", port: 8080)
        let forward = try CloudLoopbackPortForward(target: target, dialer: dialer)
        let localPort = try await forward.start()
        let client = try await Self.client(port: localPort)
        try await client.sendAll(Data("ping".utf8))
        #expect(try await client.receiveExactly(4) == Array("ping".utf8))
        #expect(hub.connectTargets.first?.port == 8080)
        #expect(hub.connectTargets.first?.host.hasPrefix("fd60:1e5e:6720") == true)
        client.cancel()
        await forward.stop()
    }

    @Test("the hub is dialed over its unix socket, the way the real cmux-tui hub listens")
    func unixSocketHub() async throws {
        let path = "/tmp/cmux-hub-test-\(UUID().uuidString.prefix(8)).sock"
        let hub = try FakeSocksHub(unixSocketPath: path)
        try await hub.start()
        defer { hub.stop() }
        let dialer = FakeHubDialer(endpoint: hub.endpoint)
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: 5173)
        let forward = try CloudLoopbackPortForward(target: target, dialer: dialer)
        let localPort = try await forward.start()
        let client = try await Self.client(port: localPort)
        try await client.sendAll(Data("over-unix".utf8))
        #expect(try await client.receiveExactly(9) == Array("over-unix".utf8))
        #expect(hub.connectTargets == [target])
        client.cancel()
        #expect(await Self.waitUntil { dialer.releases == 1 })
        await forward.stop()
    }

    @Test("a refused CONNECT closes the client instead of hanging it")
    func refusedConnectClosesClient() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        hub.replyCode = 0x05
        let dialer = FakeHubDialer(endpoint: hub.endpoint)
        let forward = try CloudLoopbackPortForward(target: CloudPortForwardTarget(host: "10.0.0.7", port: 1), dialer: dialer)
        let localPort = try await forward.start()
        let client = try await Self.client(port: localPort)
        try? await client.sendAll(Data("hello".utf8))
        let ended: Bool
        do {
            let (data, isComplete) = try await client.receiveChunk()
            ended = isComplete && (data?.isEmpty ?? true)
        } catch {
            ended = true
        }
        #expect(ended, "the browser must see the connection end, never wait on a dead forward")
        #expect(await Self.waitUntil { dialer.releases == 1 })
        client.cancel()
        await forward.stop()
    }

    @Test("a hub that cannot start closes the client and is reported by warmUpHub")
    func hubUnavailable() async throws {
        let dialer = FakeHubDialer(endpoint: .hostPort(host: "127.0.0.1", port: 9))
        dialer.unavailable = true
        let forward = try CloudLoopbackPortForward(target: CloudPortForwardTarget(host: "10.0.0.7", port: 80), dialer: dialer)
        let localPort = try await forward.start()
        await #expect(throws: FakeHubDialer.Unavailable.self) { try await forward.warmUpHub() }
        let client = try await Self.client(port: localPort)
        let ended: Bool
        do {
            let (_, isComplete) = try await client.receiveChunk()
            ended = isComplete
        } catch {
            ended = true
        }
        #expect(ended)
        client.cancel()
        await forward.stop()
    }

    @Test("concurrent first uses share one start and every waiter gets the same bookkept forward")
    func concurrentFirstUses() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let forwarder = CloudHubPortForwarder(dialer: FakeHubDialer(endpoint: hub.endpoint))
        let results = await withTaskGroup(of: CloudLoopbackPortForward?.self) { group in
            for _ in 0..<4 {
                group.addTask { try? await forwarder.forward(machineID: "vm-1", to: CloudPortForwardTarget(host: "10.0.0.7", port: 3000)) }
            }
            var collected: [CloudLoopbackPortForward] = []
            for await forward in group {
                if let forward { collected.append(forward) }
            }
            return collected
        }
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0 === results.first })
        #expect(await forwarder.count == 1)
        #expect(await forwarder.localPort(machineID: "vm-1", port: 3000) == results.first?.localPort)
        await forwarder.closeAll()
    }

    @Test("a failed bind does not poison later opens of the same port")
    func failedBindIsRetried() async throws {
        struct BindFailed: Error {}
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let attempts = FakeHubDialer(endpoint: hub.endpoint)
        let failures = NSLock()
        nonisolated(unsafe) var remainingFailures = 1
        let forwarder = CloudHubPortForwarder(dialer: attempts) { target, dialer in
            let failNow = failures.withLock { () -> Bool in
                guard remainingFailures > 0 else { return false }
                remainingFailures -= 1
                return true
            }
            if failNow { throw BindFailed() }
            return try CloudLoopbackPortForward(target: target, dialer: dialer)
        }
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: 3000)
        await #expect(throws: BindFailed.self) {
            try await forwarder.forward(machineID: "vm-1", to: target)
        }
        let forward = try await forwarder.forward(machineID: "vm-1", to: target)
        #expect(await forward.isListening, "the second open binds fresh instead of joining the failed start")
        #expect(await forwarder.count == 1)
        await forwarder.closeAll()
    }

    @Test("a forward whose listener died is torn down and replaced on the next use")
    func deadForwardIsReplaced() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let forwarder = CloudHubPortForwarder(dialer: FakeHubDialer(endpoint: hub.endpoint))
        let target = CloudPortForwardTarget(host: "10.0.0.7", port: 3000)
        let first = try await forwarder.forward(machineID: "vm-1", to: target)
        let deadPort = await first.localPort
        await first.stop()
        #expect(await first.isListening == false)
        let replacement = try await forwarder.forward(machineID: "vm-1", to: target)
        #expect(replacement !== first)
        #expect(await replacement.isListening)
        _ = deadPort
        let client = try await Self.client(port: await replacement.localPort)
        try await client.sendAll(Data("alive".utf8))
        #expect(try await client.receiveExactly(5) == Array("alive".utf8), "the replacement carries traffic")
        client.cancel()
        #expect(await forwarder.count == 1)
        await forwarder.closeAll()
    }

    @Test("a refusal that closes right after the reply header still reports the SOCKS5 reason")
    func refusalWithoutBoundAddress() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        hub.replyCode = 0x05
        hub.closesAfterReplyHeader = true
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: hub.port)!, using: .tcp)
        try await upstream.startAndWaitUntilReady(queue: DispatchQueue(label: "cmux.tests.socks-direct"))
        await #expect(throws: SocksV5Client.ClientError.connectFailed(code: 0x05)) {
            try await CloudPortForwardRelay.connect(upstream, to: CloudPortForwardTarget(host: "10.0.0.7", port: 1))
        }
        upstream.cancel()
    }

    @Test("a hub that accepts and never answers is cut off by the handshake deadline and its claim released")
    func stalledHubIsCutOff() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        hub.silent = true
        let dialer = FakeHubDialer(endpoint: hub.endpoint)
        var relay = CloudPortForwardRelay(dialer: dialer)
        let clock = SidebarTestManualClock()
        relay.clock = clock
        let forward = try CloudLoopbackPortForward(target: CloudPortForwardTarget(host: "10.0.0.7", port: 80), dialer: dialer, relay: relay)
        let localPort = try await forward.start()
        let client = try await Self.client(port: localPort)
        #expect(await hub.accepted.result == true)
        await clock.waitUntilSleeping(for: relay.handshakeTimeout)
        clock.advance(by: relay.handshakeTimeout)
        let ended: Bool
        do {
            let (_, isComplete) = try await client.receiveChunk()
            ended = isComplete
        } catch {
            ended = true
        }
        #expect(ended, "the browser side is closed instead of waiting on a stalled hub")
        #expect(await Self.waitUntil { dialer.claims == 1 && dialer.releases == 1 })
        client.cancel()
        await forward.stop()
    }

    @Test("a provider hands out a loopback URL for a machine with a private address and none without one")
    @MainActor
    func providerLocalURL() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let forwarder = CloudHubPortForwarder(dialer: FakeHubDialer(endpoint: hub.endpoint))
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil })
        func summary(address: String?) -> VMSummary {
            var summary = VMSummary(id: "vm-1", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
            summary.addressIPv4 = address
            return summary
        }
        let addressed = CmuxTuiSurfaceProvider(summary: summary(address: "10.0.0.7"), links: links, catalog: catalog, portForwards: forwarder)
        let url = try #require(try await addressed.localPortURL(port: 3000))
        #expect(url.hasPrefix("http://127.0.0.1:"))
        #expect(try await addressed.portLinkURL(port: 3000) == url, "Copy Link and vm.port_open hand out the pane's loopback URL")
        #expect(await forwarder.localPort(machineID: "vm-1", port: 3000) != nil)

        let unaddressed = CmuxTuiSurfaceProvider(summary: summary(address: nil), links: links, catalog: catalog, portForwards: forwarder)
        #expect(try await unaddressed.localPortURL(port: 3000) == nil, "no private address means the control-plane preview route, not an error")
        await forwarder.closeAll()
    }

    @Test("Copy Link refuses a machine with neither a private address nor preview support")
    @MainActor
    func unsupportedProviderLocalURL() async throws {
        let catalog = SurfaceCatalog()
        let links = CloudMachineLinkManager(clientURL: nil, hub: nil, hostThemeColors: { nil })
        var summary = VMSummary(id: "vm-unsupported", provider: "unknown", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)
        summary.capabilities.ports = false
        let provider = CmuxTuiSurfaceProvider(summary: summary, links: links, catalog: catalog)
        #expect(!provider.capabilities.ports)
        await #expect(throws: (any Error).self) {
            _ = try await provider.localPortURL(port: 3000)
        }
        await #expect(throws: (any Error).self, "no route is an error, never an empty link") {
            _ = try await provider.portLinkURL(port: 3000)
        }
    }

    @Test("one machine port keeps one local port; a new address retargets it; closing frees it")
    func forwarderKeepsStablePorts() async throws {
        let hub = try FakeSocksHub()
        try await hub.start()
        defer { hub.stop() }
        let dialer = FakeHubDialer(endpoint: hub.endpoint)
        let forwarder = CloudHubPortForwarder(dialer: dialer)
        let first = try await forwarder.forward(machineID: "vm-1", to: CloudPortForwardTarget(host: "10.0.0.7", port: 3000))
        let again = try await forwarder.forward(machineID: "vm-1", to: CloudPortForwardTarget(host: "10.0.0.7", port: 3000))
        #expect(first === again)
        let other = try await forwarder.forward(machineID: "vm-1", to: CloudPortForwardTarget(host: "10.0.0.7", port: 3001))
        #expect(await other.localPort != first.localPort)
        #expect(await forwarder.localPort(machineID: "vm-1", port: 3000) == first.localPort)
        #expect(await forwarder.count == 2)

        let moved = try await forwarder.forward(machineID: "vm-1", to: CloudPortForwardTarget(host: "10.0.0.9", port: 3000))
        #expect(moved === first, "a changed private address keeps the local port panes already use")
        let client = try await Self.client(port: await first.localPort)
        try await client.sendAll(Data("x".utf8))
        _ = try await client.receiveExactly(1)
        #expect(hub.connectTargets.last == CloudPortForwardTarget(host: "10.0.0.9", port: 3000))
        client.cancel()

        let freed = await first.localPort
        await forwarder.close(machineID: "vm-1")
        #expect(await forwarder.count == 0)
        #expect(await forwarder.localPort(machineID: "vm-1", port: 3000) == nil)
        let dead = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: freed)!, using: .tcp)
        await #expect(throws: (any Error).self, "the listener is gone once its machine is closed") {
            try await dead.startAndWaitUntilReady(queue: DispatchQueue(label: "cmux.tests.dead-client"))
        }
        dead.cancel()
    }
}
