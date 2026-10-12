import CmuxNativeHost
import CmuxNativeLink
import CmuxNativeWire
import Foundation

/// `cmux-native-host e2e`: runs the host bridge and a phone link in one
/// process and drives the daemon and host services through the link.
struct SelfTest {
    let args: Arguments
    var failures = 0

    init(args: Arguments) {
        self.args = args
    }

    mutating func check(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
        let extra = detail()
        print("\(ok ? "PASS" : "FAIL") \(what)\(extra.isEmpty ? "" : ": \(extra)")")
        if !ok { failures += 1 }
    }

    mutating func run() async throws -> Bool {
        let transport = args.options["transport"] ?? "worker"
        let locator = DaemonSocketLocator(explicitPath: args.options["socket"], session: args.options["session"])
        guard let socket = locator.resolve() else { throw CLIError("no daemon socket found (use --socket or --session)") }
        print("daemon socket: \(socket)")

        let acceptor: any HostAcceptor
        let link: any HostLink
        switch transport {
        case "worker":
            let api = try args.url("api") ?? URL(string: "https://cmux-next-native.debussy.workers.dev")!
            guard let secret = ProcessInfo.processInfo.environment["CMUX_NATIVE_DEV_SECRET"], !secret.isEmpty else {
                throw CLIError("set CMUX_NATIVE_DEV_SECRET for the worker transport")
            }
            let worker = WorkerAPI(baseURL: api)
            let auth = try await worker.authDev(email: "native-host-e2e@test.cmux.dev", secret: secret)
            let host = try await worker.withToken(auth.sessionToken).registerHost(name: "e2e-\(ProcessInfo.processInfo.hostName)", platform: "macos")
            print("worker: \(api.absoluteString) user \(auth.user.id) host \(host.hostID)")
            let relayOnly = args.flags.contains("relay-only")
            acceptor = WebRTCHostAcceptor(configuration: .init(apiBase: api, hostID: host.hostID, hostSecret: host.hostSecret, relayOnly: relayOnly))
            var config = WebRTCHostLink.Configuration(apiBase: api, hostID: host.hostID, token: { auth.sessionToken })
            config.relayOnly = relayOnly
            let service = NativeHostService(acceptor: acceptor, configuration: .init(locator: locator, log: log))
            await service.start()
            // No wait for the host's signaling socket: an early offer gets
            // host_offline and the phone link retries with backoff.
            link = WebRTCHostLink(configuration: config)
            let ok = try await exercise(link: link, acceptorService: service)
            _ = try? await worker.withToken(auth.sessionToken).unpair(hostID: host.hostID)
            return ok
        case "local":
            let hub = InMemorySignalingHub()
            acceptor = WebRTCHostAcceptor(signaling: { hub.hostTransport() }, iceServers: { [] })
            let service = NativeHostService(acceptor: acceptor, configuration: .init(locator: locator, log: log))
            await service.start()
            link = WebRTCHostLink(signaling: { hub.phoneTransport(userID: "e2e") }, iceServers: { [] })
            return try await exercise(link: link, acceptorService: service)
        case "loopback":
            let loop = LoopbackHostAcceptor()
            let service = NativeHostService(acceptor: loop, configuration: .init(locator: locator, log: log))
            await service.start()
            link = LoopbackHostLink(port: try await loop.port())
            return try await exercise(link: link, acceptorService: service)
        default:
            throw CLIError("unknown transport \(transport)")
        }
    }

