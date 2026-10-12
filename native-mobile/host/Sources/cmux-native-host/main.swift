import CmuxNativeHost
import CmuxNativeLink
import CmuxNativeWire
import Foundation

let usage = """
usage:
  cmux-native-host register --api <url> --name <name> [--config <path>]
  cmux-native-host pair-code [--config <path>]
  cmux-native-host run [--socket <path>] [--session <name>] [--config <path>]
                       [--loopback-port <port>] [--no-worker] [--relay-only]
  cmux-native-host e2e [--transport worker|local|loopback] [--api <url>] [--socket <path>]
                       [--session <name>] [--relay-only] [--git-repo <dir>]
       (worker transport reads the dev login secret from $CMUX_NATIVE_DEV_SECRET)
"""

struct Arguments {
    var command: String
    var options: [String: String] = [:]
    var flags: Set<String> = []

    init(_ argv: [String]) throws {
        guard let first = argv.first else { throw CLIError(usage) }
        command = first
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            guard arg.hasPrefix("--") else { throw CLIError("unexpected argument \(arg)\n\(usage)") }
            let name = String(arg.dropFirst(2))
            if ["no-worker", "relay-only", "help"].contains(name) {
                flags.insert(name)
                i += 1
            } else {
                guard i + 1 < argv.count else { throw CLIError("--\(name) needs a value") }
                options[name] = argv[i + 1]
                i += 2
            }
        }
    }

    func url(_ name: String) throws -> URL? {
        guard let value = options[name] else { return nil }
        guard let url = URL(string: value), url.scheme == "https" || url.scheme == "http" else { throw CLIError("bad --\(name) \(value)") }
        return url
    }
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime])
    FileHandle.standardError.write(Data("[\(stamp)] \(message)\n".utf8))
}

func store(_ args: Arguments) -> HostConfigStore {
    HostConfigStore(url: args.options["config"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) })
}

func register(_ args: Arguments) async throws {
    guard let api = try args.url("api"), let name = args.options["name"] else { throw CLIError("register needs --api and --name") }
    let response = try await WorkerAPI(baseURL: api).registerHost(name: name, platform: "macos")
    let config = HostConfig(api: api, hostID: response.hostID, hostSecret: response.hostSecret, name: name)
    let s = store(args)
    try s.save(config)
    print("registered host \(response.hostID) (\(name))")
    print("saved \(s.url.path)")
    print("pairing code: \(response.pairingCode)")
}

func pairCode(_ args: Arguments) async throws {
    let config = try store(args).load()
    let response = try await WorkerAPI(baseURL: config.api, token: config.hostSecret).pairingCode()
    print(response.pairingCode)
}

func run(_ args: Arguments) async throws -> Never {
    var acceptors: [any HostAcceptor] = []
    if !args.flags.contains("no-worker") {
        let config = try store(args).load()
        acceptors.append(WebRTCHostAcceptor(configuration: .init(
            apiBase: config.api, hostID: config.hostID, hostSecret: config.hostSecret,
            relayOnly: args.flags.contains("relay-only"))))
        log("host \(config.hostID) (\(config.name)) via \(config.api.absoluteString)")
    }
    if let port = args.options["loopback-port"].flatMap(UInt16.init) {
        acceptors.append(LoopbackHostAcceptor(port: port))
        log("loopback transport on 127.0.0.1:\(port)")
    }
    guard !acceptors.isEmpty else { throw CLIError("nothing to run: --no-worker without --loopback-port") }
    let locator = DaemonSocketLocator(explicitPath: args.options["socket"], session: args.options["session"])
    let service = NativeHostService(acceptors: acceptors, configuration: .init(locator: locator, log: log))
    await service.start()
    let signals = AsyncStream<Int32> { continuation in
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { continuation.yield(sig) }
            source.resume()
            nonisolatedRetain(source)
        }
    }
    for await sig in signals {
        log("signal \(sig); stopping")
        break
    }
    await service.stop()
    exit(0)
}

nonisolated(unsafe) var retained: [AnyObject] = []
func nonisolatedRetain(_ object: AnyObject) { retained.append(object) }

let argv = Array(CommandLine.arguments.dropFirst())
do {
    let args = try Arguments(argv)
    if args.flags.contains("help") || args.command == "help" {
        print(usage)
        exit(0)
    }
    switch args.command {
    case "register": try await register(args)
    case "pair-code": try await pairCode(args)
    case "run": try await run(args)
    case "e2e":
        var test = SelfTest(args: args)
        exit(try await test.run() ? 0 : 1)
    default: throw CLIError("unknown command \(args.command)\n\(usage)")
    }
} catch {
    FileHandle.standardError.write(Data("cmux-native-host: \(error)\n".utf8))
    exit(2)
}
