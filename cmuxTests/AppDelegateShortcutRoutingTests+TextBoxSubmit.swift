import XCTest
import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - Text box submit pipeline tests
extension AppDelegateShortcutRoutingTests {
    func testTextBoxSubmitUsesPastePayloadAndSeparateReturn() throws {
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: "hello"), "hello")
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: "hello\nworld"), "hello\nworld")
        XCTAssertNil(TextBoxSubmit.submittedPasteText(for: "\n"))
        XCTAssertNil(TextBoxSubmit.submittedPasteText(for: " \t\n"))
        XCTAssertEqual(TextBoxSubmit.submittedPasteText(for: " echo hi "), " echo hi ")

        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let imageSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" now"),
                .waitForVisibleText(" now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:/bin/zsh -lc claude --resume"
            ),
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:/bin/zsh -lc 'claude --resume'"
            ),
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:claude"
            )
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text(" now")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" now"),
                .waitForVisibleText(" now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .pasteText(" "),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "restoredAgent:codex"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "panelTitle:Claude Code"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("what is "), .attachment(attachment), .text("now")],
                terminalAgentContext: "initialCommand:echo Claude Code"
            ),
            [
                .pasteText("what is \(imageSubmissionText) now"),
                .namedKey("return")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [.text("hello\nworld")],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [.pasteText("hello\nworld"), .namedKey("ctrl+enter")]
        )
    }

    func testTextBoxSubmitStagesClaudeImagePromptWithMultilineTail() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let imageSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: imageURL)

        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: [
                    .text("how are you "),
                    .attachment(attachment),
                    .text("what does this say?\n\n3+3")
                ],
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("how are you "),
                .waitForVisibleText("how are you "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(imageSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" what does this say?\n\n3+3"),
                .waitForVisibleText(" what does this say?\n\n3+3"),
                .namedKey("ctrl+enter")
            ]
        )
    }

    func testTextBoxSubmitBoundsVisibleWaitForLongClaudePromptSegments() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )
        let longPrompt = "\(String(repeating: "alpha ", count: 60))\nshort visible tail"

        let events = TextBoxSubmit.dispatchEvents(
            for: [.text(longPrompt), .attachment(attachment)],
            terminalAgentContext: "restoredAgent:claude"
        )
        let visibleWaitTexts = events.compactMap { event -> String? in
            if case .waitForVisibleText(let text) = event { return text }
            return nil
        }

        XCTAssertTrue(events.contains(.pasteText(longPrompt)))
        XCTAssertFalse(events.contains(.waitForVisibleText(longPrompt)))
        XCTAssertEqual(visibleWaitTexts.first, "short visible tail")
    }

    func testTextBoxSubmitUsesLocalPreviewPathForClaudeRemoteImage() throws {
        let previewURL = try makeTemporaryPNGFile(named: "moon.png")
        let remotePath = "/tmp/cmux-upload/moon.png"
        let attachment = TextBoxAttachment(
            localURL: previewURL,
            submissionText: TextBoxAttachment.submissionText(forPath: remotePath),
            submissionPath: remotePath,
            cleanupLocalURLWhenDisposed: true
        )

        let events = TextBoxSubmit.dispatchEvents(
            for: [.text("what is "), .attachment(attachment), .text("now")],
            terminalAgentContext: "restoredAgent:claude"
        )

        XCTAssertEqual(
            events.compactMap { event -> String? in
                if case .pasteFilePath(let path) = event { return path }
                return nil
            },
            [previewURL.path]
        )
        XCTAssertTrue(events.contains(.waitForClaudeImageToken(attachment.submissionText)))
        XCTAssertFalse(events.contains(.pasteFilePath(remotePath)))
        XCTAssertEqual(
            TextBoxSubmit.cleanupAttachmentsAfterSubmit(
                from: [.attachment(attachment)],
                terminalAgentContext: "restoredAgent:claude",
                completionContext: TextBoxSubmit.CompletionContext(
                    confirmedClaudeImageSubmissionTexts: [
                        attachment.submissionText: 1
                    ]
                )
            ).map(\.displayName),
            ["moon.png"]
        )
    }

    func testTextBoxSubmitVisibleWaitAcceptsMultilinePromptRendering() {
        let baseline = """
        > how are you [Image #3]
        """
        let visible = """
        > how are you [Image #3] what does this say?

        3+3
        """

        XCTAssertTrue(
            TextBoxSubmit.visibleTextReady(
                expectedText: " what does this say?\n\n3+3",
                visibleText: visible,
                baseline: baseline
            )
        )
        XCTAssertFalse(
            TextBoxSubmit.visibleTextReady(
                expectedText: " what does this say?\n\n3+3",
                visibleText: baseline,
                baseline: baseline
            )
        )
    }

    func testTextBoxSubmitClipboardReadWaitStaysPendingUntilCompletionNotification() {
#if DEBUG
        let surface = FakeTextBoxSubmitSurface()
        TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
        defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

        var completionContext: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.debugRunDispatchEvents(
            [
                .captureClipboardReadBaseline,
                .waitForClipboardRead,
                .pasteText("after")
            ],
            via: surface
        ) { context in
            completionContext = context
        }

        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertEqual(surface.sentText, [])
        XCTAssertNil(completionContext)

        surface.completeClipboardRead()
        waitFor(timeout: 1.0, until: { surface.sentText == ["after"] })

        XCTAssertEqual(surface.sentText, ["after"])
        XCTAssertEqual(completionContext, TextBoxSubmit.CompletionContext.empty)
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitReportsRejectedTerminalWriteWithoutContinuing() {
#if DEBUG
        let surface = FakeTextBoxSubmitSurface()
        surface.sendTextResult = false

        var completionContext: TextBoxSubmit.CompletionContext?
        TextBoxSubmit.debugRunDispatchEvents(
            [
                .pasteText("draft"),
                .namedKey("return")
            ],
            via: surface
        ) { context in
            completionContext = context
        }

        XCTAssertEqual(surface.sentText, ["draft"])
        XCTAssertEqual(surface.sentKeys, [])
        XCTAssertEqual(completionContext?.failure, .terminalWriteRejected)
#else
        XCTFail("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxFailedSubmitRollbackOnlyRestoresUnchangedClearedDraft() {
        let rollbackSnapshot = TextBoxFailedSubmitRollbackSnapshot(
            revision: 4,
            text: "",
            attachmentCount: 0
        )

        XCTAssertTrue(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "",
                attachmentCount: 0
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "new draft",
                attachmentCount: 0
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 4,
                text: "",
                attachmentCount: 1
            )
        ))
        XCTAssertFalse(TextBoxFailedSubmitRollbackPolicy.shouldRestore(
            rollbackSnapshot: rollbackSnapshot,
            currentSnapshot: TextBoxFailedSubmitRollbackSnapshot(
                revision: 5,
                text: "",
                attachmentCount: 0
            )
        ))
    }

    func testTextBoxSubmitClipboardReadTimeoutRestoresPasteboard() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let surface = FakeTextBoxSubmitSurface()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString("user clipboard", forType: .string))
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 0
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completed = false
            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead
                ],
                via: surface
            ) { _ in
                completed = true
            }

            XCTAssertEqual(surface.sentKeys, ["paste_from_clipboard"])
            waitFor(timeout: 1.0, until: { completed })

            XCTAssertTrue(completed)
            XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitSerializesRunsPerSurface() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let surface = FakeTextBoxSubmitSurface()
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }
            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead,
                    .pasteText("first")
                ],
                via: surface
            ) { _ in
                completions.append("first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("second")],
                via: surface
            ) { _ in
                completions.append("second")
            }

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(surface.sentText, [])
            XCTAssertEqual(completions, [])
            XCTAssertEqual(surface.sentKeys, ["paste_from_clipboard"])

            surface.completeClipboardRead()
            waitFor(timeout: 1.0, until: { completions == ["first", "second"] })

            XCTAssertEqual(surface.sentText, ["first", "second"])
            XCTAssertEqual(completions, ["first", "second"])
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitSerializesPasteboardRunsAcrossSurfaces() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let firstSurface = FakeTextBoxSubmitSurface()
            let secondSurface = FakeTextBoxSubmitSurface()
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.declareTypes([.string], owner: nil)
            XCTAssertTrue(pasteboard.setString("user clipboard", forType: .string))
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }

            let firstURL = try makeTemporaryPNGFile(named: "first.png")
            let secondURL = try makeTemporaryPNGFile(named: "second.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(firstURL.path),
                    .waitForClipboardRead,
                    .pasteText("first")
                ],
                via: firstSurface
            ) { _ in
                completions.append("first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(secondURL.path),
                    .waitForClipboardRead,
                    .pasteText("second")
                ],
                via: secondSurface
            ) { _ in
                completions.append("second")
            }

            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            XCTAssertEqual(firstSurface.sentKeys, ["paste_from_clipboard"])
            XCTAssertEqual(secondSurface.sentKeys, [])
            XCTAssertEqual(completions, [])

            firstSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: {
                completions == ["first"] &&
                    secondSurface.sentKeys == ["paste_from_clipboard"]
            })

            XCTAssertEqual(firstSurface.sentText, ["first"])
            XCTAssertEqual(secondSurface.sentText, [])
            XCTAssertEqual(completions, ["first"])

            secondSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: { completions == ["first", "second"] })

            XCTAssertEqual(secondSurface.sentText, ["second"])
            XCTAssertEqual(completions, ["first", "second"])
            XCTAssertEqual(pasteboard.string(forType: .string), "user clipboard")
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitKeepsQueuedRunForStillActiveSurfaceWhenAnotherSurfaceFinishes() throws {
#if DEBUG
        try withPreservedGeneralPasteboard {
            let activeSurface = FakeTextBoxSubmitSurface()
            let finishingSurface = FakeTextBoxSubmitSurface()
            TextBoxSubmit.debugWaitTimeoutSecondsOverride = 10
            defer { TextBoxSubmit.debugWaitTimeoutSecondsOverride = nil }
            let imageURL = try makeTemporaryPNGFile(named: "moon.png")
            var completions: [String] = []

            TextBoxSubmit.debugRunDispatchEvents(
                [
                    .captureClipboardReadBaseline,
                    .pasteFilePath(imageURL.path),
                    .waitForClipboardRead,
                    .pasteText("active-first")
                ],
                via: activeSurface
            ) { _ in
                completions.append("active-first")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("active-second")],
                via: activeSurface
            ) { _ in
                completions.append("active-second")
            }
            TextBoxSubmit.debugRunDispatchEvents(
                [.pasteText("finishing")],
                via: finishingSurface
            ) { _ in
                completions.append("finishing")
            }

            waitFor(timeout: 1.0, until: { completions == ["finishing"] })
            XCTAssertEqual(finishingSurface.sentText, ["finishing"])
            XCTAssertEqual(activeSurface.sentText, [])
            XCTAssertEqual(activeSurface.sentKeys, ["paste_from_clipboard"])

            activeSurface.completeClipboardRead()
            waitFor(timeout: 1.0, until: {
                completions == ["finishing", "active-first", "active-second"]
            })

            XCTAssertEqual(activeSurface.sentText, ["active-first", "active-second"])
            XCTAssertEqual(completions, ["finishing", "active-first", "active-second"])
        }
