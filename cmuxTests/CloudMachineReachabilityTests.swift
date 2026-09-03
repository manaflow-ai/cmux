import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The gate that stops a Cloud VM dial from hanging when the WireGuard tunnel
/// is down, and the bounded dial that stops it hanging for any other reason.
///
/// Every test drives the real decision table with injected providers: what the
/// tunnel config says, what the local interfaces hold, whether wg-quick's
/// runtime record exists, what a dial does, and how long the clock allows.
@Suite
struct CloudMachineReachabilityTests {
    /// The tunnel-side address a Cloud VM enrollment hands this Mac.
    private static let tunnelAddress = "10.16.0.2"

    /// A clock with no real time in it, so the bounded dial's race has exactly
    /// one possible winner in every test.
    ///
    /// `.deadlineReached` returns from `sleep` at once, which is how a test
    /// makes the timeout win against a dial that never answers.
    /// `.deadlineNeverReached` never returns, which is how a test makes the
    /// dial's own verdict win. Nothing here waits on wall-clock time, so
    /// neither outcome can flake.
    private struct TestClock: Clock {
        enum Behavior: Sendable {
            case deadlineReached
            case deadlineNeverReached
        }

        struct Instant: InstantProtocol {
            var offset: Duration = .zero
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
        }

        var behavior: Behavior

