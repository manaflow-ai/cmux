import CmuxFoundation
import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
        let resultLock = NSLock()
        var firstResult: ProcessOutputResult?
        var secondResult: ProcessOutputResult?
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
            resultLock.lock()
            firstResult = result
            resultLock.unlock()
            firstFinished.signal()
        }
        #expect(drainEntered.wait(timeout: .now() + 1) == .success)

        DispatchQueue.global().async {
            let result = collector.finishResult()
            resultLock.lock()
            secondResult = result
            resultLock.unlock()
            secondFinished.signal()
        }
        #expect(secondFinished.wait(timeout: .now() + 0.05) == .timedOut)

        releaseDrain.signal()
        #expect(firstFinished.wait(timeout: .now() + 1) == .success)
        #expect(secondFinished.wait(timeout: .now() + 1) == .success)
        resultLock.lock()
        let results = (firstResult, secondResult)
        resultLock.unlock()
        #expect(results.0 == results.1)
        #expect(results.0?.stdout == "tail")
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
        collector.start()
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
}