    // swiftlint:disable:next function_body_length
    mutating func exercise(link: any HostLink, acceptorService service: NativeHostService) async throws -> Bool {
        let started = ContinuousClock.now
        var connectedState: LinkState?
        for await state in link.state {
            print("link state: \(state)")
            if case .connected = state {
                connectedState = state
                break
            }
            if state.isTerminal || ContinuousClock.now - started > .seconds(40) { break }
        }
        check(connectedState != nil, "link connected", "\(connectedState.map { "\($0)" } ?? "no") in \(ContinuousClock.now - started)")
        guard connectedState != nil else { return false }
        if let rtc = link as? WebRTCHostLink {
            // Let stats settle, then report the selected pair.
            try await Task.sleep(for: .milliseconds(500))
            if let info = rtc.pathInfo {
                print("path: \(info.path) local=\(info.localCandidateType ?? "?") remote=\(info.remoteCandidateType ?? "?") relay=\(info.relayProtocol ?? "-") rtt=\(info.rtt.map { "\($0)" } ?? "?")")
            }
        }

        // Daemon control channel.
        let control = ChannelClient(channel: try await link.openChannel(label: "daemon:\(UUID().uuidString.lowercased())"))
        let identify = try await control.request(["cmd": "identify"])
        let proto = identify["data"]?["protocol"]?.intValue
        check(identify["ok"] == true && proto == 12, "identify", "protocol \(proto.map(String.init) ?? "?"), app \(identify["data"]?["app"]?.stringValue ?? "?"), session \(identify["data"]?["session"]?.stringValue ?? "?")")

        var surface = try await firstSurface(control)
        if surface == nil {
            let created = try await control.request(["cmd": "new-workspace", "name": "native-e2e", "cols": 100, "rows": 30])
            check(created["ok"] == true, "new-workspace (no workspaces yet)", created["error"]?.stringValue ?? "")
            surface = try await firstSurface(control)
        }
        check(surface != nil, "list-workspaces", "first pty surface \(surface.map(String.init) ?? "none")")
        guard let surface else { return false }

        // Attach on its own channel, like the app does.
        let attach = ChannelClient(channel: try await link.openChannel(label: "daemon:\(UUID().uuidString.lowercased())"))
        try await attach.sendRaw(["id": 1, "cmd": "attach-surface", "surface": .number(Double(surface)), "cols": 100, "rows": 30])
        let vt = try await attach.waitFor { $0["event"]?.stringValue == "vt-state" }
        let vtBytes = vt["data"]?.stringValue.flatMap { Data(base64Encoded: $0) }?.count ?? -1
        check(vtBytes >= 0, "attach-surface vt-state", "\(vt["cols"]?.intValue ?? 0)x\(vt["rows"]?.intValue ?? 0), \(vtBytes) replay bytes")
        let attached = try await attach.waitFor { $0["id"]?.intValue == 1 && $0["event"] == nil }
        check(attached["ok"] == true, "attach-surface response", attached["error"]?.stringValue ?? "")

        let marker = "nxn-e2e-\(Int.random(in: 100_000...999_999))"
        let sent = try await control.request(["cmd": "send", "surface": .number(Double(surface)), "text": .string("echo \(marker)\r")])
        check(sent["ok"] == true, "send", sent["error"]?.stringValue ?? "")
        let output = try? await attach.waitFor(timeout: .seconds(15)) { line in
            guard line["event"] != nil, let data = line["data"]?.stringValue, let bytes = Data(base64Encoded: data) else { return false }
            return String(decoding: bytes, as: UTF8.self).contains(marker)
        }
        check(output != nil, "attach stream carries the sent command's output", output?["event"]?.stringValue ?? "no event with marker")
        let screen = try await control.request(["cmd": "read-screen", "surface": .number(Double(surface))])
        let text = screen["data"]?["text"]?.stringValue ?? ""
        check(text.contains(marker), "read-screen shows output", "marker \(marker) \(text.contains(marker) ? "found" : "missing")")

        // Allowlist.
        let run = try await control.request(["cmd": "run", "argv": ["/usr/bin/true"]])
        check(run["ok"] == false && run["error_code"]?.stringValue == "forbidden", "run is refused", run["error"]?.stringValue ?? "")
        let tab = try await control.request(["cmd": "new-tab", "cwd": "/"])
        check(tab["error_code"]?.stringValue == "forbidden", "new-tab with cwd is refused", tab["error"]?.stringValue ?? "")

        // Host services.
        let svc = ChannelClient(channel: try await link.openChannel(label: "svc"))
        let info = try await svc.request(["method": "host.info"])
        check(info["ok"] == true, "svc host.info", "\(info["result"]?["hostname"]?.stringValue ?? "?") \(info["result"]?["os"]?.stringValue ?? "")")
        let list = try await svc.request(["method": "fs.list", "params": ["path": "~"]])
        check(list["ok"] == true, "svc fs.list ~", "\(list["result"]?["entries"]?.arrayValue?.count ?? 0) entries")
        let outside = try await svc.request(["method": "fs.read", "params": ["path": "/etc/hosts"]])
        check(outside["error"]?["code"]?.stringValue == "forbidden", "svc fs.read outside home is refused")
        let blob = Data((0..<100_000).map { UInt8($0 % 256) })
        let put = try await svc.request(["method": "upload.put", "params": ["name": "e2e.bin", "data_b64": .string(blob.base64EncodedString())]])
        let uploaded = put["result"]?["path"]?.stringValue ?? ""
        check(put["ok"] == true && (try? Data(contentsOf: URL(fileURLWithPath: uploaded))) == blob, "svc upload.put (100 KB, fragmented)", uploaded)
        let read = try await svc.request(["method": "fs.read", "params": ["path": .string(uploaded), "length": 200_000]])
        check(read["result"]?["data"]?.stringValue.flatMap { Data(base64Encoded: $0) } == blob, "svc fs.read round trip")
        try? FileManager.default.removeItem(atPath: uploaded)
        if let repo = args.options["git-repo"] {
            let status = try await svc.request(["method": "git.status", "params": ["cwd": .string(repo)]])
            check(status["ok"] == true, "svc git.status", "\(status["result"]?["files"]?.arrayValue?.count ?? -1) files on \(status["result"]?["branch"]?.stringValue ?? "?")")
            let diff = try await svc.request(["method": "git.diff", "params": ["cwd": .string(repo)]])
            let files = diff["result"]?["files"]?.arrayValue ?? []
            check(diff["ok"] == true && !files.isEmpty, "svc git.diff", files.map { "\($0["path"]?.stringValue ?? "?"):\($0["status"]?.stringValue ?? "?")+\($0["additions"]?.intValue ?? 0)" }.joined(separator: " "))
            let refs = try await svc.request(["method": "session.refs", "params": ["cwd": .string(repo), "text": "edited README.md and src/main.swift:12:3, see https://cmux.com/docs."]])
            check(refs["ok"] == true, "svc session.refs", (refs["result"]?["refs"]?.arrayValue ?? []).map { "\($0["kind"]?.stringValue ?? "?"):\($0["path"]?.stringValue ?? "?")" }.joined(separator: " "))
        }

        await control.close()
        await attach.close()
        await svc.close()
        link.close()
        await service.stop()
        print(failures == 0 ? "E2E PASS" : "E2E FAIL (\(failures) failed)")
        return failures == 0
    }

    func firstSurface(_ control: ChannelClient) async throws -> Int? {
        let list = try await control.request(["cmd": "list-workspaces"])
        for workspace in list["data"]?["workspaces"]?.arrayValue ?? [] {
            for screen in workspace["screens"]?.arrayValue ?? [] {
                for pane in screen["panes"]?.arrayValue ?? [] {
                    for tab in pane["tabs"]?.arrayValue ?? [] where tab["kind"]?.stringValue == "pty" && tab["dead"] != true {
                        if let id = tab["surface"]?.intValue { return id }
                    }
                }
            }
        }
        return nil
    }
}
