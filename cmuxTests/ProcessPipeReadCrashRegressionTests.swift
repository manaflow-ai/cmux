import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private final class ProcessOutputResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessOutputResult?] = [nil, nil]

    func set(_ result: ProcessOutputResult, at index: Int) {
        lock.lock()
        values[index] = result
        lock.unlock()
    }

    func get() -> (ProcessOutputResult?, ProcessOutputResult?) {
        lock.lock()
        let result = (values[0], values[1])
        lock.unlock()
        return result
    }
}

private final class ConcurrentOutputCallbackCoordinator: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let reentrantReturned = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var callbackCount = 0
    var collector: ProcessOutputCollector?

    func handle(_ data: Data) {
        lock.lock()
        callbackCount += 1
        let index = callbackCount
        lock.unlock()
        if index == 1 {
            _ = collector?.finishResult()
            reentrantReturned.signal()
        }
        entered.signal()
        release.wait()
        _ = data
    }
}

// The descriptor-level read regressions (would-block on an open writer,
// end-of-file on a closed writer, partial data preserved on a failing read)
// are covered in CmuxFoundation's FileHandleProcessPipeReadingTests, next to
// the moved implementation. This app-side test pins the consumer behavior
// that depends on app types.
@Suite
struct ProcessPipeReadCrashRegressionTests {
    @Test
    func testProcessOutputCollectorTreatsBrokenReadDescriptorAsClosedPipe() {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr)

        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        Darwin.close(stdout.fileHandleForReading.fileDescriptor)

        let output = collector.finish()

