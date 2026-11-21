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
// Options: --backend URL, --name NAME, --state DIR, --relay-only, --approve EMAIL

struct Options {
    var command = "serve"
    var backend = BackendClient.productionURL
    var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    var state: URL?
    var relayOnly = false
    /// Approve a claim without asking when it comes from exactly this
    /// account (automated runs only).
    var autoApprove: String?

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        var positional: [String] = []
        while let argument = iterator.next() {
            switch argument {
            case "--backend": if let value = iterator.next(), let url = URL(string: value) { backend = url }
            case "--name": if let value = iterator.next() { name = value }
            case "--state": if let value = iterator.next() { state = URL(fileURLWithPath: value) }
            case "--relay-only": relayOnly = true
            case "--approve": autoApprove = iterator.next()?.lowercased()
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

/// Asks on the terminal before giving this Mac to the account that claimed
/// the code (or approves the one account named by --approve).
@MainActor func approve(_ email: String) async -> Bool {
    if let expected = options.autoApprove {
        let ok = expected == email.lowercased()
        print(ok ? "Approved \(email) (--approve)." : "Rejected \(email): --approve names \(expected).")
        return ok
    }
    print("\n  \(email) wants to pair with this Mac. It will be able to open shells and run agents here.")
    print("  Allow? [y/N] ", terminator: "")
    fflush(stdout)
    let answer = await Task.detached { readLine() }.value
    return answer?.lowercased().hasPrefix("y") == true
}

func printCode(_ code: String, name: String) {
    let spaced = code.count == 8 ? code.prefix(4) + "-" + code.dropFirst(4) : Substring(code)
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
    let identity = try await runtime.pair(onCode: { printCode($0, name: options.name) }, approve: approve)
    print("Paired with \(identity.userEmail ?? "your account").")
case "serve":
    if await runtime.identity == nil {
        let identity = try await runtime.pair(onCode: { printCode($0, name: options.name) }, approve: approve)
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
    print("usage: cnm-host [pair|serve|status|unpair] [--backend URL] [--name NAME] [--state DIR] [--relay-only] [--approve EMAIL]")
    exit(2)
}
