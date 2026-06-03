import OSLog
import SwiftUI

private let scannerLog = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.scanner")

struct DiscoveredServer: Identifiable {
    let id = UUID()
    let hostname: String
    let port: Int
    let name: String
    let version: String
    let instanceID: String?
    let workspaceCount: Int
    let workspaceChangeSeq: UInt64?
    let wsSecret: String

    init(hostname: String, port: Int, name: String, version: String, instanceID: String?, workspaceCount: Int, workspaceChangeSeq: UInt64?, wsSecret: String) {
        self.hostname = hostname
        self.port = port
        self.name = name
        self.version = version
        self.instanceID = instanceID
        self.workspaceCount = workspaceCount
        self.workspaceChangeSeq = workspaceChangeSeq
        self.wsSecret = wsSecret
    }
}

/// Thread-safe ring buffer for scanner debug logs.
final class ScannerLog: @unchecked Sendable {
    static let shared = ScannerLog()
    private var entries: [String] = []
    private let lock = NSLock()
    private let maxEntries = 200

    func log(_ message: String) {
        let ts = Self.formatter.string(from: Date())
        let line = "\(ts) \(message)"
        lock.lock()
        entries.append(line)
        if entries.count > maxEntries { entries.removeFirst(entries.count - maxEntries) }
        lock.unlock()
        scannerLog.debug("\(message, privacy: .public)")
    }

    func allEntries() -> String {
        lock.lock()
        defer { lock.unlock() }
        return entries.joined(separator: "\n")
    }

    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

@MainActor
@Observable
final class ServerScanner {
    var servers: [DiscoveredServer] = []
    var isScanning = false
    private(set) var currentSecret: String = ""
    private var scanTask: Task<Void, Never>?
    private let log = ScannerLog.shared

    func startScan() {
        guard !isScanning else { return }
        isScanning = true
        servers = []

        scanTask = Task {
            await scanAll()
            self.isScanning = false
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func scanAll() async {
        let secret = loadWsSecret()
        self.currentSecret = secret
        let relayHost = loadRelayHost()

        log.log("scan.start secret=\(secret.isEmpty ? "empty" : "\(secret.prefix(8))...") relay=\(relayHost ?? "none")")

        // Build immediate candidates (localhost + relay host). For
        // cross-network reach, users install Tailscale (or any VPN/SSH
        // tunnel of choice) and add the mac's tailnet hostname:port as
        // a relay host — cmux no longer ships an embedded Tailscale node.
        var candidates: [(String, Int)] = []

        for port in 52100...52199 {
            candidates.append(("127.0.0.1", port))
        }

        if let relayHost, relayHost != "127.0.0.1" {
            log.log("scan.relay adding \(relayHost):52100-52199")
            for port in 52100...52199 {
                candidates.append((relayHost, port))
            }
        }

        log.log("scan.candidates count=\(candidates.count)")

        var found: [DiscoveredServer] = []
        var seenEndpoints: Set<String> = []

        found = await probeCandidates(candidates, secret: secret, existing: found, seen: &seenEndpoints)
        log.log("scan.probe.done found=\(found.count)")

        self.servers = found.sorted { $0.port < $1.port }
        log.log("scan.complete total=\(found.count)")
    }

    private func probeCandidates(
        _ candidates: [(String, Int)],
        secret: String,
        existing: [DiscoveredServer],
        seen: inout Set<String>
    ) async -> [DiscoveredServer] {
        var found = existing
        let batchSize = 20

        for batchStart in stride(from: 0, to: candidates.count, by: batchSize) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + batchSize, candidates.count)
            let batch = candidates[batchStart..<batchEnd]

            let results = await withTaskGroup(of: DiscoveredServer?.self) { group in
                for (host, port) in batch {
                    group.addTask {
                        await Self.probeAndIdentify(hostname: host, port: port, secret: secret)
                    }
                }
                var batchResults: [DiscoveredServer] = []
                for await result in group {
                    if let server = result {
                        batchResults.append(server)
                    }
                }
                return batchResults
            }

            for server in results {
                let key = "\(server.name):\(server.port)"
                if seen.insert(key).inserted {
                    found.append(server)
                    log.log("scan.found \(server.hostname):\(server.port) name=\(server.name) ws=\(server.workspaceCount)")
                }
            }
            self.servers = found.sorted { $0.port < $1.port }
        }
        return found
    }