        var now: Instant { Instant() }
        var minimumResolution: Duration { .zero }

        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            switch behavior {
            case .deadlineReached:
                try Task.checkCancellation()
            case .deadlineNeverReached:
                // Parked until the group cancels it, which is what a real clock
                // does when the dial answers well inside the timeout.
                try await parkUntilCancelled()
            }
        }
    }

    private func gate(
        tunnelUp: Bool,
        interfacePresent: Bool = true,
        deadline: TestClock.Behavior = .deadlineNeverReached,
        dial: @escaping @Sendable (String, Int) async throws -> Void = { _, _ in }
    ) -> CloudMachineReachability {
        CloudMachineReachability(
            tunnelAddresses: { [Self.tunnelAddress] },
            localAddresses: { tunnelUp ? ["192.168.1.20", Self.tunnelAddress] : ["192.168.1.20"] },
            tunnelInterfacePresent: { interfacePresent },
            dial: dial,
            connectTimeout: .seconds(4),
            clock: TestClock(behavior: deadline)
        )
    }

    // MARK: - Route gate

    @Test
    func privateDestinationWithTunnelDownIsRefusedWithoutDialing() async throws {
        let dialed = TestBox(false)
        let reachability = gate(tunnelUp: false, dial: { _, _ in dialed.set(true) })
        await #expect(throws: VMClientError.self) {
            try await reachability.ensureReachable(
                machine: "hopeful-otter",
                urlString: "ws://[fd0b:2b1a:8c4d::5]:1337/v1/link"
            )
        }
        // The point of the gate: no socket is opened at all, so nothing can hang.
        #expect(dialed.get() == false)
    }

    @Test
    func refusedErrorNamesTheMachineAndTheFix() async throws {
        let reachability = gate(tunnelUp: false)
        do {
            try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "ws://[fd0b::5]:1337/v1/link")
            Issue.record("expected the gate to refuse a private destination with the tunnel down")
        } catch let error as VMClientError {
            guard case .tunnelDown(let machine, let address) = error else {
                Issue.record("expected .tunnelDown, got \(error)")
                return
            }
            #expect(machine == "hopeful-otter")
            #expect(address == "fd0b::5")
            #expect(error.isTunnelDown)
            #expect(error.displayMessage.contains("hopeful-otter"))
            #expect(error.displayMessage.contains("cmux vpn up"))
            // The CLI prints `description`, which wraps the same sentence in the
            // "What to do:" shape the other cloud errors use.
            #expect(error.description.contains("What to do:"))
            #expect(error.description.contains("cmux vpn up"))
            #expect(error.description.hasPrefix(error.displayMessage))
        }
    }

    @Test
    func privateDestinationWithTunnelUpPassesTheGate() async throws {
        let dialed = TestBox(false)
        let reachability = gate(tunnelUp: true, dial: { _, _ in dialed.set(true) })
        try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "ws://[fd0b::5]:1337/v1/link")
        #expect(dialed.get() == true)
    }

    @Test
    func publicDestinationIsNeverGatedByTheTunnel() async throws {
        let dialed = TestBox(false)
        let reachability = gate(tunnelUp: false, dial: { _, _ in dialed.set(true) })
        // A public-posture machine needs no tunnel, so a down tunnel must not
        // block it.
        try await reachability.ensureReachable(machine: "public-box", urlString: "ws://203.0.113.7:1337/v1/link")
        #expect(dialed.get() == true)
    }

    @Test
    func anotherEnrollmentsInterfaceDoesNotCountAsUp() async throws {
        // Every enrollment gives this Mac the same tunnel-side address, so the
        // address matching alone is not proof: wg-quick's runtime record for
        // this interface must exist too.
        let reachability = gate(tunnelUp: true, interfacePresent: false)
        await #expect(throws: VMClientError.self) {
            try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "ws://[fd0b::5]:1337/v1/link")
        }
    }

    @Test
    func neverEnrolledMacRefusesAPrivateDestination() async throws {
        let reachability = CloudMachineReachability(
            tunnelAddresses: { [] },
            localAddresses: { ["192.168.1.20"] },
            tunnelInterfacePresent: { true },
            dial: { _, _ in },
            clock: TestClock(behavior: .deadlineNeverReached)
        )
        await #expect(throws: VMClientError.self) {
            try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "ws://[10.16.0.9]:1337/v1/link")
        }
    }

    // MARK: - Bounded dial

    @Test
    func aDestinationThatNeverAnswersFailsAtTheDeadline() async throws {
        let reachability = gate(tunnelUp: true, deadline: .deadlineReached, dial: { _, _ in
            // A never-answering listener: exactly the shape of a dial into a
            // route that silently drops SYNs.
            try await parkUntilCancelled()
        })
        do {
            try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "ws://[fd0b::5]:1337/v1/link")
            Issue.record("expected the bounded dial to fail at the deadline")
        } catch let error as VMClientError {
            guard case .machineUnreachable(let machine, _, let privateNetwork) = error else {
                Issue.record("expected .machineUnreachable, got \(error)")
                return
            }
            #expect(machine == "hopeful-otter")
            #expect(privateNetwork)
            // A private address that stops answering gets the same fix as a
            // down tunnel, because that is what it almost always is.
            #expect(error.isTunnelDown)
            #expect(error.displayMessage.contains("cmux vpn up"))
        }
    }

    @Test
    func publicDestinationTimeoutAsksForAStatusCheckInstead() async throws {
        let reachability = gate(tunnelUp: true, deadline: .deadlineReached, dial: { _, _ in
            try await parkUntilCancelled()
        })
        do {
            try await reachability.ensureReachable(machine: "public-box", urlString: "ws://203.0.113.7:1337/v1/link")
            Issue.record("expected the bounded dial to fail at the deadline")
        } catch let error as VMClientError {
            #expect(error.isTunnelDown == false)
            #expect(error.displayMessage.contains("203.0.113.7"))
            #expect(error.displayMessage.contains("cmux vm status public-box"))
            #expect(error.description.contains("What to do:"))
        }
    }

    @Test
    func aRefusedPortCountsAsReachable() async throws {
        // The address answered: the machine is routable and the daemon on it is
        // simply not listening yet. The transport's own retry loop owns that,
        // and turning it into a tunnel error would be a lie.
        let reachability = gate(tunnelUp: true, dial: { _, _ in
            throw CloudMachineReachability.DialFailure.refused
        })
        try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "ws://[fd0b::5]:1337/v1/link")
    }

    @Test
    func anUnreachableRouteFailsWithTheTunnelFix() async throws {
        let reachability = gate(tunnelUp: true, dial: { _, _ in
            throw CloudMachineReachability.DialFailure.unreachable("ENETUNREACH")
        })
        do {
            try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "ws://[fd0b::5]:1337/v1/link")
            Issue.record("expected an unreachable route to fail")
        } catch let error as VMClientError {
            #expect(error.isTunnelDown)
        }
    }

    @Test
    func aDestinationWithNoPortSkipsTheDialButKeepsTheGate() async throws {
        let dialed = TestBox(false)
        let up = gate(tunnelUp: true, dial: { _, _ in dialed.set(true) })
        try await up.ensureReachable(machine: "hopeful-otter", host: "10.16.0.9", port: nil)
        #expect(dialed.get() == false)

        let down = gate(tunnelUp: false, dial: { _, _ in dialed.set(true) })
        await #expect(throws: VMClientError.self) {
            try await down.ensureReachable(machine: "hopeful-otter", host: "10.16.0.9", port: nil)
        }
    }

    // MARK: - The probe-free gate (browser panes)

    @Test
    func aBrowserPaneOnAPrivatePortIsRefusedWithoutDialing() throws {
        let dialed = TestBox(false)
        let reachability = gate(tunnelUp: false, dial: { _, _ in dialed.set(true) })
        do {
            try reachability.ensureRoutable(
                machine: "hopeful-otter",
                urlString: "http://10.16.0.9:3000/"
            )
            Issue.record("a private port pane must not open while the tunnel is down")
        } catch let error as VMClientError {
            #expect(error.isTunnelDown)
            #expect(error.displayMessage.contains("hopeful-otter"))
            #expect(error.displayMessage.contains("cmux vpn up"))
        }
        #expect(dialed.get() == false)
    }

    @Test
    func aBrowserPaneOnAPrivatePortOpensWhenTheTunnelIsUp() throws {
        let dialed = TestBox(false)
        let reachability = gate(tunnelUp: true, dial: { _, _ in dialed.set(true) })
        try reachability.ensureRoutable(machine: "hopeful-otter", urlString: "http://10.16.0.9:3000/")
        // Even up, the probe-free gate never dials: WebKit does that itself.
        #expect(dialed.get() == false)
    }

    @Test
    func aBrowserPaneOnAMintedPublicEndpointIsNeverGated() throws {
        let reachability = gate(tunnelUp: false)
        try reachability.ensureRoutable(
            machine: "hopeful-otter",
            urlString: "https://preview.cmux.com/p/abc123"
        )
    }

    // MARK: - Destination parsing

    @Test(arguments: [
        ("ws://[fd0b:2b1a:8c4d::5]:1337/v1/link", "fd0b:2b1a:8c4d::5", 1337),
        ("ws://10.16.0.9:1337/v1/link", "10.16.0.9", 1337),
        ("http://10.16.0.9:6901/vnc.html", "10.16.0.9", 6901),
        ("10.16.0.9:22", "10.16.0.9", 22),
    ])
    func destinationIsParsedFromAnythingURLShaped(input: String, host: String, port: Int) {
        let destination = CloudMachineReachability.destination(from: input)
        #expect(destination?.host == host)
        #expect(destination?.port == port)
    }

    @Test
    func aDestinationWithNoHostIsNotGated() async throws {
        #expect(CloudMachineReachability.destination(from: "") == nil)
        // Nothing to classify means nothing to refuse: the transport reports
        // its own failure rather than the gate inventing one.
        let reachability = gate(tunnelUp: false)
        try await reachability.ensureReachable(machine: "hopeful-otter", urlString: "")
    }

    // MARK: - Address classification

    @Test(arguments: [
        "10.16.0.9",            // RFC 1918 10/8, today's Cloud VM posture
        "10.0.0.1",
        "172.16.4.5",           // RFC 1918 172.16/12
        "172.31.255.254",
        "192.168.1.10",         // RFC 1918 192.168/16
        "100.64.0.1",           // CGNAT 100.64/10
        "100.127.255.255",
        "169.254.1.1",          // link-local
        "fd0b:2b1a:8c4d::5",    // ULA fc00::/7, today's Cloud VM IPv6 posture
        "fc00::1",
        "fe80::1",              // IPv6 link-local fe80::/10
        "::ffff:10.16.0.9",     // IPv4-mapped private
        "fd0b::5%utun6",        // zone id
        "[fd0b::5]",            // still bracketed
        "vm-abc.internal",      // the name cmux publishes for a private address
    ])
    func privateDestinationsAreRecognized(host: String) {
        #expect(CloudMachineReachability.isPrivateAddress(host))
    }

    @Test(arguments: [
        "203.0.113.7",          // public
        "8.8.8.8",
        "172.15.0.1",           // just below 172.16/12
        "172.32.0.1",           // just above 172.16/12
        "100.63.255.255",       // just below 100.64/10
        "100.128.0.1",          // just above 100.64/10
        "192.167.1.1",          // adjacent to 192.168/16
        "2606:4700::1111",      // public IPv6
        "127.0.0.1",            // loopback needs no tunnel
        "::1",
        "cmux.com",
        "",
    ])
    func publicDestinationsAreNotGated(host: String) {
        #expect(CloudMachineReachability.isPrivateAddress(host) == false)
    }
}

