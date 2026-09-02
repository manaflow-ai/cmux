import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The listener Cloud VMs use to reach this Mac exists only while all four
/// facts hold: enabled, signed in, tunnel up, at least one machine.
@Suite
struct VMHostListenerCoordinatorTests {
    private let live = ["100.64.0.1", "fd7a:7570:6c6b::1"]

    @Test
    func listenerIsOnOnlyWhenEveryConditionHolds() {
        #expect(VMHostListenerCoordinator.desiredState(enabled: true, signedIn: true, liveTunnelAddresses: live, machineCount: 1) == .on)
        #expect(VMHostListenerCoordinator.desiredState(enabled: true, signedIn: true, liveTunnelAddresses: live, machineCount: 12) == .on)
    }

    @Test
    func defaultOffAndEveryMissingConditionTurnsItOff() {
        #expect(VMHostListenerCoordinator.desiredState(enabled: false, signedIn: true, liveTunnelAddresses: live, machineCount: 1) == .off(reason: "disabled"))
        #expect(VMHostListenerCoordinator.desiredState(enabled: true, signedIn: false, liveTunnelAddresses: live, machineCount: 1) == .off(reason: "signed_out"))
        #expect(VMHostListenerCoordinator.desiredState(enabled: true, signedIn: true, liveTunnelAddresses: [], machineCount: 1) == .off(reason: "tunnel_down"))
        #expect(VMHostListenerCoordinator.desiredState(enabled: true, signedIn: true, liveTunnelAddresses: live, machineCount: 0) == .off(reason: "no_machines"))
        // Disabled wins over everything else, so the toggle alone is a full off switch.
        #expect(VMHostListenerCoordinator.desiredState(enabled: false, signedIn: false, liveTunnelAddresses: [], machineCount: 0) == .off(reason: "disabled"))
    }

    @Test
    func settingDefaultsToOff() {
        let suite = "cmux-vmhost-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(defaults.object(forKey: VMHostListenerCoordinator.settingsKey) == nil)
        #expect(VMHostListenerCoordinator.settingsKey == "cloud.vmHostNotifications.enabled")
    }

    @Test
    func deliverCommandInstallsDaemonReadableEnvFileAtomically() throws {
        let payload = VMHostListenerCoordinator.envPayload(
            endpoint: "[fd53::2]:41234", token: "abc", workspaceID: "11111111-2222-3333-4444-555555555555"
        )
        #expect(payload == "CMUX_HOST_ENDPOINT=[fd53::2]:41234\nCMUX_HOST_TOKEN=abc\nCMUX_HOST_WORKSPACE_ID=11111111-2222-3333-4444-555555555555\n")
        // Withdrawal keeps the file but empties the endpoint, which the guest reads as "off".
        #expect(VMHostListenerCoordinator.envPayload(endpoint: nil, token: "", workspaceID: nil).hasPrefix("CMUX_HOST_ENDPOINT=\n"))
        let command = VMHostListenerCoordinator.deliverCommand(payload: payload)
        // The daemon drops to the `cmux` user and runs hooks with an empty
        // environment, so the file must be readable by that user.
        #expect(command.hasPrefix("sudo -n sh -c 'umask 022;"))
        #expect(command.contains("chmod 0644 /etc/cmux/host.env.tmp && mv -f /etc/cmux/host.env.tmp /etc/cmux/host.env"))
        // The payload travels base64-encoded so no shell metacharacter in a
        // token or address can escape the quoting.
        let encoded = Data(payload.utf8).base64EncodedString()
        #expect(command.contains(encoded))
        #expect(!command.contains("abc\n"))
    }

    @Test
    func hostForwardHookManifestMatchesTheGuestContract() throws {
        let manifest = VMHostForwardHook.manifest()
        #expect(manifest["hook_id"] as? String == "cmux_host_forward")
        let exec = manifest["exec"] as? [String: Any]
        #expect(exec?["argv"] as? [String] == ["/usr/local/bin/cmux-tui", "host-forward"])
        let filter = manifest["filter"] as? [String: Any]
        #expect(filter?["kinds"] as? [String] == VMHostForwardHook.forwardedKinds)
        #expect(VMHostForwardHook.forwardedKinds.contains("agent.turn.completed"))
        #expect(manifest["permissions"] as? [String] == ["journal.read"])
        let arguments = CloudTuiCommandLine.putJournalHookArguments(socketPath: "/tmp/link.sock", manifestJSON: VMHostForwardHook.manifestJSON())
        #expect(arguments.prefix(9) == ["--socket", "/tmp/link.sock", "--json", "session", "current", "journal", "hook", "put", "--manifest-json"])
        let decoded = try JSONSerialization.jsonObject(with: Data(arguments[9].utf8)) as? [String: Any]
        #expect(decoded?["manifest_version"] as? Int == 1)
    }

    @Test
    func listenerBindsOnlyTheGivenAddressAndReportsThePeer() async throws {
        let accepted = AcceptRecorder()
        let listener = VMHostListener { socket, peer in
            close(socket)
            accepted.record(peer)
        }
        defer { listener.stop() }
        try listener.start(addresses: ["127.0.0.1"], port: 0)
        let bound = try #require(listener.boundAddresses.first)
        #expect(bound.address == "127.0.0.1")
        #expect(bound.port != 0)

        // Connect over loopback; the accept callback sees the loopback peer.
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = bound.port.bigEndian
        _ = inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(result == 0)
        let peer = await accepted.first(timeout: .seconds(5))
        #expect(peer == "127.0.0.1")

        listener.stop()
        #expect(!listener.isListening)
        #expect(listener.boundAddresses.isEmpty)
    }

    @Test
    func requestLineDropsNothingButIsStableJSON() throws {
        let request = ControlRequest(
            id: .string("r1"),
            method: "notification.create",
            params: ["title": .string("Done"), "workspace_id": .string("11111111-1111-1111-1111-111111111111")]
        )
        let line = try #require(TerminalController.vmHostRequestLine(request))
        let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(object["id"] as? String == "r1")
        #expect(object["method"] as? String == "notification.create")
        #expect((object["params"] as? [String: Any])?["title"] as? String == "Done")
        #expect(!line.contains("\n"))
    }
}

/// Collects peers from the listener's accept callback across threads.
private final class AcceptRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [String] = []
    private var continuation: CheckedContinuation<String, Never>?

    func record(_ peer: String) {
        lock.lock()
        peers.append(peer)
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(returning: peer)
    }

    func first(timeout: Duration) async -> String? {
        lock.lock()
        if let existing = peers.first {
            lock.unlock()
            return existing
        }
        lock.unlock()
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
                    self.lock.lock()
                    if let existing = self.peers.first {
                        self.lock.unlock()
                        continuation.resume(returning: existing)
                        return
                    }
                    self.continuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
