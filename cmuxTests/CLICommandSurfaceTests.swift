import Darwin
import XCTest

extension CLINotifyProcessIntegrationRegressionTests {
    private struct CLIHelpCommandCase {
        let command: String
        let expectedText: String
    }

    private struct CLISocketCommandCase {
        let name: String
        let arguments: [String]
        let expectedV2Methods: [String]
        let expectedV1Prefixes: [String]
        let standardInput: String?

        init(
            _ name: String,
            arguments: [String],
            expectedV2Methods: [String] = [],
            expectedV1Prefixes: [String] = [],
            standardInput: String? = nil
        ) {
            self.name = name
            self.arguments = arguments
            self.expectedV2Methods = expectedV2Methods
            self.expectedV1Prefixes = expectedV1Prefixes
            self.standardInput = standardInput
        }
    }

    func testPublicCLICommandsExposeHelpWithoutSocket() throws {
        let cliPath = try bundledCLIPath()
        let cases: [CLIHelpCommandCase] = [
            .init(command: "ping", expectedText: "Usage: cmux ping"),
            .init(command: "capabilities", expectedText: "Usage: cmux capabilities"),
            .init(command: "events", expectedText: "Usage: cmux events"),
            .init(command: "auth", expectedText: "Usage: cmux auth"),
            .init(command: "login", expectedText: "Alias for `cmux auth login`"),
            .init(command: "logout", expectedText: "Alias for `cmux auth logout`"),
            .init(command: "vm", expectedText: "Usage: cmux vm"),
            .init(command: "cloud", expectedText: "Usage: cmux cloud"),
            .init(command: "rpc", expectedText: "Usage: cmux rpc"),
            .init(command: "help", expectedText: "Usage: cmux help"),
            .init(command: "docs", expectedText: "Usage: cmux docs"),
            .init(command: "settings", expectedText: "Usage: cmux settings"),
            .init(command: "config", expectedText: "Usage: cmux config"),
            .init(command: "welcome", expectedText: "Usage: cmux welcome"),
            .init(command: "shortcuts", expectedText: "Usage: cmux shortcuts"),
            .init(command: "disable-browser", expectedText: "Usage: cmux disable-browser"),
            .init(command: "enable-browser", expectedText: "Usage: cmux enable-browser"),
            .init(command: "browser-status", expectedText: "Usage: cmux browser-status"),
            .init(command: "restore-session", expectedText: "Usage: cmux restore-session"),
            .init(command: "feedback", expectedText: "Usage: cmux feedback"),
            .init(command: "feed", expectedText: "Usage: cmux feed"),
            .init(command: "hooks", expectedText: "Usage: cmux hooks"),
            .init(command: "themes", expectedText: "Usage: cmux themes"),
            .init(command: "omo", expectedText: "Usage: cmux omo"),
            .init(command: "omx", expectedText: "Usage: cmux omx"),
            .init(command: "omc", expectedText: "Usage: cmux omc"),
            .init(command: "identify", expectedText: "Usage: cmux identify"),
            .init(command: "list-windows", expectedText: "Usage: cmux list-windows"),
            .init(command: "current-window", expectedText: "Usage: cmux current-window"),
            .init(command: "new-window", expectedText: "Usage: cmux new-window"),
            .init(command: "focus-window", expectedText: "Usage: cmux focus-window"),
            .init(command: "close-window", expectedText: "Usage: cmux close-window"),
            .init(command: "move-workspace-to-window", expectedText: "Usage: cmux move-workspace-to-window"),
            .init(command: "move-surface", expectedText: "Usage: cmux move-surface"),
            .init(command: "reorder-surface", expectedText: "Usage: cmux reorder-surface"),
            .init(command: "reorder-workspace", expectedText: "Usage: cmux reorder-workspace"),
            .init(command: "workspace-action", expectedText: "Usage: cmux workspace-action"),
            .init(command: "tab-action", expectedText: "Usage: cmux tab-action"),
            .init(command: "move-tab-to-new-workspace", expectedText: "Usage: cmux move-tab-to-new-workspace"),
            .init(command: "detach-tab", expectedText: "Usage: cmux move-tab-to-new-workspace"),
            .init(command: "rename-tab", expectedText: "Usage: cmux rename-tab"),
            .init(command: "new-workspace", expectedText: "Usage: cmux new-workspace"),
            .init(command: "list-workspaces", expectedText: "Usage: cmux list-workspaces"),
            .init(command: "ssh", expectedText: "Usage: cmux ssh"),
            .init(command: "remote-daemon-status", expectedText: "Usage: cmux remote-daemon-status"),
            .init(command: "new-split", expectedText: "Usage: cmux new-split"),
            .init(command: "list-panes", expectedText: "Usage: cmux list-panes"),
            .init(command: "list-pane-surfaces", expectedText: "Usage: cmux list-pane-surfaces"),
            .init(command: "tree", expectedText: "Usage: cmux tree"),
            .init(command: "top", expectedText: "Usage: cmux top"),
            .init(command: "focus-pane", expectedText: "Usage: cmux focus-pane"),
            .init(command: "new-pane", expectedText: "Usage: cmux new-pane"),
            .init(command: "new-surface", expectedText: "Usage: cmux new-surface"),
            .init(command: "close-surface", expectedText: "Usage: cmux close-surface"),
            .init(command: "drag-surface-to-split", expectedText: "Usage: cmux drag-surface-to-split"),
            .init(command: "split-off", expectedText: "Usage: cmux split-off"),
            .init(command: "refresh-surfaces", expectedText: "Usage: cmux refresh-surfaces"),
            .init(command: "reload-config", expectedText: "Usage: cmux reload-config"),
            .init(command: "surface-health", expectedText: "Usage: cmux surface-health"),
            .init(command: "debug-terminals", expectedText: "Usage: cmux debug-terminals"),
            .init(command: "trigger-flash", expectedText: "Usage: cmux trigger-flash"),
            .init(command: "list-panels", expectedText: "Usage: cmux list-panels"),
            .init(command: "focus-panel", expectedText: "Usage: cmux focus-panel"),
            .init(command: "close-workspace", expectedText: "Usage: cmux close-workspace"),
            .init(command: "select-workspace", expectedText: "Usage: cmux select-workspace"),
            .init(command: "rename-workspace", expectedText: "Usage: cmux rename-workspace"),
            .init(command: "rename-window", expectedText: "Usage: cmux rename-workspace"),
            .init(command: "current-workspace", expectedText: "Usage: cmux current-workspace"),
            .init(command: "capture-pane", expectedText: "Usage: cmux capture-pane"),
            .init(command: "resize-pane", expectedText: "Usage: cmux resize-pane"),
            .init(command: "pipe-pane", expectedText: "Usage: cmux pipe-pane"),
            .init(command: "wait-for", expectedText: "Usage: cmux wait-for"),
            .init(command: "swap-pane", expectedText: "Usage: cmux swap-pane"),
            .init(command: "break-pane", expectedText: "Usage: cmux break-pane"),
            .init(command: "join-pane", expectedText: "Usage: cmux join-pane"),
            .init(command: "next-window", expectedText: "Usage: cmux next-window"),
            .init(command: "previous-window", expectedText: "Usage: cmux previous-window"),
            .init(command: "last-window", expectedText: "Usage: cmux last-window"),
            .init(command: "last-pane", expectedText: "Usage: cmux last-pane"),
            .init(command: "find-window", expectedText: "Usage: cmux find-window"),
            .init(command: "clear-history", expectedText: "Usage: cmux clear-history"),
            .init(command: "set-hook", expectedText: "Usage: cmux set-hook"),
            .init(command: "popup", expectedText: "Usage: cmux popup"),
            .init(command: "bind-key", expectedText: "tmux compatibility placeholder"),
            .init(command: "unbind-key", expectedText: "tmux compatibility placeholder"),
            .init(command: "copy-mode", expectedText: "tmux compatibility placeholder"),
            .init(command: "set-buffer", expectedText: "Usage: cmux set-buffer"),
            .init(command: "paste-buffer", expectedText: "Usage: cmux paste-buffer"),
            .init(command: "list-buffers", expectedText: "Usage: cmux list-buffers"),
            .init(command: "respawn-pane", expectedText: "Usage: cmux respawn-pane"),
            .init(command: "display-message", expectedText: "Usage: cmux display-message"),
            .init(command: "read-screen", expectedText: "Usage: cmux read-screen"),
            .init(command: "send", expectedText: "Usage: cmux send"),
            .init(command: "send-key", expectedText: "Usage: cmux send-key"),
            .init(command: "send-panel", expectedText: "Usage: cmux send-panel"),
            .init(command: "send-key-panel", expectedText: "Usage: cmux send-key-panel"),
            .init(command: "notify", expectedText: "Usage: cmux notify"),
            .init(command: "list-notifications", expectedText: "Usage: cmux list-notifications"),
            .init(command: "clear-notifications", expectedText: "Usage: cmux clear-notifications"),
            .init(command: "set-status", expectedText: "Usage: cmux set-status"),
            .init(command: "clear-status", expectedText: "Usage: cmux clear-status"),
            .init(command: "list-status", expectedText: "Usage: cmux list-status"),
            .init(command: "set-progress", expectedText: "Usage: cmux set-progress"),
            .init(command: "clear-progress", expectedText: "Usage: cmux clear-progress"),
            .init(command: "log", expectedText: "Usage: cmux log"),
            .init(command: "clear-log", expectedText: "Usage: cmux clear-log"),
            .init(command: "list-log", expectedText: "Usage: cmux list-log"),
            .init(command: "sidebar-state", expectedText: "Usage: cmux sidebar-state"),
            .init(command: "set-app-focus", expectedText: "Usage: cmux set-app-focus"),
            .init(command: "simulate-app-active", expectedText: "Usage: cmux simulate-app-active"),
            .init(command: "claude-hook", expectedText: "Usage: cmux claude-hook"),
            .init(command: "codex", expectedText: "Usage: cmux codex"),
            .init(command: "browser", expectedText: "Usage: cmux browser"),
            .init(command: "open-browser", expectedText: "Legacy alias for 'cmux browser open'"),
            .init(command: "navigate", expectedText: "Legacy alias for 'cmux browser navigate'"),
            .init(command: "browser-back", expectedText: "Legacy alias for 'cmux browser back'"),
            .init(command: "browser-forward", expectedText: "Legacy alias for 'cmux browser forward'"),
            .init(command: "browser-reload", expectedText: "Legacy alias for 'cmux browser reload'"),
            .init(command: "get-url", expectedText: "Legacy alias for 'cmux browser get-url'"),
            .init(command: "focus-webview", expectedText: "Legacy alias for 'cmux browser focus-webview'"),
            .init(command: "is-webview-focused", expectedText: "Legacy alias for 'cmux browser is-webview-focused'"),
            .init(command: "open", expectedText: "Usage: cmux open"),
            .init(command: "markdown", expectedText: "Usage: cmux markdown open"),
        ]

        let helpResult = runCLIHelp(cliPath: cliPath, arguments: ["help"])
        XCTAssertEqual(helpResult.status, 0, helpResult.stderr)
        XCTAssertTrue(helpResult.stdout.contains("Commands:"), helpResult.stdout)

        for testCase in cases {
            let result = runCLIHelp(cliPath: cliPath, arguments: [testCase.command, "--help"])
            XCTAssertFalse(result.timedOut, "\(testCase.command) --help timed out")
            XCTAssertEqual(result.status, 0, "\(testCase.command) --help failed\nstdout:\(result.stdout)\nstderr:\(result.stderr)")
            XCTAssertTrue(result.stderr.isEmpty, "\(testCase.command) --help wrote stderr: \(result.stderr)")
            XCTAssertTrue(
                result.stdout.contains(testCase.expectedText),
                "\(testCase.command) --help did not contain expected text '\(testCase.expectedText)'\nstdout:\(result.stdout)"
            )
        }

        let versionResult = runCLIHelp(cliPath: cliPath, arguments: ["version"])
        XCTAssertFalse(versionResult.timedOut, versionResult.stderr)
        XCTAssertEqual(versionResult.status, 0, versionResult.stderr)
        XCTAssertTrue(versionResult.stdout.contains("cmux"), versionResult.stdout)
    }

