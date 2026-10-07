import CmuxiOSFeatureKit
import CmuxiOSSSHCore
@testable import CmuxiOSSSHWorkspacesCore
import CmuxiOSWorkspacesCore
import CmuxMobileSSH
import CmuxMobileWire
import Foundation
import Testing

/// A runner that answers each discovery with the next scripted result.
actor ScriptedRunner: SSHCommandRunning {
    private var results: [Result<String, SSHSessionFailure>]
    private(set) var commands: [String] = []

    init(_ results: [Result<String, SSHSessionFailure>]) { self.results = results }

    func run(_ command: String, input: String?) async throws -> String {
        commands.append(command)
        let next = results.isEmpty ? .success("") : results.removeFirst()
        return try next.get()
    }
}

/// A shell that records the connector that opened it and ends on demand.
final class EndableShell: SSHShellChannel, @unchecked Sendable {
    let events: AsyncStream<SSHSessionEvent>
    private let continuation: AsyncStream<SSHSessionEvent>.Continuation

    init() { (events, continuation) = AsyncStream.makeStream(of: SSHSessionEvent.self) }

    func end() {
        continuation.yield(.closed)
        continuation.finish()
    }

    func write(_ data: Data) async throws {}
    func resize(cols: Int, rows: Int) async throws {}
    func close() async { continuation.finish() }
}

struct RecordingConnector: SSHShellConnector {
    let shell: EndableShell
    func openShell(cols: Int, rows: Int) async throws -> any SSHShellChannel { shell }
}

actor TargetLog {
    private(set) var targets: [SSHSessionTarget] = []
    func add(_ target: SSHSessionTarget) { targets.append(target) }
}

@Suite struct SSHWorkspacesTests {
    let host = HostID("ssh_box1")
    let reasons = SSHWorkspaceReasons(untrustedKey: "untrusted", needsLogin: "login", unreachable: "down", refused: "refused")
    static let listing = """
    @tmux\t/usr/bin/tmux
    S\twork\t2\t1\t1791331200
    W\twork\t0\t1\tzsh
    W\twork\t1\t0\tlogs
    @screen\t/usr/bin/screen
    \t4242.build\t(Detached)
    """

    func channel(_ runner: ScriptedRunner, catalog: SSHSessionCatalog = SSHSessionCatalog()) -> SSHWorkspaceChannel {
        SSHWorkspaceChannel(hostID: host, catalog: catalog, reasons: reasons, makeRunner: { runner })
    }

