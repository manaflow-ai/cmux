import XCTest
import Foundation

final class ControlSocketClient {
    private let path: String
    private let responseTimeout: TimeInterval

    init(path: String, responseTimeout: TimeInterval = 2.0) {
        self.path = path
        self.responseTimeout = responseTimeout
    }

    func sendJSON(_ object: [String: Any]) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8),
              let response = sendLine(line),
              let responseData = response.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return parsed
    }

    func sendLine(_ line: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var socketTimeout = timeval(
            tv_sec: Int(responseTimeout.rounded(.down)),
            tv_usec: Int32(((responseTimeout - floor(responseTimeout)) * 1_000_000).rounded())
        )

#if os(macOS)
        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                ptr,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
#endif
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { ptr in
            setsockopt(
                fd,
                SOL_SOCKET,
                SO_SNDTIMEO,
                ptr,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= maxLen else { return nil }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            memset(raw, 0, maxLen)
            for index in 0..<bytes.count {
                raw[index] = bytes[index]
            }
        }

        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
        let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
        addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                connect(fd, socketAddress, addrLen)
            }
        }
        guard connected == 0 else { return nil }

        let payload = line + "\n"
        let wrote: Bool = payload.withCString { cString in
            var remaining = strlen(cString)
            var pointer = UnsafeRawPointer(cString)
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written <= 0 { return false }
                remaining -= written
                pointer = pointer.advanced(by: written)
            }
            return true
        }
        guard wrote else { return nil }

        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulator = ""
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
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

extension XCTestCase {
    /// Waits for a cmux control socket listener to become ready in two
    /// decoupled phases, then returns whether it answered a `ping` with `PONG`.
    ///
    /// The two phases exist to keep a slow app cold-launch on hosted CI runners
    /// from starving the ping budget:
    ///
    /// 1. **Listener bound.** Wait up to `listenerBindTimeout` for the listener
    ///    to bind, observed as the Unix-domain socket file appearing on disk.
    ///    The server creates that file with `bind(2)` before it accepts, so the
    ///    file appearing is a real readiness signal, not a fixed sleep. Each UI
    ///    test binds a unique per-run socket path and removes it in `setUp`, so
    ///    the file can only appear because *this* app instance bound it.
    /// 2. **Accepting and responsive.** With the listener bound, wait up to
    ///    `pingTimeout` (a *fresh* budget that only starts once phase 1
    ///    completes) for it to accept a connection and answer `ping` with
    ///    `PONG`.
    ///
    /// Splitting the wait this way is the fix for the flake in
    /// https://github.com/manaflow-ai/cmux/issues/5414: previously a single
    /// fixed `pingTimeout` had to cover *both* the time for the listener to
    /// bind and the time to answer, so a slow cold-launch could exhaust the
    /// whole budget before the listener even existed. Now a slow launch is
    /// absorbed by `listenerBindTimeout` and the ping confirmation always gets
    /// its full budget.
    ///
    /// Both phases poll their condition on a fixed cadence with a deterministic
    /// deadline loop (``pollControlSocketCondition``), re-evaluating every
    /// ``pollInterval`` until the bound elapses.
    ///
    /// This deliberately does *not* use `XCTNSPredicateExpectation`. That class
    /// is unreliable here because the conditions are non-KVO closures that do
    /// blocking socket I/O: the ping closure opens a connection and blocks up to
    /// its response timeout on every evaluation. `XCTNSPredicateExpectation`
    /// evaluates such a predicate once, then relies on a polling timer scheduled
    /// on the run loop to re-evaluate; under `XCTWaiter.wait` that re-poll can be
    /// starved, so a single early `false` (the listener bound but its accept
    /// loop not yet answering, a sub-second window) makes the waiter sit on the
    /// stale `false` for the full timeout even though the socket became
    /// responsive almost immediately. That is the flake seen in CI on
    /// `BrowserPaneNavigationKeybindUITests` (issue surfaced 2026-06-13): the
    /// app's own sanity check reported `PONG` ~1s after launch, yet the test's
    /// 12s ping wait failed. A plain deadline loop guarantees the ping is
    /// actually retried for the whole budget. See also
    /// https://github.com/manaflow-ai/cmux/issues/5414 for the two-phase split.
    ///
    /// - Parameters:
    ///   - listenerBindTimeout: Maximum time to wait for the socket file to
    ///     appear (the listener-bound signal). Generous on purpose so a slow
    ///     launch does not eat the ping budget; only hit on a genuine bind
    ///     failure.
    ///   - pingTimeout: Fresh budget for the `ping` -> `PONG` round trip once
    ///     the listener has bound.
    ///   - pollInterval: How long to wait between condition re-evaluations.
    ///   - socketFileExists: Returns true once the listener's socket file is on
    ///     disk. A closure (not a path) so callers that resolve among several
    ///     candidate paths can report "any candidate exists".
    ///   - pingReturnsPong: Returns true when a `ping` to the listener answered
    ///     `PONG`.
    /// - Returns: `true` only when both phases complete.
    func waitForControlSocketReady(
        listenerBindTimeout: TimeInterval = 60.0,
        pingTimeout: TimeInterval,
        pollInterval: TimeInterval = 0.2,
        socketFileExists: @escaping () -> Bool,
        pingReturnsPong: @escaping () -> Bool
    ) -> Bool {
        guard pollControlSocketCondition(
            timeout: listenerBindTimeout,
            pollInterval: pollInterval,
            condition: socketFileExists
        ) else {
            return false
        }
        return pollControlSocketCondition(
            timeout: pingTimeout,
            pollInterval: pollInterval,
            condition: pingReturnsPong
        )
    }

