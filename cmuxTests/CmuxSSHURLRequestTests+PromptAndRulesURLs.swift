import XCTest
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Prompt, rules, and text payload URLs
extension CmuxSSHURLRequestTests {
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

}
