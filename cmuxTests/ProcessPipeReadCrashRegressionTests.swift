import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class ProcessPipeReadCrashRegressionTests: XCTestCase {
    func testReadAvailableDataReturnsEmptyWhenWriterRemainsOpenWithoutBufferedBytes() {
        let pipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        var result: Result<ProcessPipeAvailableRead, ProcessPipeReadError>?

        DispatchQueue.global(qos: .userInitiated).async {
            result = ProcessPipeReader.readAvailableData(from: pipe.fileHandleForReading)
            completion.signal()
        }

        let status = completion.wait(timeout: .now() + 1)
        try? pipe.fileHandleForWriting.close()

        guard status == .success else {
            _ = completion.wait(timeout: .now() + 1)
            XCTFail("readAvailableData blocked on an empty pipe with an open writer")
            return
        }

        switch result {
        case .success(.wouldBlock):
            break
        case .success(let read):
            XCTFail("readAvailableData should report wouldBlock, got \(read)")
        case .failure(let error):
            XCTFail("readAvailableData failed unexpectedly: \(error)")
        case nil:
            XCTFail("readAvailableData did not produce a result")
        }
    }

    func testReadAvailableDataReportsEndOfFileWhenWriterIsClosed() {
        let pipe = Pipe()
        try? pipe.fileHandleForWriting.close()

        let result = ProcessPipeReader.readAvailableData(from: pipe.fileHandleForReading)

        switch result {
        case .success(.endOfFile):
            break
        case .success(let read):
            XCTFail("readAvailableData should report endOfFile, got \(read)")
        case .failure(let error):
            XCTFail("readAvailableData failed unexpectedly: \(error)")
        }
    }

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
