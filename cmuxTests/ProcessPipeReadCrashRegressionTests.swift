import CmuxFoundation
import Darwin
import Foundation
import XCTest

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
final class ProcessPipeReadCrashRegressionTests: XCTestCase {
    func testProcessOutputCollectorTreatsBrokenReadDescriptorAsClosedPipe() {
        let stdout = Pipe()
        let stderr = Pipe()
        let collector = ProcessOutputCollector(stdout: stdout, stderr: stderr)

        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        Darwin.close(stdout.fileHandleForReading.fileDescriptor)

        let output = collector.finish()

        XCTAssertEqual(output, "")
    }

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

        XCTAssertLessThanOrEqual(result.stdout.utf8.count, 32 * 1024)
        XCTAssertNotNil(String(data: Data(result.stdout.utf8), encoding: .utf8))
        XCTAssertNil(MachineCreateCoordinator.createdMachineID(fromOutput: result.stdout))
        XCTAssertTrue(result.output.contains("OK machine=stderr-id"))
    }
}
