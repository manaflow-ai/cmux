import CMUXMobileCore
import Network
import UIKit
import XCTest


// MARK: - App Launch Helpers
extension cmuxUITests {
    @MainActor
    func launchConnectedApp(port: UInt16, assertStatusRows: Bool = true) throws -> XCUIApplication {
        let attachURL = try attachURL(port: port)
        let app = launchApp(mockData: true, environment: [
            "CMUX_UITEST_ATTACH_URL": attachURL.absoluteString,
        ])
        waitForWorkspaceShell(in: app)
        try openSelectedWorkspaceIfNeeded(app)
        if assertStatusRows {
            assertTerminalRow(0, label: "$ cmux ios status", in: app)
            assertTerminalRow(1, label: "Mobile Core: connected", in: app)
        }
        return app
    }

    private func attachURL(port: UInt16) throws -> URL {
        let route = try CmxAttachRoute(
            id: "debug_loopback",
            kind: .debugLoopback,
            endpoint: .hostPort(host: "127.0.0.1", port: Int(port))
        )
        let ticket = try CmxAttachTicket(
            workspaceID: "",
            terminalID: nil,
            macDeviceID: "ui-test-mac",
            macDisplayName: "UI Test Mac",
            routes: [route],
            expiresAt: Date(timeIntervalSinceNow: 60 * 60),
            authToken: "ui-test-ticket"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = base64URLEncode(try encoder.encode(ticket))
        guard let url = URL(string: "cmux-ios://attach?v=\(ticket.version)&payload=\(payload)") else {
            throw URLError(.badURL)
        }
        return url
    }

    private func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    @MainActor
    func launchApp(
        mockData: Bool,
        clearAuth: Bool = false,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CMUX_UITEST_MOCK_DATA"] = mockData ? "1" : "0"
        for (key, value) in environment {
            app.launchEnvironment[key] = value
        }
        if clearAuth {
            app.launchEnvironment["CMUX_UITEST_CLEAR_AUTH"] = "1"
        }
        app.launch()
        return app
    }

    @MainActor
    func openSelectedWorkspaceIfNeeded(_ app: XCUIApplication) throws {
        if app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8) {
            return
        }

        let row = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        row.tap()
        XCTAssertTrue(app.otherElements["MobileTerminalSurface"].waitForExistence(timeout: 8))
    }

    @MainActor
    private func waitForWorkspaceShell(
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let workspaceRow = app.descendants(matching: .any)["MobileWorkspaceRow-workspace-main"]
        let terminalSurface = app.otherElements["MobileTerminalSurface"]
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                workspaceRow.exists || terminalSurface.exists
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: 90)
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

}
