import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalPointerGestureStateTests {
    @Test
    func usesModifiersCapturedAtPress() throws {
        var state = TerminalPointerGestureState()
        state.begin(
            windowNumber: 7,
            timestamp: 10,
            modifierFlagsRawValue: 0x0010_0000,
            permitsLinkActivation: true
        )

        let rawCompletion = state.complete(windowNumber: 7, timestamp: 11)
        let completion = try #require(rawCompletion)

        #expect(completion.modifierFlagsRawValue == 0x0010_0000)
        #expect(completion.permitsLinkActivation)
        #expect(!state.hasPendingRelease)
    }

    @Test
    func rejectsReleaseFromAnotherWindowAndClearsState() {
        var state = TerminalPointerGestureState()
        state.begin(
            windowNumber: 7,
            timestamp: 10,
            modifierFlagsRawValue: 0,
            permitsLinkActivation: true
        )

        let completion = state.complete(windowNumber: 8, timestamp: 11)

        #expect(completion?.modifierFlagsRawValue == nil)
        #expect(!state.hasPendingRelease)
    }

    @Test
    func rejectsReleaseWithStaleTimestampAndClearsState() {
        var state = TerminalPointerGestureState()
        state.begin(
            windowNumber: 7,
            timestamp: 10,
            modifierFlagsRawValue: 0,
            permitsLinkActivation: true
        )

        let completion = state.complete(windowNumber: 7, timestamp: 9)

        #expect(completion?.modifierFlagsRawValue == nil)
        #expect(!state.hasPendingRelease)
    }

    @Test
    func cancelledGestureCannotBeCompletedLater() {
        var state = TerminalPointerGestureState()
        state.begin(
            windowNumber: 7,
            timestamp: 10,
            modifierFlagsRawValue: 0,
            permitsLinkActivation: true
        )

        state.cancel()
        let completion = state.complete(windowNumber: 7, timestamp: 20)

        #expect(completion?.modifierFlagsRawValue == nil)
    }

    @Test
    func pointerExitInvalidatesLinkButRetainsBalancingRelease() throws {
        var state = TerminalPointerGestureState()
        state.begin(
            windowNumber: 7,
            timestamp: 10,
            modifierFlagsRawValue: 0,
            permitsLinkActivation: true
        )

        state.invalidateLinkActivation()

        #expect(state.hasPendingRelease)
        let rawCompletion = state.complete(windowNumber: 7, timestamp: 11)
        let completion = try #require(rawCompletion)
        #expect(!completion.permitsLinkActivation)
    }

    @Test
    func newerPressReplacesUnfinishedPress() throws {
        var state = TerminalPointerGestureState()
        state.begin(
            windowNumber: 7,
            timestamp: 10,
            modifierFlagsRawValue: 1,
            permitsLinkActivation: true
        )
        state.begin(
            windowNumber: 9,
            timestamp: 20,
            modifierFlagsRawValue: 2,
            permitsLinkActivation: false
        )

        let rawCompletion = state.complete(windowNumber: 9, timestamp: 21)
        let completion = try #require(rawCompletion)
        #expect(completion.modifierFlagsRawValue == 2)
        #expect(!completion.permitsLinkActivation)
    }
}
