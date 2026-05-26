import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
}
