import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for the local tmux endpoint (`RemoteTmuxHost.local`): the identity
/// invariants that keep it from ever aliasing an SSH endpoint, the argv shapes
/// that run tmux directly, the transport's local no-SSH command path, and — when
/// a tmux binary is installed — a live `tmux -CC` control-mode attach under a
/// locally-allocated PTY against an isolated (`TMUX_TMPDIR`) server, including
/// one sync round-trip in each direction (tmux→cmux and cmux→tmux).
@MainActor
@Suite(.serialized) struct RemoteTmuxLocalEndpointTests {
    // MARK: - Identity

    @Test func localHostIdentityNeverAliasesSSH() throws {
        let local = RemoteTmuxHost.local
        #expect(local.isLocal)
        #expect(local.kind == .local)
        #expect(local.connectionHash == "local")

        // An ssh alias that happens to be named `local` stays a distinct
        // endpoint: its hash is a 16-hex digest, never the literal "local".
        let sshAliasNamedLocal = RemoteTmuxHost(destination: "local")
        #expect(!sshAliasNamedLocal.isLocal)
        #expect(sshAliasNamedLocal.connectionHash != local.connectionHash)
        #expect(sshAliasNamedLocal.connectionHash.count == 16)

        // No ControlMaster socket work for the local endpoint.
        try RemoteTmuxHost.local.ensureControlSocketDirectory()
    }

    @Test func localControlModeInvocationShapes() {
        let create = RemoteTmuxHost.local.localControlModeInvocation(
            sessionName: "my session",
            createIfMissing: true
        )
        #expect(create.first == "/bin/sh")
        #expect(create.suffix(5) == ["-CC", "new-session", "-A", "-s", "my session"])

        let attach = RemoteTmuxHost.local.localControlModeInvocation(
            sessionName: "dev",
            createIfMissing: false
        )
        #expect(attach.first == "/bin/sh")
        #expect(attach.suffix(4) == ["-CC", "attach-session", "-t", "dev"])
    }

    @Test func socketParamsBuildLocalHost() {
        let local = TerminalController.remoteTmuxHost(from: ["local": true])
        #expect(local?.isLocal == true)

        // `local: true` wins over SSH params.
        let both = TerminalController.remoteTmuxHost(from: ["local": true, "host": "dev@example.test"])
        #expect(both?.isLocal == true)

        // A plain string host named "local" is an SSH alias, not the local endpoint.
        let alias = TerminalController.remoteTmuxHost(from: ["host": "local"])
        #expect(alias?.isLocal == false)

        // `local: false` falls through to the required-host validation.
        #expect(TerminalController.remoteTmuxHost(from: ["local": false]) == nil)
    }

    // MARK: - Transport (no tmux required)

    @Test func localTransportRunsCommandsDirectly() async throws {
        let transport = RemoteTmuxSSHTransport(host: .local)
        let result = try await transport.run(["echo", "local-ok"])
        #expect(result.succeeded)
        #expect(result.stdout.contains("local-ok"))

        // The master lifecycle degenerates to a ready no-op locally.
        #expect(try await transport.ensureMasterReady())
    }

    // MARK: - Live control mode (requires an installed tmux)

