import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Destination and parameter validation
extension CmuxSSHURLRequestTests {
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

    func testUsesNameWhenTitleIsBlank() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "title", value: " "),
            URLQueryItem(name: "name", value: "Dev SSH")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.title, "Dev SSH")
            XCTAssertEqual(request.cliArguments, ["ssh", "--name", "Dev SSH", "dev.example.com"])
        case .success(nil):
            XCTFail("Expected SSH URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testRejectsConflictingTitleAliases() throws {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "title", value: "Title"),
            URLQueryItem(name: "name", value: "Name")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.conflictingTitleParameters):
            break
        default:
            XCTFail("Expected conflicting title parameter rejection")
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

    func testRejectsIdentityParameterFromExternalLinks() throws {
        let url = try XCTUnwrap(sshURL(queryItems: [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "identity", value: "~/.ssh/id_ed25519")
        ]))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.unsupportedParameter("identity")):
            break
        default:
            XCTFail("Expected identity parameter rejection")
        }
    }

    func testRejectsRawSSHOptionParameterFromExternalLinks() throws {
        let cases = [
            "HostName=evil.example.com",
            "ProxyJump=evil.example.com",
            "ProxyCommand=/bin/sh -c id",
            "SendEnv=*",
            "ControlMaster=auto",
            "StrictHostKeyChecking = no",
            "UserKnownHostsFile=/tmp/link-known-hosts"
        ]

        for option in cases {
            let url = try XCTUnwrap(sshURL(queryItems: [
                URLQueryItem(name: "host", value: "dev.example.com"),
                URLQueryItem(name: "ssh-option", value: option)
            ]))
            switch CmuxSSHURLRequest.parse(url) {
            case .failure(.unsupportedParameter("ssh-option")):
                break
            default:
                XCTFail("Expected raw ssh-option rejection for \(option)")
            }
        }
    }

    func testParsesAllowedHostKeyPolicies() throws {
        let cases = [
            ("accept-new", "StrictHostKeyChecking=accept-new"),
            ("ask", "StrictHostKeyChecking=ask"),
            ("strict", "StrictHostKeyChecking=yes"),
            ("yes", "StrictHostKeyChecking=yes")
        ]

        for (value, option) in cases {
            let url = try XCTUnwrap(sshURL(queryItems: [
                URLQueryItem(name: "host", value: "dev.example.com"),
                URLQueryItem(name: "host-key-policy", value: value)
            ]))
            switch CmuxSSHURLRequest.parse(url) {
            case .success(.some(let request)):
                XCTAssertEqual(request.sshOptions, [option])
            case .success(nil):
                XCTFail("Expected SSH URL request")
            case .failure(let error):
                XCTFail("Unexpected parse error for \(value): \(error)")
            }
        }
    }

    func testRejectsHostKeyPolicyThatDisablesChecking() throws {
        for value in ["no", "off", "false", "0"] {
            let url = try XCTUnwrap(sshURL(queryItems: [
                URLQueryItem(name: "host", value: "dev.example.com"),
                URLQueryItem(name: "host-key-policy", value: value)
            ]))
            switch CmuxSSHURLRequest.parse(url) {
            case .failure(.invalidHostKeyPolicy("host-key-policy")):
                break
            default:
                XCTFail("Expected host-key-policy rejection for \(value)")
            }
        }
    }

    func testRejectsInvalidStructuredIntegerKnobs() throws {
        let cases = [
            ("connect-timeout", "0"),
            ("connect-timeout", "601"),
            ("server-alive-interval", "0"),
            ("server-alive-interval", "3601"),
            ("server-alive-count-max", "0"),
            ("server-alive-count-max", "101"),
            ("server-alive-count-max", "1\n2"),
            ("server-alive-count-max", "1.5")
        ]

        for (parameter, value) in cases {
            let url = try XCTUnwrap(sshURL(queryItems: [
                URLQueryItem(name: "host", value: "dev.example.com"),
                URLQueryItem(name: parameter, value: value)
            ]))
            switch CmuxSSHURLRequest.parse(url) {
            case .failure(.invalidIntegerParameter(parameter)):
                break
            default:
                XCTFail("Expected invalid integer rejection for \(parameter)=\(value)")
            }
        }
    }

    func testRejectsInvalidNoFocusValue() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://ssh?host=dev.example.com&no-focus=maybe"))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.invalidBooleanParameter("no-focus")):
            break
        default:
            XCTFail("Expected invalid no-focus value rejection")
        }
    }

    func testRejectsDuplicateStructuredKnobs() throws {
        let url = try XCTUnwrap(sshURL(queryItems: [
            URLQueryItem(name: "host", value: "dev.example.com"),
            URLQueryItem(name: "connect-timeout", value: "10"),
            URLQueryItem(name: "connect-timeout", value: "20")
        ]))

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.duplicateParameter("connect-timeout")):
            break
        default:
            XCTFail("Expected duplicate connect-timeout rejection")
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
            URLQueryItem(name: "user", value: "alice;bad")
        ]
        let url = try XCTUnwrap(components.url)

        switch CmuxSSHURLRequest.parse(url) {
        case .failure(.destinationContainsUnsafeCharacters):
            break
        default:
            XCTFail("Expected unsafe user rejection")
        }
    }

}
