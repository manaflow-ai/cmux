import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

extension TerminalImageTransferConcurrencyTests {
    @MainActor
    @Test("repeated bounded paste payloads survive isolated worker transport",
          .serialized, arguments: ["plain-rich", "html", "rtf", "image"])
    func repeatedWorkerPastesPreservePayload(format: String) async throws {
        let pasteboard = NSPasteboard(name: .init("cmux-repeated-paste-\(UUID())"))
        pasteboard.clearContents()
        defer { pasteboard.releaseGlobally() }
        // HTML renders tabs to tab stops. Literal tab fidelity is covered by
        // the plain-text and RTF cases; the HTML case uses rendered spaces.
        let separator = format == "html" ? "  " : "\t"
        let text = (0..<256).map {
            "line \($0): 日本語 café 🧪\(separator)left  right"
        }.joined(separator: "\n")
        let image = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a8lEAAAAASUVORK5CYII="
        ))
        switch format {
        case "plain-rich":
            #expect(pasteboard.setString(text, forType: .string))
            #expect(pasteboard.setString("<pre>unused rich flavor</pre>", forType: .html))
        case "html":
            #expect(pasteboard.setString("<pre>\(text)</pre>", forType: .html))
        case "rtf":
            let attributed = NSAttributedString(string: text)
            let data = try attributed.data(
                from: NSRange(location: 0, length: attributed.length),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            #expect(pasteboard.setData(data, forType: .rtf))
        default:
            #expect(pasteboard.setData(image, forType: .png))
            #expect(pasteboard.setString("<img src='clipboard.png'>", forType: .html))
        }
        let generation = pasteboard.changeCount
        let service = makeLivePreparationService()
        let request = TerminalPasteboardReadRequest(pasteboard: pasteboard)
        let results = await withTaskGroup(of: TerminalImageTransferPreparedContent.self) { group in
            for _ in 0..<4 {
                group.addTask { await service.prepare(request: request, mode: .paste) }
            }
            var results: [TerminalImageTransferPreparedContent] = []
            for await result in group { results.append(result) }
            return results
        }
        defer {
            for result in results { service.cleanupTransferredTemporaryFiles(result) }
        }
        #expect(results.count == 4)
        #expect(pasteboard.changeCount == generation)
        for result in results {
            if format == "image" {
                guard case .fileURLs(let urls) = result else {
                    Issue.record("Expected each image paste to produce an owned file")
                    continue
                }
                #expect(urls.count == 1)
                for url in urls { #expect(try Data(contentsOf: url) == image) }
            } else {
                #expect(result == .insertText(text))
            }
        }
    }
}
