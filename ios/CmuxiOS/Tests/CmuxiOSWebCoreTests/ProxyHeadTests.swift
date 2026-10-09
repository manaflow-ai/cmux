import CmuxiOSWebCore
import Foundation
import Testing

@Suite("Proxy request heads and addresses")
struct ProxyHeadTests {
    static let raw = "GET /app?x=1 HTTP/1.1\r\nHost: localhost:61000\r\nCookie: a=1; __cmux_tunnel=T0K; b=2\r\n"
        + "Connection: keep-alive\r\nAccept: */*\r\n\r\nBODY"

    @Test func splitsAHeadFromItsBodyAndWaitsForMore() throws {
        #expect(try ProxyRequestHead.split(Data("GET / HTTP/1.1\r\nHost: x".utf8)) == nil)
        let (head, rest) = try #require(try ProxyRequestHead.split(Data(Self.raw.utf8)))
        #expect(head.requestLine == "GET /app?x=1 HTTP/1.1")
        #expect(head.cookie("__cmux_tunnel") == "T0K")
        #expect(head.cookie("missing") == nil)
        #expect(rest == Data("BODY".utf8))
    }

    @Test func refusesTLSAndGarbage() {
        #expect(throws: ProxyHeadError.notHTTP) { try ProxyRequestHead.split(Data([0x16, 0x03, 0x01, 0x00])) }
        #expect(throws: ProxyHeadError.notHTTP) { try ProxyRequestHead.split(Data("hello world\r\n\r\n".utf8)) }
        #expect(throws: ProxyHeadError.tooLarge) {
            try ProxyRequestHead.split(Data(("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000)).utf8))
        }
    }

    @Test func forwardingStripsTheTokenRewritesHostAndClosesAfter() throws {
        let (head, _) = try #require(try ProxyRequestHead.split(Data(Self.raw.utf8)))
        let mirrored = String(decoding: head.forwarded(strippingCookie: "__cmux_tunnel", host: nil, closeAfter: false), as: UTF8.self)
        #expect(mirrored == "GET /app?x=1 HTTP/1.1\r\nHost: localhost:61000\r\nCookie: a=1; b=2\r\nConnection: keep-alive\r\nAccept: */*\r\n\r\n")
        let rewritten = String(decoding: head.forwarded(strippingCookie: "__cmux_tunnel", host: "localhost:5173", closeAfter: true),
                               as: UTF8.self)
        #expect(rewritten == "GET /app?x=1 HTTP/1.1\r\nHost: localhost:5173\r\nCookie: a=1; b=2\r\nAccept: */*\r\nConnection: close\r\n\r\n")
        let upgrade = "GET /hmr HTTP/1.1\r\nHost: localhost:1\r\nCookie: __cmux_tunnel=T0K\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n"
        let (ws, _) = try #require(try ProxyRequestHead.split(Data(upgrade.utf8)))
        let kept = String(decoding: ws.forwarded(strippingCookie: "__cmux_tunnel", host: "localhost:5173", closeAfter: true), as: UTF8.self)
        #expect(kept == "GET /hmr HTTP/1.1\r\nHost: localhost:5173\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n")
    }

    @Test func addressesAreLoopbackOnly() {
        #expect(WebAddress("5173") == WebAddress(port: 5173))
        #expect(WebAddress("localhost:3000/app?x=1") == WebAddress(port: 3000, path: "/app", query: "x=1"))
        #expect(WebAddress("http://127.0.0.1:8080") == WebAddress(port: 8080))
        #expect(WebAddress.isLoopbackHost("project.localhost"))
        #expect(WebAddress("http://project.localhost:8080/assets/app.js") == WebAddress(port: 8080, path: "/assets/app.js"))
        #expect(WebAddress.isLoopbackHost("[::1]"))
        #expect(!WebAddress.isLoopbackHost("project.example.com"))
        #expect(WebAddress("https://localhost:8443") == nil)
        #expect(WebAddress("https://example.com") == nil)
        #expect(WebAddress("http://10.0.0.2:3000") == nil)
        #expect(WebAddress("0") == nil)
    }

    @Test func tokensAreRandomAndCookiesAreHttpOnly() {
        let a = WebTunnelCookie.random()
        #expect(a.value.count == 43)
        #expect(a.value != WebTunnelCookie.random().value)
        #expect(a.httpCookie?.isHTTPOnly == true)
        #expect(a.httpCookie?.domain == "localhost")
    }
}