/// Suspends without consuming wall-clock time until the enclosing task is
/// cancelled, then throws. Stands in for anything that never answers (a route
/// that drops SYNs, a deadline that never arrives) so the bounded dial's race
/// resolves on logic rather than on timing.
private func parkUntilCancelled() async throws -> Never {
    while !Task.isCancelled {
        await Task.yield()
    }
    throw CancellationError()
}

/// What the two failures read like. The CLI prints ``description`` (headline,
/// then a "What to do:" block, the same shape as the not-signed-in error); an
/// app surface renders `localizedDescription`, which is the headline alone.
@Suite
struct CloudTunnelErrorShapeTests {
    @Test
    func theCLIBlockNamesTheMachineTheFixAndTheAddress() {
        let text = String(describing: VMClientError.tunnelDown(machine: "hopeful-otter", address: "10.16.0.9"))
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first?.contains("cmux can't reach hopeful-otter") == true)
        #expect(lines.first?.contains("cmux vpn up") == true)
        #expect(lines.contains("What to do:"))
        #expect(text.contains("  cmux vpn up"))
        #expect(text.contains("  cmux vpn status"))
        #expect(text.contains("10.16.0.9"))
    }

    @Test
    func anAppSurfaceGetsTheHeadlineWithoutTheCLIScaffolding() {
        let error = VMClientError.tunnelDown(machine: "hopeful-otter", address: "10.16.0.9")
        let shown = error.localizedDescription
        #expect(shown == error.displayMessage)
        #expect(shown.contains("cmux can't reach hopeful-otter"))
        #expect(shown.contains("cmux vpn up"))
        #expect(!shown.contains("What to do:"))
        #expect(!shown.contains("\n"))
    }

    @Test
    func aTimeoutOnAPrivateAddressStillBlamesTheTunnel() {
        let error = VMClientError.machineUnreachable(
            machine: "hopeful-otter", address: "10.16.0.9", privateNetwork: true
        )
        #expect(error.isTunnelDown)
        #expect(error.displayMessage.contains("cmux vpn up"))
        #expect(String(describing: error).contains("  cmux vpn up"))
    }

    @Test
    func aTimeoutOnAPublicAddressAsksForAStatusCheckInstead() {
        let error = VMClientError.machineUnreachable(
            machine: "hopeful-otter", address: "203.0.113.7", privateNetwork: false
        )
        #expect(!error.isTunnelDown)
        let text = String(describing: error)
        #expect(text.contains("cmux vm status hopeful-otter"))
        #expect(!text.contains("cmux vpn up"))
        #expect(error.displayMessage.contains("203.0.113.7"))
    }

    /// Every other case keeps the text it had before the two new ones existed:
    /// ``LocalizedError`` conformance routes them through ``description``.
    @Test
    func unrelatedCloudErrorsAreUnchanged() {
        let error = VMClientError.notSignedIn
        #expect(error.localizedDescription == String(describing: error))
        #expect(error.localizedDescription.contains("cmux auth login"))
        #expect(!error.isTunnelDown)
    }
}

