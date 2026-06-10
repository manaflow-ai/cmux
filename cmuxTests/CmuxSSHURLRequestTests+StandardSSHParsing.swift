import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Standard ssh:// URL parsing
extension CmuxSSHURLRequestTests {
    func testParsesStandardSSHURL() throws {
        let url = try XCTUnwrap(URL(string: "ssh://alice@dev.example.com:2222?title=Dev%20SSH"))

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.destination, "alice@dev.example.com")
            XCTAssertEqual(request.port, 2222)
            XCTAssertEqual(request.title, "Dev SSH")
            XCTAssertEqual(request.cliArguments, ["ssh", "--port", "2222", "--name", "Dev SSH", "alice@dev.example.com"])
        case .success(nil):
            XCTFail("Expected standard SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesStandardSSHURLWithIPv6Host() throws {
        let url = try XCTUnwrap(URL(string: "ssh://alice@[2001:db8::1]:2222"))

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.destination, "alice@2001:db8::1")
            XCTAssertEqual(request.port, 2222)
            XCTAssertEqual(request.cliArguments, ["ssh", "--port", "2222", "alice@2001:db8::1"])
        case .success(nil):
            XCTFail("Expected standard SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesStandardSSHURLWithBlankUserAsHostOnly() throws {
        let url = try XCTUnwrap(URL(string: "ssh://%20@dev.example.com"))

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.destination, "dev.example.com")
            XCTAssertEqual(request.cliArguments, ["ssh", "dev.example.com"])
        case .success(nil):
            XCTFail("Expected standard SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testRejectsStandardSSHURLWithPathDestination() throws {
        let url = try XCTUnwrap(URL(string: "ssh://dev.example.com/run"))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.conflictingDestinationParameters):
            break
        default:
            XCTFail("Expected path destination rejection")
        }
    }

    func testRejectsStandardSSHURLWithInvalidPort() throws {
        for rawURL in [
            "ssh://dev.example.com:",
            "ssh://dev.example.com:0",
            "ssh://dev.example.com:65536",
            "ssh://dev.example.com:999999999999999999999999999999"
        ] {
            let url = try XCTUnwrap(URL(string: rawURL))

            switch CmuxSSHURLRequest.parse(url) {
            case .failure(.invalidPort):
                break
            default:
                XCTFail("Expected invalid port rejection for \(rawURL)")
            }
        }
    }

    func testRejectsStandardSSHURLWithEncodedHostWhitespace() throws {
        for rawURL in ["ssh://%20host", "ssh://host%20", "ssh://ho%0Ast"] {
            let url = try XCTUnwrap(URL(string: rawURL))

            switch CmuxSSHURLRequest.parse(url) {
            case .failure(.destinationContainsUnsafeCharacters):
                break
            default:
                XCTFail("Expected unsafe host rejection for \(rawURL)")
            }
        }
    }

    func testRejectsStandardSSHURLWithPassword() throws {
        let url = try XCTUnwrap(URL(string: "ssh://alice:secret@dev.example.com"))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.unsupportedParameter("password")):
            break
        default:
            XCTFail("Expected password rejection")
        }
    }

}
