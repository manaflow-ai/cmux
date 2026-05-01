import Foundation
import XCTest
@testable import cmux_DEV

final class TerminalDaemonTicketServiceTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testFetchTicketPostsBearerAndDecodesResponse() async throws {
        let session = makeSession()
        let service = TerminalDaemonTicketService(
            endpoint: URL(string: "https://cmux.dev/api/daemon-ticket")!,
            session: session,
            tokenProvider: { "access-token" }
        )

        StubURLProtocol.requestHandler = { [self] request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-token")

            let body = try XCTUnwrap(requestBody(from: request))
            let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            XCTAssertEqual(payload?["server_id"] as? String, "cmux-macmini")
            XCTAssertEqual(payload?["session_id"] as? String, "sess-1")
            XCTAssertEqual(payload?["attachment_id"] as? String, "att-1")

            let responseBody = """
            {
              "ticket": "ticket-123",
              "direct_url": "tls://cmux-macmini:9443",
              "direct_tls_pins": [" sha256:pin-a ", "", "sha256:pin-b"],
              "session_id": "sess-1",
              "attachment_id": "att-1",
              "expires_at": "2026-03-15T23:59:59Z"
            }
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(responseBody.utf8)
            )
        }

        let ticket = try await service.fetchTicket(
            request: TerminalDaemonTicketRequest(
                serverID: "cmux-macmini",
                sessionID: "sess-1",
                attachmentID: "att-1"
            )
        )

        XCTAssertEqual(ticket.ticket, "ticket-123")
        XCTAssertEqual(ticket.directURL.absoluteString, "tls://cmux-macmini:9443")
        XCTAssertEqual(ticket.directTLSPins, ["sha256:pin-a", "sha256:pin-b"])
        XCTAssertEqual(ticket.sessionID, "sess-1")
        XCTAssertEqual(ticket.attachmentID, "att-1")
        XCTAssertEqual(ticket.expiresAt, ISO8601DateFormatter().date(from: "2026-03-15T23:59:59Z"))
    }

    func testFetchTicketSurfacesHTTPErrorBody() async {
        let session = makeSession()
        let service = TerminalDaemonTicketService(
            endpoint: URL(string: "https://cmux.dev/api/daemon-ticket")!,
            session: session,
            tokenProvider: { "access-token" }
        )

        StubURLProtocol.requestHandler = { request in
            let responseBody = #"{"error":"team access required"}"#
            return (
                HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!,
                Data(responseBody.utf8)
            )
        }

        do {
            _ = try await service.fetchTicket(
                request: TerminalDaemonTicketRequest(serverID: "cmux-macmini")
            )
            XCTFail("expected request to fail")
        } catch let error as TerminalDaemonTicketServiceError {
            switch error {
            case .httpError(let statusCode, let message):
                XCTAssertEqual(statusCode, 403)
                XCTAssertEqual(message, "team access required")
            default:
                XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testFetchTicketReusesUnexpiredCachedTicketForSameRequest() async throws {
        let session = makeSession()
        let requestCounter = LockedCounter()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = TerminalDaemonTicketService(
            endpoint: URL(string: "https://cmux.dev/api/daemon-ticket")!,
            session: session,
            tokenProvider: { "access-token" },
            nowProvider: { now },
            refreshLeeway: 30
        )

        StubURLProtocol.requestHandler = { request in
            requestCounter.increment()
            let responseBody = """
            {
              "ticket": "ticket-\(requestCounter.value())",
              "direct_url": "tls://cmux-macmini:9443",
              "direct_tls_pins": [],
              "session_id": "sess-1",
              "attachment_id": "att-1",
              "expires_at": "2023-11-14T22:30:00Z"
            }
            """
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(responseBody.utf8)
            )
        }

        let request = TerminalDaemonTicketRequest(
            serverID: "cmux-macmini",
            teamID: "team-1",
            sessionID: "sess-1",
            attachmentID: "att-1"
        )
        let firstTicket = try await service.fetchTicket(request: request)
        let secondTicket = try await service.fetchTicket(request: request)

        XCTAssertEqual(firstTicket, secondTicket)
        XCTAssertEqual(requestCounter.value(), 1)
    }

    func testFetchTicketRefetchesWhenCachedTicketIsNearExpiry() async throws {
        let session = makeSession()
        let requestCounter = LockedCounter()
        let now = LockedDate(value: Date(timeIntervalSince1970: 1_700_000_000))
        let service = TerminalDaemonTicketService(
            endpoint: URL(string: "https://cmux.dev/api/daemon-ticket")!,
            session: session,
            tokenProvider: { "access-token" },
            nowProvider: { now.value() },
            refreshLeeway: 30
        )

        StubURLProtocol.requestHandler = { request in
            requestCounter.increment()
            let responseBody = switch requestCounter.value() {
            case 1:
                """
                {
                  "ticket": "ticket-1",
                  "direct_url": "tls://cmux-macmini:9443",
                  "direct_tls_pins": [],
                  "session_id": "sess-1",
                  "attachment_id": "att-1",
                  "expires_at": "2023-11-14T22:14:00Z"
                }
                """
            default:
                """
                {
                  "ticket": "ticket-2",
                  "direct_url": "tls://cmux-macmini:9443",
                  "direct_tls_pins": [],
                  "session_id": "sess-1",
                  "attachment_id": "att-1",
                  "expires_at": "2023-11-14T22:30:00Z"
                }
                """
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(responseBody.utf8)
            )
        }

        let request = TerminalDaemonTicketRequest(
            serverID: "cmux-macmini",
            teamID: "team-1",
            sessionID: "sess-1",
            attachmentID: "att-1"
        )
        let firstTicket = try await service.fetchTicket(request: request)
        now.set(Date(timeIntervalSince1970: 1_700_000_830))
        let secondTicket = try await service.fetchTicket(request: request)

        XCTAssertEqual(firstTicket.ticket, "ticket-1")
        XCTAssertEqual(secondTicket.ticket, "ticket-2")
        XCTAssertEqual(requestCounter.value(), 2)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func requestBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        let bufferSize = 1024
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 {
                break
            }
            data.append(buffer, count: count)
        }

        return data.isEmpty ? nil : data
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(value: Date) {
        storage = value
    }

    func set(_ value: Date) {
        lock.lock()
        storage = value
        lock.unlock()
    }

    func value() -> Date {
        lock.lock()
        let snapshot = storage
        lock.unlock()
        return snapshot
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = StubURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
