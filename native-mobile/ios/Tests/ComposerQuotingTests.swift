import Testing
@testable import CmuxNative

struct ComposerQuotingTests {
    @Test func plainPathStaysBare() {
        #expect(ComposerModel.shellQuoted("/Users/me/Library/Caches/cmux-native-host/uploads/2026-10-12/photo-1.jpg")
            == "/Users/me/Library/Caches/cmux-native-host/uploads/2026-10-12/photo-1.jpg")
    }

    @Test func spacesAndShellCharactersAreQuoted() {
        #expect(ComposerModel.shellQuoted("/tmp/IMG (1).jpg") == "'/tmp/IMG (1).jpg'")
        #expect(ComposerModel.shellQuoted("/tmp/a$b&c;d.txt") == "'/tmp/a$b&c;d.txt'")
        #expect(ComposerModel.shellQuoted("/tmp/日本.png") == "'/tmp/日本.png'")
    }

    @Test func embeddedSingleQuoteIsEscaped() {
        #expect(ComposerModel.shellQuoted("/tmp/Aziz's notes.pdf") == "'/tmp/Aziz'\\''s notes.pdf'")
    }

    @Test func emptyPathIsQuoted() {
        #expect(ComposerModel.shellQuoted("") == "''")
    }
}
