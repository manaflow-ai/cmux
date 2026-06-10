import XCTest
import AppKit
import Carbon.HIToolbox
import Darwin
import PDFKit
import Testing
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
@testable import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class TerminalDefaultFileOpenRequestTests: XCTestCase {
    func testBuildsQuotedLaunchInputForTerminalCommandFile() throws {
        let contentType = DefaultTerminalRegistration.contentType(forIdentifier: "com.apple.terminal.shell-script")
        let url = URL(fileURLWithPath: "/tmp/cmux default's/Run Me.command")

        let request = try XCTUnwrap(TerminalDefaultFileOpenRequest(fileURL: url, contentType: contentType))

        XCTAssertEqual(request.workingDirectory, "/tmp/cmux default's")
        XCTAssertEqual(request.initialInput, "'/tmp/cmux default'\\''s/Run Me.command'\n")
    }

    func testIgnoresPlainTextFiles() {
        let url = URL(fileURLWithPath: "/tmp/notes.txt")

        XCTAssertNil(TerminalDefaultFileOpenRequest(fileURL: url, contentType: .plainText))
    }

    func testBuildsLaunchInputForExtensionlessUnixExecutable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-default-executable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let executable = directory.appendingPathComponent("runme", isDirectory: false)
        try "#!/bin/sh\necho cmux\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let request = try XCTUnwrap(TerminalDefaultFileOpenRequest(fileURL: executable))

        XCTAssertEqual(request.workingDirectory, directory.path)
        XCTAssertEqual(request.initialInput, "'\(executable.path)'\n")
    }

    func testIgnoresDirectoriesWithTerminalScriptExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-terminal-default-directory-\(UUID().uuidString).command", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        XCTAssertNil(TerminalDefaultFileOpenRequest(fileURL: directory, contentType: .directory))
    }
}


