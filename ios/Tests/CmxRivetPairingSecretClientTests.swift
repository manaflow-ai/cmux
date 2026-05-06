import Foundation
import XCTest
@testable import cmux_ios

final class CmxRivetPairingSecretClientTests: XCTestCase {
    override func tearDown() {
        CmxRivetPairingURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchSecretUsesStackHeadersAndValidatesResponse() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CmxRivetPairingURLProtocol.self]
        let client = CmxRivetPairingSecretClient(urlSession: URLSession(configuration: configuration))
        CmxRivetPairingURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.absoluteString, "https://rivet.example.test/cmux/pairings/pairing-1/secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Stack-Refresh-Token"), "refresh")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Stack-Project-ID"), "stack-project")
            let data = Data(
                """
                {
                  "pairing_id": "pairing-1",
                  "pairing_secret": "shared-secret-from-rivet",
                  "expires_at_unix": 4000000000
                }
                """.utf8
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        let secret = try await client.fetchSecret(
            for: .rivetStack(
                pairingID: "pairing-1",
                rivetEndpoint: "https://rivet.example.test/cmux",
                stackProjectID: "stack-project",
                expiresAtUnix: 4000000000
            ),
            stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"),
            now: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(secret.pairingID, "pairing-1")
        XCTAssertEqual(secret.secret, "shared-secret-from-rivet")
        XCTAssertFalse(String(describing: secret).contains("shared-secret-from-rivet"))
    }

    func testFetchSecretRejectsMismatchedPairingID() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CmxRivetPairingURLProtocol.self]
        let client = CmxRivetPairingSecretClient(urlSession: URLSession(configuration: configuration))
        CmxRivetPairingURLProtocol.handler = { request in
            let data = Data(
                """
                {
                  "pairing_id": "other-pairing",
                  "pairing_secret": "shared-secret-from-rivet",
                  "expires_at_unix": 4000000000
                }
                """.utf8
            )
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }

        await XCTAssertThrowsErrorAsync(
            try await client.fetchSecret(
                for: .rivetStack(
                    pairingID: "pairing-1",
                    rivetEndpoint: "https://rivet.example.test/cmux",
                    stackProjectID: "stack-project",
                    expiresAtUnix: 4000000000
                ),
                stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"),
                now: Date(timeIntervalSince1970: 20)
            )
        ) { error in
            XCTAssertEqual(error as? CmxRivetPairingSecretError, .pairingIDMismatch)
        }
    }

    func testFetchSecretRejectsHTTPError() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CmxRivetPairingURLProtocol.self]
        let client = CmxRivetPairingSecretClient(urlSession: URLSession(configuration: configuration))
        CmxRivetPairingURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }

        await XCTAssertThrowsErrorAsync(
            try await client.fetchSecret(
                for: .rivetStack(
                    pairingID: "pairing-1",
                    rivetEndpoint: "https://rivet.example.test/cmux",
                    stackProjectID: "stack-project",
                    expiresAtUnix: 4000000000
                ),
                stackSession: CmxStackAuthSession(refreshToken: "refresh", accessToken: "access"),
                now: Date(timeIntervalSince1970: 20)
            )
        ) { error in
            XCTAssertEqual(error as? CmxRivetPairingSecretError, .badStatus(401))
        }
    }
}

private final class CmxRivetPairingURLProtocol: URLProtocol {
    private static let handlerStore = CmxRivetPairingURLProtocolHandlerStore()

    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get { handlerStore.handler }
        set { handlerStore.handler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: CmxRivetPairingURLProtocolError.missingHandler)
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

private final class CmxRivetPairingURLProtocolHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedHandler
        }
        set {
            lock.lock()
            storedHandler = newValue
            lock.unlock()
        }
    }
}

private enum CmxRivetPairingURLProtocolError: Error {
    case missingHandler
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown.", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
