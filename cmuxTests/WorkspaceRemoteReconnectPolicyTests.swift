import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/5734:
// the SSH remote auto-reconnect loop must stop retrying once the host stays
// unreachable, instead of retrying indefinitely, so the user controls when
// reconnection happens.
@Suite("Workspace remote reconnect policy")
struct WorkspaceRemoteReconnectPolicyTests {
    private func evaluate(
        _ outcome: WorkspaceRemoteHostProbeOutcome,
        previous: Int
    ) -> WorkspaceRemoteReconnectPolicy.Evaluation {
        WorkspaceRemoteReconnectPolicy.evaluate(
            outcome: outcome,
            previousConsecutiveUnreachableProbes: previous
        )
    }

    @Test("Reachable host keeps the existing backoff retry loop")
    func reachableHostKeepsRetrying() {
        for previous in [0, 1, WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes] {
            let evaluation = evaluate(.reachable, previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == 0)
        }
    }

    @Test("Indeterminate probes keep retrying and reset the unreachable streak")
    func indeterminateProbeKeepsRetrying() {
        for previous in [0, 1, WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes] {
            let evaluation = evaluate(.indeterminate, previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == 0)
        }
    }

    @Test("Unreachable probes below the threshold keep retrying")
    func unreachableBelowThresholdKeepsRetrying() {
        for previous in 0..<(WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes - 1) {
            let evaluation = evaluate(.unreachable(reason: "connection refused"), previous: previous)
            #expect(evaluation.decision == .scheduleRetry)
            #expect(evaluation.consecutiveUnreachableProbes == previous + 1)
        }
    }

    @Test("Reconnect loop suspends once the host stays unreachable")
    func suspendsAtUnreachableThreshold() {
        var streak = 0
        var decisions: [WorkspaceRemoteReconnectPolicy.Decision] = []
        for _ in 0..<WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes {
            let evaluation = evaluate(.unreachable(reason: "host timed out"), previous: streak)
            streak = evaluation.consecutiveUnreachableProbes
            decisions.append(evaluation.decision)
        }
        #expect(
            decisions.last == .suspend,
            "The auto-reconnect loop must suspend after \(WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes) consecutive unreachable probes instead of retrying indefinitely."
        )
        #expect(streak == WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes)
    }

    @Test("Suspension persists for further unreachable probes past the threshold")
    func staysSuspendedPastThreshold() {
        let evaluation = evaluate(
            .unreachable(reason: "no route to host"),
            previous: WorkspaceRemoteReconnectPolicy.maxConsecutiveUnreachableProbes
        )
        #expect(evaluation.decision == .suspend)
    }

    @Test("A reachable probe in between resets the unreachable streak")
    func reachableProbeResetsStreak() {
        var streak = 0
        var sawSuspend = false
        let outcomes: [WorkspaceRemoteHostProbeOutcome] = [
            .unreachable(reason: "timeout"),
            .unreachable(reason: "timeout"),
            .reachable,
            .unreachable(reason: "timeout"),
            .unreachable(reason: "timeout"),
        ]
        for outcome in outcomes {
            let evaluation = evaluate(outcome, previous: streak)
            streak = evaluation.consecutiveUnreachableProbes
            if evaluation.decision == .suspend {
                sawSuspend = true
            }
        }
        #expect(!sawSuspend, "Streaks interrupted by a reachable probe must not suspend the loop.")
        #expect(streak == 2)

        let third = evaluate(.unreachable(reason: "timeout"), previous: streak)
        #expect(
            third.decision == .suspend,
            "Once the streak reaches the threshold again the loop must suspend."
        )
    }
}

@Suite("Cloud terminal reconnect overlay policy")
struct CloudTerminalReconnectOverlayPolicyTests {
    @Test("Cloud terminal surfaces show reconnect UI when disconnected")
    func cloudTerminalShowsReconnectWhenDisconnected() {
        let presentation = CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: true,
            connectionState: .disconnected,
            detail: nil
        )

        #expect(presentation?.showsReconnectButton == true)
        #expect(presentation?.showsProgress == false)
    }

    @Test("Cloud terminal surfaces show progress while reconnecting")
    func cloudTerminalShowsProgressWhileReconnecting() {
        let presentation = CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: true,
            connectionState: .reconnecting,
            detail: "Waiting"
        )

        #expect(presentation?.showsReconnectButton == false)
        #expect(presentation?.showsProgress == true)
        #expect(presentation?.detail == "Waiting")
    }

    @Test("Connected Cloud terminal surfaces hide the overlay")
    func connectedCloudTerminalHidesOverlay() {
        let presentation = CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: true,
            connectionState: .connected,
            detail: nil
        )

        #expect(presentation == nil)
    }

    @Test("SSH and non-terminal surfaces never show the Cloud overlay")
    func nonCloudSurfacesHideOverlay() {
        #expect(CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: false,
            isRemoteTerminalSurface: true,
            connectionState: .disconnected,
            detail: nil
        ) == nil)
        #expect(CloudTerminalReconnectOverlayPolicy.presentation(
            isManagedCloudWorkspace: true,
            isRemoteTerminalSurface: false,
            connectionState: .disconnected,
            detail: nil
        ) == nil)
    }
}

