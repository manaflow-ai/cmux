import XCTest
import Testing
import CmuxControlSocket
import CmuxTerminalCopyMode
import CmuxSocketControl
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import CMUXMobileCore
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalCmdClickPathPunctuationTrimmingTests: XCTestCase {
    func testTrimsTrailingPeriodAfterMarkdownFile() {
        XCTAssertEqual(
            cmuxTrimTerminalPathTrailingPunctuationForTesting(
                "~/ClaudeCode/feature-spec-template.md."
            ),
            "~/ClaudeCode/feature-spec-template.md"
        )
    }

    func testTrimsTrailingCommaInList() {
        XCTAssertEqual(
            cmuxTrimTerminalPathTrailingPunctuationForTesting(
                "/tmp/fixtures/first.txt,"
            ),
            "/tmp/fixtures/first.txt"
        )
    }

    func testTrimsTrailingCloseParenWhenNoBalancedOpenParen() {
        XCTAssertEqual(
            cmuxTrimTerminalPathTrailingPunctuationForTesting(
                "/tmp/fixtures/notes.txt)"
            ),
            "/tmp/fixtures/notes.txt"
        )
    }

    func testPreservesBalancedParensInMiddleOfPath() {
        XCTAssertEqual(
            cmuxTrimTerminalPathTrailingPunctuationForTesting(
                "/tmp/fixtures/report (draft)/notes.txt"
            ),
            "/tmp/fixtures/report (draft)/notes.txt"
        )
    }

    func testStripsMultipleTrailingPunctuationCharacters() {
        XCTAssertEqual(
            cmuxTrimTerminalPathTrailingPunctuationForTesting(
                "/tmp/fixtures/report (draft).md).,!?\""
            ),
            "/tmp/fixtures/report (draft).md"
        )
    }

    func testTrimsTrailingClosingQuote() {
        XCTAssertEqual(
            cmuxTrimTerminalPathTrailingPunctuationForTesting(
                "/tmp/fixtures/notes.txt\""
            ),
            "/tmp/fixtures/notes.txt"
        )
    }

    func testResolveQuicklookFallsBackToStrippedPathWhenLiteralPathIsMissing() {
        let strippedPath = "/tmp/cmux-cmdclick-path.md"

        XCTAssertEqual(
            cmuxResolveQuicklookPathForTesting(
                "\(strippedPath).",
                cwd: "/tmp",
                existingPaths: [strippedPath]
            ),
            strippedPath
        )
    }

    func testResolveQuicklookPrefersLiteralPathThatReallyEndsWithDot() {
        let literalPath = "/tmp/cmux-cmdclick-literal-dot.md."
        let strippedPath = "/tmp/cmux-cmdclick-literal-dot.md"

        XCTAssertEqual(
            cmuxResolveQuicklookPathForTesting(
                literalPath,
                cwd: "/tmp",
                existingPaths: [literalPath, strippedPath]
            ),
            literalPath
        )
    }

    func testResolveQuicklookPrefersLiteralPathThatReallyEndsWithParen() {
        let literalPath = "/tmp/cmux-cmdclick-literal-paren)"
        let strippedPath = "/tmp/cmux-cmdclick-literal-paren"

        XCTAssertEqual(
            cmuxResolveQuicklookPathForTesting(
                literalPath,
                cwd: "/tmp",
                existingPaths: [literalPath, strippedPath]
            ),
            literalPath
        )
    }

    // MARK: - Relative path + trailing punctuation (bug #4569)

    func testResolveQuicklookResolvesRelativeMarkdownPathWithTrailingDot() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/docs/specs/2026-05-22-test.md"

        XCTAssertEqual(
            cmuxResolveQuicklookPathForTesting(
                "docs/specs/2026-05-22-test.md.",
                cwd: cwd,
                existingPaths: [existingFile]
            ),
            existingFile
        )
    }

    func testResolveTerminalOpenURLFilePathResolvesAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"

        XCTAssertEqual(
            cmuxResolveTerminalOpenURLFilePathForTesting(
                "\(existingFile).",
                cwd: "/Users/dev/project",
                existingPaths: [existingFile]
            ),
            existingFile
        )
    }

    func testResolveTerminalOpenURLFilePathResolvesQuotedAbsoluteMarkdownPathWithTrailingDot() {
        let existingFile = "/Users/dev/project/skills/marketing/data/lawrencecchen-tweets.md"

        XCTAssertEqual(
            cmuxResolveTerminalOpenURLFilePathForTesting(
                "\"\(existingFile).\"",
                cwd: "/Users/dev/project",
                existingPaths: [existingFile]
            ),
            existingFile
        )
    }

    func testResolveQuicklookResolvesRelativePathWithTrailingComma() {
        let cwd = "/Users/dev/project"
        let existingFile = "/Users/dev/project/src/main.swift"

        XCTAssertEqual(
            cmuxResolveQuicklookPathForTesting(
                "src/main.swift,",
                cwd: cwd,
                existingPaths: [existingFile]
            ),
            existingFile
        )
    }

    func testResolveQuicklookReturnsNilForRelativePathThatDoesNotExist() {
        XCTAssertNil(
            cmuxResolveQuicklookPathForTesting(
                "docs/nonexistent.md.",
                cwd: "/Users/dev/project",
                existingPaths: []
            )
        )
    }
}

// MARK: - Scheme detection gate for file-path-before-URL resolution (bug #4569)

