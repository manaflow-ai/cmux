import AppKit
import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Named Ctrl-letter encoding", .serialized)
struct GhosttyNamedCtrlLetterTests {
    @Test(arguments: [0, 1, 3, 31])
    func namedAndPhysicalCtrlLettersProduceTheSameBytes(flags: Int) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let terminal = try ScrollbackTestTerminal()
            defer { terminal.close() }
            try await terminal.launch()
            // Parse negotiation synchronously before submitting input. Mode 1
            // disambiguates keys; mode 3 also reports releases; mode 31 enables
            // every Kitty flag, including alternate and associated text.
            try terminal.output("\u{1b}c\u{1b}[>\(flags)u")
            #expect(try await terminal.inputBytesBeforeBarrier().isEmpty)

            // macOS ANSI keycodes are not ordered alphabetically.
            let keycodes: [UInt16] = [
                0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
                45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6
            ]
            for (offset, keycode) in keycodes.enumerated() {
                let codepoint = UInt32(97 + offset)
                let letter = String(try #require(UnicodeScalar(codepoint)))
                let expected: Data
                if flags == 0 {
                    expected = Data([UInt8(offset + 1)])
                } else {
                    var sequence = "\u{1b}[\(codepoint);5u"
                    if flags & 2 != 0 {
                        sequence += "\u{1b}[\(codepoint);5:3u"
                    }
                    expected = Data(sequence.utf8)
                }

                #expect(terminal.surface.sendNamedKey("ctrl+\(letter)") == .sent)
                let namedBytes = try await terminal.inputBytesBeforeBarrier()
                #expect(namedBytes == expected, "flags=\(flags), ctrl+\(letter): \(namedBytes as NSData)")

                let controlText = String(try #require(UnicodeScalar(offset + 1)))
                #expect(terminal.surface.hostedView.debugSendSyntheticKeyPressAndReleaseForUITest(
                    characters: controlText,
                    charactersIgnoringModifiers: letter,
                    keyCode: keycode,
                    modifierFlags: [.control]
                ))
                let physicalBytes = try await terminal.inputBytesBeforeBarrier()
                #expect(physicalBytes == expected, "physical flags=\(flags), ctrl+\(letter): \(physicalBytes as NSData)")
                #expect(namedBytes == physicalBytes)
            }
        }
    }
}
