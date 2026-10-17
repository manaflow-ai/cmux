import Darwin
import Foundation
import Testing

/// Black-box `cmux vm ports` / `cmux vm open <m> <port>` against a scripted socket.
@Suite("cmux vm ports and the vm open port preflight", .serialized)
struct CLIVMPortsCommandTests {
    /// What `ss -ltnp` printed on the evaluator's desktop machine with one dev server.
    static let listing = """
        State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
        LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*     users:(("systemd-resolve",pid=310,fd=14))
        LISTEN 0      128          0.0.0.0:22         0.0.0.0:*     users:(("sshd",pid=402,fd=3))
        LISTEN 0      4096               *:1337             *:*     users:(("cmux-tui",pid=512,fd=9))
        LISTEN 0      5            0.0.0.0:5901       0.0.0.0:*     users:(("Xtigervnc",pid=640,fd=7))
        LISTEN 0      100          0.0.0.0:6901       0.0.0.0:*     users:(("websockify",pid=641,fd=3))
        LISTEN 0      511          0.0.0.0:3000       0.0.0.0:*     users:(("node",pid=2000,fd=21))
        LISTEN 0      511        127.0.0.1:5173       0.0.0.0:*     users:(("vite",pid=2100,fd=21))
        """

    static func responder(method: String, params: [String: Any]) -> [String: Any]? {
        switch method {
        case "vm.exec":
            return ["exit_code": 0, "stdout": listing, "stderr": ""]
        case "vm.status":
            return ["id": params["id"] ?? "", "status": "running", "privateAddress": "10.140.85.1"]
        case "vm.publication_list":
            return ["publications": [
                ["vmId": "vivid-newt", "port": 3000, "accessMode": "team", "url": "https://x.cmux.sh"],
                ["vmId": "other-vm", "port": 5173, "accessMode": "public", "url": "https://y.cmux.sh"],
            ]]
        case "vm.port_open":
            return ["surface_id": "surface-1", "workspace_id": "workspace-1", "url": "http://10.140.85.1:\(params["port"] ?? 0)"]
        case "vm.open_port":
            return ["open_url": "https://preview.example/\(params["port"] ?? 0)"]
        default:
            return [:]
        }
    }

    @Test("vm ports shows only the person's servers as a table, system ports behind --all")
    func defaultTable() throws {
        let (result, requests) = try runCLI(["vm", "ports", "vivid-newt"])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let lines = result.stdout.split(separator: "\n").map(String.init)
        #expect(lines.first?.hasPrefix("PORT") == true, Comment(rawValue: result.stdout))
        #expect(lines.first?.contains("PRIVATE URL") == true)
        #expect(lines.first?.contains("SHARED") == true)
        #expect(lines.contains { $0.hasPrefix("3000") && $0.contains("node") && $0.contains("http://10.140.85.1:3000") && $0.hasSuffix("team") })
        #expect(lines.contains { $0.hasPrefix("5173") && $0.contains("vite") && $0.contains("http://10.140.85.1:5173 *") && $0.hasSuffix("none") })
        for system in ["22 ", "53 ", "1337", "5901", "6901"] {
            #expect(!lines.contains { $0.hasPrefix(system) }, Comment(rawValue: result.stdout))
        }
        #expect(result.stdout.contains("System ports hidden: 5"))
        #expect(requests.contains("vm.exec"))

        let (all, _) = try runCLI(["vm", "ports", "vivid-newt", "--all"])
        #expect(all.status == 0, Comment(rawValue: all.stderr))
        let allLines = all.stdout.split(separator: "\n").map(String.init)
        #expect(allLines.first?.contains("KIND") == true)
        #expect(allLines.contains { $0.hasPrefix("22 ") && $0.hasSuffix("ssh") })
        #expect(allLines.contains { $0.hasPrefix("1337") && $0.hasSuffix("cmux") })
        #expect(!all.stdout.contains("System ports hidden"))
    }

