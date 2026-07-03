import XCTest
import Foundation
import Darwin

/// End-to-end gate for remote-tmux mirror sizing, against a REAL tmux server.
///
/// The sizing authority and tmux form a closed loop (rendered grids → client
/// size → tmux's per-pane deal → re-render), and every historical defect in
/// this area was a property of that loop — invisible to open-loop unit tests.
/// This suite drives the real loop end to end and asserts the two invariants
/// that define "settled":
///
///   1. STABILITY: after any disturbance, the client size converges to a
///      single value and stays there (no oscillation, no churn).
///   2. COHERENCE: client == every window's size, and a split window's
///      top-row pane widths + one separator per gap == the window width.
///
/// Hermetic by construction: a throwaway tmux server runs on an isolated
/// socket directory, and the app is launched with
/// `CMUX_REMOTE_TMUX_SSH_FOR_TESTING` pointing at a shim that strips the ssh
/// framing and execs the remote command locally — the full mirror stack runs
/// with no sshd and no network. Skips when no tmux binary is present (CI
/// installs one in the e2e workflow's dependency step).
final class RemoteTmuxSizingUITests: XCTestCase {
    private var socketPath = ""
    private var launchTag = ""
    private var tmuxTmpDir = ""
    private var shimPath = ""
    private var tmuxBin: String?
    private let sessionName = "sizing"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-\(UUID().uuidString).sock"
        launchTag = "ui-tests-sizing-\(UUID().uuidString.prefix(8))"
        tmuxTmpDir = NSTemporaryDirectory() + "cmux-sizing-e2e-\(UUID().uuidString.prefix(8))"
        shimPath = NSTemporaryDirectory() + "cmux-ssh-shim-\(UUID().uuidString.prefix(8)).sh"
        tmuxBin = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        try? FileManager.default.createDirectory(atPath: tmuxTmpDir, withIntermediateDirectories: true)
        writeShim()
    }

    override func tearDown() {
        _ = tmux(["kill-server"])
        try? FileManager.default.removeItem(atPath: shimPath)
        try? FileManager.default.removeItem(atPath: tmuxTmpDir)
        try? FileManager.default.removeItem(atPath: socketPath)
        super.tearDown()
    }

    // MARK: scenarios

    /// Attach a session holding a 3-pane split window plus a single-pane
    /// window; the client must settle to one stable, coherent size.
    func testAttachSettlesStableAndCoherent() throws {
        try requireTmux()
        try buildLabSession()
        let app = launchAppAndAttach()
        defer { app.terminate() }
        try assertSettles(within: 15, context: "after attach")
    }

    /// Resizing the app window (the local trigger) must re-converge at each
    /// width — the sweep that exposes resize feedback loops.
    func testWindowResizeSweepConvergesAtEachWidth() throws {
        try requireTmux()
        try buildLabSession()
        let app = launchAppAndAttach()
        defer { app.terminate() }
        try assertSettles(within: 15, context: "before sweep")

        let window = app.windows.firstMatch
        for dx in [-140.0, 60.0, 45.0] {
            let edge = window.coordinate(withNormalizedOffset: CGVector(dx: 0.999, dy: 0.5))
            edge.press(forDuration: 0.1, thenDragTo: edge.withOffset(CGVector(dx: dx, dy: 0)))
            try assertSettles(within: 10, context: "after resize by \(dx)px")
        }
    }

    /// A geometry-only layout change NOT caused by the app — a co-attached
    /// client's `resize-pane` — must heal (bounded correction), not stick
    /// mismatched and not oscillate.
    func testForeignResizePaneHealsAndHolds() throws {
        try requireTmux()
        try buildLabSession()
        let app = launchAppAndAttach()
        defer { app.terminate() }
        try assertSettles(within: 15, context: "before foreign resize")

        let panes = try splitWindowPaneIds()
        _ = tmux(["resize-pane", "-t", "\(sessionName):@0.\(panes[0])", "-x", "13"])
        try assertSettles(within: 10, context: "after foreign resize-pane")
    }

    // MARK: settle oracle

    /// Polls until STABILITY (8 consecutive identical client samples) and
    /// COHERENCE (client == windows; split panes + separators == window) hold.
    private func assertSettles(within timeout: TimeInterval, context: String) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastFailure = "no samples"
        while Date() < deadline {
            if let failure = settleFailure() {
                lastFailure = failure
                Thread.sleep(forTimeInterval: 0.5)
                continue
            }
            return
        }
        XCTFail("Sizing never settled \(context): \(lastFailure)")
    }

    private func settleFailure() -> String? {
        var samples: [String] = []
        for _ in 0..<8 {
            guard let width = tmux(["list-clients", "-t", sessionName, "-F", "#{client_width}x#{client_height}"])?
                .split(separator: "\n").first.map(String.init) else {
                return "no client attached"
            }
            samples.append(width)
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard Set(samples).count == 1 else {
            return "client size oscillating: \(samples.joined(separator: " "))"
        }
        guard let clientCols = Int(samples[0].split(separator: "x")[0]) else {
            return "unparseable client width \(samples[0])"
        }
        guard let windows = tmux(["list-windows", "-t", sessionName, "-F", "#{window_id} #{window_width}"]) else {
            return "no windows"
        }
        for line in windows.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let w = Int(parts[1]) else { continue }
            if w != clientCols {
                return "window \(parts[0])=\(w) != client \(clientCols)"
            }
        }
        guard let panes = tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_width} #{pane_top}"]) else {
            return "no panes"
        }
        var topRowSum = 0
        var topRowCount = 0
        for line in panes.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let w = Int(parts[0]), parts[1] == "0" else { continue }
            topRowSum += w
            topRowCount += 1
        }
        if topRowCount > 1 {
            let expected = topRowSum + (topRowCount - 1)
            guard let winWidth = windows.split(separator: "\n").first.flatMap({ Int($0.split(separator: " ")[1]) }) else {
                return "no split window width"
            }
            if expected != winWidth {
                return "split panes \(topRowSum)+\(topRowCount - 1)sep=\(expected) != window \(winWidth)"
            }
        }
        return nil
    }

    // MARK: lab plumbing

    private func requireTmux() throws {
        try XCTSkipIf(tmuxBin == nil, "tmux binary not found; e2e workflow installs it via brew")
    }

    private func buildLabSession() throws {
        _ = tmux(["kill-server"])
        XCTAssertNotNil(tmux(["new-session", "-d", "-s", sessionName, "-x", "180", "-y", "45"]))
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["split-window", "-h", "-t", "\(sessionName):0"])
        _ = tmux(["select-layout", "-t", "\(sessionName):0", "even-horizontal"])
        _ = tmux(["new-window", "-t", sessionName])
        _ = tmux(["select-window", "-t", "\(sessionName):0"])
    }

    private func splitWindowPaneIds() throws -> [String] {
        let out = try XCTUnwrap(tmux(["list-panes", "-t", "\(sessionName):@0", "-F", "#{pane_id}"]))
        return out.split(separator: "\n").map(String.init)
    }

    private func launchAppAndAttach() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            "-remoteTmux.beta.enabled", "YES",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launchEnvironment["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"] = shimPath
        // The shim needs the same TMUX_TMPDIR to reach the lab server.
        app.launchEnvironment["TMUX_TMPDIR"] = tmuxTmpDir
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "app failed to reach foreground")
        XCTAssertTrue(waitForSocket(timeout: 12), "control socket never answered at \(socketPath)")
        let response = socketJSON(method: "remote.tmux.attach", params: [
            "host": "e2e-shim-host",
            "session": sessionName,
        ])
        XCTAssertEqual(response?["ok"] as? Bool, true, "remote.tmux.attach failed: \(response ?? [:])")
        return app
    }

    /// The hermetic ssh replacement: drop ssh's option framing and the
    /// destination, then exec the "remote" command locally. The command cmux
    /// builds is `/bin/sh -c <script> cmux-remote-tmux -CC attach ...`, so the
    /// local exec runs the identical tmux control-mode attach against the lab
    /// server (TMUX_TMPDIR is inherited from the app's environment).
    private func writeShim() {
        let shim = """
        #!/bin/bash
        while [ $# -gt 0 ]; do
          case "$1" in
            --) shift; break ;;
            -o|-p|-i|-l|-F) shift 2 ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        shift  # the ssh destination
        exec "$@"
        """
        try? shim.write(toFile: shimPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimPath)
    }

    @discardableResult
    private func tmux(_ args: [String]) -> String? {
        guard let bin = tmuxBin else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["TMUX_TMPDIR"] = tmuxTmpDir
        env.removeValue(forKey: "TMUX")
        proc.environment = env
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: socket plumbing (per-file copy, matching the target's pattern)

    private func waitForSocket(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if socketJSON(method: "system.ping", params: [:])?["ok"] as? Bool == true { return true }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    private func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8),
              let response = sendLine(line),
              let responseData = response.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
    }

    private func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 65, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            for index in 0..<pathBytes.count { raw[index] = pathBytes[index] }
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + pathBytes.count)
        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addrLen) }
        }
        guard connected == 0 else { return nil }
        let payload = Array((line + "\n").utf8)
        let wrote = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return Darwin.write(fd, base, raw.count) == raw.count
        }
        guard wrote else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var accumulator = ""
        let deadline = Date().addingTimeInterval(65)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            if let chunk = String(bytes: buffer[0..<count], encoding: .utf8) {
                accumulator.append(chunk)
                if let newline = accumulator.firstIndex(of: "\n") {
                    return String(accumulator[..<newline])
                }
            }
        }
        return accumulator.isEmpty ? nil : accumulator.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
