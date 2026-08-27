import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalClipboardInputSequencerTests {
    @Test("overflow replay can reserve another paste before current input")
    func overflowCannotDropInputBehindAReplayStartedPaste() {
        let sequencer = TerminalClipboardInputSequencer<() -> Void, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        var nestedAdmissionAccepted = false
        sequencer.beginRequest(
            id: 1,
            onOverflow: {
                sequencer.cancelRequest(
                    id: 1,
                    currentEpoch: 0,
                    deferredInputDisposition: .replay
                ) { replay in
                    replay()
                }
            }
        )
        #expect(sequencer.shouldDefer {
            delivered.append("replayed-input")
            nestedAdmissionAccepted = sequencer.reserveRequestAdmission(
                id: 2,
                onOverflow: {
                    sequencer.cancelReservedRequest(
                        id: 2,
                        requestEpoch: 0,
                        currentEpoch: 0,
                        deferredInputDisposition: .replay
                    ) { replay in
                        replay()
                    }
                }
            )
        })
        #expect(sequencer.shouldDefer {
            delivered.append("queued-input")
        })

        let currentInputDeferred = sequencer.shouldDefer {
            delivered.append("current-input")
        }
        if !currentInputDeferred {
            delivered.append("current-input")
        }

        #expect(nestedAdmissionAccepted)
        #expect(currentInputDeferred)
        #expect(delivered == ["replayed-input"])

        sequencer.beginReservedRequest(id: 2)
        delivered.append("paste-2-complete")
        sequencer.completeRequest(id: 2, confirmed: false) { replay in
            replay()
        }

        #expect(
            delivered == [
                "replayed-input",
                "paste-2-complete",
                "queued-input",
                "current-input",
            ]
        )
    }

    @Test("overlapping reservations hold input through every request")
    func overlappingReservationsHoldInputThroughEveryRequest() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []

        await Task.detached {
            _ = sequencer.reserveRequestAdmission(id: 1, onOverflow: {})
            _ = sequencer.reserveRequestAdmission(id: 2, onOverflow: {})
        }.value
        #expect(sequencer.shouldDefer("suffix"))

        sequencer.beginReservedRequest(id: 1)
        delivered.append("paste-1")
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["paste-1"])

        sequencer.beginReservedRequest(id: 2)
        delivered.append("paste-2")
        sequencer.completeRequest(id: 2, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["paste-1", "paste-2", "suffix"])
    }

    @Test("chained paste completions preserve callback registration order")
    func chainedPasteCompletionsPreserveRegistrationOrder() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []

        await Task.detached {
            #expect(sequencer.reserveRequestAdmission(id: 1, onOverflow: {}))
            #expect(sequencer.reserveRequestAdmission(id: 2, onOverflow: {}))
        }.value
        #expect(sequencer.shouldDefer("suffix"))

        sequencer.beginReservedRequest(id: 2)
        sequencer.performCompletionWhenReady(id: 2) {
            delivered.append("paste-2")
            sequencer.completeRequest(id: 2, confirmed: false) {
                delivered.append($0)
            }
        }
        #expect(delivered.isEmpty)

        sequencer.beginReservedRequest(id: 1)
        sequencer.performCompletionWhenReady(id: 1) {
            delivered.append("paste-1")
            sequencer.completeRequest(id: 1, confirmed: false) {
                delivered.append($0)
            }
        }

        #expect(delivered == ["paste-1", "paste-2", "suffix"])
    }

    @Test("blocked paste completes before queued suffix and return")
    func blockedPasteCompletesBeforeQueuedInput() async {
        let operation = ControlledPastePreparationOperation()
        let deadlines = ControlledPastePreparationDeadlines()
        let service = TerminalImageTransferPreparationService(
            deadline: .seconds(30),
            deadlineSleep: { _ in try await deadlines.sleep() },
            operation: { try await operation.run($0) },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        let (request, pasteboard) = makeReadRequest(label: "ordered-input")
        defer {
            pasteboard.clearContents()
            pasteboard.releaseGlobally()
        }
        var started = operation.startedEvents().makeAsyncIterator()
        var delivered: [String] = []

        sequencer.beginRequest(id: 1)
        let pasteTask = Task {
            await service.prepare(request: request, mode: .paste)
        }
        await deadlines.waitForArrivalCount(1)
        let startedName = await started.next()
        #expect(startedName == request.pasteboardName)
        #expect(sequencer.shouldDefer("suffix"))
        #expect(sequencer.shouldDefer("return"))
        #expect(delivered.isEmpty)

        await operation.release(request.pasteboardName)
        let pasteResult = await pasteTask.value
        #expect(pasteResult == .insertText(request.pasteboardName))
        delivered.append("paste")
        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }

        #expect(delivered == ["paste", "suffix", "return"])
    }

    @Test("replayed paste pauses later suffix until its read completes")
    func replayedPastePausesDrain() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1)
        #expect(sequencer.shouldDefer("paste-2"))
        #expect(sequencer.shouldDefer("suffix"))

        sequencer.completeRequest(id: 1, confirmed: false) { event in
            delivered.append(event)
            if event == "paste-2" {
                sequencer.beginRequest(id: 2)
            }
        }
        #expect(delivered == ["paste-2"])

        delivered.append("paste-2-complete")
        sequencer.completeRequest(id: 2, confirmed: false) {
            delivered.append($0)
        }
        #expect(delivered == ["paste-2", "paste-2-complete", "suffix"])
    }

    @Test("a replayed runtime batch pauses when it starts another paste")
    func replayedRuntimeBatchCanDeferItsRemainingInput() {
        let sequencer = TerminalClipboardInputSequencer<() -> Void, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1)
        #expect(sequencer.shouldDefer {
            delivered.append("paste-2")
            sequencer.beginRequest(id: 2)
            let deferred = sequencer.shouldDefer {
                delivered.append("suffix")
            }
            if !deferred {
                delivered.append("suffix")
            }
        })

        sequencer.completeRequest(id: 1, confirmed: false) { replay in
            replay()
        }
        #expect(delivered == ["paste-2"])

        delivered.append("paste-2-complete")
        sequencer.completeRequest(id: 2, confirmed: false) { replay in
            replay()
        }
        #expect(delivered == ["paste-2", "paste-2-complete", "suffix"])
    }

    @Test("cancelling stale input preserves replacement-surface input")
    func cancellingStaleRequestPreservesReplacementInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1, epoch: 7)
        #expect(sequencer.shouldDefer("stale-suffix", epoch: 7))

        #expect(!sequencer.shouldDefer("replacement-input", epoch: 9))
        delivered.append("replacement-input")
        sequencer.cancelRequest(
            id: 1,
            currentEpoch: 9,
            deferredInputDisposition: .discard
        ) {
            delivered.append($0)
        }

        #expect(delivered == ["replacement-input"])
    }

    @Test("pre-admission teardown discards input from the dying surface")
    func preAdmissionTeardownDiscardsDyingSurfaceInput() async {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []

        let reservationAccepted = await Task.detached {
            sequencer.reserveRequestAdmission(
                id: 1,
                epoch: 7,
                onOverflow: {}
            )
        }.value
        #expect(reservationAccepted)
        #expect(sequencer.shouldDefer("dying-surface-input", epoch: 7))

        sequencer.cancelReservedRequest(
            id: 1,
            requestEpoch: 7,
            currentEpoch: 9,
            deferredInputDisposition: .discard
        ) {
            delivered.append($0)
        }

        #expect(delivered.isEmpty)
    }

    @Test("confirmation keeps input queued and reports one logical completion")
    func confirmationKeepsInputQueued() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 8
        )
        var delivered: [String] = []
        var logicalCompletionCount = 0
        sequencer.beginRequest(id: 1)
        #expect(sequencer.shouldDefer("suffix"))
        sequencer.requireConfirmation(for: 1)

        sequencer.completeRequest(
            id: 1,
            confirmed: true,
            onLogicalCompletion: { logicalCompletionCount += 1 }
        ) {
            delivered.append($0)
        }
        #expect(delivered.isEmpty)
        #expect(logicalCompletionCount == 0)

        sequencer.completeRequest(
            id: 1,
            confirmed: false,
            onLogicalCompletion: { logicalCompletionCount += 1 }
        ) {
            delivered.append($0)
        }
        #expect(delivered == ["suffix"])
        #expect(logicalCompletionCount == 1)
    }

    @Test("clipboard request identity rejects allocator pointer reuse")
    func clipboardRequestIdentityRejectsPointerReuse() {
        let identity = TerminalClipboardRequestSurfaceIdentity(
            surfaceAddress: 0x7540,
            generation: 7
        )

        #expect(identity.matches(surfaceAddress: 0x7540, generation: 7))
        #expect(!identity.matches(surfaceAddress: 0x7540, generation: 9))
        #expect(!identity.matches(surfaceAddress: 0x7550, generation: 7))
    }

    @Test("pointer input waits for the clipboard request to complete")
    func pointerInputWaitsForClipboardRequest() throws {
        let terminalView = GhosttyNSView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 200)
        )
        let priorResponder = NSTextField(
            frame: NSRect(x: 0, y: 0, width: 100, height: 20)
        )
        let contentView = NSView(frame: terminalView.frame)
        contentView.addSubview(terminalView)
        contentView.addSubview(priorResponder)
        let window = NSWindow(
            contentRect: contentView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = contentView
        #expect(window.makeFirstResponder(priorResponder))
        let priorFirstResponder = try #require(window.firstResponder)
        defer {
            window.orderOut(nil)
            window.close()
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        terminalView.terminalClipboardInputSequencer.beginRequest(
            id: 1,
            epoch: .max
        )
        terminalView.mouseDown(with: event)
        #expect(window.firstResponder === priorFirstResponder)

        terminalView.completeClipboardRead(1, confirmed: false)
        #expect(window.firstResponder === terminalView)
    }

    @Test("surface factory injects one shared paste preparation service")
    func surfaceFactoryInjectsSharedPastePreparationService() throws {
        let preparationService = TerminalImageTransferPreparationService(
            operation: { _ in throw CancellationError() },
            cleanup: { _ in },
            failureSignal: { _ in }
        )
        let factory = TerminalSurfaceViewFactory(
            imageTransferPreparation: preparationService
        )
        let firstView = try #require(
            factory.makeSurfaceViews(initialFrame: .zero).surfaceView
                as? GhosttyNSView
        )
        let secondView = try #require(
            factory.makeSurfaceViews(initialFrame: .zero).surfaceView
                as? GhosttyNSView
        )
        let firstService = try #require(firstView.imageTransferPreparation)
        let secondService = try #require(secondView.imageTransferPreparation)

        #expect(firstService === preparationService)
        #expect(secondService === preparationService)
    }

    @Test("pointer overflow never releases keyboard input before paste")
    func pointerOverflowNeverReleasesKeyboardInput() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        sequencer.beginRequest(id: 1)

        #expect(sequencer.shouldDefer("pointer-1", discardWhenFull: true))
        #expect(sequencer.shouldDefer("pointer-2", discardWhenFull: true))
        #expect(
            sequencer.shouldDefer(
                "pointer-3",
                discardWhenFull: true
            )
        )
        #expect(sequencer.shouldDefer("return", discardWhenFull: false))
        #expect(delivered.isEmpty)

        sequencer.completeRequest(id: 1, confirmed: false) {
            delivered.append($0)
        }

        #expect(delivered == ["pointer-2", "return"])
    }

    @Test("non-lossy overflow cancels paste before routing current input")
    func nonLossyOverflowCancelsPasteFirst() {
        let sequencer = TerminalClipboardInputSequencer<String, Int>(
            maximumBufferedEvents: 2
        )
        var delivered: [String] = []
        sequencer.beginRequest(
            id: 1,
            epoch: 7,
            onOverflow: {
                delivered.append("paste-cancelled")
                sequencer.completeRequest(id: 1, confirmed: false) {
                    delivered.append($0)
                }
            }
        )
        #expect(sequencer.shouldDefer("first", epoch: 7))
        #expect(sequencer.shouldDefer("second", epoch: 7))

        #expect(!sequencer.shouldDefer("current", epoch: 7))
        delivered.append("current")

        #expect(
            delivered == [
                "paste-cancelled",
                "first",
                "second",
                "current",
            ]
        )
    }

    private func makeReadRequest(
        label: String
    ) -> (TerminalPasteboardReadRequest, NSPasteboard) {
        let pasteboard = NSPasteboard(
            name: .init("cmux-tests-input-sequence-\(label)-\(UUID().uuidString)")
        )
        pasteboard.clearContents()
        return (TerminalPasteboardReadRequest(pasteboard: pasteboard), pasteboard)
    }
}
