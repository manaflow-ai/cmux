import Foundation
import Testing
@testable import CmuxNative

struct FilePreviewTextSniffTests {
    @Test func cjkTextCutMidCharacterIsText() {
        // 3-byte characters; 8192 = 3 * 2730 + 2 cuts the last one after 2 bytes,
        // and a 1-byte cut needs exactly 1 byte dropped.
        let text = String(repeating: "日本語のテキスト", count: 1200)
        #expect(FilePreviewModel.looksLikeText(Data(text.utf8)))
        let shifted = "a" + text
        #expect(FilePreviewModel.looksLikeText(Data(shifted.utf8)))
        let shifted2 = "ab" + text
        #expect(FilePreviewModel.looksLikeText(Data(shifted2.utf8)))
    }

    @Test func nulBytesAreBinary() {
        #expect(!FilePreviewModel.looksLikeText(Data([0x41, 0x00, 0x42])))
    }

    @Test func invalidUTF8IsBinary() {
        #expect(!FilePreviewModel.looksLikeText(Data(repeating: 0xFF, count: 64)))
    }
}

struct CodeDocumentLongLineTests {
    @Test func minifiedLineIsClippedAndPlain() {
        let line = String(repeating: "a=1;", count: 50_000)
        let document = CodeDocument.make(text: line + "\nlet x = 1\n", path: "bundle.min.js")
        #expect(document.lines.count >= 2)
        #expect(document.maxColumns < CodeDocument.maximumLineCharacters + 40)
        #expect(String(document.lines[0].characters).hasSuffix("more characters"))
    }

    @Test func shortLinesAreUntouched() {
        #expect(CodeDocument.clipped("let x = 1") == "let x = 1")
    }
}
