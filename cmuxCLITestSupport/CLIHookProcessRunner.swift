import Darwin
import Dispatch
import Foundation

// Black-box subprocess runner shared by the app-host test bundle (cmuxTests)
// and the product-level bundle (cmuxCLITests).
//
// It used to live as `CLINotifyProcessIntegrationRegressionTests.runProcess`,
// which tied every hook helper to that one app-host suite. The helpers that
// spawn the bundled CLI do not need an app host, so the runner they share
// cannot be attached to a suite that stays behind: this file is a member of
// both test targets and owns the implementation, while the old static method
// forwards to it.
enum CLIHookProcessRunner {
    struct Result {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    static func run(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        timeout: TimeInterval
    ) -> Result {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = standardInput == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = CLIChildEnvironment(
            appHostEnvironment: ProcessInfo.processInfo.environment
        ).normalizing(environment)
        process.standardInput = stdinPipe ?? FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exitSignal = DispatchSemaphore(value: 0)
        // Observe actual termination instead of scheduling a blocking waiter on
        // the same global pool used to drain the child's output.
        process.terminationHandler = { _ in exitSignal.signal() }

        // A child may exit or be killed while its stdin writer is blocked.
        // Suppress SIGPIPE on this descriptor only, leaving the test process
        // and spawned CLI signal dispositions unchanged.
        if let stdinPipe,
           fcntl(stdinPipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 {
            return Result(status: -1, stdout: "", stderr: "Cannot suppress stdin SIGPIPE: \(errno)", timedOut: false)
        }

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }
        let outputLock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()
        let ioGroup = DispatchGroup()

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stdoutData = data
            outputLock.unlock()
            ioGroup.leave()
        }

        ioGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock()
            stderrData = data
            outputLock.unlock()
            ioGroup.leave()
        }

        // Start input only after both drains exist: a child can fill either
        // output pipe before it reads a large input. The writer shares the
        // lifecycle group so timeout termination also releases blocked writes.
        if let standardInput, let stdinPipe {
            ioGroup.enter()
            DispatchQueue.global(qos: .utility).async {
                defer {
                    try? stdinPipe.fileHandleForWriting.close()
                    ioGroup.leave()
                }
                try? stdinPipe.fileHandleForWriting.write(contentsOf: Data(standardInput.utf8))
            }
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        _ = ioGroup.wait(timeout: .now() + 2)

        outputLock.lock()
        let finalStdoutData = stdoutData
        let finalStderrData = stderrData
        outputLock.unlock()
        return Result(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: String(data: finalStdoutData, encoding: .utf8) ?? "",
            stderr: String(data: finalStderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
