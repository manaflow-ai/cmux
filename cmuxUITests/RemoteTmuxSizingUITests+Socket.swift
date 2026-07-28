import XCTest
import Foundation
import Darwin

extension RemoteTmuxSizingUITests {

    /// Launches the app and waits for its control socket. The app owns the
    /// lab tmux server (built afterward through `remote.tmux.test_exec`), so
    /// launch precedes any tmux call — the sandboxed runner never spawns tmux
    /// itself.
    func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-socketControlMode", "allowAll",
            // Plist-typed bool: the settings decoder accepts only real
            // booleans, so a bare "YES" string via the argument domain never
            // enables the flag.
            "-remoteTmux.beta.enabled", "<true/>",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        // These three actually START the socket listener (matching the
        // passing browser/automation UITests); without them the app never
        // binds CMUX_SOCKET_PATH and every socket call times out.
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_ENABLE"] = "1"
        app.launchEnvironment["CMUX_SOCKET_MODE"] = "allowAll"
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_DIAGNOSTICS_PATH"] = diagnosticsPath
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_ALLOW_SOCKET_OVERRIDE"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        // The ssh shim (checked into the repo) and the app's own tmux commands
        // both use this TMUX_TMPDIR to reach the one lab server.
        app.launchEnvironment["CMUX_REMOTE_TMUX_SSH_FOR_TESTING"] = shimPath
        app.launchEnvironment["TMUX_TMPDIR"] = tmuxTmpDir
        if let path = ProcessInfo.processInfo.environment["PATH"], !path.isEmpty {
            app.launchEnvironment["PATH"] = path
        }
        // Activation can fail on a headless or lock-screen session
        // ("Running Background"). The suite is socket-driven end to end and
        // the sizing oracle follows view LAYOUT (which advances for
        // background apps), not visible painting — so treat activation as
        // best-effort, exactly like the browser-fixture suites.
        let activationOptions = XCTExpectedFailure.Options()
        activationOptions.isStrict = false
        XCTExpectFailure("App activation may fail on headless/locked sessions", options: activationOptions) {
            app.launch()
        }
        _ = app.wait(for: .runningForeground, timeout: 10)
        XCTAssertTrue(
            waitForSocket(timeout: 12),
            "control socket never answered. candidates=\(socketCandidates()) "
                + "lastSocketFailure=\(lastSocketFailure ?? "nil") diagnostics=\(loadDiagnostics())"
        )
        return app
    }

    /// Runs a tmux argv against the lab server — INSIDE THE APP via the
    /// `remote.tmux.test_exec` debug socket verb, never in the sandboxed
    /// runner (which cannot create /tmp dirs or spawn tmux there). Returns
    /// trimmed stdout on exit 0, else records the failure and returns nil.
    @discardableResult
    func tmux(_ args: [String]) -> String? {
        guard let bin = tmuxBin else { return nil }
        guard let response = socketJSON(method: "remote.tmux.test_exec", params: [
            "tmpdir": tmuxTmpDir,
            "bin": bin,
            "args": args,
        ]) else {
            lastTmuxFailure = "tmux \(args.joined(separator: " ")): socket call returned nil"
            return nil
        }
        // The socket call succeeded (response["ok"]); tmux's own exit is in
        // "exit". Both must be clean.
        guard response["ok"] as? Bool == true, response["exit"] as? Int == 0 else {
            lastTmuxFailure = "tmux \(args.joined(separator: " ")) -> \(response)"
            return nil
        }
        return (response["stdout"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The app binds a TAG-DERIVED socket (`/tmp/cmux-debug-<slug>.sock`) and
    /// ignores CMUX_SOCKET_PATH in tag mode, so probe both and adopt whichever
    /// answers — matching the passing browser/automation UITests. Once found,
    /// `socketPath` is updated so every later call uses the live socket.
    func waitForSocket(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in socketCandidates() {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                socketPath = candidate
                if socketJSON(method: "system.ping", params: [:])?["ok"] as? Bool == true {
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return false
    }

    /// Every path the app might have bound: the one we dictated, the
    /// tag-derived one, and whatever the app itself recorded in its
    /// diagnostics file — the app's own ground truth.
    func socketCandidates() -> [String] {
        var candidates = [socketPath, taggedSocketPath()]
        if let expected = loadDiagnostics()["socketExpectedPath"], !expected.isEmpty {
            candidates.append(expected)
        }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    /// The app's UI-test diagnostics (socket path, sanity result, …), or empty.
    func loadDiagnostics() -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: diagnosticsPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object.reduce(into: [:]) { $0[$1.key] = String(describing: $1.value) }
    }

    /// `/tmp/cmux-debug-<slug>.sock`, the path the app derives from CMUX_TAG.
    func taggedSocketPath() -> String {
        let slug = launchTag
            .lowercased()
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return "/tmp/cmux-debug-\(slug).sock"
    }

    func socketJSON(method: String, params: [String: Any]) -> [String: Any]? {
        let request: [String: Any] = ["id": UUID().uuidString, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(request),
              let data = try? JSONSerialization.data(withJSONObject: request),
              let line = String(data: data, encoding: .utf8),
              let response = sendLine(line),
              let responseData = response.data(using: .utf8),
              var object = (try? JSONSerialization.jsonObject(with: responseData)) as? [String: Any]
        else { return nil }
        // Success responses nest the payload under "result" ({ok, id, result});
        // errors are flat ({ok, id, error}). Flatten result up so callers read
        // payload keys (exit, windows, …) and the top-level "ok" uniformly.
        if let result = object["result"] as? [String: Any] {
            for (key, value) in result where object[key] == nil { object[key] = value }
        }
        return object
    }

    func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            lastSocketFailure = "socket() errno=\(errno) (\(String(cString: strerror(errno))))"
            return nil
        }
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
        guard connected == 0 else {
            lastSocketFailure = "connect(\(socketPath)) errno=\(errno) (\(String(cString: strerror(errno))))"
            return nil
        }
        let payload = Array((line + "\n").utf8)
        let wrote = payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return false }
            return Darwin.write(fd, base, raw.count) == raw.count
        }
        guard wrote else { return nil }
        var buffer = [UInt8](repeating: 0, count: 8192)
        var accumulator = Data()
        let deadline = Date().addingTimeInterval(65)
        while Date() < deadline {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            accumulator.append(contentsOf: buffer[0..<count])
            if let newline = accumulator.firstIndex(of: UInt8(ascii: "\n")) {
                return String(decoding: accumulator[..<newline], as: UTF8.self)
            }
        }
        return accumulator.isEmpty
            ? nil
            : String(decoding: accumulator, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
