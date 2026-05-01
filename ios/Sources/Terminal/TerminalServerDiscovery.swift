import Combine
import Foundation

protocol TerminalServerDiscovering {
    var hostsPublisher: AnyPublisher<[TerminalHost], Never> { get }
}

/// Discovers the active cmux daemon for the main sidebar.
///
/// Tagged dev builds embed `debug-ws-port`; when present it is the active
/// desktop endpoint and the sidebar probes only that port. The manual Find
/// Servers sheet remains the explicit broad scanner for attaching additional
/// daemons.
final class TailscaleServerDiscovery: TerminalServerDiscovering {
    let hostsPublisher: AnyPublisher<[TerminalHost], Never>

    private let subject = CurrentValueSubject<[TerminalHost], Never>([])
    private var probeTimer: DispatchSourceTimer?
    private let stateLock = NSLock()
    private var knownHosts: [TerminalHost] = []
    private let wsSecret: String
    private let probeHostname: String
    private let hintedPorts: [Int]
    private let forcedPorts: [Int]?
    private let hasActiveTaggedEndpoint: Bool
    private let expectedInstanceID: String?

    @MainActor
    convenience init() {
        let secret = Self.loadWsSecret()
        let env = ProcessInfo.processInfo.environment
        let hostname = Self.loadForcedProbeHostname(env: env) ?? Self.loadProbeHostname()
        let hints = Self.loadHintedPorts()
        let forcedPorts = Self.loadForcedProbePorts(env: env)
        let expectedInstanceID = Self.loadExpectedInstanceID()
        let hasActiveTaggedEndpoint = !hints.isEmpty && forcedPorts == nil

        ScannerLog.shared.log("discovery.init hostname=\(hostname) secret=\(secret.isEmpty ? "empty" : "\(secret.prefix(8))...") hints=\(hints) forced=\(forcedPorts ?? []) active=\(hasActiveTaggedEndpoint) instance=\(expectedInstanceID ?? "none")")

        #if DEBUG
        self.init(
            hostname: hostname,
            secret: secret,
            hintedPorts: hints,
            forcedPorts: forcedPorts,
            hasActiveTaggedEndpoint: hasActiveTaggedEndpoint,
            expectedInstanceID: expectedInstanceID,
            existingHosts: []
        )
        #else
        // Production: seed with any persisted hosts in addition to the dynamic scan.
        var persisted: [TerminalHost] = []
        do {
            let store = try TerminalCacheRepository(database: AppDatabase.live())
            persisted = store.load().hosts.filter { $0.wsPort != nil }
        } catch {
            persisted = []
        }
        self.init(
            hostname: hostname,
            secret: secret,
            hintedPorts: hints,
            forcedPorts: forcedPorts,
            hasActiveTaggedEndpoint: hasActiveTaggedEndpoint,
            expectedInstanceID: expectedInstanceID,
            existingHosts: persisted
        )
        #endif
    }

    init(
        hostname: String,
        secret: String,
        hintedPorts: [Int],
        forcedPorts: [Int]? = nil,
        hasActiveTaggedEndpoint: Bool = false,
        expectedInstanceID: String? = nil,
        existingHosts: [TerminalHost]
    ) {
        self.hostsPublisher = subject.eraseToAnyPublisher()
        self.wsSecret = secret
        self.probeHostname = hostname
        self.hintedPorts = hintedPorts
        self.forcedPorts = forcedPorts
        self.hasActiveTaggedEndpoint = hasActiveTaggedEndpoint
        self.expectedInstanceID = expectedInstanceID
        self.knownHosts = existingHosts

        // Single launch probe. Tagged builds probe only their embedded active
        // endpoint. Untagged/debug fallback still sweeps once.
        // After the initial scan, workspace subscriptions (push-based
        // WebSocket) handle all ongoing state. Attaching any other daemon is
        // an explicit Find Servers action.
        performScan(fullSweep: true)
        startProbeTimer()
    }

    deinit {
        probeTimer?.cancel()
    }

    /// Used by callers (e.g. the manual Find Servers sheet) to inject a
    /// host they discovered. The next scan will probe it alongside the
    /// default port range.
    func addHost(_ host: TerminalHost) {
        stateLock.lock()
        if !knownHosts.contains(where: { $0.stableID == host.stableID }) {
            knownHosts.append(host)
        }
        stateLock.unlock()
        // Probe just the known hosts (including the one just added).
        performScan(fullSweep: false)
    }