/// The one in-app repair for a down tunnel. The command has to be the app's own
/// bundled CLI pointed at its own socket, because each deployment owns a
/// separate WireGuard tunnel and a dev build must not repair the release one.
@Suite
struct CloudTunnelRepairActionTests {
    @Test
    func theRepairRunsTheBundledCLIAgainstThisAppsSocket() throws {
        let argv = try #require(CloudTunnelRepairAction.command(
            cliPath: "/Apps/cmux DEV.app/Contents/Resources/bin/cmux",
            socketPath: "/tmp/cmux-debug-tunfast.sock"
        ))
        #expect(argv == [
            "/Apps/cmux DEV.app/Contents/Resources/bin/cmux",
            "--socket", "/tmp/cmux-debug-tunfast.sock",
            "vpn", "up",
        ])
    }

    @Test
    func theRepairStillRunsWhenTheSocketPathIsUnknown() throws {
        let argv = try #require(CloudTunnelRepairAction.command(cliPath: "/bin/cmux", socketPath: nil))
        #expect(argv == ["/bin/cmux", "vpn", "up"])
        let blank = try #require(CloudTunnelRepairAction.command(cliPath: "/bin/cmux", socketPath: ""))
        #expect(blank == ["/bin/cmux", "vpn", "up"])
    }

    @Test
    func aBuildWithNoBundledCLIOffersNoRepair() {
        #expect(CloudTunnelRepairAction.command(cliPath: nil, socketPath: "/tmp/x.sock") == nil)
    }
}

/// The smallest box that lets a `@Sendable` test closure record that it ran.
private final class TestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
