import Foundation

// rdclient: macOS measurement client for the rdproto/0 remote desktop prototype. Usage: Args.usage.
do {
    let args = try Args(CommandLine.arguments)
    switch args.command {
    case "connect": try runConnect(ConnectOptions(args))
    case "selftest": try runSelftest(args)
    case "fakehost": try runFakeHost(args)
    case "help", "--help", "-h": print(Args.usage)
    default: throw UsageError.message("unknown command \(args.command)\n\(Args.usage)")
    }
} catch {
    log("error: \(error)")
    exit(1)
}
