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
        // The callback only signals termination; the caller polls it without
        // blocking so pipe draining and deadline enforcement stay synchronous.
        process.terminationHandler = { _ in exitSignal.signal() }
        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        let stdinFD = stdinPipe?.fileHandleForWriting.fileDescriptor
        defer {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            try? stdinPipe?.fileHandleForWriting.close()
        }

        // Only the parent's endpoints are nonblocking; the child's opposite
        // pipe ends retain their normal blocking stdio contract.
        for fd in [stdoutFD, stderrFD] + (stdinFD.map { [$0] } ?? []) {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                return Result(status: -1, stdout: "", stderr: "Cannot configure process pipe: \(errno)", timedOut: false)
            }
        }
        // A child may close stdin before consuming the whole payload. Protect
        // this writer only; the child still observes the normal SIGPIPE state.
        if let stdinFD, fcntl(stdinFD, F_SETNOSIGPIPE, 1) == -1 {
            return Result(status: -1, stdout: "", stderr: "Cannot suppress stdin SIGPIPE: \(errno)", timedOut: false)
        }

        do {
            try process.run()
        } catch {
            return Result(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }

        var stdoutData = Data()
        var stderrData = Data()
        var stdoutEnded = false
        var stderrEnded = false
        let input = Data((standardInput ?? "").utf8)
        var inputOffset = 0
        var inputEnded = stdinFD == nil
        var timedOut = false
        var sentKill = false
        var didTerminate = false
        var deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)

        // The synchronous test runner owns all three pipes. Waiting for global
        // queue readers and then ignoring their timeout returned empty output
        // under app-host load, even after an immediate successful child exit.
        // Polling readiness here drains both streams while feeding large input
        // without a blocked worker or a cross-thread FileHandle close.
        while true {
            if !didTerminate, exitSignal.wait(timeout: .now()) == .success {
                didTerminate = true
            }
            if !stdoutEnded { stdoutEnded = drainAvailable(fd: stdoutFD, into: &stdoutData) }
            if !stderrEnded { stderrEnded = drainAvailable(fd: stderrFD, into: &stderrData) }
            guard !didTerminate, process.isRunning else { break }

            let now = ProcessInfo.processInfo.systemUptime
            if now >= deadline {
                guard process.isRunning else {
                    didTerminate = true
                    break
                }
                if !timedOut {
                    timedOut = true
                    process.terminate()
                } else if !sentKill {
                    sentKill = true
                    kill(process.processIdentifier, SIGKILL)
                } else {
                    break
                }
                deadline = now + 1
            }

            if !inputEnded, let stdinFD {
                if inputOffset < input.count, !timedOut {
                    let written = input.withUnsafeBytes { bytes in
                        Darwin.write(stdinFD, bytes.baseAddress!.advanced(by: inputOffset), input.count - inputOffset)
                    }
                    if written > 0 {
                        inputOffset += written
                    } else if written < 0, errno != EINTR, errno != EAGAIN, errno != EWOULDBLOCK {
                        inputEnded = true
                    }
                }
                if inputEnded || inputOffset == input.count || timedOut {
                    try? stdinPipe?.fileHandleForWriting.close()
                    inputEnded = true
                }
            }

            var descriptors = [
                pollfd(fd: stdoutEnded ? -1 : stdoutFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: stderrEnded ? -1 : stderrFD, events: Int16(POLLIN), revents: 0),
                pollfd(fd: inputEnded ? -1 : (stdinFD ?? -1), events: Int16(POLLOUT), revents: 0),
            ]
            // A child may close all pipes before exiting. Bound the readiness
            // wait so Process's observed exit and the monotonic deadline still
            // advance without relying on a termination callback worker.
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let milliseconds = Int32(min(50, (remaining * 1_000).rounded(.up)))
            _ = Darwin.poll(&descriptors, nfds_t(descriptors.count), milliseconds)
        }

        // Direct-child exit guarantees its writes reached the pipe. Read those
        // buffered bytes without waiting for EOF from an inherited descendant.
        while !drainAvailable(fd: stdoutFD, into: &stdoutData) {
            var readiness = pollfd(fd: stdoutFD, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&readiness, 1, 0) > 0 else { break }
        }
        while !drainAvailable(fd: stderrFD, into: &stderrData) {
            var readiness = pollfd(fd: stderrFD, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&readiness, 1, 0) > 0 else { break }
        }
        return Result(
            status: process.isRunning ? SIGKILL : process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    /// Drains a bounded batch so a continuously writing child cannot starve the deadline.
    private static func drainAvailable(fd: Int32, into data: inout Data) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(fd, baseAddress, bytes.count)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return true
            } else if errno == EINTR {
                continue
            } else {
                return errno != EAGAIN && errno != EWOULDBLOCK
            }
        }
        return false
    }
}

/// Keeps a fixture server's write to a client that already hung up from
/// raising SIGPIPE. cmuxCLITests runs without an app host, so nothing else
/// ignores the signal and it would terminate the whole test runner. The option
/// is set per socket so the CLI's own SIGPIPE behavior stays under test.
///
/// Returns false when the option could not be set. The caller must then close
/// the client without writing to it.
func ignoreSIGPIPE(onAcceptedFixtureSocket fd: Int32) -> Bool {
    var noSignal: Int32 = 1
    return setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
}

/// Writes all of `text` to a fixture socket, retrying short and interrupted
/// writes. Returns false once the write fails, for example after the client
/// hung up.
@discardableResult
func writeAllToFixtureSocket(_ text: String, fd: Int32) -> Bool {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let written = bytes.withUnsafeBytes { buffer in
            Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        if written == 0 { return false }
        offset += written
    }
    return true
}
