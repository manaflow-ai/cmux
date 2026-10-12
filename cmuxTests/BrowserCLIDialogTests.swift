import AppKit
import CMUXMobileCore
import CmuxBrowser
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#else
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct BrowserCLIDialogTests {
    @Test(arguments: [true, false])
    func confirmCompletesWithCLIAnswer(accept: Bool) async throws {
        try await withPanel { panel, params in
            var answers: [Bool] = []
            enqueue(panel, kind: .javaScriptConfirm) { button, _ in answers.append(button == "ok") }
            #expect(panel.activeInteractiveBrowserPromptIDs.isEmpty)
            #expect(!panel.canRecoverFromAutomationTimeout)
            let response = try await request(accept ? "browser.dialog.accept" : "browser.dialog.dismiss", params)
            #expect(response["ok"] as? Bool == true)
            #expect(answers == [accept])
            #expect(panel.mobileBrowserDialogBroker.currentDialog == nil)
            let duplicate = try await request("browser.dialog.accept", params)
            #expect(duplicate["ok"] as? Bool == false)
            #expect(answers == [accept])
        }
    }

    @Test(arguments: [true, false])
    func alertCompletesOnce(accept: Bool) async throws {
        try await withPanel { panel, params in
            var completions = 0
            enqueue(panel, kind: .javaScriptAlert) { _, _ in completions += 1 }
            let response = try await request(accept ? "browser.dialog.accept" : "browser.dialog.dismiss", params)
            #expect(response["ok"] as? Bool == true)
            panel.mobileBrowserDialogBroker.resolveAll()
            #expect(completions == 1)
        }
    }

    @Test(arguments: [true, false])
    func promptReturnsTextOrCancellation(accept: Bool) async throws {
        try await withPanel { panel, params in
            var answers: [String?] = []
            enqueue(panel, kind: .javaScriptPrompt) { button, text in
                answers.append(button == "ok" ? text : nil)
            }
            var params = params
            params["text"] = "answer"
            let response = try await request(accept ? "browser.dialog.accept" : "browser.dialog.dismiss", params)
            #expect(response["ok"] as? Bool == true)
            #expect(answers.count == 1)
            #expect(answers.first == .some(accept ? "answer" : nil))
        }
    }

    @Test func queuedDialogsAreFIFOAndTeardownCancelsTheRest() async throws {
        try await withPanel { panel, params in
            var answers: [String] = []
            enqueue(panel, kind: .javaScriptConfirm) { button, _ in answers.append("first:" + button) }
            enqueue(panel, kind: .javaScriptConfirm) { button, _ in answers.append("second:" + button) }
            let response = try await request("browser.dialog.accept", params)
            #expect(response["ok"] as? Bool == true)
            #expect(answers == ["first:ok"])
            panel.tearDownWebViewBeforeReplacement(panel.webView, reason: "dialog-test")
            #expect(answers == ["first:ok", "second:cancel"])
            #expect(panel.mobileBrowserDialogBroker.currentDialog == nil)
        }
    }

    @Test func promptAcceptUsesDefaultWhenTextIsOmitted() async throws {
        try await withPanel { panel, params in
            var answer: String?
            enqueue(panel, kind: .javaScriptPrompt) { _, text in answer = text }
            let response = try await request("browser.dialog.accept", params)
            #expect(response["ok"] as? Bool == true)
            #expect(answer == "default")
        }
    }

    @Test func queuedUIDialogCanBeAnsweredWithoutPageScript() async throws {
        try await withPanel { panel, params in
            panel.browserDialogsOwnedByCLI = false
            var answers: [Bool] = []
            enqueue(panel, kind: .javaScriptConfirm) { button, _ in answers.append(button == "ok") }
            #expect(panel.activeInteractiveBrowserPromptIDs.count == 1)
            let response = try await request("browser.dialog.accept", params)
            #expect(response["ok"] as? Bool == true)
            #expect(answers == [true])
            #expect(panel.activeInteractiveBrowserPromptIDs.isEmpty)
            panel.cancelPendingInteractiveBrowserPrompts(reason: "test")
            #expect(answers == [true])
        }
    }

    @Test func userInteractionRestoresUIPresentationForSubsequentDialogs() async throws {
        try await withPanel { panel, _ in
            let webView = try #require(panel.webView as? CmuxWebView)
            webView.onPhysicalUserInteraction?()
            enqueue(panel, kind: .javaScriptConfirm) { _, _ in }
            #expect(panel.activeInteractiveBrowserPromptIDs.count == 1)
        }
    }

    @Test func navigationAndProcessTerminationClearPendingCompletions() async throws {
        try await withPanel { panel, _ in
            var answers: [String] = []
            enqueue(panel, kind: .javaScriptConfirm) { button, _ in answers.append(button) }
            panel.cancelPendingJavaScriptDialogs()
            #expect(answers == ["cancel"])
            #expect(panel.mobileBrowserDialogBroker.currentDialog == nil)
            enqueue(panel, kind: .javaScriptConfirm) { button, _ in answers.append(button) }
            panel.handleWebContentProcessTermination(for: panel.webView)
            #expect(answers == ["cancel", "cancel"])
            #expect(panel.mobileBrowserDialogBroker.currentDialog == nil)
        }
    }

    private func withPanel(_ body: (BrowserPanel, [String: String]) async throws -> Void) async throws {
        let manager = TabManager()
        defer {
            manager.tabs.forEach { $0.teardownAllPanels() }
            TerminalController.shared.setActiveTabManager(nil)
        }
        let workspace = try #require(manager.selectedWorkspace)
        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        let panel = try #require(workspace.newBrowserSurface(inPane: pane, focus: false, creationPolicy: .restoration))
        TerminalController.shared.setActiveTabManager(manager)
        _ = panel.webViewForAutomationCommand()
        try await body(panel, ["workspace_id": workspace.id.uuidString, "surface_id": panel.id.uuidString])
    }

    private func enqueue(
        _ panel: BrowserPanel,
        kind: MobileBrowserDialogKind,
        response: @escaping @MainActor (String, String?) -> Void
    ) {
        let alert = NSAlert()
        alert.addButton(withTitle: "OK")
        if kind != .javaScriptAlert { alert.addButton(withTitle: "Cancel") }
        panel.presentMobileBrowserDialog(
            kind: kind, title: "Dialog", message: "test", host: nil,
            buttons: kind == .javaScriptAlert
                ? [MobileBrowserDialogButton(id: "ok", label: "OK", role: .default)]
                : [MobileBrowserDialogButton(id: "ok", label: "OK", role: .default),
                   MobileBrowserDialogButton(id: "cancel", label: "Cancel", role: .cancel)],
            textField: kind == .javaScriptPrompt
                ? MobileBrowserDialogTextField(placeholder: nil, initial: "default", secure: false) : nil,
            informational: false, alert: alert, response: response,
            macResponse: { ($0 == .alertFirstButtonReturn ? "ok" : "cancel", nil) },
            cancelButtonID: kind == .javaScriptAlert ? "ok" : "cancel"
        )
    }

    private func request(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": method, "params": params])
        let line = String(decoding: data, as: UTF8.self)
        let response = await Task.detached {
            TerminalController.shared.handleSocketLine(line)
        }.value
        return try #require(JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any])
    }
}
