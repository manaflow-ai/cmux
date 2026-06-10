import XCTest
import Foundation
import CoreGraphics


// MARK: - Control Socket Resolution and Client
extension MultiWindowNotificationsUITests {
    func resolveSocketPath(timeout: TimeInterval, requiredWorkspaceId: String? = nil) -> String? {
        let primaryCandidates = expectedSocketCandidates(includeGlobalFallback: false)
        let fallbackCandidates: [String]
        if let requiredWorkspaceId, !requiredWorkspaceId.isEmpty {
            fallbackCandidates = expectedSocketCandidates(includeGlobalFallback: true)
                .filter { !primaryCandidates.contains($0) }
        } else {
            fallbackCandidates = []
        }

        var resolvedPath: String?
        _ = waitForCondition(timeout: timeout) {
            for candidate in primaryCandidates {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                // Primary candidate is the explicitly requested CMUX_SOCKET_PATH. If it responds,
                // prefer it even before workspace contents are fully initialized.
                if self.socketRespondsToPing(at: candidate) {
                    resolvedPath = candidate
                    return true
                }
            }
            for candidate in fallbackCandidates {
                guard FileManager.default.fileExists(atPath: candidate) else { continue }
                if self.socketRespondsToPing(at: candidate),
                   self.socketMatchesRequiredWorkspace(candidate, workspaceId: requiredWorkspaceId) {
                    resolvedPath = candidate
                    return true
                }
            }
            return false
        }
        if let resolvedPath {
            return resolvedPath
        }
        for candidate in primaryCandidates {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            if socketRespondsToPing(at: candidate) {
                return candidate
            }
        }
        for candidate in fallbackCandidates {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            if socketRespondsToPing(at: candidate),
               socketMatchesRequiredWorkspace(candidate, workspaceId: requiredWorkspaceId) {
                return candidate
            }
        }
        return nil
    }

    private func expectedSocketCandidates(includeGlobalFallback: Bool) -> [String] {
        var candidates = [socketPath]
        let taggedDebugSocket = "/tmp/cmux-debug-\(launchTag).sock"
        if !taggedDebugSocket.isEmpty {
            candidates.append(taggedDebugSocket)
        }
        if includeGlobalFallback {
            candidates.append(contentsOf: discoverTmpSocketCandidates(limit: 12))
            candidates.append("/tmp/cmux-debug.sock")
            candidates.append(stableSocketPath())
            candidates.append("/tmp/cmux.sock")
        }

        var unique: [String] = []
        var seen = Set<String>()
        for candidate in candidates {
            if seen.insert(candidate).inserted {
                unique.append(candidate)
            }
        }
        return unique
    }

    private func stableSocketPath() -> String {
        // Mirrors CmuxStateDirectory.url() + cmux.sock (non-TCC ~/.local/state/cmux;
        // see https://github.com/manaflow-ai/cmux/issues/5146).
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/cmux", isDirectory: true)
            .appendingPathComponent("cmux.sock", isDirectory: false)
            .path
    }

    private func socketMatchesRequiredWorkspace(_ candidatePath: String, workspaceId: String?) -> Bool {
        guard let workspaceId, !workspaceId.isEmpty else { return true }
        let originalPath = socketPath
        socketPath = candidatePath
        defer { socketPath = originalPath }

        guard let response = socketCommand("list_surfaces \(workspaceId)"),
              !response.isEmpty,
              !response.hasPrefix("ERROR"),
              response != "No surfaces" else {
            return false
        }
        return true
    }

    private func discoverTmpSocketCandidates(limit: Int) -> [String] {
        let tmpPath = "/tmp"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tmpPath) else {
            return []
        }

        let matches = entries.filter { $0.hasPrefix("cmux") && $0.hasSuffix(".sock") }
        let sorted = matches.compactMap { entry -> (path: String, mtime: Date)? in
            let fullPath = (tmpPath as NSString).appendingPathComponent(entry)
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fullPath) else {
                return nil
            }
            let mtime = (attrs[.modificationDate] as? Date) ?? .distantPast
            return (fullPath, mtime)
        }
        .sorted { $0.mtime > $1.mtime }

        return Array(sorted.prefix(limit)).map(\.path)
    }

    private func socketRespondsToPing(at path: String) -> Bool {
        let originalPath = socketPath
        socketPath = path
        defer { socketPath = originalPath }
        return socketCommand("ping") == "PONG"
    }

    func socketCommand(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        if let response = ControlSocketClient(path: socketPath, responseTimeout: responseTimeout).sendLine(cmd) {
            return response
        }
        return socketCommandViaNetcat(cmd, responseTimeout: responseTimeout)
    }

    private func socketCommandViaNetcat(_ cmd: String, responseTimeout: TimeInterval = 2.0) -> String? {
        let nc = "/usr/bin/nc"
        guard FileManager.default.isExecutableFile(atPath: nc) else { return nil }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        let timeoutSeconds = max(1, Int(ceil(responseTimeout)))
        let script = "printf '%s\\n' \(shellSingleQuote(cmd)) | \(nc) -U \(shellSingleQuote(socketPath)) -w \(timeoutSeconds) 2>/dev/null"
        proc.arguments = ["-lc", script]

        let outPipe = Pipe()
        proc.standardOutput = outPipe

        do {
            try proc.run()
        } catch {
            return nil
        }

        proc.waitUntilExit()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard let outStr = String(data: outData, encoding: .utf8) else { return nil }
        if let first = outStr.split(separator: "\n", maxSplits: 1).first {
            return String(first).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = outStr.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func shellSingleQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    func readTrimmedFile(atPath path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval = 2.0) {
            self.path = path
            self.responseTimeout = responseTimeout
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
            withUnsafeMutablePointer(to: &addr.sun_path) { p in
                let raw = UnsafeMutableRawPointer(p).assumingMemoryBound(to: CChar.self)
                memset(raw, 0, maxLen)
                for i in 0..<bytes.count {
                    raw[i] = bytes[i]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + bytes.count)
#if os(macOS)
            addr.sun_len = UInt8(min(Int(addrLen), 255))
#endif

            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    connect(fd, sa, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = line + "\n"
            let wrote: Bool = payload.withCString { cstr in
                var remaining = strlen(cstr)
                var p = UnsafeRawPointer(cstr)
                while remaining > 0 {
                    let n = write(fd, p, remaining)
                    if n <= 0 { return false }
                    remaining -= n
                    p = p.advanced(by: n)
                }
                return true
            }
            guard wrote else { return nil }

            var buf = [UInt8](repeating: 0, count: 4096)
            var accum = ""
            while true {
                let n = read(fd, &buf, buf.count)
                if n < 0 {
                    let code = errno
                    if code == EAGAIN || code == EWOULDBLOCK {
                        break
                    }
                    return nil
                }
                if n <= 0 { break }
                if let chunk = String(bytes: buf[0..<n], encoding: .utf8) {
                    accum.append(chunk)
                    if let idx = accum.firstIndex(of: "\n") {
                        return String(accum[..<idx])
                    }
                }
            }
            return accum.isEmpty ? nil : accum.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func readCurrentTerminalText() -> String? {
        guard let response = socketCommand("read_terminal_text"), response.hasPrefix("OK ") else {
            return nil
        }
        let encoded = String(response.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func loadData() -> [String: String]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: dataPath)) else {
            return nil
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String]
    }
}
