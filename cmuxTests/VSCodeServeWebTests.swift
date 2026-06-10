import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - VS Code Serve Web
final class VSCodeServeWebURLBuilderTests: XCTestCase {
    func testExtractWebUIURLParsesServeWebOutput() {
        let output = """
        *
        * Visual Studio Code Server
        *
        Web UI available at http://127.0.0.1:5555?tkn=test-token
        """

        let url = VSCodeServeWebURLBuilder.extractWebUIURL(from: output)
        XCTAssertEqual(url?.absoluteString, "http://127.0.0.1:5555?tkn=test-token")
    }

    func testOpenFolderURLAppendsFolderQueryWhilePreservingToken() {
        let baseURL = URL(string: "http://127.0.0.1:5555?tkn=test-token")!

        let url = VSCodeServeWebURLBuilder.openFolderURL(
            baseWebUIURL: baseURL,
            directoryPath: "/Users/tester/Projects/cmux"
        )

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "tkn" })?.value, "test-token")
        XCTAssertEqual(components?.queryItems?.first(where: { $0.name == "folder" })?.value, "/Users/tester/Projects/cmux")
    }

    func testOpenFolderURLReplacesExistingFolderQuery() {
        let baseURL = URL(string: "http://127.0.0.1:5555?tkn=test-token&folder=/tmp/old")!

        let url = VSCodeServeWebURLBuilder.openFolderURL(
            baseWebUIURL: baseURL,
            directoryPath: "/Users/tester/New Folder"
        )

        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(
            components?.queryItems?.filter { $0.name == "folder" }.count,
            1
        )
        XCTAssertEqual(
            components?.queryItems?.first(where: { $0.name == "folder" })?.value,
            "/Users/tester/New Folder"
        )
    }
}


final class VSCodeCLILaunchConfigurationBuilderTests: XCTestCase {
    func testLaunchConfigurationPrefersCachedCodeServerOverCodeTunnelWrapper() {
        let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
        let productURL = appURL.appendingPathComponent("Contents/Resources/app/product.json", isDirectory: false)
        let cacheURL = URL(fileURLWithPath: "/Users/tester/.vscode/cli/serve-web", isDirectory: true)
        let lruURL = cacheURL.appendingPathComponent("lru.json", isDirectory: false)
        let codeTunnelPath = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"
        let expectedExecutablePath = "/Users/tester/.vscode/cli/serve-web/server-new/bin/code-server"

        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: appURL,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            baseEnvironment: [
                "ELECTRON_RUN_AS_NODE": "stale",
            ],
            isExecutableAtPath: { $0 == codeTunnelPath || $0 == expectedExecutablePath },
            dataAtURL: { url in
                if url == productURL {
                    return Data(#"{"dataFolderName": ".vscode"}"#.utf8)
                }
                if url == lruURL {
                    return Data(#"["missing","server-new"]"#.utf8)
                }
                return nil
            },
            contentsOfDirectoryAtURL: { _ in
                XCTFail("Expected lru.json to select the cached code-server binary")
                return []
            },
            contentModificationDateAtURL: { _ in nil }
        )

        XCTAssertEqual(configuration?.executableURL.path, expectedExecutablePath)
        XCTAssertEqual(configuration?.argumentsPrefix, [])
        XCTAssertNil(configuration?.environment["ELECTRON_RUN_AS_NODE"])
    }

    func testLaunchConfigurationFallsBackToCodeTunnelBinary() {
        let appURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)
        let expectedExecutablePath = "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code-tunnel"

        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: appURL,
            homeDirectoryURL: URL(fileURLWithPath: "/Users/tester", isDirectory: true),
            baseEnvironment: [:],
            isExecutableAtPath: { $0 == expectedExecutablePath },
            dataAtURL: { _ in nil },
            contentsOfDirectoryAtURL: { _ in [] },
            contentModificationDateAtURL: { _ in nil }
        )

        XCTAssertEqual(configuration?.executableURL.path, expectedExecutablePath)
        XCTAssertEqual(configuration?.argumentsPrefix, ["serve-web"])
        XCTAssertEqual(configuration?.environment["ELECTRON_RUN_AS_NODE"], "1")
    }

    func testLaunchConfigurationMapsNodeEnvironmentVariables() {
        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "NODE_OPTIONS": "--max-old-space-size=4096",
                "NODE_REPL_EXTERNAL_MODULE": "module-name"
            ],
            isExecutableAtPath: { _ in true }
        )

        XCTAssertEqual(configuration?.environment["PATH"], "/usr/bin:/bin")
        XCTAssertEqual(configuration?.environment["VSCODE_NODE_OPTIONS"], "--max-old-space-size=4096")
        XCTAssertEqual(configuration?.environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"], "module-name")
        XCTAssertNil(configuration?.environment["NODE_OPTIONS"])
        XCTAssertNil(configuration?.environment["NODE_REPL_EXTERNAL_MODULE"])
    }

    func testLaunchConfigurationClearsStaleVSCodeNodeVariablesWhenNodeVariablesAreAbsent() {
        let configuration = VSCodeCLILaunchConfigurationBuilder.launchConfiguration(
            vscodeApplicationURL: URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true),
            baseEnvironment: [
                "PATH": "/usr/bin:/bin",
                "VSCODE_NODE_OPTIONS": "--stale",
                "VSCODE_NODE_REPL_EXTERNAL_MODULE": "stale-module"
            ],
            isExecutableAtPath: { _ in true }
        )

        XCTAssertEqual(configuration?.environment["PATH"], "/usr/bin:/bin")
        XCTAssertNil(configuration?.environment["VSCODE_NODE_OPTIONS"])
        XCTAssertNil(configuration?.environment["VSCODE_NODE_REPL_EXTERNAL_MODULE"])
    }
}