    @Test func discoveryBecomesASnapshotTheMirrorReads() async throws {
        let runner = ScriptedRunner([.success(Self.listing)])
        let catalog = SSHSessionCatalog()
        let channel = channel(runner, catalog: catalog)
        var states = await channel.states().makeAsyncIterator()
        #expect(await states.next() == .connecting)
        var updates = await channel.updates().makeAsyncIterator()
        guard case .snapshot(let frame)? = await updates.next() else { Issue.record("no snapshot"); return }
        #expect(frame.stream == "workspace:ssh_box1")
        #expect(await states.next() == .live(path: "ssh", caps: []))
        var mirror = HostWorkspaceMirror()
        try mirror.apply(frame)
        let rows = mirror.summaries(hostID: host)
        #expect(rows.map(\.id) == ["ssh:tmux:work", "ssh:screen:4242.build"])
        #expect(rows[0].group?.name == "tmux")
        #expect(rows[0].panes.first?.surfaces.map(\.terminalID) == ["ssh:tmux:work:0", "ssh:tmux:work:1"])
        #expect(rows[0].panes.first?.surfaces.map(\.title) == ["0: zsh", "1: logs"])
        #expect(rows[1].panes.first?.surfaces.first?.terminalID == "ssh:screen:4242.build")
        #expect(mirror.confirmedGroups.map(\.id) == ["ssh-tmux", "ssh-screen"])
        #expect(await catalog.target(host: host, surfaceID: "ssh:tmux:work:1")?.attachCommand
            == "exec '/usr/bin/tmux' attach-session -t '=work:1'")
        #expect(await runner.commands == ["/bin/sh -s"])
    }

    @Test func opsAreRefusedAndFailuresShowAReason() async throws {
        let runner = ScriptedRunner([.failure(.hostKeyRejected), .success(""), .failure(.network)])
        let channel = channel(runner)
        var states = await channel.states().makeAsyncIterator()
        _ = await states.next()
        var updates = await channel.updates().makeAsyncIterator()
        #expect(await states.next() == .offline(reason: "untrusted"))
        let outcome = try await channel.submit(OpFrame(op: "workspace.close", params: .object(["workspace": "ssh:tmux:work"]),
                                                       idempotencyKey: "close-key-01"))
        guard case .rejected(let reject) = outcome else { Issue.record("not refused"); return }
        #expect(reject.code == "proto.unsupported")
        await channel.requestSnapshot()
        guard case .snapshot(let frame)? = await updates.next() else { Issue.record("no snapshot"); return }
        #expect(frame.seq == 1)
        #expect(await states.next() == .live(path: "ssh", caps: []))
        await channel.requestSnapshot()
        #expect(await states.next() == .offline(reason: "down"))
        await channel.close()
    }

    @Test func aFailedDiscoveryLeavesNothingAttachable() async {
        let catalog = SSHSessionCatalog()
        await catalog.record(SSHSessionDiscovery().parse(Self.listing), for: host)
        let channel = channel(ScriptedRunner([.failure(.network)]), catalog: catalog)
        var states = await channel.states().makeAsyncIterator()
        _ = await states.next()
        _ = await channel.updates()
        #expect(await states.next() == .offline(reason: "down"))
        #expect(await catalog.target(host: host, surfaceID: "ssh:tmux:work") == nil)
        await channel.close()
    }

    @Test func anEndedTerminalRediscoversItsHost() async throws {
        let runner = ScriptedRunner([.success(Self.listing), .success("")])
        let catalog = SSHSessionCatalog()
        let channel = channel(runner, catalog: catalog)
        var updates = await channel.updates().makeAsyncIterator()
        guard case .snapshot(let first)? = await updates.next() else { Issue.record("no snapshot"); return }
        // Other hosts' endings are ignored; this host's trigger one run.
        await catalog.sessionEnded(on: HostID("ssh_other"))
        await catalog.sessionEnded(on: host)
        guard case .snapshot(let second)? = await updates.next() else { Issue.record("no rediscovery"); return }
        #expect(second.seq == first.seq + 1)
        #expect(await runner.commands.count == 2)
        #expect(await catalog.target(host: host, surfaceID: "ssh:tmux:work") == nil)
        await channel.close()
    }

    @Test func attachUsesOnlyCatalogTargets() async throws {
        let catalog = SSHSessionCatalog()
        let log = TargetLog()
        let shell = EndableShell()
        let connector = SSHCatalogAttachConnector(hostID: host, surfaceID: "ssh:tmux:work:1", catalog: catalog) { _, target in
            await log.add(target)
            return RecordingConnector(shell: shell)
        }
        await #expect(throws: SSHSessionFailure.sessionGone) { try await connector.openShell(cols: 80, rows: 24) }
        await catalog.record(SSHSessionDiscovery().parse(Self.listing), for: host)
        var endings = await catalog.endings().makeAsyncIterator()
        let opened = try await connector.openShell(cols: 80, rows: 24)
        #expect(await log.targets.map(\.attachCommand) == ["exec '/usr/bin/tmux' attach-session -t '=work:1'"])
        // A surface id that discovery never listed cannot be attached, even
        // when it looks like one.
        let forged = SSHCatalogAttachConnector(hostID: host, surfaceID: "ssh:tmux:evil;id", catalog: catalog) { _, _ in
            RecordingConnector(shell: shell)
        }
        await #expect(throws: SSHSessionFailure.sessionGone) { try await forged.openShell(cols: 80, rows: 24) }
        var events = opened.events.makeAsyncIterator()
        shell.end()
        while await events.next() != nil {}
        #expect(await endings.next() == host)
    }

    @Test func cmuxTUIAttachUsesTheCurrentCatalogSocketAndRefusesRemovedSessions() async throws {
        let catalog = SSHSessionCatalog()
        let log = TargetLog()
        let shell = EndableShell()
        let connector = SSHCatalogAttachConnector(hostID: host, surfaceID: "ssh:cmux-tui:work", catalog: catalog) { _, target in
            await log.add(target)
            return RecordingConnector(shell: shell)
        }
        let oldPath = "/var/folders/xy/owner/T/cmux-tui-501/work.sock"
        let newPath = "/tmp/cmux-tui-501/work.sock"
        let discovery = SSHSessionDiscovery()
        await catalog.record(discovery.parse("@cmux-tui\t/usr/local/bin/cmux-tui\nC\t\(oldPath)\n"), for: host)
        await catalog.record(discovery.parse("@cmux-tui\t/usr/local/bin/cmux-tui\nC\t\(newPath)\n"), for: host)
        let opened = try await connector.openShell(cols: 80, rows: 24)
        #expect(await log.targets.map(\.attachCommand)
            == ["exec '/usr/local/bin/cmux-tui' attach --socket '\(newPath)'"])
        await opened.close()
        await catalog.record([], for: host)
        await #expect(throws: SSHSessionFailure.sessionGone) { try await connector.openShell(cols: 80, rows: 24) }
        #expect(await log.targets.count == 1)
    }

    @Test func directoryListsOnlySSHRecords() {
        let records = [
            HostRecord(id: HostID("mac1"), name: "Mac", kind: .pairedMac, reachability: .unknown),
            HostRecord(id: host, name: "box", kind: .ssh(endpoint: HostEndpoint(address: "box", user: "u"), jumpHost: nil),
                       reachability: .unknown),
        ]
        #expect(SSHHostDirectory.hosts(in: records) == [WorkspaceHostDescriptor(id: host, name: "box", kind: .ssh)])
    }

    @Test func factoryRoutesByHostKind() async {
        let catalog = SSHSessionCatalog()
        let runner = ScriptedRunner([])
        let other = UnavailableWorkspaceChannelFactory(reason: "nope")
        let factory = SSHWorkspaceChannelFactory(fallback: other, catalog: catalog, reasons: reasons) { _ in { runner } }
        #expect(factory.channel(for: WorkspaceHostDescriptor(id: host, name: "box", kind: .ssh)) is SSHWorkspaceChannel)
        #expect(!(factory.channel(for: WorkspaceHostDescriptor(id: HostID("mac1"), name: "Mac")) is SSHWorkspaceChannel))
    }

    @Test func reasonsCoverEveryFailure() {
        #expect(reasons.text(for: .missingCredentials) == "login")
        #expect(reasons.text(for: .authenticationFailed) == "login")
        #expect(reasons.text(for: .network) == "down")
        #expect(reasons.text(for: .sessionGone) == "refused")
    }
}
