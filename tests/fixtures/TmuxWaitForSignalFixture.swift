import Foundation

/// Drives the CLI's `wait-for` signal owner:
/// `path|signal|wait|lockpath|lock|unlock NAME [TIMEOUT]`.
/// `wait` and `lock` write `watching` to stderr once, only if the first attempt
/// finds the channel contended (no signal yet, or the lock held). An already
/// signaled `wait` or a free `lock` finishes without printing it.
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
        case "lockpath":
            print(waitForSignal.lockPath)
        case "lock":
            let timeout = arguments.count > 3 ? Double(arguments[3]) ?? 0 : 0
            let locked = try waitForSignal.lock(timeout: timeout) {
                FileHandle.standardError.write(Data("watching\n".utf8))
            }
            print(locked ? "OK" : "timeout")
        case "unlock":
            try waitForSignal.unlock()
            print("OK")
        default:
            exit(2)
        }
    }
}