    @Test("vm ports --json keeps the raw inventory and flags system ports")
    func json() throws {
        let (result, _) = try runCLI(["vm", "ports", "vivid-newt", "--json"])
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect((object["stdout"] as? String)?.contains("users:((\"sshd\"") == true)
        let ports = try #require(object["ports"] as? [[String: Any]])
        let byPort = Dictionary(uniqueKeysWithValues: ports.compactMap { row in (row["port"] as? Int).map { ($0, row) } })
        #expect(byPort[22]?["system"] as? Bool == true)
        #expect(byPort[3000]?["system"] as? Bool == false)
        #expect(byPort[3000]?["shared"] as? String == "team")
        #expect(byPort[3000]?["private_url"] as? String == "http://10.140.85.1:3000")
        #expect(byPort[5173]?["loopback_only"] as? Bool == true)
    }

    @Test("vm open refuses a port nothing listens on and names the listening ones")
    func openDeadPortWarns() throws {
        let (result, requests) = try runCLI(["vm", "open", "vivid-newt", "9999"])
        #expect(result.status != 0)
        #expect(result.stderr.contains("Nothing is listening on port 9999 inside vivid-newt."), Comment(rawValue: result.stderr))
        #expect(result.stderr.contains("3000 (node)"))
        #expect(result.stderr.contains("5173 (vite)"))
        #expect(!result.stderr.contains("22 (sshd)"))
        #expect(result.stderr.contains("--force"))
        #expect(!requests.contains("vm.port_open"), "a dead port must not open a pane")
        #expect(!result.stdout.contains("http"))
    }

    @Test("vm open --force and a listening port both open the pane")
    func openForceAndLivePort() throws {
        let (forced, forcedRequests) = try runCLI(["vm", "open", "vivid-newt", "9999", "--force"])
        #expect(forced.status == 0, Comment(rawValue: forced.stderr))
        #expect(forcedRequests.contains("vm.port_open"))
        #expect(!forcedRequests.contains("vm.exec"), "--force skips the preflight")

        let (live, liveRequests) = try runCLI(["vm", "open", "vivid-newt", "3000"])
        #expect(live.status == 0, Comment(rawValue: live.stderr))
        #expect(liveRequests.contains("vm.exec"))
        #expect(liveRequests.contains("vm.port_open"))
        #expect(live.stdout.contains("http://10.140.85.1:3000"))
    }

    @Test("vm open with an invalid port prints usage and leaves a paused machine asleep")
    func openInvalidPortDoesNotWake() throws {
        let respond: @Sendable (String, [String: Any]) -> [String: Any]? = { method, params in
            method == "vm.status" ? ["id": params["id"] ?? "", "status": "paused"] : [:]
        }
        for port in ["0", "65536", "nope"] {
            let (result, requests) = try runCLI(["vm", "open", "vivid-newt", port], respond: respond)
            #expect(result.status != 0)
            #expect(result.stderr.contains("cmux vm open"), Comment(rawValue: result.stderr))
            #expect(!result.stderr.contains("Waking"), Comment(rawValue: result.stderr))
            #expect(!requests.contains("vm.resume"), "an invalid port must not wake the machine (\(port))")
        }
    }

    // MARK: - vm share

