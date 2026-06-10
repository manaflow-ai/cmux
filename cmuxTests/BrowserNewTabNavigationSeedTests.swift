@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class BrowserNewTabNavigationSeedTests: XCTestCase {
    func testPreservesOriginalRequestHeadersMethodBodyAndBypassHost() throws {
        let url = try XCTUnwrap(URL(string: "https://www.linkedin.com/redir/redirect?url=https%3A%2F%2Fexample.com"))
        let body = Data("payload=1".utf8)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("https://www.linkedin.com/feed/", forHTTPHeaderField: "Referer")
        request.setValue("keep-me", forHTTPHeaderField: "X-Cmux-Test")

        let seed = try XCTUnwrap(
            browserNewTabNavigationSeed(
                from: request,
                bypassInsecureHTTPHostOnce: "www.linkedin.com"
            )
        )

        // This covers the pure seeding helper only. WebKit may still rewrite
        // programmatic loads when the request is replayed in the destination tab.
        XCTAssertEqual(seed.url, url)
        XCTAssertEqual(seed.bypassInsecureHTTPHostOnce, "www.linkedin.com")
        XCTAssertEqual(seed.initialRequest.httpMethod, "POST")
        XCTAssertEqual(seed.initialRequest.httpBody, body)
        XCTAssertEqual(
            seed.initialRequest.value(forHTTPHeaderField: "Referer"),
            "https://www.linkedin.com/feed/"
        )
        XCTAssertEqual(
            seed.initialRequest.value(forHTTPHeaderField: "X-Cmux-Test"),
            "keep-me"
        )
        XCTAssertEqual(seed.initialRequest.cachePolicy, .reloadIgnoringLocalCacheData)
    }
}

