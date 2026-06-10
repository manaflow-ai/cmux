import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import ObjectiveC.runtime
import Bonsplit
import UserNotifications
import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


@MainActor
final class BrowserPanelFileSystemAccessBridgeTests: XCTestCase {
    func testShowOpenFilePickerIsInstalledInBrowserPages() async throws {
        let panel = try await loadFilePickerTestPage()

        let result = try await panel.evaluateJavaScript("typeof window.showOpenFilePicker")
        XCTAssertEqual(result as? String, "function")
    }

    func testShowOpenFilePickerRejectsWhenWindowFocusReturnsWithoutCancelEvent() async throws {
        let panel = try await loadFilePickerTestPage()

        let result = try await panel.webView.callAsyncJavaScript(
            """
            const inputCount = () => document.querySelectorAll("input[type='file']").length;
            const originalClick = HTMLInputElement.prototype.click;
            HTMLInputElement.prototype.click = function() {};
            const pickerPromise = window.showOpenFilePicker();
            HTMLInputElement.prototype.click = originalClick;

            return await new Promise((resolve) => {
              pickerPromise.then(
                () => resolve({ status: "resolved", inputCount: inputCount() }),
                (error) => resolve({
                  status: "rejected",
                  name: error && error.name,
                  inputCount: inputCount(),
                })
              );

              window.dispatchEvent(new Event("focus"));
              setTimeout(() => resolve({ status: "pending", inputCount: inputCount() }), 100);
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let dictionary = try XCTUnwrap(result as? [String: Any])
        let inputCount = try XCTUnwrap(dictionary["inputCount"] as? NSNumber)
        XCTAssertEqual(dictionary["status"] as? String, "rejected")
        XCTAssertEqual(dictionary["name"] as? String, "AbortError")
        XCTAssertEqual(inputCount.intValue, 0)
    }

    func testShowOpenFilePickerDoesNotRejectOnElementFocus() async throws {
        let panel = try await loadFilePickerTestPage()

        let result = try await panel.webView.callAsyncJavaScript(
            """
            const inputCount = () => document.querySelectorAll("input[type='file']").length;
            const originalClick = HTMLInputElement.prototype.click;
            HTMLInputElement.prototype.click = function() {};
            const pickerPromise = window.showOpenFilePicker();
            HTMLInputElement.prototype.click = originalClick;

            let settled = false;
            pickerPromise.finally(() => { settled = true; }).catch(() => {});

            const textInput = document.createElement("input");
            textInput.type = "text";
            document.body.appendChild(textInput);
            textInput.focus();

            await new Promise((resolve) => setTimeout(resolve, 50));
            const beforeWindowFocus = {
              settled,
              inputCount: inputCount(),
            };

            window.dispatchEvent(new Event("focus"));
            const afterWindowFocus = await new Promise((resolve) => {
              pickerPromise.then(
                () => resolve({ status: "resolved", inputCount: inputCount() }),
                (error) => resolve({
                  status: "rejected",
                  name: error && error.name,
                  inputCount: inputCount(),
                })
              );
            });

            return { beforeWindowFocus, afterWindowFocus };
            """,
            arguments: [:],
            in: nil,
            contentWorld: .page
        )
        let dictionary = try XCTUnwrap(result as? [String: Any])
        let beforeWindowFocus = try XCTUnwrap(dictionary["beforeWindowFocus"] as? [String: Any])
        let beforeInputCount = try XCTUnwrap(beforeWindowFocus["inputCount"] as? NSNumber)
        XCTAssertEqual(beforeWindowFocus["settled"] as? Bool, false)
        XCTAssertEqual(beforeInputCount.intValue, 1)

        let afterWindowFocus = try XCTUnwrap(dictionary["afterWindowFocus"] as? [String: Any])
        let afterInputCount = try XCTUnwrap(afterWindowFocus["inputCount"] as? NSNumber)
        XCTAssertEqual(afterWindowFocus["status"] as? String, "rejected")
        XCTAssertEqual(afterWindowFocus["name"] as? String, "AbortError")
        XCTAssertEqual(afterInputCount.intValue, 0)
    }

    private func loadFilePickerTestPage() async throws -> BrowserPanel {
        let panel = BrowserPanel(workspaceId: UUID())
        let baseURL = try XCTUnwrap(URL(string: "https://example.test/file-picker"))
        let loaded = expectation(description: "browser panel test page loaded")
        let previousDelegate = panel.webView.navigationDelegate
        let loadDelegate = BrowserPanelTestNavigationDelegate(expectation: loaded)
        panel.webView.navigationDelegate = loadDelegate
        defer { panel.webView.navigationDelegate = previousDelegate }

        panel.webView.loadHTMLString(
            "<!doctype html><html><body>browser panel test page</body></html>",
            baseURL: baseURL
        )
        await fulfillment(of: [loaded], timeout: 5)
        if let error = loadDelegate.error {
            throw error
        }
        return panel
    }
}


