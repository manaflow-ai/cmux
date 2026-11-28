// NetLab: DEBUG-only network-change probe for the cmux-next transport (plans/cmux-next/transport.md 10).
// Drop into a DEBUG build (iOS 17+). Shows one screen with Start / Stop. While running it records,
// with mach continuous time (counts sleep):
//  - every NWPathMonitor update (status, interface types, expensive/constrained);
//  - UDP leg "kept": one NWConnection created at Start and never recreated (source-following only);
//  - UDP leg "rebound": a NWConnection recreated on every path change (what the engine does);
//    both ping the echo server every 100 ms; replies carry the server-observed source ip:port;
//  - STUN bindings (Cloudflare 3478, Google 19302, Cloudflare 53) at Start and after each change;
//  - a WebSocket to the relay echo (Durable Object) with one echo per second, reconnected on failure.
// Stop uploads the event log as JSON to the test server. No secret is logged; the upload token is
// pasted by the operator into the Token field (not committed).
#if DEBUG
import Network
import SwiftUI
import UIKit

struct NetLabConfig: Sendable {
    var udpHost = "cmuxnp-dev-tp-wc-server.fly.dev"   // dedicated IPv4 of the test server
    var udpPort: UInt16 = 9000
    var uploadURL = "https://cmuxnp-dev-tp-wc-server.fly.dev/log"
    var relayURL = ""                                  // wss://.../r/<room>?role=echo&t=<token>
    var token = ""
}

actor NetLabLog {
    private var events: [[String: String]] = []
    private let start = NetLabLog.nowNs()

    static func nowNs() -> UInt64 {
        clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) // counts sleep on Darwin (continuous)
    }

    func add(_ kind: String, _ fields: [String: String] = [:]) {
        var event = fields
        event["kind"] = kind
        event["t_ms"] = String(format: "%.3f", Double(NetLabLog.nowNs() - start) / 1e6)
        events.append(event)
    }

    func json() -> Data {
        (try? JSONSerialization.data(withJSONObject: ["events": events], options: [])) ?? Data()
    }
}

/// One UDP leg: pings every 100 ms with a sequence number and records each reply's RTT.
final class UdpLeg: @unchecked Sendable {
    private let name: String
    private let log: NetLabLog
    private let config: NetLabConfig
    private let queue = DispatchQueue(label: "netlab.udp")
    private var connection: NWConnection?
    private var sent: [UInt32: UInt64] = [:]
    private var seq: UInt32 = 0
    private var timer: DispatchSourceTimer?

    init(name: String, log: NetLabLog, config: NetLabConfig) {
        self.name = name; self.log = log; self.config = config
    }