    @Test("vm share with no flag says who can open the port and writes nothing")
    func shareStatus() throws {
        let fixture = PublicationFixture()
        let (result, requests) = try runCLI(["vm", "share", "vivid-newt", "3000"], respond: fixture.respond)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout.contains("Port 3000 on vivid-newt: shared with your team"), Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("https://gen.cmux.sh"))
        #expect(result.stdout.contains("cmux vm share vivid-newt 3000 --team"))
        #expect(!requests.contains { ["vm.publication_create", "vm.publication_update", "vm.publication_delete"].contains($0) })
    }

    @Test("vm share --team gives an unshared port one team link through the domains methods")
    func shareTeam() throws {
        let fixture = PublicationFixture()
        let (result, _) = try runCLI(["vm", "share", "vivid-newt", "5173", "--team"], respond: fixture.respond)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let created = fixture.calls.filter { $0.method == "vm.publication_create" }
        #expect(created.count == 1)
        #expect(created.first?.params["accessMode"] as? String == "team")
        #expect(created.first?.params["teamId"] as? String == "team-1")
        #expect(created.first?.params["port"] as? Int == 5173)
        #expect(result.stdout.contains("Port 5173 on vivid-newt: shared with your team"), Comment(rawValue: result.stdout))
    }

    @Test("vm share --public asks first and refuses without a terminal or --yes")
    func sharePublicRefusedWithoutConfirmation() throws {
        let fixture = PublicationFixture()
        let (result, requests) = try runCLI(["vm", "share", "vivid-newt", "5173", "--public"], respond: fixture.respond)
        #expect(result.status != 0)
        #expect(result.stderr.contains("anyone on the internet"), Comment(rawValue: result.stderr))
        #expect(result.stderr.contains("--yes"))
        #expect(!requests.contains("vm.publication_create"), "a refused public share must write nothing")
    }

    @Test("vm share --public --yes creates the link private, then opens it")
    func sharePublicConfirmed() throws {
        let fixture = PublicationFixture()
        let (result, _) = try runCLI(["vm", "share", "vivid-newt", "5173", "--public", "--yes"], respond: fixture.respond)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let writes = fixture.calls.filter { $0.method.hasPrefix("vm.publication_") && $0.method != "vm.publication_list" }
        #expect(writes.map(\.method) == ["vm.publication_create", "vm.publication_update"])
        #expect(writes.first?.params["accessMode"] as? String == "personal")
        #expect(writes.last?.params["accessMode"] as? String == "public")
        #expect(writes.last?.params["confirmPublic"] as? Bool == true)
        #expect(result.stdout.contains("PUBLIC (anyone with the link)"), Comment(rawValue: result.stdout))
    }

    @Test("vm share --private deletes generated links and keeps a custom domain for the owner")
    func stopSharing() throws {
        let fixture = PublicationFixture()
        let (result, _) = try runCLI(["vm", "share", "vivid-newt", "3000", "--private"], respond: fixture.respond)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(fixture.calls.contains { $0.method == "vm.publication_delete" && $0.params["id"] as? String == "gen" })
        #expect(fixture.calls.contains {
            $0.method == "vm.publication_update" && $0.params["id"] as? String == "custom"
                && $0.params["accessMode"] as? String == "personal"
        })
        #expect(!fixture.calls.contains { $0.method == "vm.publication_delete" && $0.params["id"] as? String == "custom" })
        #expect(result.stdout.contains("Kept app.example.com for you only"), Comment(rawValue: result.stdout))
    }

    @Test("vm share --json reports the audience and every link of the port")
    func shareJSON() throws {
        let fixture = PublicationFixture()
        let (result, _) = try runCLI(["vm", "share", "vivid-newt", "3000", "--json"], respond: fixture.respond)
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        #expect(object["shared"] as? String == "team")
        #expect(object["changed"] as? Bool == false)
        let links = try #require(object["links"] as? [[String: Any]])
        #expect(links.map { $0["id"] as? String } == ["gen", "custom"])
        #expect(links.last?["generated"] as? Bool == false)
    }

    @Test("vm share refuses a bad port and conflicting audiences before any request")
    func shareUsage() throws {
        let fixture = PublicationFixture()
        let (badPort, _) = try runCLI(["vm", "share", "vivid-newt", "nope"], respond: fixture.respond)
        #expect(badPort.status != 0)
        let (both, _) = try runCLI(["vm", "share", "vivid-newt", "3000", "--team", "--public"], respond: fixture.respond)
        #expect(both.status != 0)
        #expect(both.stderr.contains("cmux vm share <machine> <port>"), Comment(rawValue: both.stderr))
        #expect(!fixture.calls.contains { $0.method.hasPrefix("vm.publication_") })
    }

    // MARK: - Harness

    private func runCLI(_ arguments: [String]) throws -> (CLIHookProcessRunner.Result, [String]) {
        try runCLI(arguments, respond: Self.responder)
    }

    private func runCLI(
        _ arguments: [String],
        respond: @escaping @Sendable (String, [String: Any]) -> [String: Any]?
    ) throws -> (CLIHookProcessRunner.Result, [String]) {
        let server = try ScriptedVMSocketServer(respond: respond)
        defer { server.stop() }
        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(),
            arguments: arguments,
            environment: [
                "CMUX_SOCKET_PATH": server.path,
                "CMUX_SOCKET_PASSWORD": "",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            timeout: 20
        )
        #expect(!result.timedOut)
        return (result, server.methods())
    }
}

/// A machine with a team-shared port 3000 (a generated link plus a custom domain)
/// and an unshared 5173, answering the publication methods statefully.
private final class PublicationFixture: @unchecked Sendable {
    struct Call {
        let method: String
        let params: [String: Any]
    }

