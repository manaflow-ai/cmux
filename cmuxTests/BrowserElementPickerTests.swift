import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class BrowserElementPickerTests: XCTestCase {
    func testPickPayloadIsSanitizedBeforeTerminalHandoff() throws {
        let pick = try XCTUnwrap(
            BrowserElementPick.make(
                body: [
                    "selector": "button#buy\n\u{001B}[31m",
                    "selector_kind": "css",
                    "xpath": "/html/body/button\n",
                    "text": "Buy now\nrm -rf /\u{202E}",
                    "tag": "BUTTON",
                    "role": "button\n",
                    "label": "Checkout\u{200B}",
                    "attributes": [
                        "onclick": "evil()",
                        "aria-label": "Checkout\nnow",
                        "href": "javascript:alert(1)\n",
                    ],
                    "timestamp_ms": 1_772_000_000_000,
                ],
                surfaceId: UUID(),
                workspaceId: UUID(),
                pageURL: URL(string: "https://example.test/cart"),
                pageTitle: "Cart"
            )
        )

        XCTAssertEqual(pick.tagName, "button")
        XCTAssertEqual(pick.text, "Buy nowrm -rf /")
        XCTAssertEqual(pick.label, "Checkout")
        XCTAssertEqual(pick.attributes["aria-label"], "Checkoutnow")
        XCTAssertEqual(pick.attributes["onclick"], nil)
        XCTAssertFalse(pick.selector.contains("\n"))
        XCTAssertFalse(pick.selector.contains("\u{001B}"))

        let terminalContext = pick.terminalContext
        XCTAssertTrue(terminalContext.hasPrefix("# cmux browser picked element: "))
        XCTAssertFalse(terminalContext.contains("\n"))
        XCTAssertFalse(terminalContext.contains("\r"))
        XCTAssertFalse(terminalContext.contains("\u{001B}"))
    }

    func testPickStoreReadWaitAndClearAreScopedToSurface() {
        let store = BrowserElementPickStore()
        let surfaceId = UUID()
        let otherSurfaceId = UUID()
        let workspaceId = UUID()
        let first = makePick(surfaceId: surfaceId, workspaceId: workspaceId, selector: "button#first", text: "First")
        let other = makePick(surfaceId: otherSurfaceId, workspaceId: workspaceId, selector: "button#other", text: "Other")

        XCTAssertNil(store.get(surfaceId: surfaceId))
        XCTAssertNil(store.waitForPick(surfaceId: surfaceId, includeCurrent: false, timeoutMs: 0))

        let storedFirst = store.record(first)
        _ = store.record(other)
        XCTAssertEqual(store.get(surfaceId: surfaceId)?.sequence, storedFirst.sequence)
        XCTAssertEqual(store.waitForPick(surfaceId: surfaceId, includeCurrent: true, timeoutMs: 0)?.selector, "button#first")
        XCTAssertNil(store.waitForPick(surfaceId: surfaceId, includeCurrent: false, timeoutMs: 0))

        let second = makePick(
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            selector: "button#second",
            text: "Second"
        )
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            _ = store.record(second)
        }

        let waited = store.waitForPick(surfaceId: surfaceId, includeCurrent: false, timeoutMs: 1_000)
        XCTAssertEqual(waited?.selector, "button#second")
        XCTAssertEqual(store.get(surfaceId: otherSurfaceId)?.selector, "button#other")
        XCTAssertTrue(store.clear(surfaceId: surfaceId))
        XCTAssertNil(store.get(surfaceId: surfaceId))
        XCTAssertNotNil(store.get(surfaceId: otherSurfaceId))
        store.clear(surfaceIds: [surfaceId, otherSurfaceId])
        XCTAssertNil(store.get(surfaceId: otherSurfaceId))
    }

    private func makePick(
        surfaceId: UUID,
        workspaceId: UUID,
        selector: String,
        text: String
    ) -> BrowserElementPick {
        BrowserElementPick(
            sequence: 0,
            surfaceId: surfaceId,
            workspaceId: workspaceId,
            selector: selector,
            selectorKind: "css",
            xpath: nil,
            text: text,
            tagName: "button",
            role: nil,
            label: nil,
            attributes: [:],
            shadowPath: [],
            url: "https://example.test",
            title: "Example",
            frameURL: "https://example.test",
            rect: nil,
            timestampMs: 1_772_000_000_000
        )
    }
}