final class ServeWebOutputCollectorTests: XCTestCase {
    func testWaitForURLReturnsFalseAfterProcessExitSignal() {
        let collector = ServeWebOutputCollector()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            collector.markProcessExited()
        }

        let start = Date()
        let resolved = collector.waitForURL(timeoutSeconds: 1)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertFalse(resolved)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testWaitForURLReturnsTrueWhenURLIsCollected() {
        let collector = ServeWebOutputCollector()
        let urlLine = "Web UI available at http://127.0.0.1:7777?tkn=test-token\n"

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            collector.append(Data(urlLine.utf8))
        }

        XCTAssertTrue(collector.waitForURL(timeoutSeconds: 1))
        XCTAssertEqual(collector.webUIURL?.absoluteString, "http://127.0.0.1:7777?tkn=test-token")
    }

    func testMarkProcessExitedParsesFinalURLWithoutTrailingNewline() {
        let collector = ServeWebOutputCollector()
        let finalChunk = "Web UI available at http://127.0.0.1:9001?tkn=final-token"

        collector.append(Data(finalChunk.utf8))
        collector.markProcessExited()

        XCTAssertTrue(collector.waitForURL(timeoutSeconds: 0.1))
        XCTAssertEqual(collector.webUIURL?.absoluteString, "http://127.0.0.1:9001?tkn=final-token")
    }
}


final class VSCodeServeWebControllerTests: XCTestCase {
    func testStopDuringInFlightLaunchDoesNotDropNextGenerationCompletion() {
        let firstLaunchStarted = expectation(description: "first launch started")
        let firstCompletionCalled = expectation(description: "first generation completion called")
        let secondCompletionCalled = expectation(description: "second generation completion called")

        let launchGate = DispatchSemaphore(value: 0)
        let launchCallLock = NSLock()
        var launchCallCount = 0

        let controller = VSCodeServeWebController.makeForTesting { _, _ in
            launchCallLock.lock()
            launchCallCount += 1
            let callNumber = launchCallCount
            launchCallLock.unlock()

            if callNumber == 1 {
                firstLaunchStarted.fulfill()
                _ = launchGate.wait(timeout: .now() + 1)
            }
            return nil
        }

        let callbackLock = NSLock()
        var firstGenerationCallbacks: [URL?] = []
        var secondGenerationCallbacks: [URL?] = []
        let vscodeAppURL = URL(fileURLWithPath: "/Applications/Visual Studio Code.app", isDirectory: true)

        controller.ensureServeWebURL(vscodeApplicationURL: vscodeAppURL) { url in
            callbackLock.lock()
            firstGenerationCallbacks.append(url)
            callbackLock.unlock()
            firstCompletionCalled.fulfill()
        }

        wait(for: [firstLaunchStarted], timeout: 1)
        controller.stop()

        controller.ensureServeWebURL(vscodeApplicationURL: vscodeAppURL) { url in
            callbackLock.lock()
            secondGenerationCallbacks.append(url)
            callbackLock.unlock()
            secondCompletionCalled.fulfill()
        }

        launchGate.signal()
        wait(for: [firstCompletionCalled, secondCompletionCalled], timeout: 2)

        callbackLock.lock()
        let firstSnapshot = firstGenerationCallbacks
        let secondSnapshot = secondGenerationCallbacks
        callbackLock.unlock()

        launchCallLock.lock()
        let launchCalls = launchCallCount
        launchCallLock.unlock()

        XCTAssertEqual(firstSnapshot.count, 1)
        if firstSnapshot.count == 1 {
            XCTAssertNil(firstSnapshot[0])
        }
        XCTAssertEqual(secondSnapshot.count, 1)
        if secondSnapshot.count == 1 {
            XCTAssertNil(secondSnapshot[0])
        }
        XCTAssertEqual(launchCalls, 2)
    }

    func testStopRemovesOrphanedConnectionTokenFiles() throws {
        let tokenFileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tokenFileURL) }
        try Data("token".utf8).write(to: tokenFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tokenFileURL.path))

        let controller = VSCodeServeWebController.makeForTesting { _, _ in
            XCTFail("Expected no launch")
            return nil
        }
        controller.trackConnectionTokenFileForTesting(tokenFileURL)

        controller.stop()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tokenFileURL.path))
    }
}