    func testRepresentativeCLICommandsReachExpectedSocketProtocol() throws {
        let cliPath = try bundledCLIPath()
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-command-surface-\(UUID().uuidString)", isDirectory: true)
        let markdownURL = rootURL.appendingPathComponent("notes.md")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try "# Notes\n".write(to: markdownURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"
        let paneID = "33333333-3333-3333-3333-333333333333"
        let windowID = "44444444-4444-4444-4444-444444444444"
        let secondPaneID = "55555555-5555-5555-5555-555555555555"
        let waitSignalName = "cli-surface-test-\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(
                atPath: "/tmp/cmux-wait-for-\(waitSignalName).sig"
            )
        }

        let cases: [CLISocketCommandCase] = [
            .init("ping", arguments: ["ping"], expectedV1Prefixes: ["ping"]),
            .init("capabilities", arguments: ["capabilities"], expectedV2Methods: ["system.capabilities"]),
            .init("auth status", arguments: ["auth", "status"], expectedV2Methods: ["auth.status"]),
            .init("vm ls", arguments: ["vm", "ls"], expectedV2Methods: ["vm.list"]),
            .init("vm new", arguments: ["vm", "new", "--detach"], expectedV2Methods: ["vm.create"]),
            .init("vm rm", arguments: ["vm", "rm", "vm-test"], expectedV2Methods: ["vm.destroy"]),
            .init("vm ssh", arguments: ["vm", "ssh", "vm-test"], expectedV2Methods: ["vm.ssh_info"]),
            .init("vm exec", arguments: ["vm", "exec", "vm-test", "--", "printf", "hello world"], expectedV2Methods: ["vm.exec"]),
            .init("rpc", arguments: ["rpc", "system.identify", #"{"probe":true}"#], expectedV2Methods: ["system.identify"]),
            .init("identify", arguments: ["identify", "--no-caller"], expectedV2Methods: ["system.identify"]),
            .init("list-windows", arguments: ["list-windows"], expectedV1Prefixes: ["list_windows"]),
            .init("current-window", arguments: ["current-window"], expectedV1Prefixes: ["current_window"]),
            .init("new-window", arguments: ["new-window"], expectedV1Prefixes: ["new_window"]),
            .init("focus-window", arguments: ["focus-window", "--window", windowID], expectedV1Prefixes: ["focus_window \(windowID)"]),
            .init("close-window", arguments: ["close-window", "--window", windowID], expectedV1Prefixes: ["close_window \(windowID)"]),
            .init("move-workspace-to-window", arguments: ["move-workspace-to-window", "--workspace", workspaceID, "--window", windowID], expectedV2Methods: ["workspace.move_to_window"]),
            .init("move-surface", arguments: ["move-surface", "--surface", surfaceID, "--pane", paneID], expectedV2Methods: ["surface.move"]),
            .init("reorder-surface", arguments: ["reorder-surface", "--surface", surfaceID, "--index", "0"], expectedV2Methods: ["surface.reorder"]),
            .init("reorder-workspace", arguments: ["reorder-workspace", "--workspace", workspaceID, "--index", "0"], expectedV2Methods: ["workspace.reorder"]),
            .init("workspace-action", arguments: ["workspace-action", "--workspace", workspaceID, "--action", "rename", "--title", "Build"], expectedV2Methods: ["workspace.action"]),
            .init("tab-action", arguments: ["tab-action", "--workspace", workspaceID, "--surface", surfaceID, "--action", "rename", "--title", "Build"], expectedV2Methods: ["tab.action"]),
            .init("move-tab-to-new-workspace", arguments: ["move-tab-to-new-workspace", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["tab.action"]),
            .init("rename-tab", arguments: ["rename-tab", "--workspace", workspaceID, "--surface", surfaceID, "Logs"], expectedV2Methods: ["tab.action"]),
            .init("list-workspaces", arguments: ["list-workspaces"], expectedV2Methods: ["workspace.list"]),
            .init("new-workspace", arguments: ["new-workspace", "--name", "Scratch"], expectedV2Methods: ["workspace.create"]),
            .init("new-split", arguments: ["new-split", "right", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.split"]),
            .init("list-panes", arguments: ["list-panes", "--workspace", workspaceID], expectedV2Methods: ["pane.list"]),
            .init("list-pane-surfaces", arguments: ["list-pane-surfaces", "--workspace", workspaceID, "--pane", paneID], expectedV2Methods: ["pane.surfaces"]),
            .init("tree", arguments: ["tree", "--json"], expectedV2Methods: ["system.tree"]),
            .init("top", arguments: ["top", "--json"], expectedV2Methods: ["system.top"]),
            .init("focus-pane", arguments: ["focus-pane", "--workspace", workspaceID, "--pane", paneID], expectedV2Methods: ["pane.focus"]),
            .init("new-pane", arguments: ["new-pane", "--workspace", workspaceID, "--type", "terminal"], expectedV2Methods: ["pane.create"]),
            .init("new-surface", arguments: ["new-surface", "--workspace", workspaceID, "--pane", paneID, "--type", "terminal"], expectedV2Methods: ["surface.create"]),
            .init("close-surface", arguments: ["close-surface", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.close"]),
            .init("split-off", arguments: ["split-off", "--workspace", workspaceID, "--surface", surfaceID, "right"], expectedV2Methods: ["surface.split_off"]),
            .init("refresh-surfaces", arguments: ["refresh-surfaces"], expectedV1Prefixes: ["refresh_surfaces"]),
            .init("reload-config", arguments: ["reload-config"], expectedV1Prefixes: ["reload_config"]),
            .init("surface-health", arguments: ["surface-health", "--workspace", workspaceID], expectedV2Methods: ["surface.health"]),
            .init("debug-terminals", arguments: ["debug-terminals"], expectedV2Methods: ["debug.terminals"]),
            .init("trigger-flash", arguments: ["trigger-flash", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.trigger_flash"]),
            .init("list-panels", arguments: ["list-panels", "--workspace", workspaceID], expectedV2Methods: ["surface.list"]),
            .init("focus-panel", arguments: ["focus-panel", "--workspace", workspaceID, "--panel", surfaceID], expectedV2Methods: ["surface.focus"]),
            .init("close-workspace", arguments: ["close-workspace", "--workspace", workspaceID], expectedV2Methods: ["workspace.close"]),
            .init("select-workspace", arguments: ["select-workspace", "--workspace", workspaceID], expectedV2Methods: ["workspace.select"]),
            .init("rename-workspace", arguments: ["rename-workspace", "--workspace", workspaceID, "Renamed"], expectedV2Methods: ["workspace.rename"]),
            .init("current-workspace", arguments: ["current-workspace"], expectedV2Methods: ["workspace.current"]),
            .init("read-screen", arguments: ["read-screen", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.read_text"]),
            .init("send", arguments: ["send", "--workspace", workspaceID, "--surface", surfaceID, "echo hi"], expectedV2Methods: ["surface.send_text"]),
            .init("send-key", arguments: ["send-key", "--workspace", workspaceID, "--surface", surfaceID, "enter"], expectedV2Methods: ["surface.send_key"]),
            .init("send-panel", arguments: ["send-panel", "--workspace", workspaceID, "--panel", surfaceID, "echo hi"], expectedV2Methods: ["surface.send_text"]),
            .init("send-key-panel", arguments: ["send-key-panel", "--workspace", workspaceID, "--panel", surfaceID, "enter"], expectedV2Methods: ["surface.send_key"]),
            .init("notify", arguments: ["notify", "--workspace", workspaceID, "--surface", surfaceID, "--title", "Done"], expectedV2Methods: ["notification.create"]),
            .init("list-notifications", arguments: ["list-notifications"], expectedV1Prefixes: ["list_notifications"]),
            .init("clear-notifications", arguments: ["clear-notifications", "--workspace", workspaceID], expectedV1Prefixes: ["clear_notifications"]),
            .init("set-status", arguments: ["set-status", "build", "running", "--workspace", workspaceID], expectedV1Prefixes: ["set_status"]),
            .init("clear-status", arguments: ["clear-status", "build", "--workspace", workspaceID], expectedV1Prefixes: ["clear_status"]),
            .init("list-status", arguments: ["list-status", "--workspace", workspaceID], expectedV1Prefixes: ["list_status"]),
            .init("set-progress", arguments: ["set-progress", "0.5", "--workspace", workspaceID], expectedV1Prefixes: ["set_progress"]),
            .init("clear-progress", arguments: ["clear-progress", "--workspace", workspaceID], expectedV1Prefixes: ["clear_progress"]),
            .init("log", arguments: ["log", "--workspace", workspaceID, "started"], expectedV1Prefixes: ["log"]),
            .init("clear-log", arguments: ["clear-log", "--workspace", workspaceID], expectedV1Prefixes: ["clear_log"]),
            .init("list-log", arguments: ["list-log", "--workspace", workspaceID], expectedV1Prefixes: ["list_log"]),
            .init("sidebar-state", arguments: ["sidebar-state", "--workspace", workspaceID], expectedV1Prefixes: ["sidebar_state"]),
            .init("set-app-focus", arguments: ["set-app-focus", "inactive"], expectedV1Prefixes: ["set_app_focus inactive"]),
            .init("simulate-app-active", arguments: ["simulate-app-active"], expectedV1Prefixes: ["simulate_app_active"]),
            .init("capture-pane", arguments: ["capture-pane", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.read_text"]),
            .init("resize-pane", arguments: ["resize-pane", "--workspace", workspaceID, "--pane", paneID, "-R", "--amount", "2"], expectedV2Methods: ["pane.resize"]),
            .init("pipe-pane", arguments: ["pipe-pane", "--workspace", workspaceID, "--surface", surfaceID, "--command", "cat"], expectedV2Methods: ["surface.read_text"]),
            .init("wait-for", arguments: ["wait-for", "-S", waitSignalName], expectedV2Methods: []),
            .init("swap-pane", arguments: ["swap-pane", "--workspace", workspaceID, "--pane", paneID, "--target-pane", secondPaneID], expectedV2Methods: ["pane.swap"]),
            .init("break-pane", arguments: ["break-pane", "--workspace", workspaceID, "--pane", paneID, "--surface", surfaceID], expectedV2Methods: ["pane.break"]),
            .init("join-pane", arguments: ["join-pane", "--workspace", workspaceID, "--pane", paneID, "--surface", surfaceID, "--target-pane", secondPaneID], expectedV2Methods: ["pane.join"]),
            .init("last-window", arguments: ["last-window"], expectedV2Methods: ["workspace.last"]),
            .init("next-window", arguments: ["next-window"], expectedV2Methods: ["workspace.next"]),
            .init("previous-window", arguments: ["previous-window"], expectedV2Methods: ["workspace.previous"]),
            .init("last-pane", arguments: ["last-pane", "--workspace", workspaceID], expectedV2Methods: ["pane.last"]),
            .init("find-window", arguments: ["find-window", "scratch"], expectedV2Methods: ["workspace.list"]),
            .init("clear-history", arguments: ["clear-history", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.clear_history"]),
            .init("set-hook", arguments: ["set-hook", "after-new-window", "echo hi"], expectedV2Methods: []),
            .init("set-buffer", arguments: ["set-buffer", "clipboard"], expectedV2Methods: []),
            .init("paste-buffer", arguments: ["paste-buffer", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.send_text"]),
            .init("list-buffers", arguments: ["list-buffers"], expectedV2Methods: []),
            .init("respawn-pane", arguments: ["respawn-pane", "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["surface.send_text"]),
            .init("display-message", arguments: ["display-message", "hello"], expectedV2Methods: ["notification.create"]),
            .init("open url", arguments: ["open", "https://example.com"], expectedV2Methods: ["browser.open_split"]),
            .init("restore-session", arguments: ["restore-session"], expectedV2Methods: ["session.restore_previous"]),
            .init("feedback open", arguments: ["feedback"], expectedV2Methods: ["feedback.open"]),
            .init("feedback submit", arguments: ["feedback", "--email", "dev@example.com", "--body", "works"], expectedV2Methods: ["feedback.submit"]),
            .init("browser open", arguments: ["browser", "open", "https://example.com"], expectedV2Methods: ["browser.open_split"]),
            .init("browser navigate", arguments: ["browser", "--surface", surfaceID, "navigate", "https://example.com"], expectedV2Methods: ["browser.navigate"]),
            .init("browser back", arguments: ["browser", "--surface", surfaceID, "back"], expectedV2Methods: ["browser.back"]),
            .init("browser forward", arguments: ["browser", "--surface", surfaceID, "forward"], expectedV2Methods: ["browser.forward"]),
            .init("browser reload", arguments: ["browser", "--surface", surfaceID, "reload"], expectedV2Methods: ["browser.reload"]),
            .init("browser get-url", arguments: ["browser", "--surface", surfaceID, "get-url"], expectedV2Methods: ["browser.url.get"]),
            .init("browser focus-webview", arguments: ["browser", "--surface", surfaceID, "focus-webview"], expectedV2Methods: ["browser.focus_webview"]),
            .init("browser is-webview-focused", arguments: ["browser", "--surface", surfaceID, "is-webview-focused"], expectedV2Methods: ["browser.is_webview_focused"]),
            .init("browser profiles", arguments: ["browser", "profiles", "list"], expectedV2Methods: ["browser.profiles.list"]),
            .init("browser import", arguments: ["browser", "import", "--non-interactive", "--from", "Chrome"], expectedV2Methods: ["browser.import.cookies"]),
            .init("browser cookies get", arguments: ["browser", "--surface", surfaceID, "cookies", "get"], expectedV2Methods: ["browser.cookies.get"]),
            .init("browser storage get", arguments: ["browser", "--surface", surfaceID, "storage", "local", "get"], expectedV2Methods: ["browser.storage.get"]),
            .init("browser tab list", arguments: ["browser", "--surface", surfaceID, "tab", "list"], expectedV2Methods: ["browser.tab.list"]),
            .init("browser console", arguments: ["browser", "--surface", surfaceID, "console", "list"], expectedV2Methods: ["browser.console.list"]),
            .init("browser errors", arguments: ["browser", "--surface", surfaceID, "errors", "list"], expectedV2Methods: ["browser.errors.list"]),
            .init("browser highlight", arguments: ["browser", "--surface", surfaceID, "highlight", "body"], expectedV2Methods: ["browser.highlight"]),
            .init("browser state", arguments: ["browser", "--surface", surfaceID, "state", "save", rootURL.appendingPathComponent("state.json").path], expectedV2Methods: ["browser.state.save"]),
            .init("browser addscript", arguments: ["browser", "--surface", surfaceID, "addscript", "window.test = true"], expectedV2Methods: ["browser.addscript"]),
            .init("browser addstyle", arguments: ["browser", "--surface", surfaceID, "addstyle", "body { color: red; }"], expectedV2Methods: ["browser.addstyle"]),
            .init("browser viewport", arguments: ["browser", "--surface", surfaceID, "viewport", "800", "600"], expectedV2Methods: ["browser.viewport.set"]),
            .init("browser geo", arguments: ["browser", "--surface", surfaceID, "geo", "37.0", "-122.0"], expectedV2Methods: ["browser.geolocation.set"]),
            .init("browser offline", arguments: ["browser", "--surface", surfaceID, "offline", "true"], expectedV2Methods: ["browser.offline.set"]),
            .init("browser trace", arguments: ["browser", "--surface", surfaceID, "trace", "start"], expectedV2Methods: ["browser.trace.start"]),
            .init("browser network", arguments: ["browser", "--surface", surfaceID, "network", "requests"], expectedV2Methods: ["browser.network.requests"]),
            .init("browser screencast", arguments: ["browser", "--surface", surfaceID, "screencast", "start"], expectedV2Methods: ["browser.screencast.start"]),
            .init("browser input", arguments: ["browser", "--surface", surfaceID, "input", "mouse", "click"], expectedV2Methods: ["browser.input_mouse"]),
            .init("legacy open-browser", arguments: ["open-browser", "https://example.com"], expectedV2Methods: ["browser.open_split"]),
            .init("legacy navigate", arguments: ["navigate", "--surface", surfaceID, "https://example.com"], expectedV2Methods: ["browser.navigate"]),
            .init("legacy browser-back", arguments: ["browser-back", "--surface", surfaceID], expectedV2Methods: ["browser.back"]),
            .init("markdown", arguments: ["markdown", "open", markdownURL.path, "--workspace", workspaceID, "--surface", surfaceID], expectedV2Methods: ["markdown.open"]),
        ]

        var baseEnvironment = ProcessInfo.processInfo.environment
        baseEnvironment["CMUX_WORKSPACE_ID"] = workspaceID
        baseEnvironment["CMUX_SURFACE_ID"] = surfaceID
        baseEnvironment["CMUX_TAB_ID"] = surfaceID
        baseEnvironment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        baseEnvironment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        baseEnvironment["CODEX_THREAD_ID"] = "cli-command-surface-tests"
        baseEnvironment["HOME"] = rootURL.path

        for testCase in cases {
            let socketPath = makeSocketPath(testCase.name)
            let listenerFD = try bindUnixSocket(at: socketPath)
            let state = MockSocketServerState()
            var environment = baseEnvironment
            environment["CMUX_SOCKET_PATH"] = socketPath

            defer {
                Darwin.close(listenerFD)
                unlink(socketPath)
            }

            let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
                self.cliCommandSurfaceResponse(
                    line,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    paneID: paneID,
                    secondPaneID: secondPaneID,
                    windowID: windowID
                )
            }

            let result = runProcess(
                executablePath: cliPath,
                arguments: testCase.arguments,
                environment: environment,
                standardInput: testCase.standardInput,
                timeout: 5
            )
            wait(for: [serverHandled], timeout: 5)

            XCTAssertFalse(result.timedOut, "\(testCase.name) timed out\nstderr:\(result.stderr)")
            XCTAssertEqual(result.status, 0, "\(testCase.name) failed\nstdout:\(result.stdout)\nstderr:\(result.stderr)\ncommands:\(state.commands)")
            XCTAssertTrue(result.stderr.isEmpty, "\(testCase.name) wrote stderr: \(result.stderr)")

            let v2Methods = state.commands.compactMap { line -> String? in
                self.jsonObject(line)?["method"] as? String
            }
            for method in testCase.expectedV2Methods {
                XCTAssertTrue(
                    v2Methods.contains(method),
                    "\(testCase.name) did not send v2 method \(method); saw \(v2Methods) commands=\(state.commands)"
                )
            }
            for prefix in testCase.expectedV1Prefixes {
                XCTAssertTrue(
                    state.commands.contains { $0.hasPrefix(prefix) },
                    "\(testCase.name) did not send v1 command prefix \(prefix); saw \(state.commands)"
                )
            }
        }
    }

    private func runCLIHelp(cliPath: String, arguments: [String]) -> ProcessRunResult {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "CMUX_SOCKET_PATH")
        environment.removeValue(forKey: "CMUX_SOCKET")
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 5
        )
    }

    private func cliCommandSurfaceResponse(
        _ line: String,
        workspaceID: String,
        surfaceID: String,
        paneID: String,
        secondPaneID: String,
        windowID: String
    ) -> String {
        guard let payload = jsonObject(line),
              let id = payload["id"] as? String,
              let method = payload["method"] as? String else {
            return cliCommandSurfaceV1Response(line, workspaceID: workspaceID, windowID: windowID)
        }

        return v2Response(
            id: id,
            ok: true,
            result: cliCommandSurfaceV2Result(
                method: method,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                paneID: paneID,
                secondPaneID: secondPaneID,
                windowID: windowID
            )
        )
    }

    private func cliCommandSurfaceV1Response(_ line: String, workspaceID: String, windowID: String) -> String {
        if line.hasPrefix("list_windows") {
            return "*0: \(windowID) selected_workspace=\(workspaceID) workspaces=1"
        }
        if line.hasPrefix("current_window") {
            return windowID
        }
        if line.hasPrefix("list_notifications") {
            return "No notifications"
        }
        return "OK"
    }

    private func cliCommandSurfaceV2Result(
        method: String,
        workspaceID: String,
        surfaceID: String,
        paneID: String,
        secondPaneID: String,
        windowID: String
    ) -> [String: Any] {
        let window: [String: Any] = [
            "id": windowID,
            "ref": "window:1",
            "window_id": windowID,
            "window_ref": "window:1",
            "index": 0,
            "selected_workspace_id": workspaceID,
            "selected_workspace_ref": "workspace:1",
            "workspace_count": 1,
        ]
        let workspace: [String: Any] = [
            "id": workspaceID,
            "ref": "workspace:1",
            "workspace_id": workspaceID,
            "workspace_ref": "workspace:1",
            "window_id": windowID,
            "window_ref": "window:1",
            "index": 0,
            "title": "Scratch",
            "selected": true,
        ]
        let pane: [String: Any] = [
            "id": paneID,
            "ref": "pane:1",
            "pane_id": paneID,
            "pane_ref": "pane:1",
            "workspace_id": workspaceID,
            "workspace_ref": "workspace:1",
            "index": 0,
            "focused": true,
            "surface_count": 1,
            "x": 0,
            "y": 0,
            "width": 800,
            "height": 600,
        ]
        let secondPane: [String: Any] = [
            "id": secondPaneID,
            "ref": "pane:2",
            "pane_id": secondPaneID,
            "pane_ref": "pane:2",
            "workspace_id": workspaceID,
            "workspace_ref": "workspace:1",
            "index": 1,
            "focused": false,
            "surface_count": 1,
            "x": 800,
            "y": 0,
            "width": 800,
            "height": 600,
        ]
        let surface: [String: Any] = [
            "id": surfaceID,
            "ref": "surface:1",
            "surface_id": surfaceID,
            "surface_ref": "surface:1",
            "tab_id": surfaceID,
            "tab_ref": "tab:1",
            "pane_id": paneID,
            "pane_ref": "pane:1",
            "workspace_id": workspaceID,
            "workspace_ref": "workspace:1",
            "window_id": windowID,
            "window_ref": "window:1",
            "index": 0,
            "title": "Terminal",
            "selected": true,
            "focused": true,
            "type": "terminal",
        ]

        var base: [String: Any] = [
            "ok": true,
            "id": "ok",
            "window_id": windowID,
            "window_ref": "window:1",
            "workspace_id": workspaceID,
            "workspace_ref": "workspace:1",
            "pane_id": paneID,
            "pane_ref": "pane:1",
            "surface_id": surfaceID,
            "surface_ref": "surface:1",
            "tab_id": surfaceID,
            "tab_ref": "tab:1",
            "created_surface_id": surfaceID,
            "created_surface_ref": "surface:1",
            "created_workspace_id": workspaceID,
            "created_workspace_ref": "workspace:1",
            "index": 0,
        ]

        switch method {
        case "auth.status":
            base["signed_in"] = false
            base["user"] = ["email": "dev@example.com"]
        case "vm.list":
            base["vms"] = []
        case "vm.create":
            base["id"] = "vm-test"
            base["provider"] = "e2b"
            base["image"] = "default"
        case "vm.ssh_info":
            base["host"] = "127.0.0.1"
            base["port"] = 2222
            base["username"] = "root"
            base["credential"] = ["kind": "password", "value": "secret"]
        case "vm.exec":
            base["stdout"] = "ran\n"
            base["stderr"] = ""
            base["exit_code"] = 0
        case "system.identify":
            base["focused"] = surface
            base["caller"] = surface
        case "system.capabilities":
            base["methods"] = ["system.identify", "workspace.list"]
        case "system.tree":
            base["windows"] = [
                window.merging(["workspaces": [workspace.merging(["panes": [pane.merging(["surfaces": [surface]])])])]) { _, new in new },
            ]
            base["active"] = surface
            base["caller"] = surface
        case "system.top":
            base["windows"] = [
                window.merging(["workspaces": [workspace.merging(["panes": [pane.merging(["surfaces": [surface]])])])]) { _, new in new },
            ]
            base["totals"] = ["windows": 1, "workspaces": 1, "panes": 1, "surfaces": 1]
        case "window.list":
            base["windows"] = [window]
        case "window.current":
            base["window_id"] = windowID
            base["window_ref"] = "window:1"
        case "workspace.list":
            base["workspaces"] = [workspace]
        case "workspace.current":
            base["workspace_id"] = workspaceID
            base["workspace_ref"] = "workspace:1"
        case "pane.list":
            base["panes"] = [pane, secondPane]
            base["container_frame"] = ["x": 0, "y": 0, "width": 1600, "height": 600]
        case "pane.surfaces", "surface.list":
            base["surfaces"] = [surface]
        case "surface.current":
            base["surface_id"] = surfaceID
            base["surface_ref"] = "surface:1"
        case "surface.read_text":
            base["text"] = "screen text\n"
        case "debug.terminals":
            base["terminals"] = [surface.merging(["tty": "ttys001", "index": 0]) { _, new in new }]
        case "browser.url.get":
            base["url"] = "https://example.com"
        case "browser.get.title":
            base["title"] = "Example"
        case "browser.is_webview_focused":
            base["focused"] = true
        case "browser.profiles.list":
            base["profiles"] = [["id": "profile-default", "slug": "default", "name": "Default", "current": true]]
        case "browser.import.cookies":
            base["browser"] = "Chrome"
            base["imported_cookies"] = 1
            base["skipped_cookies"] = 0
            base["warnings"] = []
        case "browser.console.list":
            base["entries"] = []
        case "browser.errors.list":
            base["errors"] = []
        case "browser.network.requests":
            base["requests"] = []
        case "browser.download.wait":
            base["path"] = "/tmp/download.txt"
        case "browser.tab.list":
            base["tabs"] = [["index": 0, "url": "https://example.com", "title": "Example", "active": true]]
        case "feedback.submit":
            base["feedback_id"] = "feedback-test"
        case "markdown.open":
            base["path"] = "/tmp/notes.md"
        default:
            break
        }

        return base
    }
}
