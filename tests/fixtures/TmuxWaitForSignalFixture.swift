import Foundation

/// Drives the CLI's `wait-for` signal owner: `path|signal|wait NAME [TIMEOUT]`.
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
            print(try waitForSignal.wait(timeout: timeout) ? "OK" : "timeout")
        default:
            exit(2)
        }
    }
}