    /// Polls `condition` until it returns true or `timeout` elapses, spinning
    /// the current run loop for `pollInterval` between attempts so the app
    /// process keeps making progress without busy-waiting. The condition may
    /// block (e.g. a socket round trip); the deadline still bounds total wait.
    private func pollControlSocketCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        } while Date() < deadline
        // One final attempt right at the deadline so a condition that became
        // true during the last sleep is not missed.
        return condition()
    }

    /// Convenience wrapper of ``waitForControlSocketReady(listenerBindTimeout:pingTimeout:socketFileExists:pingReturnsPong:)``
    /// for the common single-path case: the listener-bound signal is simply the
    /// file at `socketPath` appearing. `pingReturnsPong` is a trailing closure
    /// so call sites stay as terse as the previous single-budget poll.
    func waitForControlSocketReady(
        socketPath: String,
        listenerBindTimeout: TimeInterval = 60.0,
        pingTimeout: TimeInterval,
        pingReturnsPong: @escaping () -> Bool
    ) -> Bool {
        waitForControlSocketReady(
            listenerBindTimeout: listenerBindTimeout,
            pingTimeout: pingTimeout,
            socketFileExists: { FileManager.default.fileExists(atPath: socketPath) },
            pingReturnsPong: pingReturnsPong
        )
    }

    /// Sends one line to a Unix-domain control socket through `/usr/bin/nc`.
    ///
    /// This is a fallback for hosted macOS UI tests where the in-process
    /// Darwin socket client can occasionally fail to connect even though the
    /// app's own diagnostics and `nc -U` both prove the listener is accepting.
    func controlSocketCommandViaNetcat(
        _ command: String,
        socketPath: String,
        responseTimeout: TimeInterval = 2.0
    ) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        process.arguments = [
            "-lc",
            "printf '%s\\n' \(controlSocketShellSingleQuote(command)) | \(nc) -U \(controlSocketShellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        ]

        let output = Pipe()
        process.standardOutput = output

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        if let first = text.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns true when the app-side socket sanity probe confirmed that the
    /// configured listener path is bound by the app and answers `ping`.
    func controlSocketDiagnosticsReportReady(_ diagnostics: [String: String]) -> Bool {
        diagnostics["socketReady"] == "1" &&
            diagnostics["socketPingResponse"] == "PONG" &&
            diagnostics["socketPathExists"] == "1" &&
            diagnostics["socketPathMatches"] == "1" &&
            diagnostics["socketPathOwnedByListener"] == "1"
    }

    /// Sends a JSON-RPC object through the same `nc -U` fallback as line-based
    /// socket commands and decodes one JSON response object.
    func controlSocketJSONViaNetcat(
        _ object: [String: Any],
        socketPath: String,
        responseTimeout: TimeInterval = 2.0
    ) -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let line = String(data: data, encoding: .utf8),
              let response = controlSocketCommandViaNetcat(
                line,
                socketPath: socketPath,
                responseTimeout: responseTimeout
              ),
              let responseData = response.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return nil
        }
        return decoded
    }

    private func controlSocketShellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
