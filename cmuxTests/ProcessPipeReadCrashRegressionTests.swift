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

    func testReadToEndPreservesPartialDataWhenLaterReadFails() {
        let partialData = Data("partial output".utf8)
        let readError = ProcessPipeReadError(
            operation: "readDataToEndOfFile",
            errnoCode: EIO
        )
        var reads: [Result<Data, ProcessPipeReadError>] = [
            .success(partialData),
            .failure(readError),
        ]

        let result = ProcessPipeReader.readDataToEndOfFile(
            fileDescriptor: -1,
            chunkSize: partialData.count
        ) { _, _, _ in
            reads.removeFirst()
        }

        XCTAssertEqual(result.data, partialData)
        XCTAssertEqual(result.readError, readError)
    }
}
