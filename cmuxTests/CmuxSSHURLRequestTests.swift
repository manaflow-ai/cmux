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

    func testParsesPromptURLWithTextTitleAndNoFocus() throws {
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: "Review this branch without running tests yet."),
            URLQueryItem(name: "title", value: "Review prompt"),
            URLQueryItem(name: "no-focus", value: "true")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.kind, .prompt)
            XCTAssertEqual(request.text, "Review this branch without running tests yet.")
            XCTAssertEqual(request.title, "Review prompt")
            XCTAssertNil(request.name)
            XCTAssertTrue(request.noFocus)
            XCTAssertEqual(request.pasteText, request.text)
        case .success(nil):
            XCTFail("Expected prompt URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testPreservesPromptURLTextWhitespace() throws {
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: "  indented prompt  ")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.text, "  indented prompt  ")
            XCTAssertEqual(request.pasteText, "  indented prompt  ")
        case .success(nil):
            XCTFail("Expected prompt URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesPromptURLPercentEncodedSpaces() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://prompt?text=Review%20this%20branch"))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.text, "Review this branch")
        case .success(nil):
            XCTFail("Expected prompt URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesPromptURLPreservesURLComponentsLiteralPlus() throws {
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: "C++ tips")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.text, "C++ tips")
        case .success(nil):
            XCTFail("Expected prompt URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesPromptURLLiteralPlusCommasAndColons() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://prompt?text=C%2B%2B,%20Rust:%20compare"))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.text, "C++, Rust: compare")
        case .success(nil):
            XCTFail("Expected prompt URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesRulesURLWithName() throws {
        let url = try XCTUnwrap(textURL(host: "rules", queryItems: [
            URLQueryItem(name: "name", value: "freestyle"),
            URLQueryItem(name: "text", value: "Prefer small PRs.")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.kind, .rules)
            XCTAssertEqual(request.name, "freestyle")
            XCTAssertEqual(request.text, "Prefer small PRs.")
            XCTAssertEqual(request.pasteText, "Prefer small PRs.")
        case .success(nil):
            XCTFail("Expected rules URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testParsesSingularRuleAlias() throws {
        let url = try XCTUnwrap(textURL(host: "rule", queryItems: [
            URLQueryItem(name: "text", value: "Prefer small PRs.")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.kind, .rules)
        case .success(nil):
            XCTFail("Expected rules URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testRejectsTextURLDuplicateParameters() throws {
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: "one"),
            URLQueryItem(name: "text", value: "two")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .failure(.duplicateParameter("text")):
            break
        default:
            XCTFail("Expected duplicate text parameter rejection")
        }
    }

    func testRejectsTextURLUnsupportedParameter() throws {
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: "hello"),
            URLQueryItem(name: "command", value: "rm -rf /")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .failure(.unsupportedParameter("command")):
            break
        default:
            XCTFail("Expected unsupported command parameter rejection")
        }
    }

    func testRejectsTextURLUnsafeFormattingCharacter() throws {
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: "hello\u{202E}world")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .failure(.textContainsUnsafeCharacters):
            break
        default:
            XCTFail("Expected unsafe text character rejection")
        }
    }

    func testRejectsTextURLControlCharacters() throws {
        for value in ["hello\nworld", "hello\rworld", "hello\tworld", "hello\u{0000}world", "hello\u{001B}world"] {
            let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
                URLQueryItem(name: "text", value: value)
            ]))

            switch CmuxTextURLRequest.parse(url) {
            case .failure(.textContainsUnsafeCharacters):
                break
            default:
                XCTFail("Expected control character rejection for \(value.debugDescription)")
            }
        }
    }

    func testRejectsTextURLWhitespaceOnlyText() throws {
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: "   ")
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .failure(.missingText):
            break
        default:
            XCTFail("Expected whitespace-only text rejection")
        }
    }

    func testAcceptsTextURLAtMaxLength() throws {
        let text = String(repeating: "a", count: CmuxTextURLRequest.maxTextLength)
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: text)
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .success(.some(let request)):
            XCTAssertEqual(request.text.count, CmuxTextURLRequest.maxTextLength)
        case .success(nil):
            XCTFail("Expected prompt URL request")
        case .failure(let error):
            XCTFail("Unexpected parse error: \(error)")
        }
    }

    func testRejectsTextURLExceedingMaxLength() throws {
        let text = String(repeating: "a", count: CmuxTextURLRequest.maxTextLength + 1)
        let url = try XCTUnwrap(textURL(host: "prompt", queryItems: [
            URLQueryItem(name: "text", value: text)
        ]))

        switch CmuxTextURLRequest.parse(url) {
        case .failure(.textTooLong(maxLength: CmuxTextURLRequest.maxTextLength)):
            break
        default:
            XCTFail("Expected text length rejection")
        }
    }

    func testRejectsTextURLPathPayload() throws {
        let url = try XCTUnwrap(URL(string: "\(supportedScheme)://prompt/run?text=hello"))

        switch CmuxTextURLRequest.parse(url) {
        case .failure(.unsupportedParameter("path")):
            break
        default:
            XCTFail("Expected path payload rejection")
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

    private func sshURL(queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = "ssh"
        components.queryItems = queryItems
        return components.url
    }

    private func textURL(host: String, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = supportedScheme
        components.host = host
        components.queryItems = queryItems
        return components.url
    }
}

final class CmuxNavigationURLRequestTests: XCTestCase {
    private let supportedScheme = "cmux-test"
    private let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let paneId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let surfaceId = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!

    func testParsesWorkspacePaneAndSurfaceLinks() throws {
        let workspaceURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)"))
        let paneURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)/pane/\(paneId.uuidString)"))
        let surfaceURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)"))
        let panelAliasURL = try XCTUnwrap(URL(string: "\(supportedScheme)://workspace/\(workspaceId.uuidString)/panel/\(surfaceId.uuidString)"))

        XCTAssertEqual(try parsedTarget(workspaceURL), .workspace(workspaceId))
        XCTAssertEqual(try parsedTarget(paneURL), .pane(workspaceId: workspaceId, paneId: paneId))
        XCTAssertEqual(try parsedTarget(surfaceURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
        XCTAssertEqual(try parsedTarget(panelAliasURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    func testGeneratedLinksRoundTrip() throws {
        let workspaceURL = try XCTUnwrap(URL(string: CmuxNavigationURLRequest.workspaceLink(workspaceId: workspaceId, scheme: supportedScheme)))
        let paneURL = try XCTUnwrap(URL(string: CmuxNavigationURLRequest.paneLink(workspaceId: workspaceId, paneId: paneId, scheme: supportedScheme)))
        let surfaceURL = try XCTUnwrap(URL(string: CmuxNavigationURLRequest.surfaceLink(workspaceId: workspaceId, surfaceId: surfaceId, scheme: supportedScheme)))

        XCTAssertEqual(try parsedTarget(workspaceURL), .workspace(workspaceId))
        XCTAssertEqual(try parsedTarget(paneURL), .pane(workspaceId: workspaceId, paneId: paneId))
        XCTAssertEqual(try parsedTarget(surfaceURL), .surface(workspaceId: workspaceId, surfaceId: surfaceId))
    }

    func testIgnoresOtherCmuxRoutesAndInactiveSchemes() throws {
        let sshURL = try XCTUnwrap(URL(string: "\(supportedScheme)://ssh?host=dev.example.com"))
        let authURL = try XCTUnwrap(URL(string: "\(supportedScheme)://auth-callback?stack_refresh=abc"))
        let inactiveURL = try XCTUnwrap(URL(string: "cmux-other://workspace/\(workspaceId.uuidString)"))

        XCTAssertNil(try parsedOptional(sshURL))
        XCTAssertNil(try parsedOptional(authURL))
        XCTAssertNil(try parsedOptional(inactiveURL))
    }

    func testRejectsQueryFragmentAuthorityAndExtraPathComponents() throws {
        let cases = [
            "\(supportedScheme)://workspace/\(workspaceId.uuidString)?command=id",
            "\(supportedScheme)://workspace/\(workspaceId.uuidString)#fragment",
            "\(supportedScheme)://user@workspace/\(workspaceId.uuidString)",
            "\(supportedScheme)://workspace:123/\(workspaceId.uuidString)",
            "\(supportedScheme)://workspace/\(workspaceId.uuidString)/surface/\(surfaceId.uuidString)/run"
        ]

        for rawURL in cases {
            let url = try XCTUnwrap(URL(string: rawURL))
            switch CmuxNavigationURLRequest.parse(url, supportedSchemes: [supportedScheme]) {
            case .failure(.unsupportedURLShape):
                break
            default:
                XCTFail("Expected unsupported URL shape rejection for \(rawURL)")
            }
        }
    }

    func testRejectsNonUUIDIdentifiersAndRelativeRefs() throws {
        let cases = [
            ("\(supportedScheme)://workspace/workspace:1", "workspace"),
            ("\(supportedScheme)://workspace/\(workspaceId.uuidString)/pane/pane:1", "pane"),
            ("\(supportedScheme)://workspace/\(workspaceId.uuidString)/surface/surface:1", "surface")
        ]

        for (rawURL, component) in cases {
            let url = try XCTUnwrap(URL(string: rawURL))
            switch CmuxNavigationURLRequest.parse(url, supportedSchemes: [supportedScheme]) {
            case .failure(.invalidIdentifier(component)):
                break
            default:
                XCTFail("Expected invalid \(component) rejection for \(rawURL)")
            }
        }
    }

    private func parsedOptional(_ url: URL) throws -> CmuxNavigationURLRequest? {
        switch CmuxNavigationURLRequest.parse(url, supportedSchemes: [supportedScheme]) {
        case .success(let request):
            return request
        case .failure(let error):
            throw error
        }
    }

    private func parsedTarget(_ url: URL) throws -> CmuxNavigationURLRequest.Target {
        let request = try XCTUnwrap(parsedOptional(url))
        return request.target
    }
}
