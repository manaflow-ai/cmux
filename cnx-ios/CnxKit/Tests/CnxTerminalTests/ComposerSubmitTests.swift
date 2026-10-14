import Testing
@testable import CnxTerminal

/// Codex QA F1: Send must submit the prompt in Codex.
@Suite struct ComposerSubmitTests {
    @Test func aDraftIsOnePasteThenASeparateReturn() {
        let submit = ComposerSubmit(text: "write a 120 line python script", pressReturn: true)
        #expect(submit.steps == [.paste("write a 120 line python script"), .enter])
        #expect(submit.delaysEnter)
        #expect(ComposerSubmit.enterDelay > .zero)
    }

    @Test func aMultiLineDraftIsOnePaste() {
        let submit = ComposerSubmit(text: "line one\nline two\nline three", pressReturn: true)
        #expect(submit.steps == [.paste("line one\nline two\nline three"), .enter])
    }

    @Test func anEmptySendIsABareReturnAtOnce() {
        let submit = ComposerSubmit(text: "", pressReturn: true)
        #expect(submit.steps == [.enter])
        #expect(!submit.delaysEnter)
    }

    @Test func sendWithoutReturnOnlyPastes() {
        #expect(ComposerSubmit(text: "ls", pressReturn: false).steps == [.paste("ls")])
    }
}