    private let lock = NSLock()
    private var publications: [[String: Any]] = [
        ["id": "gen", "hostname": "gen.cmux.sh", "url": "https://gen.cmux.sh", "domainKind": "generated",
         "vmId": "vivid-newt", "port": 3000, "accessMode": "team"],
        ["id": "custom", "hostname": "app.example.com", "url": "https://app.example.com", "domainKind": "custom",
         "vmId": "vivid-newt", "port": 3000, "accessMode": "team"],
    ]
    private var recorded: [Call] = []
    private var created = 0

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var respond: @Sendable (String, [String: Any]) -> [String: Any]? {
        { [self] method, params in handle(method, params) }
    }

    private func handle(_ method: String, _ params: [String: Any]) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(Call(method: method, params: params))
        switch method {
        case "vm.list":
            return ["vms": [["id": "vivid-newt", "displayName": "vivid-newt", "status": "running"]]]
        case "auth.team.list":
            return ["teams": [["id": "team-1"]], "selected_team_id": "team-1"]
        case "vm.publication_list":
            return ["publications": publications]
        case "vm.publication_create":
            created += 1
            let id = "new-\(created)"
            let publication: [String: Any] = [
                "id": id, "hostname": "\(id).cmux.sh", "url": "https://\(id).cmux.sh", "domainKind": "generated",
                "vmId": params["vmId"] ?? "", "port": params["port"] ?? 0, "accessMode": params["accessMode"] ?? "personal",
            ]
            publications.append(publication)
            return ["publication": publication]
        case "vm.publication_update":
            guard let index = publications.firstIndex(where: { $0["id"] as? String == params["id"] as? String }) else { return [:] }
            publications[index]["accessMode"] = params["accessMode"]
            return ["publication": publications[index]]
        case "vm.publication_delete":
            publications.removeAll { $0["id"] as? String == params["id"] as? String }
            return ["deleted": true, "id": params["id"] ?? ""]
        default:
            return [:]
        }
    }
}

/// Answers newline-delimited v2 requests from a closure, across any number of connections.
final class ScriptedVMSocketServer: @unchecked Sendable {
    let path: String
    private let respond: @Sendable (String, [String: Any]) -> [String: Any]?
    private let queue = DispatchQueue(label: "com.cmux.tests.vm-ports-socket", attributes: .concurrent)
    private let lock = NSLock()
    private var listenerFD: Int32
    private var seen: [String] = []
    private var stopped = false

    init(respond: @escaping @Sendable (String, [String: Any]) -> [String: Any]?) throws {
        self.respond = respond
        path = "/tmp/cmux-vm-ports-\(UUID().uuidString.prefix(8)).sock"
        unlink(path)
        listenerFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) {
                strncpy(UnsafeMutableRawPointer($0).assumingMemoryBound(to: CChar.self), source, capacity - 1)
            }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenerFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenerFD, 8) == 0 else {
            Darwin.close(listenerFD)
            throw POSIXError(.EADDRINUSE)
        }
        queue.async { [self] in acceptLoop() }
    }

    func methods() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        Darwin.shutdown(listenerFD, SHUT_RDWR)
        Darwin.close(listenerFD)
        unlink(path)
    }

    private func acceptLoop() {
        while true {
            let client = Darwin.accept(listenerFD, nil, nil)
            guard client >= 0 else { return }
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            queue.async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer { Darwin.close(client) }
        var buffer = Data()
        var byte: UInt8 = 0
        while Darwin.recv(client, &byte, 1, 0) == 1 {
            guard byte == 0x0A else { buffer.append(byte); continue }
            defer { buffer.removeAll() }
            guard let request = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
                  let method = request["method"] as? String else { continue }
            lock.lock()
            seen.append(method)
            lock.unlock()
            let result = respond(method, (request["params"] as? [String: Any]) ?? [:]) ?? [:]
            let response: [String: Any] = ["id": request["id"] ?? NSNull(), "ok": true, "result": result]
            guard var data = try? JSONSerialization.data(withJSONObject: response) else { return }
            data.append(0x0A)
            let sent = data.withUnsafeBytes { Darwin.send(client, $0.baseAddress, data.count, 0) }
            guard sent == data.count else { return }
        }
    }
}
