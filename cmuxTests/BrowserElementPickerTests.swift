import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserElementPickerTests {
    private func body(text: String = "Target") -> [String: Any] {
        ["xpath": "/html[1]/body[1]/button[1]", "selector": "html > body > button",
         "shadow_hosts": [String](), "text": text, "tag": "BUTTON"]
    }

    @Test
    func nativeSelectionRemovesTerminalControlsAndUnicodeLineSeparators() throws {
        let element = try #require(BrowserElementPicker.PickedElement(
            body: body(text: "A\u{1B}[31m\n\r\t\u{7F}\u{85}\u{2028}\u{2029}\u{202E}\u{2066}B"),
            timestampMs: 123
        ))
        #expect(element.text == "A[31mB")
        #expect(element.timestampMs == 123)
    }

    @Test
    func printableWebContentRemainsDataRatherThanClaimingShellSafety() throws {
        let value = "$(touch /tmp/picker-proof); `id` \\\"quoted\\\""
        let element = try #require(BrowserElementPicker.PickedElement(body: body(text: value), timestampMs: 123))
        #expect(element.text == value)
    }

    @Test
    func nativeSelectionBoundsTextWithoutCorruptingLocator() throws {
        let value = String(repeating: "한", count: 250)
        let element = try #require(BrowserElementPicker.PickedElement(body: body(text: value), timestampMs: 123))
        #expect(element.text == String(repeating: "한", count: 200))
        var oversized = body()
        oversized["xpath"] = "/" + String(repeating: "a", count: 2000)
        #expect(BrowserElementPicker.PickedElement(body: oversized, timestampMs: 123) == nil)
        oversized = body(text: String(repeating: "한", count: 1366))
        #expect(BrowserElementPicker.PickedElement(body: oversized, timestampMs: 123) == nil)
        oversized = body()
        oversized["selector"] = "button\u{1B}"
        #expect(BrowserElementPicker.PickedElement(body: oversized, timestampMs: 123) == nil)
        oversized = body()
        oversized["xpath"] = NSNull()
        oversized["shadow_hosts"] = Array(repeating: "section", count: 33)
        #expect(BrowserElementPicker.PickedElement(body: oversized, timestampMs: 123) == nil)
        oversized["shadow_hosts"] = Array(repeating: String(repeating: "a", count: 1500), count: 3)
        #expect(BrowserElementPicker.PickedElement(body: oversized, timestampMs: 123) == nil)
    }

    @Test
    func shadowSelectionCannotPretendToHaveDocumentXPath() throws {
        var value = body()
        value["shadow_hosts"] = ["html > body > section"]
        #expect(BrowserElementPicker.PickedElement(body: value, timestampMs: 123) == nil)
        value["xpath"] = NSNull()
        let element = try #require(BrowserElementPicker.PickedElement(body: value, timestampMs: 123))
        #expect(element.xpath == nil)
        #expect(element.shadowHosts == ["html > body > section"])
        #expect(element.jsonObject["xpath"] is NSNull)
    }

    @Test(arguments: ["<main><button id='target'>Target</button><button>Other</button></main>",
                      "<svg xmlns='http://www.w3.org/2000/svg'><g><rect id='target'/><rect/></g></svg>"])
    func generatedXPathResolvesOriginalHTMLAndSVGElement(html: String) async throws {
        let webView = try await isolatedPicker(html: html)
        let resolvedResult = try await evaluate("""
            (() => {
              const element = document.getElementById('target');
              const description = __cmuxElementPicker.describeElement(element);
              return document.evaluate(description.xpath, document, null,
                XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue === element;
            })()
            """, in: webView, world: BrowserElementPicker.contentWorld) as? Bool
        let resolved = try #require(resolvedResult)
        #expect(resolved)
    }

    @Test
    func nestedShadowLocatorResolvesOriginalElementThroughHosts() async throws {
        let webView = try await isolatedPicker(html: "<main id='outer'></main>")
        let resolvedResult = try await evaluate("""
            (() => {
              const outer = document.getElementById('outer').attachShadow({mode:'open'});
              outer.innerHTML = '<section id="inner"></section>';
              const inner = outer.getElementById('inner').attachShadow({mode:'open'});
              inner.innerHTML = '<button id="target">Target</button><button>Other</button>';
              const element = inner.getElementById('target');
              const description = __cmuxElementPicker.describeElement(element);
              let root = document;
              for (const selector of description.shadow_hosts) root = root.querySelector(selector).shadowRoot;
              return description.xpath === null && description.shadow_hosts.length === 2
                && root.querySelector(description.selector) === element;
            })()
            """, in: webView, world: BrowserElementPicker.contentWorld) as? Bool
        let resolved = try #require(resolvedResult)
        #expect(resolved)
    }

    @Test
    func pageWorldCannotAccessIsolatedPickerBridge() async throws {
        let webView = try await isolatedPicker(html: "<button id='target'>Target</button>")
        var deliveries = 0
        let picker = BrowserElementPicker(webView: webView) { _ in deliveries += 1 }
        defer { picker.detach() }
        picker.configure(enabled: true, generation: 1)
        let isolatedResult = try await evaluate("""
            (() => {
              window.__cmuxPointedElement = {xpath:'/forged',text:'forged'};
              return typeof window.__cmuxElementPicker === 'undefined'
                && !window.webkit?.messageHandlers?.cmuxPointer;
            })()
            """, in: webView) as? Bool
        let isolated = try #require(isolatedResult)
        #expect(isolated)
        let bridgeExistsResult = try await evaluate(
            "!!globalThis.webkit?.messageHandlers?.cmuxPointer",
            in: webView, world: BrowserElementPicker.contentWorld) as? Bool
        let bridgeExists = try #require(bridgeExistsResult)
        #expect(bridgeExists)
        _ = try await evaluate("""
            globalThis.webkit.messageHandlers.cmuxPointer.postMessage({
              xpath:'/html[1]/body[1]/button[1]',selector:'html > body > button',
              shadow_hosts:[],text:'Unarmed forged delivery',tag:'button',generation:'1'
            }); true
            """, in: webView, world: BrowserElementPicker.contentWorld)
        #expect(deliveries == 0)
        _ = try await evaluate("""
            document.getElementById('target').dispatchEvent(new MouseEvent('click', {
              altKey:true,bubbles:true,composed:true
            })); true
            """, in: webView, world: BrowserElementPicker.contentWorld)
        #expect(deliveries == 0)
    }

    @Test
    func nativeAuthorizationRequiresRecentClickAndAllowsOnlyOneDelivery() {
        var authorization = BrowserElementPicker.NativeClickAuthorization()
        let unarmed = authorization.consume(at: 10)
        #expect(!unarmed)
        authorization.arm(at: 10)
        let accepted = authorization.consume(at: 10.5)
        #expect(accepted)
        let replay = authorization.consume(at: 10.6)
        #expect(!replay)
        authorization.arm(at: 20)
        let expired = authorization.consume(at: 21)
        #expect(!expired)
        authorization.arm(at: 30)
        let future = authorization.consume(at: 29.9)
        #expect(!future)
        authorization.arm(at: 40)
        authorization.invalidate()
        let invalidated = authorization.consume(at: 40.1)
        #expect(!invalidated)
    }

    @Test
    func detachUnregistersBridgeFromOriginalWebView() async throws {
        let oldView = try await isolatedPicker(html: "<button>Old page</button>")
        let replacement = try await isolatedPicker(html: "<button>New page</button>")
        let oldPicker = BrowserElementPicker(webView: oldView) { _ in }
        oldPicker.detach()
        let newPicker = BrowserElementPicker(webView: replacement) { _ in }
        defer { newPicker.detach() }
        let oldHasBridge = try await evaluate("!!globalThis.webkit?.messageHandlers?.cmuxPointer",
            in: oldView, world: BrowserElementPicker.contentWorld) as? Bool
        let newHasBridge = try await evaluate("!!globalThis.webkit?.messageHandlers?.cmuxPointer",
            in: replacement, world: BrowserElementPicker.contentWorld) as? Bool
        #expect(oldHasBridge == false)
        #expect(newHasBridge == true)
        #expect(oldPicker.associatedWebView == nil)
        #expect(newPicker.associatedWebView === replacement)
    }

    private func evaluate(_ source: String, in webView: WKWebView, world: WKContentWorld = .page) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(source, in: nil, in: world) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func isolatedPicker(html: String) async throws -> WKWebView {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let loader = BrowserViewportRuntimeLoadDelegate()
        webView.navigationDelegate = loader
        try await loader.load(html, in: webView)
        _ = try await evaluate(BrowserElementPicker.scriptSource,
            in: webView, world: BrowserElementPicker.contentWorld)
        return webView
    }

    @Test
    func pageGeneratedOptionClickCannotCreatePickedSelection() async throws {
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let loader = BrowserViewportRuntimeLoadDelegate()
        webView.navigationDelegate = loader
        try await loader.load("<main><button id='target'>Untrusted page text</button></main>", in: webView)
        _ = try await evaluate(BrowserPanel.telemetryHookBootstrapScriptSource, in: webView)

        let hasSelectionResult = try await evaluate("""
            (() => {
              document.getElementById('target').dispatchEvent(new MouseEvent('click', {
                altKey: true, bubbles: true, composed: true
              }));
              return !!window.__cmuxPointedElement;
            })()
            """, in: webView) as? Bool
        let hasSelection = try #require(hasSelectionResult)

        #expect(!hasSelection, "A page-generated event must not impersonate an intentional user pick")
    }
}