#else
        throw XCTSkip("debugRunDispatchEvents is only available in DEBUG")
#endif
    }

    func testTextBoxSubmitStressMatrixKeepsClaudeImagesInterspersedWithText() throws {
        let firstURL = try makeTemporaryPNGFile(named: "first.png")
        let secondURL = try makeTemporaryPNGFile(named: "second.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )

        let cases: [(parts: [TextBoxSubmissionPart], paths: [String], submitKey: String)] = [
            (
                [.attachment(firstAttachment), .text("describe this")],
                [firstURL.path],
                "return"
            ),
            (
                [.text("compare "), .attachment(firstAttachment), .text(" and "), .attachment(secondAttachment)],
                [firstURL.path, secondURL.path],
                "return"
            ),
            (
                [.text("first line\n"), .attachment(firstAttachment), .text("second line")],
                [firstURL.path],
                "ctrl+enter"
            ),
            (
                [.attachment(firstAttachment), .attachment(secondAttachment), .text(" done")],
                [firstURL.path, secondURL.path],
                "return"
            ),
        ]

        for testCase in cases {
            let events = TextBoxSubmit.dispatchEvents(
                for: testCase.parts,
                terminalAgentContext: "restoredAgent:claude"
            )
            let pastedFilePaths = events.compactMap { event -> String? in
                if case .pasteFilePath(let path) = event {
                    return path
                }
                return nil
            }
            let imageWaitCount = events.filter { event in
                if case .waitForClaudeImageToken = event {
                    return true
                }
                return false
            }.count

            XCTAssertEqual(pastedFilePaths, testCase.paths)
            XCTAssertEqual(imageWaitCount, testCase.paths.count)
            XCTAssertEqual(events.last, .namedKey(testCase.submitKey))
        }
    }

    func testTextBoxClaudeImageSubmissionDoesNotUseCursorOffsetsForWideCharacters() throws {
        let imageURL = try makeTemporaryPNGFile(named: "wide.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let events = TextBoxSubmit.dispatchEvents(
            for: [
                .text("分析🙂 "),
                .attachment(attachment),
                .text(" これは?")
            ],
            terminalAgentContext: "restoredAgent:claude"
        )

        XCTAssertFalse(events.contains(.namedKeyRepeat(TextBoxTerminalKey.arrowLeft.rawValue, 1)))
        XCTAssertFalse(events.contains(.namedKeyRepeat(TextBoxTerminalKey.arrowRight.rawValue, 1)))
        XCTAssertEqual(
            events,
            [
                .captureVisibleTextBaseline,
                .pasteText("分析🙂 "),
                .waitForVisibleText("分析🙂 "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(imageURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(attachment.submissionText),
                .captureVisibleTextBaseline,
                .pasteText(" これは?"),
                .waitForVisibleText(" これは?"),
                .namedKey(TextBoxTerminalKey.returnKey.rawValue)
            ]
        )
    }

    func testTextBoxSubmissionPreservesNonBMPUnicode() {
        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.string = "hello 🙂 world"

        XCTAssertEqual(textView.submissionText(), "hello 🙂 world")
    }

    func testTextBoxSubmissionPreservesInlineAttachmentOrder() throws {
        let firstURL = try makeTemporaryPNGFile(named: "moon.png")
        let secondURL = try makeTemporaryPNGFile(named: "sun.png")
        let firstAttachment = TextBoxAttachment(
            localURL: firstURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        )
        let secondAttachment = TextBoxAttachment(
            localURL: secondURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: secondURL)
        )
        let firstSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: firstURL)
        let secondSubmissionText = TextBoxAttachment.submissionText(forLocalFileURL: secondURL)

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.string = "what is "
        textView.setSelectedRange(NSRange(location: ("what is " as NSString).length, length: 0))
        textView.insertAttachments([firstAttachment])
        textView.insertText("and ", replacementRange: textView.selectedRange())
        textView.insertAttachments([secondAttachment])

        XCTAssertEqual(
            textView.submissionText(),
            "what is \(firstSubmissionText) and \(secondSubmissionText) "
        )
        XCTAssertEqual(
            submissionPartSummaries(textView.submissionParts()),
            [
                .text("what is "),
                .attachment(firstSubmissionText),
                .text(" and "),
                .attachment(secondSubmissionText),
                .text(" ")
            ]
        )
        XCTAssertEqual(
            TextBoxSubmit.dispatchEvents(
                for: textView.submissionParts(),
                terminalAgentContext: "restoredAgent:claude"
            ),
            [
                .captureVisibleTextBaseline,
                .pasteText("what is "),
                .waitForVisibleText("what is "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(firstURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(firstSubmissionText),
                .captureVisibleTextBaseline,
                .pasteText(" and "),
                .waitForVisibleText(" and "),
                .captureClaudeImageTokenBaseline,
                .captureClipboardReadBaseline,
                .pasteFilePath(secondURL.path),
                .waitForClipboardRead,
                .waitForClaudeImageToken(secondSubmissionText),
                .pasteText(" "),
                .namedKey("return")
            ]
        )
    }

    func testTextBoxSubmissionPreservesRepeatedAttachmentsInOrder() throws {
        let imageURL = try makeTemporaryPNGFile(named: "moon.png")
        let attachment = TextBoxAttachment(
            localURL: imageURL,
            submissionText: TextBoxAttachment.submissionText(forLocalFileURL: imageURL)
        )

        let textView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 30))
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertAttachments([attachment])
        textView.insertText("what is this ", replacementRange: textView.selectedRange())
        textView.insertAttachments([attachment])
        textView.insertText("lol", replacementRange: textView.selectedRange())

        XCTAssertEqual(
            textView.submissionText(),
            "\(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)) what is this \(TextBoxAttachment.submissionText(forLocalFileURL: imageURL)) lol"
        )
    }

}
