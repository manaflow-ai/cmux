import Foundation

/// Drives the CLI's `wait-for` signal owner: `path|signal|wait NAME [TIMEOUT]`.
/// `wait` writes `watching` to stderr once its directory watch is armed.
@main
struct TmuxWaitForSignalFixture {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { exit(2) }
        let waitForSignal = TmuxWaitForSignal(name: arguments[2])
        switch arguments[1] {
        case "path":
            print(waitForSignal.path)
        case "signal":
            try waitForSignal.signal()
            print("OK")
        case "wait":
            let timeout = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
            let signaled = try waitForSignal.wait(timeout: timeout) {
                FileHandle.standardError.write(Data("watching\n".utf8))
            }
            print(signaled ? "OK" : "timeout")
        default:
            exit(2)
        }
    }
}
