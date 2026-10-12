import CNMBackend
import CNMHost
import CNMTransport
import CNMWebRTC
import Foundation

// cnm-host: the Mac side of cmux-next mobile.
//
//   cnm-host pair            show a pairing code, wait for the phone to claim it
//   cnm-host serve           accept phones over WebRTC (pairs first if needed)
//   cnm-host status          print the saved host identity
//   cnm-host unpair          forget the saved host identity
//
// Options: --backend URL, --name NAME, --state DIR, --relay-only

struct HostIdentity: Codable {
    var hostID: String
    var hostToken: String
    var userEmail: String?
    var name: String
}

struct Options {
    var command = "serve"
    var backend = BackendClient.productionURL
    var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    var state: URL?
    var relayOnly = false

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        var positional: [String] = []
        while let argument = iterator.next() {
            switch argument {
            case "--backend": if let value = iterator.next(), let url = URL(string: value) { backend = url }
            case "--name": if let value = iterator.next() { name = value }
            case "--state": if let value = iterator.next() { state = URL(fileURLWithPath: value) }
            case "--relay-only": relayOnly = true
            default: positional.append(argument)
            }
        }
        if let first = positional.first { command = first }
    }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter().string(from: Date())
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

let options = Options(CommandLine.arguments)
let environment = HostEnvironment(supportDirectory: options.state)
let identityURL = environment.supportDirectory.appendingPathComponent("identity.json")
let backend = BackendClient(baseURL: options.backend)

func loadIdentity() -> HostIdentity? {
    guard let data = try? Data(contentsOf: identityURL) else { return nil }
    return try? JSONDecoder().decode(HostIdentity.self, from: data)
}

func saveIdentity(_ identity: HostIdentity) throws {
    let data = try JSONEncoder().encode(identity)
    try data.write(to: identityURL, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: identityURL.path)
}

func pair() async throws -> HostIdentity {
    let start = try await backend.startPairing(hostName: options.name, platform: "macos", appVersion: HostServer.version)
    let spaced = start.code.enumerated().map { $0.offset == 3 ? " \($0.element)" : "\($0.element)" }.joined()
    print("""

      Pair \(options.name) with cmux on your iPhone:
      open the menu → Macs → Add a Mac, and enter

          \(spaced)

      The code expires in 10 minutes.

    """)
    print("PAIRING_CODE=\(start.code)")
    fflush(stdout)
    while true {
        try await Task.sleep(for: .seconds(2))
        let poll = try await backend.pollPairing(start)
        switch poll.status {
        case "claimed":
            guard let hostID = poll.hostID, let token = poll.hostToken else { throw TransportError("Pairing reply is incomplete") }
            let identity = HostIdentity(hostID: hostID, hostToken: token, userEmail: poll.user?.email, name: options.name)
            try saveIdentity(identity)
            print("Paired with \(poll.user?.email ?? "your account").")
            return identity
        case "pending":
            continue
        default:
            throw TransportError("Pairing \(poll.status). Run `cnm-host pair` again.")
        }
    }
}

func serve() async throws -> Never {
    var identity = loadIdentity()
    if identity == nil { identity = try await pair() }
    guard let identity else { exit(1) }
    let token = identity.hostToken
    let peerID = "host-" + identity.hostID
    let server = HostServer(hostName: identity.name, hostID: identity.hostID, environment: environment, log: log)
    let signaling = WebSocketSignaling(baseURL: options.backend, peerID: peerID, tokenProvider: { token })
    let hub = SignalHub(channel: signaling)
    let client = backend
    let acceptor = WebRTCAcceptor(hub: hub, options: WebRTCOptions(
        iceServers: {
            let servers = (try? await client.iceServers(token: token)) ?? []
            let mapped = servers.map { ICEServer(urls: $0.urls, username: $0.username, credential: $0.credential) }
            return mapped.isEmpty ? [.cloudflareSTUN] : mapped
        },
        relayOnly: options.relayOnly
    ))
    log("serving \(identity.name) (\(identity.hostID)) for \(identity.userEmail ?? "?") via \(options.backend.host ?? "")")
    Task {
        for await event in hub.subscribe() {
            switch event {
            case .welcome(let me, let peers): log("signaling up as \(me.id); \(peers.count) peers")
            case .closed(let reason): log("signaling closed: \(reason ?? "")")
            default: break
            }
        }
    }
    for await link in acceptor.incoming {
        Task {
            for await state in link.states {
                if case .connected(let route) = state { log("link \(link.remotePeerID) connected via \(route)") }
            }
        }
        server.serve(link)
    }
    exit(0)
}

setvbuf(stdout, nil, _IOLBF, 0)
switch options.command {
case "pair":
    _ = try await pair()
case "serve":
    try await serve()
case "status":
    if let identity = loadIdentity() {
        print("Paired as \(identity.name) (\(identity.hostID)) for \(identity.userEmail ?? "?")")
    } else {
        print("Not paired. Run `cnm-host pair`.")
    }
case "unpair":
    try? FileManager.default.removeItem(at: identityURL)
    print("Forgot this Mac's pairing.")
default:
    print("usage: cnm-host [pair|serve|status|unpair] [--backend URL] [--name NAME] [--state DIR] [--relay-only]")
    exit(2)
}
