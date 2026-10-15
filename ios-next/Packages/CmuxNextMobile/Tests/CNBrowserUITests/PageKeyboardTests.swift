@testable import CNBrowserUI
import CNCore
import Foundation
import Testing

struct PageKeyboardTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1000)

    private func focus(_ editable: Bool, tab: String = "T1", stream: UInt32 = 7, multiline: Bool? = false,
                       type: String? = "text", hint: String? = nil, mode: String? = nil, user: Bool? = true) -> BrowserFocusEvent {
        BrowserFocusEvent(tabId: tab, streamId: stream, editable: editable, multiline: editable ? multiline : nil,
                          inputType: editable ? type : nil, inputMode: mode, enterKeyHint: hint, userInitiated: user)
    }

    @Test func aTapOnAFieldRaisesTheKeyboard() {
        var p = PageKeyboardPolicy()
        p.touchBegan()
        p.tapped(tabId: "T1", at: t0)
        #expect(p.handle(focus(true), activeTabId: "T1", streamId: 7, now: t0.addingTimeInterval(0.2)) == .raise)
        #expect(p.focus?.inputType == "text")
    }

    @Test func focusThePageGaveItselfDoesNotRaise() {
        var p = PageKeyboardPolicy()
        // No tap at all (autofocus on load).
        #expect(p.handle(focus(true), activeTabId: "T1", streamId: 7, now: t0) == .keep)
        // A tap, but the page says no user input caused it.
        p.tapped(tabId: "T1", at: t0)
        #expect(p.handle(focus(true, user: false), activeTabId: "T1", streamId: 7, now: t0) == .keep)
        // A tap too long ago.
        #expect(p.handle(focus(true), activeTabId: "T1", streamId: 7, now: t0.addingTimeInterval(5)) == .keep)
    }

    @Test func aDragAfterATapDoesNotRaise() {
        var p = PageKeyboardPolicy()
        p.tapped(tabId: "T1", at: t0)
        // The next touch is a drag (it never ends as a tap).
        p.touchBegan()
        #expect(p.handle(focus(true), activeTabId: "T1", streamId: 7, now: t0.addingTimeInterval(0.5)) == .keep)
    }

    @Test func focusLeavingAFieldLowersTheKeyboard() {
        var p = PageKeyboardPolicy()
        p.tapped(tabId: "T1", at: t0)
        _ = p.handle(focus(true), activeTabId: "T1", streamId: 7, now: t0)
        #expect(p.handle(focus(false), activeTabId: "T1", streamId: 7, now: t0) == .lower)
        #expect(p.focus == nil)
    }

    @Test func reportsForAnotherTabOrStreamAreIgnored() {
        var p = PageKeyboardPolicy()
        p.tapped(tabId: "T1", at: t0)
        #expect(p.handle(focus(true, tab: "T2"), activeTabId: "T1", streamId: 7, now: t0) == .keep)
        #expect(p.handle(focus(false, stream: 3), activeTabId: "T1", streamId: 7, now: t0) == .keep)
        #expect(p.focus == nil)
    }

    @Test func returnLowersOnlyOutsideMultiLineFields() {
        #expect(PageFieldTraits(focus: nil).returnLowersKeyboard)
        #expect(PageFieldTraits(focus: focus(true)).returnLowersKeyboard)
        #expect(!PageFieldTraits(focus: focus(true, multiline: true, type: nil)).returnLowersKeyboard)
    }

    @Test func returnKeyAndLayoutFollowTheField() {
        #expect(PageFieldTraits(focus: focus(true, type: "search")).returnKey == .search)
        #expect(PageFieldTraits(focus: focus(true, type: "url")).returnKey == .go)
        #expect(PageFieldTraits(focus: focus(true, hint: "send")).returnKey == .send)
        #expect(PageFieldTraits(focus: focus(true, multiline: true, type: nil)).returnKey == .default)
        #expect(PageFieldTraits(focus: focus(true, type: "email")).keyboardKind == .email)
        #expect(PageFieldTraits(focus: focus(true, type: "text", mode: "numeric")).keyboardKind == .number)
        #expect(PageFieldTraits(focus: focus(true, type: "tel")).keyboardKind == .phone)
        #expect(PageFieldTraits(focus: nil).keyboardKind == .text)
    }
}
