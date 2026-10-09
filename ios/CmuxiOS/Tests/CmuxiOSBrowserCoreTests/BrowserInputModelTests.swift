import CmuxiOSBrowserCore
import CmuxiOSFeatureKit
import CoreGraphics
import Foundation
import Testing

@Suite("Browser screen input math")
struct BrowserInputModelTests {
    @Test func addressInputAddsHTTPSAndRefusesOtherSchemes() throws {
        let input = BrowserAddressInput()
        #expect(try input.url(from: "example.com/a").get().absoluteString == "https://example.com/a")
        #expect(try input.url(from: "localhost:3000").get().absoluteString == "https://localhost:3000")
        #expect(try input.url(from: " http://10.0.0.2:8080/x ").get().absoluteString == "http://10.0.0.2:8080/x")
        #expect(input.url(from: "javascript:alert(1)") == .failure(.scheme))
        #expect(input.url(from: "file:///etc/hosts") == .failure(.scheme))
        #expect(input.url(from: "two words") == .failure(.invalid))
        #expect(input.url(from: "  ") == .failure(.empty))
    }

    @Test func transformFitsWidthAndMapsPoints() {
        let t = BrowserViewportTransform(viewSize: CGSize(width: 360, height: 700), pageSize: CGSize(width: 1440, height: 900))
        #expect(t.fitScale == 0.25)
        #expect(t.pagePoint(fromView: CGPoint(x: 180, y: 100)) == CGPoint(x: 720, y: 400))
        #expect(t.pagePoint(fromView: CGPoint(x: 180, y: 600)) == nil)
        #expect(t.pageDelta(fromView: CGPoint(x: 0, y: 10)) == CGPoint(x: 0, y: 40))
    }

    @Test func zoomKeepsTheAnchorAndReportsTheBucket() {
        // A view shorter than the page, so the lens can pan both ways.
        let t = BrowserViewportTransform(viewSize: CGSize(width: 360, height: 200), pageSize: CGSize(width: 1440, height: 900))
        let anchor = CGPoint(x: 90, y: 50)
        let before = t.pagePoint(fromView: anchor)!
        let zoomed = t.zoomed(to: 2, around: anchor)
        let after = zoomed.pagePoint(fromView: anchor)!
        #expect(abs(after.x - before.x) < 0.001)
        #expect(abs(after.y - before.y) < 0.001)
        #expect(zoomed.zoomBucket == 2)
        #expect(t.zoomBucket == 1)
        #expect(t.zoomed(to: 9, around: anchor).zoom == BrowserViewportTransform.maxZoom)
    }

    @Test func tapsChainIntoDoubleAndTripleClicks() {
        var counter = BrowserTapClickCounter()
        #expect(counter.register(at: CGPoint(x: 10, y: 10), time: 1) == 1)
        #expect(counter.register(at: CGPoint(x: 12, y: 11), time: 1.2) == 2)
        #expect(counter.register(at: CGPoint(x: 12, y: 11), time: 1.4) == 3)
        #expect(counter.register(at: CGPoint(x: 200, y: 11), time: 1.5) == 1)
        #expect(counter.register(at: CGPoint(x: 200, y: 11), time: 3) == 1)
    }

    @Test func scrollPhasesFollowTheFingerThenTheFling() {
        var reducer = BrowserScrollPhaseReducer()
        #expect(reducer.consume(.trackingBegan) == (.began, .none))
        #expect(reducer.consume(.trackingChanged) == (.changed, .none))
        #expect(reducer.consume(.trackingEnded(willDecelerate: true)) == (.ended, .began))
        #expect(reducer.consume(.momentumChanged) == (.none, .changed))
        #expect(reducer.consume(.momentumEnded) == (.none, .ended))
        #expect(reducer.consume(.trackingChanged) == (.began, .none))
    }

    @Test func hidUsagesMapToDOMCodes() {
        let map = BrowserKeyCodeMap()
        #expect(map.code(forHIDUsage: 0x04) == "KeyA")
        #expect(map.code(forHIDUsage: 0x1d) == "KeyZ")
        #expect(map.code(forHIDUsage: 0x1e) == "Digit1")
        #expect(map.code(forHIDUsage: 0x27) == "Digit0")
        #expect(map.code(forHIDUsage: 0x28) == "Enter")
        #expect(map.key(forHIDUsage: 0x50) == "ArrowLeft")
        #expect(map.key(forHIDUsage: 0x3a) == "F1")
        #expect(map.key(forHIDUsage: 0x04) == nil)
    }
}