        #expect(output == "")
    }

    @Test
    func testProcessOutputCollectorKeepsUtf8BoundariesAndSeparatesStdout() {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr)
        collector.start()
        let prefix = String(repeating: "x", count: 32 * 1024) + "😀"
        try? stdout.fileHandleForWriting.write(contentsOf: Data(prefix.utf8))
        try? stderr.fileHandleForWriting.write(contentsOf: Data("OK machine=stderr-id\n".utf8))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let result = collector.finishResult()

        #expect(result.stdout.utf8.count <= 32 * 1024)
        #expect(String(data: Data(result.stdout.utf8), encoding: .utf8) != nil)
        #expect(result.machineId == nil, "machine protocol is authoritative only on stdout")
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: result.stdout) == nil)
        #expect(result.output.contains("OK machine=stderr-id"))
    }

    @Test
    func testProcessOutputCollectorKeepsMachineProtocolAfterTranscriptEviction() {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr)
        collector.start()
        let output = "OK machine=calm-petrel\n" + String(repeating: "x", count: 64 * 1024)
        try? stdout.fileHandleForWriting.write(contentsOf: Data(output.utf8))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let result = collector.finishResult()

        #expect(result.machineId == "calm-petrel")
        #expect(result.stdout.utf8.count <= 32 * 1024)
    }

    @Test
    func testProcessOutputCollectorSkipsMalformedBytesAndKeepsFollowingText() {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr)
        collector.start()
        try? stdout.fileHandleForWriting.write(contentsOf: Data([0xFF, 0x45, 0x72, 0x72, 0x6F, 0x72]))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let result = collector.finishResult()

        #expect(result.stdout.contains("Error"))
    }

    @Test
    func testProcessOutputCollectorKeepsValidBytesAfterMalformedMultibyteSequence() {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr)
        collector.start()
        try? stdout.fileHandleForWriting.write(contentsOf: Data([0xE2, 0x82, 0x41]))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        let result = collector.finishResult()

        #expect(result.stdout == "A")
    }

    @Test
    func testProcessOutputCollectorDeliversStderrProgressToLiveConsumer() {
        let stdout = Pipe()
        let stderr = Pipe()
        var chunks: [String] = []
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr) { data in
            if let chunk = String(data: data, encoding: .utf8) { chunks.append(chunk) }
        }
        collector.start()
        try? stderr.fileHandleForWriting.write(contentsOf: Data("waiting for link\n".utf8))
        try? stderr.fileHandleForWriting.close()
        try? stdout.fileHandleForWriting.close()

        _ = collector.finishResult()

        #expect(chunks.contains("waiting for link\n"))
    }

    @Test
    func testProcessOutputCollectorWaitsForInFlightReadBeforeFinishing() {
        let stdout = Pipe()
        let stderr = Pipe()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr) { _ in
            entered.signal()
            release.wait()
        }
        collector.start()
        try? stdout.fileHandleForWriting.write(contentsOf: Data("progress\n".utf8))
        #expect(entered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            _ = collector.finishResult()
            finished.signal()
        }
        #expect(finished.wait(timeout: .now() + 0.05) == .timedOut)
        release.signal()
        #expect(finished.wait(timeout: .now() + 1) == .success)
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
    }

    @Test
    func testProcessOutputCollectorConcurrentFinishersShareDrainedResult() {
        let stdout = Pipe()
        let stderr = Pipe()
        let drainEntered = DispatchSemaphore(value: 0)
        let releaseDrain = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let results = ProcessOutputResultStore()
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr) { data in
            guard data == Data("tail\n".utf8) else { return }
            drainEntered.signal()
            releaseDrain.wait()
        }

        try? stdout.fileHandleForWriting.write(contentsOf: Data("tail\n".utf8))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        DispatchQueue.global().async {
            let result = collector.finishResult()
            results.set(result, at: 0)
            firstFinished.signal()
        }
        #expect(drainEntered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            let result = collector.finishResult()
            results.set(result, at: 1)
            secondFinished.signal()
        }
        #expect(secondFinished.wait(timeout: .now() + 0.05) == .timedOut)

        releaseDrain.signal()
        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
        let collected = results.get()
        #expect(collected.0 == collected.1)
        #expect(collected.0?.stdout == "tail")
    }

    @Test
    func testProcessOutputCollectorAllowsReentrantFinishFromOutputCallback() {
        let stdout = Pipe()
        let stderr = Pipe()
        let callbackFinished = DispatchSemaphore(value: 0)
        var collector: ProcessOutputCollector!
        var callbackResult: ProcessOutputResult?
        let resultLock = NSLock()
        collector = ProcessOutputCollector(stdout: stdout, stderr: stderr) { _ in
            let result = collector.finishResult()
            resultLock.lock()
            callbackResult = result
            resultLock.unlock()
            callbackFinished.signal()
        }
        try? stdout.fileHandleForWriting.write(contentsOf: Data("reentrant\n".utf8))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        #expect(callbackFinished.wait(timeout: .now() + 1) == .success)
        let result = collector.finishResult()
        resultLock.lock()
        let nestedResult = callbackResult
        resultLock.unlock()
        #expect(nestedResult == result)
        #expect(result.stdout == "reentrant")
    }

    @Test
    func testProcessOutputCollectorDefersReentrantFinishUntilConcurrentReadsReturn() {
        let stdout = Pipe()
        let stderr = Pipe()
        let callbacks = ConcurrentOutputCallbackCoordinator()
        callbacks.collector = ProcessOutputCollector(stdout: stdout, stderr: stderr, onOutput: callbacks.handle)
        callbacks.collector?.start()
        try? stdout.fileHandleForWriting.write(contentsOf: Data("stdout\n".utf8))
        try? stderr.fileHandleForWriting.write(contentsOf: Data("stderr\n".utf8))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()

        #expect(callbacks.entered.wait(timeout: .now() + 1) == .success)
        #expect(callbacks.entered.wait(timeout: .now() + 1) == .success)
        #expect(callbacks.reentrantReturned.wait(timeout: .now() + 1) == .success)
        callbacks.release.signal()
        callbacks.release.signal()

        let result = callbacks.collector?.finishResult()
        #expect(result?.stdout.contains("stdout") == true)
        #expect(result?.output.contains("stderr") == true)
    }

    @Test
    func testProcessOutputCollectorReentrantFinishDrainsTailFromOtherPipe() {
        let stdout = Pipe()
        let stderr = Pipe()
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let callbackLock = NSLock()
        var callbackCount = 0
        var collector: ProcessOutputCollector!
        collector = ProcessOutputCollector(stdout: stdout, stderr: stderr) { _ in
            callbackLock.lock()
            callbackCount += 1
            let isFirst = callbackCount == 1
            callbackLock.unlock()
            guard isFirst else { return }
            _ = collector.finishResult()
            callbackEntered.signal()
            releaseCallback.wait()
        }
        collector.start()
        try? stdout.fileHandleForWriting.write(contentsOf: Data("OK machine=calm-petrel\n".utf8))
        #expect(callbackEntered.wait(timeout: .now() + 1) == .success)
        try? stderr.fileHandleForWriting.write(contentsOf: Data("tail from stderr\n".utf8))
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        releaseCallback.signal()

        let result = collector.finishResult()
        #expect(result.machineId == "calm-petrel")
        #expect(result.output.contains("tail from stderr"))
    }
}
