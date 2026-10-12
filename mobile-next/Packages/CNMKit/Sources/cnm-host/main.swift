import CNMBackend
import CNMHost
import CNMHostRuntime
import Foundation

// cnm-host: the Mac side of cmux-next mobile, from a terminal.
//
//   cnm-host pair            show a pairing code, wait for the phone to claim it
//   cnm-host serve           accept phones over WebRTC (pairs first if needed)
//   cnm-host status          print the saved host identity
//   cnm-host unpair          forget the saved host identity
//
// Options: --backend URL, --name NAME, --state DIR, --relay-only

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

func printCode(_ code: String, name: String) {
    let spaced = code.enumerated().map { $0.offset == 3 ? " \($0.element)" : "\($0.element)" }.joined()
    print("""

      Pair \(name) with cmux on your iPhone:
      open the menu → Macs → Add a Mac, and enter

          \(spaced)

      The code expires in 10 minutes.

    """)
    print("PAIRING_CODE=\(code)")
    fflush(stdout)
}

setvbuf(stdout, nil, _IOLBF, 0)
let options = Options(CommandLine.arguments)
let runtime = await HostRuntime(
    environment: HostEnvironment(supportDirectory: options.state),
    backend: BackendClient(baseURL: options.backend),
    name: options.name,
    log: log
)
await MainActor.run { runtime.relayOnly = options.relayOnly }

switch options.command {
case "pair":
    let identity = try await runtime.pair { printCode($0, name: options.name) }
    print("Paired with \(identity.userEmail ?? "your account").")
case "serve":
    if await runtime.identity == nil {
        let identity = try await runtime.pair { printCode($0, name: options.name) }
        print("Paired with \(identity.userEmail ?? "your account").")
    }
    await runtime.start()
    while true { try await Task.sleep(for: .seconds(3600)) }
case "status":
    if let identity = await runtime.identity {
        print("Paired as \(identity.name) (\(identity.hostID)) for \(identity.userEmail ?? "?")")
    } else {
        print("Not paired. Run `cnm-host pair`.")
    }
case "unpair":
    await runtime.unpair()
    print("Forgot this Mac's pairing.")
default:
    print("usage: cnm-host [pair|serve|status|unpair] [--backend URL] [--name NAME] [--state DIR] [--relay-only]")
    exit(2)
}
