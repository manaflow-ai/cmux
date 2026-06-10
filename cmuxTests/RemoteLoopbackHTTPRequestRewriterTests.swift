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


final class RemoteLoopbackHTTPRequestRewriterTests: XCTestCase {
    func testRewritesLoopbackAliasHostHeadersToLocalhost() {
        let original = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: cmux-loopback.localtest.me:3000\r\n" +
                "Origin: http://cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://cmux-loopback.localtest.me:3000/app\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://localhost:3000/app"))
        XCTAssertFalse(text.contains("cmux-loopback.localtest.me"))
    }

    func testRewritesLoopbackSubdomainAliasHostHeadersToOriginalLocalhostSubdomain() {
        let original = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: api.cmux-loopback.localtest.me:3000\r\n" +
                "Origin: http://api.cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://api.cmux-loopback.localtest.me:3000/app\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: api.localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://api.localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://api.localhost:3000/app"))
        XCTAssertFalse(text.contains("api.cmux-loopback.localtest.me"))
    }

    func testRewritesAbsoluteFormRequestLineForLoopbackAlias() {
        let original = Data(
            (
                "GET http://cmux-loopback.localtest.me:3000/demo HTTP/1.1\r\n" +
                "Host: cmux-loopback.localtest.me:3000\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET http://localhost:3000/demo HTTP/1.1\r\n"))
        XCTAssertTrue(text.contains("Host: localhost:3000"))
    }

    func testLeavesNonHTTPPayloadUntouched() {
        let original = Data([0x16, 0x03, 0x01, 0x00, 0x2a, 0x01, 0x00])
        let rewritten = RemoteLoopbackHTTPRequestRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )
        XCTAssertEqual(rewritten, original)
    }

    func testBuffersSplitLoopbackAliasHeadersUntilFullRequestArrives() {
        var streamRewriter = RemoteLoopbackHTTPRequestStreamRewriter(
            aliasHost: "cmux-loopback.localtest.me"
        )

        let firstChunk = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: cmux-loop"
            ).utf8
        )
        let secondChunk = Data(
            (
                "back.localtest.me:3000\r\n" +
                "Origin: http://cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://cmux-loopback.localtest.me:3000/app\r\n" +
                "\r\n" +
                "body=1"
            ).utf8
        )

        let firstOutput = streamRewriter.rewriteNextChunk(firstChunk, eof: false)
        let secondOutput = streamRewriter.rewriteNextChunk(secondChunk, eof: false)

        XCTAssertTrue(firstOutput.isEmpty)

        let text = String(decoding: secondOutput, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://localhost:3000/app"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nbody=1"))
        XCTAssertFalse(text.contains("cmux-loopback.localtest.me"))
    }

    func testFlushesBufferedLoopbackAliasHeadersOnEOFWhenHeadersRemainIncomplete() {
        var streamRewriter = RemoteLoopbackHTTPRequestStreamRewriter(
            aliasHost: "cmux-loopback.localtest.me"
        )

        let firstChunk = Data(
            (
                "GET /demo HTTP/1.1\r\n" +
                "Host: cmux-loop"
            ).utf8
        )
        let secondChunk = Data(
            (
                "back.localtest.me:3000\r\n" +
                "Origin: http://cmux-loopback.localtest.me:3000\r\n" +
                "Referer: http://cmux-loopback.localtest.me:3000/app\r\n" +
                "body=1"
            ).utf8
        )

        let firstOutput = streamRewriter.rewriteNextChunk(firstChunk, eof: false)
        let secondOutput = streamRewriter.rewriteNextChunk(secondChunk, eof: true)
        let thirdOutput = streamRewriter.rewriteNextChunk(Data(), eof: true)

        XCTAssertTrue(firstOutput.isEmpty)

        let text = String(decoding: secondOutput, as: UTF8.self)
        XCTAssertTrue(text.contains("Host: localhost:3000"))
        XCTAssertTrue(text.contains("Origin: http://localhost:3000"))
        XCTAssertTrue(text.contains("Referer: http://localhost:3000/app"))
        XCTAssertTrue(text.hasSuffix("\r\nbody=1"))
        XCTAssertFalse(text.contains("cmux-loopback.localtest.me"))
        XCTAssertTrue(thirdOutput.isEmpty)
    }

    func testRewritesLoopbackResponseHeadersBackToAlias() {
        let original = Data(
            (
                "HTTP/1.1 302 Found\r\n" +
                "Location: http://localhost:3000/login\r\n" +
                "Access-Control-Allow-Origin: http://localhost:3000\r\n" +
                "Set-Cookie: sid=1; Domain=localhost; Path=/\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Location: http://cmux-loopback.localtest.me:3000/login"))
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: http://cmux-loopback.localtest.me:3000"))
        XCTAssertTrue(text.contains("Set-Cookie: sid=1; Domain=cmux-loopback.localtest.me; Path=/"))
    }

    func testRewritesLoopbackSubdomainResponseHeadersBackToAliasSubdomain() {
        let original = Data(
            (
                "HTTP/1.1 302 Found\r\n" +
                "Location: http://api.localhost:3000/login\r\n" +
                "Access-Control-Allow-Origin: http://api.localhost:3000\r\n" +
                "Set-Cookie: sid=1; Domain=api.localhost; Path=/\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Location: http://api.cmux-loopback.localtest.me:3000/login"))
        XCTAssertTrue(text.contains("Access-Control-Allow-Origin: http://api.cmux-loopback.localtest.me:3000"))
        XCTAssertTrue(text.contains("Set-Cookie: sid=1; Domain=api.cmux-loopback.localtest.me; Path=/"))
    }

    func testRewritesLeadingDotLoopbackCookieDomainsBackToAliasDomains() {
        let original = Data(
            (
                "HTTP/1.1 200 OK\r\n" +
                "Set-Cookie: root=1; Domain=.localhost; Path=/\r\n" +
                "Set-Cookie: api=1; Domain=.api.localhost; Path=/\r\n" +
                "\r\n"
            ).utf8
        )

        let rewritten = RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: original,
            aliasHost: "cmux-loopback.localtest.me"
        )

        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.contains("Set-Cookie: root=1; Domain=.cmux-loopback.localtest.me; Path=/"))
        XCTAssertTrue(text.contains("Set-Cookie: api=1; Domain=.api.cmux-loopback.localtest.me; Path=/"))
    }
}


