import Darwin
import Foundation

struct CLIRunResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Runs the CLI binary to completion with a hard timeout, so a hung invocation
/// fails the test instead of stalling the suite.
func runCLI(
    _ cliPath: String,
    arguments: [String],
    environment: [String: String]
) throws -> CLIRunResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: cliPath)
    process.arguments = arguments

    var env = ProcessInfo.processInfo.environment
    for key in ["CMUX_SOCKET", "CMUX_SOCKET_PASSWORD", "CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"] {
        env.removeValue(forKey: key)
    }
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env.merge(environment) { _, new in new }
    process.environment = env

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        finished.signal()
    }
    try process.run()

    let deadline = DispatchTime.now() + .seconds(5)
    guard finished.wait(timeout: deadline) == .success else {
        process.terminate()
        if finished.wait(timeout: .now() + .seconds(1)) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = finished.wait(timeout: .now() + .seconds(1))
        }
        throw NSError(
            domain: "CLIProcessRunSupport",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "cmux \(arguments.joined(separator: " ")) timed out",
            ]
        )
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return CLIRunResult(
        exitCode: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
        stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    )
}
