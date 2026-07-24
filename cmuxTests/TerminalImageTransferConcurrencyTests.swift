import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal image transfer concurrency")
struct TerminalImageTransferConcurrencyTests {
    @MainActor
    @Test("lazy pasteboard providers resolve outside the main thread")
    func lazyPasteboardProviderResolvesOffMainThread() async throws {
        #expect(Thread.isMainThread)

        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-image-transfer-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }

        let mainThreadData = Data("resolved-on-main".utf8)
        let backgroundThreadData = Data("resolved-off-main".utf8)
        let provider = PasteboardThreadSignalingDataProvider(
            mainThreadData: mainThreadData,
            backgroundThreadData: backgroundThreadData
        )
        let item = NSPasteboardItem()
        item.setDataProvider(provider, forTypes: [.png])
        #expect(pasteboard.writeObjects([item]))

        let preparedContent = await TerminalImageTransferPlanner.prepare(
            pasteboard: pasteboard,
            mode: .paste
        )
        guard case .fileURLs(let fileURLs) = preparedContent,
              let materializedURL = fileURLs.first else {
            Issue.record("Expected the lazy image payload to be materialized")
            return
        }
        defer {
            GhosttyApp.terminalPasteboard.cleanupTransferredTemporaryImageFiles(fileURLs)
        }

        #expect(try Data(contentsOf: materializedURL) == backgroundThreadData)
    }
}
