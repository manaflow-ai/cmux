import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The byte-level contract with the cmux-tui hub's SOCKS5 subset: CONNECT to a
/// literal IP with no authentication, and a reply whose bound address must be
/// drained before the tunneled bytes begin.
@Suite
struct SocksV5ClientTests {
    @Test("the greeting offers exactly the no-authentication method")
    func greeting() {
        #expect(SocksV5Client.greeting == [0x05, 0x01, 0x00])
        #expect(throws: Never.self) { try SocksV5Client.checkMethodSelection([0x05, 0x00]) }
    }

    @Test("a server that picks another method or version is refused")
    func methodSelectionRejections() {
        #expect(throws: SocksV5Client.ClientError.methodRejected(0xFF)) {
            try SocksV5Client.checkMethodSelection([0x05, 0xFF])
        }
        #expect(throws: SocksV5Client.ClientError.serverVersion(0x04)) {
            try SocksV5Client.checkMethodSelection([0x04, 0x00])
        }
        #expect(throws: SocksV5Client.ClientError.malformedReply) {
            try SocksV5Client.checkMethodSelection([0x05])
        }
    }

    @Test("CONNECT encodes an IPv4 target with a big-endian port")
    func connectIPv4() throws {
        let request = try SocksV5Client.connectRequest(host: "10.16.179.2", port: 3000)
        #expect(request == [0x05, 0x01, 0x00, 0x01, 10, 16, 179, 2, 0x0B, 0xB8])
    }

    @Test("CONNECT encodes an IPv6 target as 16 raw bytes")
    func connectIPv6() throws {
        let request = try SocksV5Client.connectRequest(host: "fd60:1e5e:6720::3", port: 22)
        #expect(request.prefix(4) == [0x05, 0x01, 0x00, 0x04])
        #expect(request.count == 4 + 16 + 2)
        #expect(request[4...5] == [0xFD, 0x60])
        #expect(request.suffix(2) == [0x00, 0x16])
    }

    @Test("a hostname is refused before it reaches the hub, which only routes literal addresses")
    func connectRefusesHostnames() {
        #expect(throws: SocksV5Client.ClientError.unsupportedHost("vm-1.internal")) {
            try SocksV5Client.connectRequest(host: "vm-1.internal", port: 80)
        }
        #expect(throws: SocksV5Client.ClientError.unsupportedHost("10.0.0.1:0")) {
            try SocksV5Client.connectRequest(host: "10.0.0.1", port: 0)
        }
    }

    @Test("the reply trailer length follows the bound address type")
    func replyTrailers() throws {
        #expect(try SocksV5Client.replyTrailerLength(header: [0x05, 0x00, 0x00, 0x01]) == 6)
        #expect(try SocksV5Client.replyTrailerLength(header: [0x05, 0x00, 0x00, 0x04]) == 18)
        #expect(try SocksV5Client.replyTrailerLength(header: [0x05, 0x00, 0x00, 0x03]) == nil)
        #expect(SocksV5Client.domainReplyTrailerLength(lengthByte: 9) == 11)
        #expect(throws: SocksV5Client.ClientError.malformedReply) {
            try SocksV5Client.replyTrailerLength(header: [0x05, 0x00, 0x00, 0x09])
        }
    }

    @Test("a failure reply names the RFC 1928 reason the pane shows")
    func replyFailures() {
        #expect(throws: Never.self) { try SocksV5Client.checkReply([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]) }
        #expect(throws: SocksV5Client.ClientError.connectFailed(code: 0x05)) {
            try SocksV5Client.checkReply([0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        }
        #expect(throws: SocksV5Client.ClientError.malformedReply, "a nonzero reserved byte is not a SOCKS5 reply") {
            try SocksV5Client.checkReply([0x05, 0x00, 0x7F, 0x01, 0, 0, 0, 0, 0, 0])
        }
        #expect(SocksV5Client.ClientError.connectFailed(code: 0x05).errorDescription?.contains("connection refused") == true)
        #expect(SocksV5Client.ClientError.connectFailed(code: 0x02).errorDescription?.contains("not allowed") == true)
    }
}