    // MARK: - Scan

    /// - `fullSweep: true` — probes ports 52100-52199 (launch + manual refresh).
    /// - `fullSweep: false` — only re-probes ports of already-known hosts +
    ///   hinted ports. Cheap (1-2 TCP connects vs 100).
    private func performScan(fullSweep: Bool) {
        let hostname = probeHostname
        let secret = wsSecret
        let hints = hintedPorts
        let forcedPorts = forcedPorts
        let activeTaggedEndpoint = hasActiveTaggedEndpoint
        let expectedInstanceID = expectedInstanceID
        stateLock.lock()
        let existing = knownHosts
        stateLock.unlock()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var ports = Set<Int>()

            if fullSweep {
                if let forcedPorts {
                    ports.formUnion(forcedPorts)
                } else if expectedInstanceID != nil {
                    ports.formUnion(52100...52199)
                } else if activeTaggedEndpoint {
                    ports.formUnion(hints)
                } else {
                    ports.formUnion(52100...52199)
                }
            }

            // Always include hinted ports and ports of already-discovered hosts.
            ports.formUnion(hints)
            if let forcedPorts {
                ports.formUnion(forcedPorts)
            }
            for host in existing {
                if let port = host.wsPort { ports.insert(port) }
            }
            ScannerLog.shared.log("discovery.scan starting host=\(hostname) ports=\(ports.count) full=\(fullSweep)")

            var found: [TerminalHost] = []
            let lock = NSLock()
            let group = DispatchGroup()

            for port in ports.sorted() {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    defer { group.leave() }
                    // Run the scanner's full hello probe so we get a reliable
                    // workspace_count and treat a bound-but-non-cmux TCP port
                    // as offline.
                    let result = ServerScanner.probeSync(
                        hostname: hostname,
                        port: port,
                        secret: secret,
                        expectedInstanceID: expectedInstanceID
                    )
                    if let result {
                        let stableID = result.instanceID ?? "\(hostname)-\(port)"
                        let matched = existing.first(where: {
                            $0.stableID == stableID || ($0.hostname == hostname && $0.wsPort == port)
                        })
                        let endpointName = Self.endpointDisplayName(hostname: hostname, port: port)
                        var host = matched ?? TerminalHost(
                            stableID: stableID,
                            name: endpointName,
                            hostname: hostname,
                            port: 22,
                            username: "cmux",
                            symbolName: "desktopcomputer",
                            palette: .sky,
                            source: .discovered,
                            transportPreference: .remoteDaemon,
                            serverID: result.instanceID,
                            wsPort: port,
                            wsSecret: secret
                        )
                        host.stableID = stableID
                        host.serverID = result.instanceID
                        host.machineStatus = .online
                        host.wsPort = port
                        host.name = Self.refreshedEndpointDisplayName(
                            currentName: host.name,
                            hostname: hostname,
                            port: port,
                            source: host.source
                        )
                        host.daemonWorkspaceChangeSeq = result.workspaceChangeSeq
                        if host.wsSecret == nil || host.wsSecret?.isEmpty == true {
                            host.wsSecret = secret
                        }
                        lock.lock()
                        found.append(host)
                        lock.unlock()
                        ScannerLog.shared.log("discovery.scan.found \(hostname):\(port) ws=\(result.workspaceCount)")
                    }
                }
            }

            group.wait()

            // Also carry forward any existing non-localhost hosts (e.g. manually
            // added remotes) that didn't happen to match the current scan,
            // probed individually on their own saved port.
            let extras = existing.filter { host in
                guard let port = host.wsPort else { return false }
                return host.hostname != hostname
                    || !found.contains(where: { $0.stableID == host.stableID || ($0.hostname == hostname && $0.wsPort == port) })
            }
            for host in extras {
                let port = host.wsPort ?? 0
                let ok = Self.probeReachability(hostname: host.hostname, port: port)
                var probed = host
                probed.machineStatus = ok ? .online : .offline
                lock.lock()
                found.append(probed)
                lock.unlock()
                ScannerLog.shared.log("discovery.scan.extra \(host.hostname):\(port) online=\(ok)")
            }

