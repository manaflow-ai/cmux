import Foundation
import Testing
@testable import cmux

@Suite struct HTTPRequestParserTests {
    @Test func parseGetWithHeaders() throws {
        let raw =
            "GET /v1/surfaces?x=1 HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "Authorization: Bearer abc\r\n" +
            "\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        let outcome = try parser.next()
        guard case let .complete(req) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(req.method == "GET")
        #expect(req.path == "/v1/surfaces")
        #expect(req.query["x"] == "1")
        #expect(req.header("host") == "127.0.0.1:9778")
        #expect(req.header("Authorization") == "Bearer abc")
        #expect(req.body.isEmpty)
    }

    @Test func parsePostWithBody() throws {
        let body = "{\"type\":\"text\",\"text\":\"hi\"}"
        let raw =
            "POST /v1/surfaces/surface:1/input HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "\r\n" + body
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        let outcome = try parser.next()
        guard case let .complete(req) = outcome else {
            Issue.record("expected complete, got \(outcome)")
            return
        }
        #expect(req.method == "POST")
        #expect(req.path == "/v1/surfaces/surface:1/input")
        #expect(String(data: req.body, encoding: .utf8) == body)
    }

    @Test func percentEncodedQueryDecoded() throws {
        let raw =
            "GET /v1/surfaces?name=hello%20world&empty= HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        guard case let .complete(req) = try parser.next() else {
            Issue.record("expected complete")
            return
        }
        #expect(req.query["name"] == "hello world")
        #expect(req.query["empty"] == "")
    }

    @Test func malformedRequestLineRejected() throws {
        let raw = "NOT-A-REQUEST\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        #expect(throws: HTTPParseError.self) { try parser.next() }
    }

    @Test func oversizedHeadersRejected() throws {
        let huge = String(repeating: "X", count: 32 * 1024)
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1:9778\r\nX-Big: \(huge)\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 8 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        #expect(throws: HTTPParseError.self) { try parser.next() }
    }

    @Test func contentLengthExceedingCapRejectedUpFront() throws {
        // No body bytes sent — parser must reject from Content-Length alone,
        // not hang waiting for them.
        let raw =
            "POST /x HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "Content-Length: 999999999\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        do {
            _ = try parser.next()
            Issue.record("expected throw")
        } catch let error as HTTPParseError {
            #expect(error == .bodyTooLarge)
        }
    }

    @Test func negativeContentLengthRejected() throws {
        let raw =
            "POST /x HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "Content-Length: -1\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        do {
            _ = try parser.next()
            Issue.record("expected throw")
        } catch let error as HTTPParseError {
            #expect(error == .contentLengthInvalid)
        }
    }

    @Test func nonNumericContentLengthRejected() throws {
        let raw =
            "POST /x HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "Content-Length: notanumber\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        do {
            _ = try parser.next()
            Issue.record("expected throw")
        } catch let error as HTTPParseError {
            #expect(error == .contentLengthInvalid)
        }
    }

    @Test func missingHostOnHTTP11Rejected() throws {
        let raw = "GET / HTTP/1.1\r\nAccept: */*\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        do {
            _ = try parser.next()
            Issue.record("expected throw")
        } catch let error as HTTPParseError {
            #expect(error == .missingHost)
        }
    }

    @Test func transferEncodingRejected() throws {
        let raw =
            "POST /x HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "Transfer-Encoding: chunked\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        do {
            _ = try parser.next()
            Issue.record("expected throw")
        } catch let error as HTTPParseError {
            #expect(error == .transferEncodingUnsupported)
        }
    }

    @Test func incompleteRequestReturnsNeed() throws {
        let raw = "GET / HTTP/1.1\r\nHost: 127.0.0.1:9778\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        #expect(try parser.next() == .need)
    }

    @Test func partialBodyReturnsNeedThenCompletesOnFeed() throws {
        let body = "abcdef"
        let header =
            "POST /x HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "Content-Length: \(body.utf8.count)\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(header.utf8))
        parser.feed(Data("abc".utf8))
        #expect(try parser.next() == .need)
        parser.feed(Data("def".utf8))
        guard case let .complete(req) = try parser.next() else {
            Issue.record("expected complete after full body")
            return
        }
        #expect(String(data: req.body, encoding: .utf8) == body)
    }

    @Test func headerNamesLowercasedForCaseInsensitiveLookup() throws {
        let raw =
            "GET / HTTP/1.1\r\n" +
            "Host: 127.0.0.1:9778\r\n" +
            "X-Custom: ABC\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        guard case let .complete(req) = try parser.next() else {
            Issue.record("expected complete")
            return
        }
        #expect(req.header("X-Custom") == "ABC")
        #expect(req.header("x-custom") == "ABC")
    }

    @Test func pipelinedRequestsParsedSequentially() throws {
        let raw =
            "GET /a HTTP/1.1\r\nHost: 127.0.0.1:9778\r\n\r\n" +
            "GET /b HTTP/1.1\r\nHost: 127.0.0.1:9778\r\n\r\n"
        var parser = HTTPRequestParser(maxHeaderBytes: 16 * 1024, maxBodyBytes: 1 << 20)
        parser.feed(Data(raw.utf8))
        guard case let .complete(first) = try parser.next() else {
            Issue.record("expected first complete")
            return
        }
        #expect(first.path == "/a")
        guard case let .complete(second) = try parser.next() else {
            Issue.record("expected second complete")
            return
        }
        #expect(second.path == "/b")
        #expect(try parser.next() == .need)
    }
}
