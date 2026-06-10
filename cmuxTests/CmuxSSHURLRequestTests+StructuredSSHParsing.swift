import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Structured cmux SSH link parsing
extension CmuxSSHURLRequestTests {
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

    func testParsesSSHURLWithAllowedConnectionKnobs() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "user", value: "alice"),
            URLQueryItem(name: "port", value: "2222"),
            URLQueryItem(name: "title", value: "Dev SSH"),
            URLQueryItem(name: "connect-timeout", value: "15"),
            URLQueryItem(name: "server-alive-interval", value: "20"),
            URLQueryItem(name: "server-alive-count-max", value: "4"),
            URLQueryItem(name: "host-key-policy", value: "accept-new"),
            URLQueryItem(name: "no-focus", value: "true")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.destination, "alice@dev.example.com")
            XCTAssertEqual(request.port, 2222)
            XCTAssertEqual(request.title, "Dev SSH")
            XCTAssertEqual(request.sshOptions, [
                "ConnectTimeout=15",
                "ServerAliveInterval=20",
                "ServerAliveCountMax=4",
                "StrictHostKeyChecking=accept-new"
            ])
            XCTAssertTrue(request.noFocus)
            XCTAssertEqual(request.cliArguments, [
                "ssh",
                "--port", "2222",
                "--name", "Dev SSH",
                "--ssh-option", "ConnectTimeout=15",
                "--ssh-option", "ServerAliveInterval=20",
                "--ssh-option", "ServerAliveCountMax=4",
                "--ssh-option", "StrictHostKeyChecking=accept-new",
                "--no-focus",
                "alice@dev.example.com"
            ])
        case .success(nil):
            XCTFail("Expected SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesSSHURLWithFreestyleUserDelimiters() throws {
        let cases = [
            "workspace123,session-token_ABC.2yi9kzY-dysFsVBKh",
            "workspace123:session-token_ABC.2yi9kzY-dysFsVBKh"
        ]

        for user in cases {
            let host = "workspace123.vm-ssh.freestyle.sh"
            let url = try XCTUnwrap(sshURL(queryItems: [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "user", value: user)
            ]))

            switch CmuxSSHURLRequest.parse(url) {
            case .success(.some(let request)):
                XCTAssertEqual(request.destination, "\(user)@\(host)")
                XCTAssertEqual(request.cliArguments, ["ssh", "\(user)@\(host)"])
            case .success(nil):
                XCTFail("Expected SSH URL request")
            case .failure(let error):
                XCTFail("Unexpected parse error for \(user): \(error)")
            }
        }
    }

    func testRejectsStructuredHostPortInHostParameter() throws {
        let url = try XCTUnwrap(sshURL(queryItems: [
            URLQueryItem(name: "host", value: "dev.example.com:2222")
        ]))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.destinationContainsUnsafeCharacters):
            break
        default:
            XCTFail("Expected host:port rejection in structured host parameter")
        }
    }

    func testCommandPreviewIncludesSocketPathWhenProvided() throws {
        let url = try XCTUnwrap(sshURL(queryItems: [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "title", value: "Dev SSH")
        ]))

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(
                request.cliPreview(socketPath: "/tmp/cmux-urlcmd.sock"),
                "cmux --socket /tmp/cmux-urlcmd.sock ssh --name \"Dev SSH\" dev.example.com"
            )
        case .success(nil):
            XCTFail("Expected SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesNoFocusFlagWithoutValue() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://ssh?host=dev.example.com&no-focus"))

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertTrue(request.noFocus)
            XCTAssertEqual(request.cliArguments, ["ssh", "--no-focus", "dev.example.com"])
        case .success(nil):
            XCTFail("Expected SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesNoFocusFalseAsDisabled() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://ssh?host=dev.example.com&no-focus=false"))

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertFalse(request.noFocus)
            XCTAssertEqual(request.cliArguments, ["ssh", "dev.example.com"])
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

            switch CmuxSSHURLRequest.parse(url, supportedSchemes: CmuxSSHURLRequest.supportedSchemes) {
            case .success(.some(let request)):
                XCTAssertEqual(request.destination, "dev.example.com")
            case .success(nil):
                XCTFail("Expected SSH URL request for \(scheme)")
            case .failure(let error):
                XCTFail("Unexpected parse error for \(scheme): \(error)")
            }
        }
    }

    func testDefaultParserIgnoresOtherProductSchemes() throws {
        let inactiveScheme = try XCTUnwrap(CmuxSSHURLRequest.supportedSchemes.first {
            $0 != supportedScheme.lowercased()
        })
        var components = URLComponents()
        components.scheme = inactiveScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com")
        ]
        let url = try XCTUnwrap(components.url)

        XCTAssertEqual(try parsedOptional(url), nil)
    }

}