    /// Whether the tmux resolver finds a usable binary; the live test is a no-op
    /// on machines without tmux instead of a failure.
    private static func tmuxInstalled() -> Bool {
        let argv = RemoteTmuxHost.tmuxLocalInvocation(arguments: ["-V"])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Live end-to-end: create a session on an isolated local server, attach the
    /// control connection under a local PTY, observe the topology arrive
    /// (tmux→cmux), split from both sides, and verify each split lands.
    @Test func localControlModeAttachSyncsBothWays() async throws {
        guard Self.tmuxInstalled() else { return }

        // A SHORT path, deliberately not NSTemporaryDirectory(): tmux binds
        // `$TMUX_TMPDIR/tmux-<uid>/default`, and the sandbox's /var/folders
        // temp root plus a UUID overflows the AF_UNIX 104-byte limit
        // ("File name too long").
        let root = URL(
            fileURLWithPath: "/tmp/cmux-lt-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousTmpdir = getenv("TMUX_TMPDIR").map { String(cString: $0) }
        setenv("TMUX_TMPDIR", root.path, 1)
        // Defers run LIFO: the env restore is registered FIRST so the
        // kill-server below still sees the isolated TMUX_TMPDIR — a kill that
        // ran after the restore would hit the user's real tmux server.
        defer {
            if let previousTmpdir {
                setenv("TMUX_TMPDIR", previousTmpdir, 1)
            } else {
                unsetenv("TMUX_TMPDIR")
            }
            try? FileManager.default.removeItem(at: root)
        }
        defer { Self.runTmuxSynchronously(["kill-server"]) }
        let session = "cmux-local-e2e"
        let transport = RemoteTmuxSSHTransport(host: .local)

        let created = try await transport.runTmux([
            "new-session", "-d", "-s", session, "-x", "120", "-y", "30",
        ])
        try #require(created.succeeded, Comment(rawValue: created.stderr))

        let connection = RemoteTmuxControlConnection(host: .local, sessionName: session)
        defer { connection.stop() }
        try connection.start()

        let connected = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in await connection.waitUntilConnected() }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        try #require(connected, "local tmux -CC control stream never reached %enter")

        // tmux→cmux: the initial topology publishes through the layout pipeline.
        try await waitUntil("initial window topology") {
            !connection.windowsByID.isEmpty
        }
        let windowId = try #require(connection.windowsByID.keys.first)

        // tmux→cmux: an out-of-band split (another client / plain tmux command)
        // must arrive as a layout change with a second pane.
        let split = try await transport.runTmux(["split-window", "-h", "-t", "@\(windowId)"])
        try #require(split.succeeded, Comment(rawValue: split.stderr))
        try await waitUntil("out-of-band split visible in mirror state") {
            (connection.windowsByID[windowId]?.paneIDsInOrder.count ?? 0) == 2
        }

        // cmux→tmux: a split sent on the control stream must land on the server.
        #expect(connection.send("split-window -v -t @\(windowId)"))
        try await waitUntil("control-stream split visible on the server") {
            (connection.windowsByID[windowId]?.paneIDsInOrder.count ?? 0) == 3
        }
        let paneCount = try await transport.runTmux([
            "display-message", "-p", "-t", session + ":", "#{window_panes}",
        ])
        #expect(paneCount.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "3")
    }

    /// Live: creating a session anywhere on the server must reach
    /// `onSessionsChanged` observers on an already-attached control connection —
    /// the notification the controller's session-set reconcile (auto-mirroring
    /// of new sessions) is keyed on.
    @Test func sessionsChangedNotificationReachesObservers() async throws {
        guard Self.tmuxInstalled() else { return }

        let root = URL(
            fileURLWithPath: "/tmp/cmux-lt-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousTmpdir = getenv("TMUX_TMPDIR").map { String(cString: $0) }
        setenv("TMUX_TMPDIR", root.path, 1)
        // LIFO: restore the env AFTER kill-server so the kill targets the
        // isolated server, never the user's real one.
        defer {
            if let previousTmpdir {
                setenv("TMUX_TMPDIR", previousTmpdir, 1)
            } else {
                unsetenv("TMUX_TMPDIR")
            }
            try? FileManager.default.removeItem(at: root)
        }
        defer { Self.runTmuxSynchronously(["kill-server"]) }
        let session = "cmux-local-sesschange"
        let transport = RemoteTmuxSSHTransport(host: .local)

        let created = try await transport.runTmux([
            "new-session", "-d", "-s", session, "-x", "120", "-y", "30",
        ])
        try #require(created.succeeded, Comment(rawValue: created.stderr))

        let connection = RemoteTmuxControlConnection(host: .local, sessionName: session)
        defer { connection.stop() }
        try connection.start()
        let connected = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in await connection.waitUntilConnected() }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        try #require(connected, "local tmux -CC control stream never reached %enter")

        var fired = false
        let token = connection.addObserver(onSessionsChanged: { fired = true })
        defer { connection.removeObserver(token) }

        let sibling = try await transport.runTmux(["new-session", "-d", "-s", session + "-b"])
        try #require(sibling.succeeded, Comment(rawValue: sibling.stderr))
        try await waitUntil("%sessions-changed reaches observers") { fired }
    }

    /// Live: releasing size authority sets tmux's `ignore-size` flag on cmux's
    /// control client (so a co-attached real terminal drives the window size), and
    /// reclaiming clears it. Asserted through `list-clients` — the server's own
    /// view of the flag.
    @Test func sizeAuthorityReleaseTogglesIgnoreSizeFlag() async throws {
        guard Self.tmuxInstalled() else { return }

        let root = URL(
            fileURLWithPath: "/tmp/cmux-lt-\(UUID().uuidString.prefix(8))",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousTmpdir = getenv("TMUX_TMPDIR").map { String(cString: $0) }
        setenv("TMUX_TMPDIR", root.path, 1)
        defer {
            if let previousTmpdir {
                setenv("TMUX_TMPDIR", previousTmpdir, 1)
            } else {
                unsetenv("TMUX_TMPDIR")
            }
            try? FileManager.default.removeItem(at: root)
        }
        defer { Self.runTmuxSynchronously(["kill-server"]) }
        let session = "cmux-local-ignoresize"
        let transport = RemoteTmuxSSHTransport(host: .local)
        let created = try await transport.runTmux([
            "new-session", "-d", "-s", session, "-x", "120", "-y", "30",
        ])
        try #require(created.succeeded, Comment(rawValue: created.stderr))

        let connection = RemoteTmuxControlConnection(host: .local, sessionName: session)
        defer { connection.stop() }
        try connection.start()
        let connected = await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in await connection.waitUntilConnected() }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        try #require(connected, "local tmux -CC control stream never reached %enter")

        func anyClientIgnoresSize() async -> Bool {
            let result = try? await transport.runTmux(["list-clients", "-F", "#{client_flags}"])
            return result?.stdout.contains("ignore-size") ?? false
        }
        func waitForIgnoreSize(_ expected: Bool, _ what: String) async throws {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            while await anyClientIgnoresSize() != expected {
                if clock.now > deadline { Issue.record("timed out waiting for \(what)"); return }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        connection.setSizeAuthorityReleased(true)
        try await waitForIgnoreSize(true, "ignore-size flag set on the control client")

        connection.setSizeAuthorityReleased(false)
        try await waitForIgnoreSize(false, "ignore-size flag cleared on the control client")
    }

    /// Synchronous tmux one-shot for `defer` cleanup (a `defer` cannot await,
    /// and an escaped async cleanup would outlive the test's env restoration).
    /// Inherits the live process environment, TMUX_TMPDIR included.
    private static func runTmuxSynchronously(_ arguments: [String]) {
        let argv = RemoteTmuxHost.tmuxLocalInvocation(arguments: arguments)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    private func waitUntil(
        _ what: String,
        timeoutSeconds: Double = 15,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(timeoutSeconds))
        while !condition() {
            if clock.now > deadline {
                Issue.record("timed out waiting for \(what)")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
