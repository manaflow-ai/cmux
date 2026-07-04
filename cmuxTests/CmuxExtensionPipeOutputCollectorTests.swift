import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cmux extension pipe output collector")
struct CmuxExtensionPipeOutputCollectorTests {
    @Test("collector owns an independent read descriptor")
    func collectorOwnsIndependentReadDescriptor() async throws {
        let pipe = Pipe()
        let payload = Data("collector-payload".utf8)
        let collector = CmuxExtensionPipeOutputCollector(fileHandle: pipe.fileHandleForReading)

        try pipe.fileHandleForReading.close()
        try pipe.fileHandleForWriting.write(contentsOf: payload)
        try pipe.fileHandleForWriting.close()

        let captured = await collector.finish()
        #expect(captured == payload)
    }
}
