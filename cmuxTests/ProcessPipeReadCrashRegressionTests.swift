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
}