            ScannerLog.shared.log("discovery.scan.done online=\(found.count)")
            // Remember discovered hosts so subsequent narrow scans re-probe them.
            self?.stateLock.lock()
            for host in found {
                if let index = self?.knownHosts.firstIndex(where: { $0.stableID == host.stableID }) {
                    self?.knownHosts[index] = host
                } else {
                    self?.knownHosts.append(host)
                }
            }
            self?.stateLock.unlock()
            DispatchQueue.main.async { self?.subject.send(found) }
        }
    }

    // MARK: - Helpers

    static func endpointDisplayName(hostname: String, port: Int) -> String {
        hostname == "127.0.0.1" ? "Local Dev (:\(port))" : "\(hostname) (:\(port))"
    }

    static func refreshedEndpointDisplayName(
        currentName: String,
        hostname: String,
        port: Int,
        source: TerminalHostSource
    ) -> String {
        guard source == .discovered else { return currentName }
        guard isGeneratedEndpointDisplayName(currentName, hostname: hostname) else { return currentName }
        return endpointDisplayName(hostname: hostname, port: port)
    }

    private static func isGeneratedEndpointDisplayName(_ name: String, hostname: String) -> Bool {
        let prefix = hostname == "127.0.0.1" ? "Local Dev (:" : "\(hostname) (:"
        guard name.hasPrefix(prefix), name.hasSuffix(")") else { return false }

        let suffixStart = name.index(name.startIndex, offsetBy: prefix.count)
        let suffixEnd = name.index(before: name.endIndex)
        return Int(name[suffixStart..<suffixEnd]) != nil
    }

    private func startProbeTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 2.0, repeating: 5.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.performScan(fullSweep: self.needsTimerFullSweep())
        }
        timer.resume()
        probeTimer = timer
    }

    private func needsTimerFullSweep() -> Bool {
        guard expectedInstanceID != nil else { return false }
        guard forcedPorts == nil, hintedPorts.isEmpty else { return false }

        stateLock.lock()
        defer { stateLock.unlock() }
        return !knownHosts.contains { $0.hostname == probeHostname && $0.wsPort != nil }
    }

    private static func probeReachability(hostname: String, port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
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
        return connectResult == 0
    }

    private static func loadWsSecret() -> String {
        if let bundlePath = Bundle.main.path(forResource: "mobile-ws-secret", ofType: nil),
           let s = try? String(contentsOfFile: bundlePath, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }
        let home = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"]
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        let secretPath = "\(home)/Library/Application Support/cmux/mobile-ws-secret"
        return (try? String(contentsOfFile: secretPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
    }

    private static func loadProbeHostname() -> String {
        #if targetEnvironment(simulator)
        return "127.0.0.1"
        #else
        if let path = Bundle.main.path(forResource: "debug-relay-host", ofType: nil),
           let host = try? String(contentsOfFile: path, encoding: .utf8)
               .trimmingCharacters(in: .whitespacesAndNewlines),
           !host.isEmpty {
            return host
        }
        return "127.0.0.1"
        #endif
    }

    private static func loadForcedProbeHostname(env: [String: String]) -> String? {
        #if DEBUG
        guard let raw = env["CMUX_UITEST_DISCOVERY_HOST"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        return raw
        #else
        return nil
        #endif
    }

    private static func loadForcedProbePorts(env: [String: String]) -> [Int]? {
        #if DEBUG
        guard let raw = env["CMUX_UITEST_DISCOVERY_PORTS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }
        let ports = raw
            .split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { (1...65535).contains($0) }
        return ports.isEmpty ? nil : ports
        #else
        return nil
        #endif
    }

    private static func loadHintedPorts() -> [Int] {
        // Optional hint from reload.sh. Treated as a hint only - the full
        // port scan is authoritative so a missing or stale hint can never
        // silently break discovery.
        guard let path = Bundle.main.path(forResource: "debug-ws-port", ofType: nil),
              let raw = try? String(contentsOfFile: path, encoding: .utf8),
              let port = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return [] }
        return [port]
    }

    private static func loadExpectedInstanceID() -> String? {
        guard let path = Bundle.main.path(forResource: "debug-ws-instance", ofType: nil),
              let raw = try? String(contentsOfFile: path, encoding: .utf8)
        else { return nil }
        let instanceID = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return instanceID.isEmpty ? nil : instanceID
    }
}
