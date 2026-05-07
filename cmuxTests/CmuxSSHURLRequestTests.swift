import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CmuxSSHURLRequestTests: XCTestCase {
    deinit {}

    private var supportedScheme: String {
        AuthEnvironment.callbackScheme
    }

    func testParsesSSHURLWithExplicitHostUserPortAndTitle() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "user", value: "alice"),
            URLQueryItem(name: "port", value: "2222"),
            URLQueryItem(name: "title", value: "Dev SSH")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.destination, "alice@dev.example.com")
            XCTAssertEqual(request.port, 2222)
            XCTAssertEqual(request.title, "Dev SSH")
            XCTAssertEqual(request.cliArguments, ["ssh", "--port", "2222", "--name", "Dev SSH", "alice@dev.example.com"])
        case .success(nil):
            XCTFail("Expected SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesStableNightlyAndDevSchemes() throws {
        for scheme in ["cmux", "cmux-nightly", "cmux-dev"] {
            var components = URLComponents()
            components.scheme = scheme
            components.host = "ssh"
            components.queryItems = [
                URLQueryItem(name: "host", value: "dev.example.com")
            ]
            let url = try XCTUnwrap(components.url)

            switch CmuxSSHURLRequest.parse(url) {
            case .success(.some(let request)):
                XCTAssertEqual(request.destination, "dev.example.com")
            case .success(nil):
                XCTFail("Expected SSH URL request for \(scheme)")
            case .failure(let error):
                XCTFail("Unexpected parse error for \(scheme): \(error)")
            }
        }
    }

    func testRejectsSSHURLWithPathDestination() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://ssh/alice@dev.example.com"))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.conflictingDestinationParameters):
            break
        default:
            XCTFail("Expected path destination rejection")
        }
    }

    func testIgnoresNonSSHURLs() throws {
        let authURL = try XCTUnwrap(URL(string: "\(supportedScheme)://auth-callback?stack_refresh=abc&stack_access=def"))
        let webURL = try XCTUnwrap(URL(string: "https://example.com/ssh?host=dev.example.com"))

        XCTAssertEqual(try parsedOptional(authURL), nil)
        XCTAssertEqual(try parsedOptional(webURL), nil)
    }

    func testRejectsMissingDestination() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://ssh?title=Missing"))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.missingDestination):
            break
        default:
            XCTFail("Expected missing destination rejection")
        }
    }

    func testRejectsHiddenControlCharacters() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com\nbad")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.destinationContainsUnsafeCharacters):
            break
        default:
            XCTFail("Expected destination control character rejection")
        }
    }

    func testTrimsWhitespaceAroundStructuredHost() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "\ndev.example.com")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.destination, "dev.example.com")
        case .success(nil):
            XCTFail("Expected SSH URL request")
        case .failure(let error):
            XCTFail("Whitespace around structured host should be trimmed, saw \(error)")
        }
    }

    func testRejectsDashPrefixedDestination() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "-oProxyCommand=bad")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.destinationStartsWithDash):
            break
        default:
            XCTFail("Expected dash-prefixed destination rejection")
        }
    }

    func testRejectsUnicodeFormatCharacters() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "safe\u{202E}bad.example.com")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.destinationContainsUnsafeCharacters):
            break
        default:
            XCTFail("Expected Unicode format character rejection")
        }
    }

    func testRejectsUnicodeSeparatorsInTitle() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "title", value: "safe\u{2028}hidden")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.titleContainsUnsafeCharacters):
            break
        default:
            XCTFail("Expected title separator character rejection")
        }
    }

    func testRejectsUnsupportedCommandParameter() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "command", value: "whoami")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.unsupportedParameter("command")):
            break
        default:
            XCTFail("Expected unsupported command parameter rejection")
        }
    }

    func testRejectsOpaqueDestinationParameter() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "destination", value: "alice@dev.example.com")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.unsupportedParameter("destination")):
            break
        default:
            XCTFail("Expected opaque destination parameter rejection")
        }
    }

    func testRejectsDuplicateParameters() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "host", value: "prod.example.com")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.duplicateParameter("host")):
            break
        default:
            XCTFail("Expected duplicate host parameter rejection")
        }
    }

    func testRejectsUnsafeUser() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "user", value: "alice:bad")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.destinationContainsUnsafeCharacters):
            break
        default:
            XCTFail("Expected unsafe user rejection")
        }
    }

    private func parsedOptional(_ url: URL) throws -> CmuxSSHURLRequest? {
        switch CmuxSSHURLRequest.parse(url) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }
}