    static func probeAndIdentify(hostname: String, port: Int, secret: String, expectedInstanceID: String? = nil) async -> DiscoveredServer? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = Self.probeSync(
                    hostname: hostname,
                    port: port,
                    secret: secret,
                    expectedInstanceID: expectedInstanceID
                )
                continuation.resume(returning: result)
            }
        }
    }

    nonisolated static func probeSync(hostname: String, port: Int, secret: String, expectedInstanceID: String? = nil) -> DiscoveredServer? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        inet_pton(AF_INET, hostname, &addr.sin_addr)
        let addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let connectResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else { return nil }
        ScannerLog.shared.log("probe.connect ok host=\(hostname):\(port)")

        let req = "GET / HTTP/1.1\r\nHost: \(hostname):\(port)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGVzdA==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        _ = req.data(using: .utf8)?.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n > 0 else {
            ScannerLog.shared.log("probe.upgrade.fail host=\(hostname):\(port) n=\(n) errno=\(errno)")
            return nil
        }
        let httpResponse = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
        guard httpResponse.contains("101") else {
            ScannerLog.shared.log("probe.upgrade.reject host=\(hostname):\(port) resp=\(httpResponse.prefix(80))")
            return nil
        }
        ScannerLog.shared.log("probe.upgrade ok host=\(hostname):\(port)")

        wsSend(fd: fd, data: "{\"secret\":\"\(secret)\"}")
        guard let authResp = wsRecv(fd: fd) else {
            ScannerLog.shared.log("probe.auth.norecv host=\(hostname):\(port)")
            return nil
        }
        guard authResp.contains("authenticated") else {
            ScannerLog.shared.log("probe.auth.reject host=\(hostname):\(port) resp=\(authResp.prefix(120))")
            return nil
        }
        ScannerLog.shared.log("probe.auth ok host=\(hostname):\(port)")

        wsSend(fd: fd, data: "{\"id\":1,\"method\":\"hello\"}")
        // The daemon starts pushing workspace.changed events as soon as the
        // WebSocket is authenticated. Our hello response can land behind
        // one or more of those pushes, so skip any frame that isn't the
        // id=1 reply we're waiting for.
        var helloResult: [String: Any]?
        var lastFrame = ""
        for _ in 0..<10 {
            guard let frame = wsRecv(fd: fd) else { break }
            lastFrame = frame
            guard let frameData = frame.data(using: .utf8),
                  let frameJSON = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any] else {
                continue
            }
            if let id = frameJSON["id"] as? Int, id == 1,
               let result = frameJSON["result"] as? [String: Any] {
                helloResult = result
                break
            }
        }
        guard let result = helloResult,
              let name = result["name"] as? String,
              let version = result["version"] as? String else {
            ScannerLog.shared.log("probe.hello.parse host=\(hostname):\(port) last=\(lastFrame.prefix(120))")
            return nil
        }

        let workspaceCount = result["workspace_count"] as? Int ?? 0
        let workspaceChangeSeq = uint64Value(result["change_seq"])
        let instanceID = result["instance_id"] as? String
        if let expectedInstanceID,
           !instanceMatches(actual: instanceID, expected: expectedInstanceID) {
            ScannerLog.shared.log("probe.instance.reject host=\(hostname):\(port) expected=\(expectedInstanceID) got=\(instanceID ?? "nil")")
            return nil
        }

        return DiscoveredServer(
            hostname: hostname,
            port: port,
            name: name,
            version: version,
            instanceID: instanceID,
            workspaceCount: workspaceCount,
            workspaceChangeSeq: workspaceChangeSeq,
            wsSecret: secret
        )
    }

    private nonisolated static func uint64Value(_ value: Any?) -> UInt64? {
        if let value = value as? UInt64 {
            return value
        }
        if let value = value as? Int, value >= 0 {
            return UInt64(value)
        }
        if let value = value as? NSNumber {
            return value.uint64Value
        }
        return nil
    }

    private nonisolated static func instanceMatches(actual: String?, expected: String) -> Bool {
        let expected = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expected.isEmpty else { return true }
        guard let actual = actual?.trimmingCharacters(in: .whitespacesAndNewlines), !actual.isEmpty else {
            return false
        }
        if actual == expected {
            return true
        }
        if !expected.hasPrefix("cmuxd-dev-"), actual == "cmuxd-dev-\(expected)" {
            return true
        }
        if actual.hasPrefix("cmuxd-dev-"), String(actual.dropFirst("cmuxd-dev-".count)) == expected {
            return true
        }
        return false
    }

    // MARK: - WebSocket helpers

    private nonisolated static func wsSend(fd: Int32, data: String) {
        guard let payload = data.data(using: .utf8) else { return }
        var frame = [UInt8]()
        frame.append(0x81)
        if payload.count <= 125 {
            frame.append(UInt8(payload.count))
        } else {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        }
        frame.append(contentsOf: payload)
        _ = frame.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    private nonisolated static func wsRecv(fd: Int32) -> String? {
        var header = [UInt8](repeating: 0, count: 2)
        let headerRead = read(fd, &header, 2)
        guard headerRead == 2 else { return nil }

        var payloadLen = Int(header[1] & 0x7F)
        if payloadLen == 126 {
            var extLen = [UInt8](repeating: 0, count: 2)
            guard read(fd, &extLen, 2) == 2 else { return nil }
            payloadLen = Int(extLen[0]) << 8 | Int(extLen[1])
        } else if payloadLen == 127 {
            var extLen = [UInt8](repeating: 0, count: 8)
            guard read(fd, &extLen, 8) == 8 else { return nil }
            payloadLen = 0
            for i in 0..<8 { payloadLen = payloadLen << 8 | Int(extLen[i]) }
        }

        guard payloadLen > 0, payloadLen < 1_000_000 else { return nil }
        var payload = [UInt8](repeating: 0, count: payloadLen)
        var totalRead = 0
        while totalRead < payloadLen {
            let n = payload.withUnsafeMutableBytes { buf in
                read(fd, buf.baseAddress! + totalRead, payloadLen - totalRead)
            }
            guard n > 0 else { return nil }
            totalRead += n
        }
        return String(bytes: payload, encoding: .utf8)
    }

    // MARK: - Config helpers

    private func loadWsSecret() -> String {
        // Device: read from app bundle; Simulator: read from host filesystem
        if let bundlePath = Bundle.main.path(forResource: "mobile-ws-secret", ofType: nil),
           let s = try? String(contentsOfFile: bundlePath, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            log.log("config.secret source=bundle")
            return s
        }
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let path = "\(home)/Library/Application Support/cmux/mobile-ws-secret"
        let s = (try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        log.log("config.secret source=\(s.isEmpty ? "missing" : "filesystem")")
        return s
    }

    private func loadRelayHost() -> String? {
        guard let path = Bundle.main.path(forResource: "debug-relay-host", ofType: nil),
              let host = try? String(contentsOfFile: path, encoding: .utf8)
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !host.isEmpty else {
            return nil
        }
        return host
    }
}

struct ServerScannerView: View {
    @State private var scanner = ServerScanner()
    @State private var connectedPorts: Set<Int>
    @State private var showingLogs = false
    @State private var manualIP = ""
    @State private var manualPort = "52100"
    @State private var isProbing = false
    let onSelect: (DiscoveredServer) -> Void
    let onRemove: (DiscoveredServer) -> Void
    let onDismiss: () -> Void

    init(
        connectedPorts: Set<Int>,
        onSelect: @escaping (DiscoveredServer) -> Void,
        onRemove: @escaping (DiscoveredServer) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        _connectedPorts = State(initialValue: connectedPorts)
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onDismiss = onDismiss
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(String(localized: "server.scan.manual.ip", defaultValue: "IP address"), text: $manualIP)
                            .keyboardType(.decimalPad)
                            .textContentType(.none)
                            .autocorrectionDisabled()
                        Text(":")
                            .foregroundStyle(.secondary)
                        TextField(String(localized: "server.scan.manual.port", defaultValue: "Port"), text: $manualPort)
                            .keyboardType(.numberPad)
                            .frame(width: 60)
                    }
                    Button {
                        probeManualServer()
                    } label: {
                        HStack {
                            if isProbing {
                                ProgressView()
                                    .padding(.trailing, 4)
                            }
                            Text(String(localized: "server.scan.manual.connect", defaultValue: "Connect"))
                        }
                    }
                    .disabled(manualIP.isEmpty || isProbing)
                } header: {
                    Text(String(localized: "server.scan.manual.header", defaultValue: "Add Server"))
                }

                if !scanner.servers.isEmpty || scanner.isScanning {
                    Section {
                        if scanner.isScanning {
                            HStack {
                                ProgressView()
                                    .padding(.trailing, 8)
                                Text(String(localized: "server.scan.scanning", defaultValue: "Scanning..."))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(scanner.servers) { server in
                            let isConnected = connectedPorts.contains(server.port)
                            Button {
                                if isConnected {
                                    connectedPorts.remove(server.port)
                                    onRemove(server)
                                } else {
                                    connectedPorts.insert(server.port)
                                    onSelect(server)
                                }
                            } label: {
                                ServerScanRow(server: server, isConnected: isConnected)
                            }
                        }
                    } header: {
                        Text(String(localized: "server.scan.discovered.header", defaultValue: "Discovered"))
                    }
                }

                Section {
                    Button {
                        showingLogs = true
                    } label: {
                        Label(String(localized: "server.scan.logs", defaultValue: "Scanner Logs"), systemImage: "doc.text")
                    }
                }
            }
            .navigationTitle(String(localized: "server.scan.title", defaultValue: "Find Servers"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "server.scan.done", defaultValue: "Done")) {
                        onDismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .primaryAction) {
                    if scanner.isScanning {
                        ProgressView()
                    } else {
                        Button {
                            scanner.startScan()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                scanner.startScan()
            }
            .sheet(isPresented: $showingLogs) {
                ScannerLogView()
            }
        }
    }

    private func probeManualServer() {
        let ip = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty, let port = Int(manualPort) else { return }
        isProbing = true
        let secret = scanner.currentSecret

        Task {
            let result = await ServerScanner.probeAndIdentify(hostname: ip, port: port, secret: secret)
            await MainActor.run {
                isProbing = false
                if let server = result {
                    connectedPorts.insert(server.port)
                    onSelect(server)
                    ScannerLog.shared.log("manual.connect \(ip):\(port) name=\(server.name)")
                } else {
                    ScannerLog.shared.log("manual.connect.failed \(ip):\(port)")
                }
            }
        }
    }
}

struct ScannerLogView: View {
    @State private var logText = ScannerLog.shared.allEntries()
    @State private var copied = false
    @State private var copiedResetTimer: Timer?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(logText.isEmpty ? "No logs yet." : logText)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle(String(localized: "server.scan.logs.title", defaultValue: "Scanner Logs"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = logText
                        copied = true
                        copiedResetTimer?.invalidate()
                        copiedResetTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { timer in
                            guard copiedResetTimer === timer else { return }
                            copied = false
                            copiedResetTimer = nil
                        }
                    } label: {
                        Label(
                            copied ? String(localized: "server.scan.logs.copied", defaultValue: "Copied") : String(localized: "server.scan.logs.copy", defaultValue: "Copy"),
                            systemImage: copied ? "checkmark" : "doc.on.doc"
                        )
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "server.scan.logs.clear", defaultValue: "Clear")) {
                        ScannerLog.shared.clear()
                        logText = ""
                    }
                }
            }
            .onAppear {
                logText = ScannerLog.shared.allEntries()
            }
            .onDisappear {
                copiedResetTimer?.invalidate()
                copiedResetTimer = nil
            }
        }
    }
}

private struct ServerScanRow: View {
    let server: DiscoveredServer
    let isConnected: Bool

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(isConnected ? .blue : .secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.headline)
                HStack(spacing: 8) {
                    if server.workspaceCount > 0 {
                        Text("\(server.workspaceCount) workspaces")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("v\(server.version)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Image(systemName: isConnected ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(isConnected ? .blue : .secondary)
        }
        .padding(.vertical, 4)
    }

    private var displayName: String {
        if server.hostname == "127.0.0.1" {
            return "Local (:\(server.port))"
        }
        return "\(server.hostname) (:\(server.port))"
    }
}
