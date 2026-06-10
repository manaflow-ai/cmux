import CMUXMobileCore
import Network
import UIKit
import XCTest


// MARK: - Terminal Row Assertions
extension cmuxUITests {
    @MainActor
    func assertTerminalRow(
        _ index: Int,
        label expectedLabel: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)
        let labelExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                self.terminalRows(in: app).dropFirst(index).first == expectedLabel
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 6)
        XCTAssertEqual(
            result,
            .completed,
            "Expected terminal row \(index) to equal \(expectedLabel). Rows: \(terminalRowLabels(in: app))",
            file: file,
            line: line
        )
        XCTAssertEqual(terminalRows(in: app).dropFirst(index).first, expectedLabel, file: file, line: line)
    }

    @MainActor
    private func assertTerminalRows(
        _ expectedLabels: [Int: String],
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let surface = app.otherElements["MobileTerminalSurface"]
        XCTAssertTrue(surface.waitForExistence(timeout: 6), file: file, line: line)
        let labelExpectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                expectedLabels.allSatisfy { index, expectedLabel in
                    self.terminalRows(in: app).dropFirst(index).first == expectedLabel
                }
            },
            object: app
        )
        let result = XCTWaiter.wait(for: [labelExpectation], timeout: 6)
        if result != .completed {
            XCTFail(
                "Expected terminal rows \(expectedLabels). Rows: \(terminalRowLabels(in: app))",
                file: file,
                line: line
            )
            return
        }
        for (index, expectedLabel) in expectedLabels.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(terminalRows(in: app).dropFirst(index).first, expectedLabel, file: file, line: line)
        }
    }

    @MainActor
    private func terminalRow(_ index: Int, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["MobileTerminalRow-\(index)"]
    }

    @MainActor
    private func terminalRowLabels(in app: XCUIApplication) -> [String] {
        terminalRows(in: app).enumerated().map { index, row in
            "\(index):\(row)"
        }
    }

    @MainActor
    private func terminalRows(in app: XCUIApplication) -> [String] {
        let surface = app.otherElements["MobileTerminalSurface"]
        guard surface.exists else { return [] }
        return surface.label
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
    }

}
