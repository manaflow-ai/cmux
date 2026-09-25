import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("cmux notify --desktop parsing")
struct CLINotifyDesktopOptionTests {
    @Test func absentFlagKeepsThePolicyDefault() throws {
        #expect(try NotifyDesktopOption.parse(["--title", "Build done", "--reply"]) == nil)
        #expect(try NotifyDesktopOption.parse([]) == nil)
    }

    @Test(arguments: [
        ["--desktop", "false"],
        ["--desktop=false"],
        ["--no-desktop"],
        ["--desktop", "0"],
        ["--desktop=off"],
        ["--desktop", "NO"],
    ])
    func disablingSpellings(_ flags: [String]) throws {
        #expect(try NotifyDesktopOption.parse(["--title", "Build done"] + flags + ["--body", "ok"]) == false)
    }

    @Test(arguments: [
        ["--desktop", "true"],
        ["--desktop=yes"],
        ["--desktop", "1"],
        ["--desktop=On"],
    ])
    func enablingSpellings(_ flags: [String]) throws {
        #expect(try NotifyDesktopOption.parse(["--title", "Build done"] + flags) == true)
    }

    @Test func agreeingSpellingsCombine() throws {
        #expect(try NotifyDesktopOption.parse(["--desktop", "false", "--no-desktop"]) == false)
    }

    @Test func disagreeingSpellingsAreRejected() {
        let error = #expect(throws: NotifyDesktopOption.ParseError.self) {
            try NotifyDesktopOption.parse(["--desktop", "true", "--no-desktop"])
        }
        #expect(error?.message.contains("--no-desktop") == true)
    }

    @Test(arguments: [
        ["--desktop", "maybe"],
        ["--desktop="],
        ["--desktop", "--title"],
        ["--title", "x", "--desktop"],
    ])
    func unrecognizableValuesAreRejected(_ flags: [String]) {
        let error = #expect(throws: NotifyDesktopOption.ParseError.self) {
            try NotifyDesktopOption.parse(flags)
        }
        #expect(error?.message.contains("true or false") == true)
    }

    @Test func argumentsAfterTheTerminatorAreNotFlags() throws {
        #expect(try NotifyDesktopOption.parse(["--title", "x", "--", "--desktop", "false"]) == nil)
    }
}