@Suite("Workspace remote host reachability probe")
struct WorkspaceRemoteHostReachabilityProbeTests {
    @Test("Parses hostname, port, and proxy fields from ssh -G output")
    func parsesSSHConfigOutput() {
        let output = """
        user nobody
        hostname devbox.internal
        port 2222
        proxyjump bastion@jump.example.com:2200
        addressfamily any
        """
        let resolved = WorkspaceRemoteHostReachabilityProbe.parseSSHConfigOutput(output)
        #expect(resolved.hostName == "devbox.internal")
        #expect(resolved.port == 2222)
        #expect(resolved.proxyJump == "bastion@jump.example.com:2200")
        #expect(resolved.proxyCommand == nil)
    }

    @Test("Treats `proxycommand none` as no proxy")
    func ignoresProxyCommandNone() {
        let resolved = WorkspaceRemoteHostReachabilityProbe.parseSSHConfigOutput(
            "hostname example.com\nport 22\nproxycommand none\n"
        )
        #expect(resolved.proxyCommand == nil)
        #expect(resolved.hostName == "example.com")
    }

    @Test("Parses ProxyJump hop specs")
    func parsesJumpSpecs() {
        let plain = WorkspaceRemoteHostReachabilityProbe.parseJumpSpec("jump.example.com")
        #expect(plain == WorkspaceRemoteHostReachabilityProbe.JumpSpec(
            destination: "jump.example.com", host: "jump.example.com", port: nil
        ))

        let userAndPort = WorkspaceRemoteHostReachabilityProbe.parseJumpSpec("ops@jump.example.com:2200")
        #expect(userAndPort == WorkspaceRemoteHostReachabilityProbe.JumpSpec(
            destination: "ops@jump.example.com", host: "jump.example.com", port: 2200
        ))

        let chained = WorkspaceRemoteHostReachabilityProbe.parseJumpSpec("first.example.com:22,second.example.com")
        #expect(chained?.host == "first.example.com")
        #expect(chained?.port == 22)

        let bracketedV6 = WorkspaceRemoteHostReachabilityProbe.parseJumpSpec("[2001:db8::1]:2200")
        #expect(bracketedV6 == WorkspaceRemoteHostReachabilityProbe.JumpSpec(
            destination: "2001:db8::1", host: "2001:db8::1", port: 2200
        ))

        let bareV6 = WorkspaceRemoteHostReachabilityProbe.parseJumpSpec("2001:db8::1")
        #expect(bareV6?.host == "2001:db8::1")
        #expect(bareV6?.port == nil)
    }

    @Test("ProxyCommand destinations cannot be probed directly")
    func proxyCommandResolvesToNil() {
        // sshConfigFile pins resolution to an empty config so the test stays
        // hermetic against the developer/CI user's ~/.ssh/config.
        let endpoint = WorkspaceRemoteHostReachabilityProbe.resolveEndpoint(
            destination: "nobody@127.0.0.1",
            port: 22,
            identityFile: nil,
            sshOptions: ["ProxyCommand=/usr/bin/nc %h %p"],
            sshConfigFile: "/dev/null"
        )
        #expect(endpoint == nil)
    }

    @Test("Resolves a direct destination's endpoint via ssh -G")
    func resolvesDirectEndpoint() throws {
        let endpoint = WorkspaceRemoteHostReachabilityProbe.resolveEndpoint(
            destination: "nobody@127.0.0.1",
            port: 2222,
            identityFile: nil,
            sshOptions: [],
            sshConfigFile: "/dev/null"
        )
        let resolved = try #require(endpoint)
        #expect(resolved.host == "127.0.0.1")
        #expect(resolved.port == 2222)
    }

    @Test("TCP probe reports a listening endpoint as reachable")
    func tcpProbeReachable() async throws {
        let listener = try BlockingTCPListener()
        defer { listener.close() }
        let outcome = await probeOutcome(host: "127.0.0.1", port: listener.port)
        #expect(outcome == .reachable)
    }

    @Test("TCP probe reports a refused connection as unreachable")
    func tcpProbeRefused() async throws {
        // Bind then close a listener so the port is known-free; the
        // subsequent probe gets an immediate connection refusal.
        let listener = try BlockingTCPListener()
        let refusedPort = listener.port
        listener.close()
        let outcome = await probeOutcome(host: "127.0.0.1", port: refusedPort)
        guard case .unreachable = outcome else {
            Issue.record("Expected .unreachable for a refused port, got \(outcome)")
            return
        }
    }

    private func probeOutcome(host: String, port: Int) async -> WorkspaceRemoteHostProbeOutcome {
        await withCheckedContinuation { continuation in
            WorkspaceRemoteHostReachabilityProbe.probeTCP(
                host: host,
                port: port,
                timeout: 3.0
            ) { outcome in
                continuation.resume(returning: outcome)
            }
        }
    }
}

/// Minimal loopback TCP listener for probe tests.
private final class BlockingTCPListener {
    let port: Int
    private var fd: Int32

    init() throws {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EMFILE) }
        var reuse: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, listen(socketFD, 4) == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(.EADDRINUSE)
        }
        var boundAddr = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(socketFD, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(.EADDRNOTAVAIL)
        }
        fd = socketFD
        port = Int(UInt16(bigEndian: boundAddr.sin_port))
    }

    func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    deinit {
        close()
    }
}