    func start() {
        queue.async { self.open(reason: "start") }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.ping() }
        timer.resume()
        self.timer = timer
    }

    func rebind(reason: String) {
        queue.async { self.open(reason: reason) }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.connection?.cancel()
        }
    }

    private func open(reason: String) {
        connection?.cancel()
        let conn = NWConnection(
            host: NWEndpoint.Host(config.udpHost),
            port: NWEndpoint.Port(rawValue: config.udpPort)!,
            using: .udp
        )
        conn.stateUpdateHandler = { [log, name] state in
            Task { await log.add("udp_state", ["leg": name, "state": "\(state)"]) }
        }
        conn.pathUpdateHandler = { [log, name] path in
            Task { await log.add("udp_path", ["leg": name, "iface": path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")]) }
        }
        receive(conn)
        conn.start(queue: queue)
        connection = conn
        Task { await log.add("udp_open", ["leg": name, "reason": reason]) }
    }

    private func ping() {
        guard let conn = connection else { return }
        seq &+= 1
        let now = NetLabLog.nowNs()
        sent[seq] = now
        if sent.count > 4096 { sent.removeAll() }
        var payload = withUnsafeBytes(of: seq.bigEndian) { Data($0) }
        payload.append(Data(name.utf8))
        conn.send(content: payload, completion: .contentProcessed { [log, name, seq] error in
            if let error { Task { await log.add("udp_send_error", ["leg": name, "seq": "\(seq)", "error": "\(error)"]) } }
        })
    }

    private func receive(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, data.count >= 4 {
                let seq = data.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                let source = String(decoding: data.split(separator: UInt8(ascii: "|")).last ?? Data(), as: UTF8.self)
                if let sentAt = self.sent.removeValue(forKey: seq) {
                    let rtt = Double(NetLabLog.nowNs() - sentAt) / 1e6
                    Task { await self.log.add("udp_reply", ["leg": self.name, "seq": "\(seq)", "rtt_ms": String(format: "%.2f", rtt), "src": source]) }
                }
            }
            if error == nil { self.receive(conn) }
        }
    }
}

@MainActor
@Observable
final class NetLab {
    var running = false
    var status = "idle"
    var config = NetLabConfig()
    private let log = NetLabLog()
    private var monitor: NWPathMonitor?
    private var kept: UdpLeg?
    private var rebound: UdpLeg?
    private var socket: URLSessionWebSocketTask?
    private var wsTask: Task<Void, Never>?
    private var lastInterfaces = ""

    func start() {
        running = true
        status = "running"
        let kept = UdpLeg(name: "kept", log: log, config: config)
        let rebound = UdpLeg(name: "rebound", log: log, config: config)
        kept.start(); rebound.start()
        self.kept = kept; self.rebound = rebound
        stun(reason: "start")
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let interfaces = path.availableInterfaces.map { "\($0.type)" }.joined(separator: ",")
            Task { @MainActor in self?.pathChanged(path, interfaces: interfaces) }
        }
        monitor.start(queue: DispatchQueue(label: "netlab.path"))
        self.monitor = monitor
        wsTask = Task { await self.relayLoop() }
    }

    private func pathChanged(_ path: NWPath, interfaces: String) {
        let fields = ["status": "\(path.status)", "iface": interfaces,
                      "expensive": "\(path.isExpensive)", "constrained": "\(path.isConstrained)"]
        Task { await log.add("path", fields) }
        guard interfaces != lastInterfaces else { return }
        let first = lastInterfaces.isEmpty
        lastInterfaces = interfaces
        if first { return }
        rebound?.rebind(reason: "path:\(interfaces)")
        stun(reason: "path:\(interfaces)")
        socket?.cancel(with: .goingAway, reason: nil) // the relay loop reconnects at once
    }

    private func stun(reason: String) {
        for (host, port) in [("stun.cloudflare.com", UInt16(3478)), ("stun.l.google.com", UInt16(19302)), ("stun.cloudflare.com", UInt16(53))] {
            let conn = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .udp)
            let tx = (0..<12).map { _ in UInt8.random(in: 0...255) }
            var request = Data([0x00, 0x01, 0x00, 0x00, 0x21, 0x12, 0xA4, 0x42]); request.append(contentsOf: tx)
            conn.start(queue: .global())
            conn.send(content: request, completion: .idempotent)
            conn.receiveMessage { [log] data, _, _, _ in
                let hex = data.map { $0.map { String(format: "%02x", $0) }.joined() } ?? ""
                Task { await log.add("stun", ["server": "\(host):\(port)", "reason": reason, "response_hex": hex]) }
                conn.cancel()
            }
        }
    }

    private func relayLoop() async {
        while running && !Task.isCancelled {
            guard let url = URL(string: config.relayURL), !config.relayURL.isEmpty else { return }
            let opened = NetLabLog.nowNs()
            let task = URLSession.shared.webSocketTask(with: url)
            socket = task
            task.resume()
            await log.add("ws_open")
            var first = true
            while running {
                let sentAt = NetLabLog.nowNs()
                do {
                    try await task.send(.data(Data("echo".utf8)))
                    _ = try await task.receive()
                    let now = NetLabLog.nowNs()
                    var fields = ["rtt_ms": String(format: "%.2f", Double(now - sentAt) / 1e6)]
                    if first { fields["since_open_ms"] = String(format: "%.2f", Double(now - opened) / 1e6); first = false }
                    await log.add("ws_echo", fields)
                    try await Task.sleep(for: .seconds(1)) // measurement pacing in a DEBUG lab, not runtime code
                } catch {
                    await log.add("ws_error", ["error": "\(error)"])
                    break
                }
            }
        }
    }

    func stop() async {
        running = false
        kept?.stop(); rebound?.stop(); monitor?.cancel(); socket?.cancel(); wsTask?.cancel()
        status = "uploading"
        var request = URLRequest(url: URL(string: "\(config.uploadURL)?t=\(config.token)")!)
        request.httpMethod = "POST"
        request.httpBody = await log.json()
        let result = try? await URLSession.shared.data(for: request)
        status = (result?.1 as? HTTPURLResponse)?.statusCode == 200 ? "uploaded" : "upload failed"
    }
}

struct NetLabView: View {
    @State private var lab = NetLab()
    var body: some View {
        Form {
            Section("Config") {
                TextField("Relay wss URL", text: $lab.config.relayURL).textInputAutocapitalization(.never)
                SecureField("Upload token", text: $lab.config.token)
                // Handoff without the repo: the operator copies
                // {"relayURL": "...", "token": "..."} (e.g. from a QR code) and taps this.
                Button("Paste config from clipboard") { pasteConfig() }
            }
            Section {
                Text(lab.status)
                Button(lab.running ? "Stop and upload" : "Start") {
                    if lab.running { Task { await lab.stop() } } else { lab.start() }
                }
            }
        }
        .navigationTitle("Network Lab")
    }

    private func pasteConfig() {
        guard let text = UIPasteboard.general.string, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            lab.status = "clipboard has no {relayURL, token} JSON"
            return
        }
        if let relay = object["relayURL"] { lab.config.relayURL = relay }
        if let token = object["token"] { lab.config.token = token }
        lab.status = "config pasted"
    }
}
#endif
