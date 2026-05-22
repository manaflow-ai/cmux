import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CMUXCLIErrorOutputRegressionTests: XCTestCase {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let timedOut: Bool
    }

    func testCLIErrorPathDoesNotCrashWhenStderrIsClosed() throws {
        let cliPath = try bundledCLIPath()
        let result = runShell(
            "CMUX_CLI_SENTRY_DISABLED=1 \(shellSingleQuote(cliPath)) definitely-not-a-command 2>&-",
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 1, result.stdout)
        XCTAssertTrue(result.stdout.contains("Usage:"), result.stdout)
    }

    func testAgentTeamsHelpDoesNotLaunchExternalAgentCLI() throws {
        let cliPath = try bundledCLIPath()
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["PATH"] = "/usr/bin:/bin"

        for command in ["claude-teams", "codex-teams"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: [command, "--help"],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stdout)
            XCTAssertEqual(result.status, 0, result.stdout)
            XCTAssertTrue(result.stdout.contains("Usage: cmux \(command)"), result.stdout)
            XCTAssertFalse(result.stdout.contains("Failed to launch"), result.stdout)
        }
    }

    func testBundledCLIInTaggedDebugAppPrefersItsOwnSocketWithoutEnvironmentOverride() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-socket-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let stableSocketURL = try stableSocketURL()

        if FileManager.default.fileExists(atPath: stableSocketURL.path) {
            throw XCTSkip("Stable cmux socket already exists at \(stableSocketURL.path)")
        }

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

    func testBundledCLISkipsIdentifierlessNestedAppWhenResolvingTaggedSocket() throws {
        let cliPath = try bundledCLIPath()
        let tagSlug = "cli-nested-\(UUID().uuidString.lowercased())"
        let taggedSocketPath = "/tmp/cmux-debug-\(tagSlug).sock"
        let stableSocketURL = try stableSocketURL()

        if FileManager.default.fileExists(atPath: stableSocketURL.path) {
            throw XCTSkip("Stable cmux socket already exists at \(stableSocketURL.path)")
        }

        let stableResponder = try UnixSocketResponder(path: stableSocketURL.path, response: "STABLE")
        defer { stableResponder.stop() }
        let taggedResponder = try UnixSocketResponder(path: taggedSocketPath, response: "TAGGED")
        defer { taggedResponder.stop() }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: tagSlug,
            nestedIdentifierlessApp: true
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: fakeCLIPath,
            arguments: ["ping"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(
            result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "TAGGED",
            result.stdout
        )
    }

    func testThemesSetReloadsRunningAppAfterEveryThemeWrite() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-socket-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)
        try writeTheme(named: "Theme B", background: "#f8f8f8", to: themesURL)
        try writeTheme(named: "Theme C", background: "#003b49", to: themesURL)

        let socketPath = "/tmp/cmux-theme-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }
        let bundleIdentifier = "com.cmuxterm.app.debug.issue-4355-test"
        let reloadExpectation = expectation(description: "cmux themes set posts final reload notifications")
        reloadExpectation.expectedFulfillmentCount = 3
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == bundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            notificationLock.lock()
            observedReloads.append((bundleIdentifier: observedBundleIdentifier, phase: observedPhase))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let configURL = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)

        var observedThemeValues: [String] = []
        for themeName in ["Theme A", "Theme B", "Theme C"] {
            let result = runProcess(
                executablePath: cliPath,
                arguments: ["themes", "set", themeName],
                environment: environment,
                timeout: 5
            )

            XCTAssertFalse(result.timedOut, result.stdout)
            XCTAssertEqual(result.status, 0, result.stdout)
            observedThemeValues.append(try managedThemeValue(in: configURL))
        }
        wait(for: [reloadExpectation], timeout: 5)

        XCTAssertEqual(observedThemeValues, [
            "light:Theme A,dark:Theme A",
            "light:Theme B,dark:Theme B",
            "light:Theme C,dark:Theme C",
        ])
        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, Array(repeating: bundleIdentifier, count: 3))
        XCTAssertEqual(reloads.map { $0.phase }, Array(repeating: "final", count: 3))
        XCTAssertEqual(responder.receivedRequests, [])
    }

    func testThemesSetTargetsResolvedTaggedSocketWhenBundleEnvironmentIsStale() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-stale-bundle-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)

        let socketPath = "/tmp/cmux-debug-active-theme.sock"
        let staleBundleIdentifier = "com.cmuxterm.app.debug.stale.theme"
        let targetBundleIdentifier = "com.cmuxterm.app.debug.active.theme"
        let reloadExpectation = expectation(description: "cmux themes set targets the resolved socket bundle")
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?, socketPath: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == targetBundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            let observedSocketPath = notification.userInfo?["socketPath"] as? String
            notificationLock.lock()
            observedReloads.append((
                bundleIdentifier: observedBundleIdentifier,
                phase: observedPhase,
                socketPath: observedSocketPath
            ))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_BUNDLE_ID"] = staleBundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        wait(for: [reloadExpectation], timeout: 5)

        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [targetBundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(reloads.map { $0.socketPath }, [socketPath])
        XCTAssertFalse(result.stdout.contains(staleBundleIdentifier), result.stdout)
        XCTAssertTrue(result.stdout.contains(targetBundleIdentifier), result.stdout)
    }

    func testThemesSetNightlyOverridePathIsReadableByNightlyAppConfigResolution() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-nightly-path-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let resourcesURL = root.appendingPathComponent("resources", isDirectory: true)
        let themesURL = resourcesURL.appendingPathComponent("themes", isDirectory: true)
        try fileManager.createDirectory(at: themesURL, withIntermediateDirectories: true)
        try writeTheme(named: "Theme A", background: "#101010", to: themesURL)

        let bundleIdentifier = "com.cmuxterm.app.nightly"
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["GHOSTTY_RESOURCES_DIR"] = resourcesURL.path
        environment["CMUX_SOCKET_PATH"] = "/tmp/cmux-nightly.sock"
        environment["CMUX_BUNDLE_ID"] = bundleIdentifier
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "themes", "set", "Theme A"],
            environment: environment,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)

        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any],
            result.stdout
        )
        let configPath = try XCTUnwrap(payload["config_path"] as? String, result.stdout)
        XCTAssertEqual(payload["reload_target_bundle_id"] as? String, bundleIdentifier)

        let appSupportDirectory = root
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let expectedConfigURL = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("config.ghostty", isDirectory: false)
        XCTAssertEqual(configPath, expectedConfigURL.path)

        let appReadablePaths = GhosttyApp.cmuxAppSupportConfigURLs(
            currentBundleIdentifier: bundleIdentifier,
            appSupportDirectory: appSupportDirectory
        ).map(\.path)
        XCTAssertEqual(appReadablePaths, [expectedConfigURL.path])
    }

    func testBareInteractiveThemesReloadsRunningAppAfterPickerExits() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-picker-socket-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "theme-picker-\(UUID().uuidString.lowercased())"
        )
        let fakeGhosttyHelperURL = URL(fileURLWithPath: fakeCLIPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ghostty", isDirectory: false)
        try """
        #!/usr/bin/env python3
        import os
        import sys
        import time

        deadline = time.time() + 2.0
        last_error = ""
        while time.time() < deadline:
            try:
                if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
                    sys.exit(0)
                last_error = f"pgrp={os.getpgrp()} tpgid={os.tcgetpgrp(0)}"
            except OSError as error:
                last_error = str(error)
            time.sleep(0.02)

        sys.stderr.write(f"theme picker was not foregrounded: {last_error}\\n")
        sys.exit(42)
        """.write(to: fakeGhosttyHelperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGhosttyHelperURL.path
        )

        let socketPath = "/tmp/cmux-theme-picker-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }
        let bundleIdentifier = "com.cmuxterm.app.debug.theme-picker.\(UUID().uuidString.lowercased())"
        let reloadExpectation = expectation(description: "bare cmux themes posts final reload notification")
        let notificationQueue = OperationQueue()
        notificationQueue.maxConcurrentOperationCount = 1
        let notificationLock = NSLock()
        var observedReloads: [(bundleIdentifier: String?, phase: String?)] = []
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.cmuxterm.themes.reload-config"),
            object: nil,
            queue: notificationQueue
        ) { notification in
            let observedBundleIdentifier = notification.userInfo?["bundleIdentifier"] as? String
            guard observedBundleIdentifier == bundleIdentifier else { return }
            let observedPhase = notification.userInfo?["phase"] as? String
            notificationLock.lock()
            observedReloads.append((bundleIdentifier: observedBundleIdentifier, phase: observedPhase))
            notificationLock.unlock()
            reloadExpectation.fulfill()
        }
        defer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }

        let command = [
            "env",
            "-i",
            "HOME=\(shellSingleQuote(root.path))",
            "CFFIXED_USER_HOME=\(shellSingleQuote(root.path))",
            "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath))",
            "CMUX_BUNDLE_ID=\(shellSingleQuote(bundleIdentifier))",
            "CMUX_CLI_SENTRY_DISABLED=1",
            "PATH=/usr/bin:/bin",
            "/usr/bin/script",
            "-q",
            "/dev/null",
            shellSingleQuote(fakeCLIPath),
            "themes",
        ].joined(separator: " ")
        let result = runShell(command, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        wait(for: [reloadExpectation], timeout: 5)
        notificationLock.lock()
        let reloads = observedReloads
        notificationLock.unlock()
        XCTAssertEqual(reloads.map { $0.bundleIdentifier }, [bundleIdentifier])
        XCTAssertEqual(reloads.map { $0.phase }, ["final"])
        XCTAssertEqual(responder.receivedRequests, [])
    }

    func testBareInteractiveThemesTreatsSigintAsSilentCancel() throws {
        let cliPath = try bundledCLIPath()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-themes-picker-cancel-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCLIPath = try fakeTaggedBundledCLIPath(
            sourceCLIPath: cliPath,
            tagSlug: "theme-picker-cancel-\(UUID().uuidString.lowercased())"
        )
        let fakeGhosttyHelperURL = URL(fileURLWithPath: fakeCLIPath)
            .deletingLastPathComponent()
            .appendingPathComponent("ghostty", isDirectory: false)
        try """
        #!/usr/bin/env python3
        import os
        import signal
        import sys
        import time

        deadline = time.time() + 2.0
        while time.time() < deadline:
            if os.isatty(0) and os.tcgetpgrp(0) == os.getpgrp():
                signal.signal(signal.SIGINT, signal.SIG_DFL)
                os.kill(os.getpid(), signal.SIGINT)
            time.sleep(0.02)
        sys.exit(42)
        """.write(to: fakeGhosttyHelperURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeGhosttyHelperURL.path
        )

        let socketPath = "/tmp/cmux-theme-picker-cancel-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socketPath, response: "OK")
        defer { responder.stop() }

        let command = [
            "env",
            "-i",
            "HOME=\(shellSingleQuote(root.path))",
            "CFFIXED_USER_HOME=\(shellSingleQuote(root.path))",
            "CMUX_SOCKET_PATH=\(shellSingleQuote(socketPath))",
            "CMUX_CLI_SENTRY_DISABLED=1",
            "PATH=/usr/bin:/bin",
            "/usr/bin/script",
            "-q",
            "/dev/null",
            shellSingleQuote(fakeCLIPath),
            "themes",
        ].joined(separator: " ")
        let result = runShell(command, timeout: 5)

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertFalse(result.stdout.contains("Interactive theme picker exited"), result.stdout)
        XCTAssertEqual(responder.receivedRequests, [])
    }

    func testBrowserDownloadWaitUsesRequestedTimeoutForSocketResponse() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 0.4)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
                "--timeout-ms",
                "1000",
            ],
            environment: environment,
            timeout: 3
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

    func testBrowserDownloadWaitDefaultTimeoutMatchesServerDefaultWindow() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-dw-\(UUID().uuidString.prefix(8)).sock"
        let response = #"{"ok":true,"result":{"downloaded":true}}"#
        let responder = try UnixSocketResponder(path: socketPath, response: response, responseDelay: 10.5)
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUXTERM_CLI_RESPONSE_TIMEOUT_SEC"] = "0.1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "browser",
                UUID().uuidString,
                "download",
                "wait",
            ],
            environment: environment,
            timeout: 16
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "OK")
    }

    private func bundledCLIPath() throws -> String {
        let fileManager = FileManager.default
        let appBundleURL = Bundle(for: Self.self)
            .bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let enumerator = fileManager.enumerator(at: appBundleURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])

        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "cmux",
                  item.path.contains(".app/Contents/Resources/bin/cmux") else {
                continue
            }
            return item.path
        }

        throw XCTSkip("Bundled cmux CLI not found in \(appBundleURL.path)")
    }

    private func stableSocketURL() throws -> URL {
        let appSupport = try XCTUnwrap(
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        )
        let directory = appSupport.appendingPathComponent("cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("cmux.sock", isDirectory: false)
    }

    private func writeTheme(named name: String, background: String, to directory: URL) throws {
        try """
        background = \(background)
        foreground = #eeeeee
        cursor-color = #ff00ff
        cursor-text = #000000
        """.write(
            to: directory.appendingPathComponent(name, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private func managedThemeValue(in configURL: URL) throws -> String {
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        let values = contents.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else {
                return nil
            }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return try XCTUnwrap(values.last)
    }

    private func fakeTaggedBundledCLIPath(
        sourceCLIPath: String,
        tagSlug: String,
        nestedIdentifierlessApp: Bool = false
    ) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-socket-\(UUID().uuidString)", isDirectory: true)
        let appURL = root.appendingPathComponent("cmux DEV \(tagSlug).app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let binURL: URL
        if nestedIdentifierlessApp {
            let nestedContentsURL = contentsURL
                .appendingPathComponent("Resources/NestedTool.app/Contents", isDirectory: true)
            binURL = nestedContentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
            let nestedInfoData = try PropertyListSerialization.data(
                fromPropertyList: [
                    "CFBundleName": "NestedTool",
                    "CFBundlePackageType": "APPL"
                ],
                format: .xml,
                options: 0
            )
            try FileManager.default.createDirectory(
                at: nestedContentsURL,
                withIntermediateDirectories: true
            )
            try nestedInfoData.write(to: nestedContentsURL.appendingPathComponent("Info.plist", isDirectory: false))
        } else {
            binURL = contentsURL.appendingPathComponent("Resources/bin", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.cmuxterm.app.debug.\(tagSlug.replacingOccurrences(of: "-", with: "."))",
            "CFBundleName": "cmux DEV \(tagSlug)",
            "CFBundlePackageType": "APPL"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))

        let fakeCLIURL = binURL.appendingPathComponent("cmux", isDirectory: false)
        try FileManager.default.copyItem(atPath: sourceCLIPath, toPath: fakeCLIURL.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeCLIURL.path
        )
        return fakeCLIURL.path
    }

    private func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func runShell(_ command: String, timeout: TimeInterval) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: String(describing: error), timedOut: false)
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if exitSignal.wait(timeout: .now() + 1) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = exitSignal.wait(timeout: .now() + 1)
            }
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}

private final class UnixSocketResponder {
    let path: String
    private let response: String
    private let responseDelay: TimeInterval
    private let queue = DispatchQueue(label: "com.cmux.tests.unix-socket-responder")
    private let lock = NSLock()
    private var stopped = false
    private var requests: [String] = []
    private var listenerFD: Int32 = -1

    init(path: String, response: String, responseDelay: TimeInterval = 0) throws {
        self.path = path
        self.response = response
        self.responseDelay = responseDelay

        unlink(path)
        listenerFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenerFD >= 0 else {
            throw Self.posixError("socket")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < maxLength else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(ENAMETOOLONG),
                userInfo: [NSLocalizedDescriptionKey: "Unix socket path is too long: \(path)"]
            )
        }
        path.withCString { pointer in
            withUnsafeMutablePointer(to: &address.sun_path) { tuplePointer in
                let buffer = UnsafeMutableRawPointer(tuplePointer).assumingMemoryBound(to: CChar.self)
                strncpy(buffer, pointer, maxLength - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketPointer in
                Darwin.bind(listenerFD, socketPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let error = Self.posixError("bind")
            close(listenerFD)
            listenerFD = -1
            throw error
        }
        guard listen(listenerFD, 8) == 0 else {
            let error = Self.posixError("listen")
            close(listenerFD)
            listenerFD = -1
            throw error
        }

        let fd = listenerFD
        queue.async { [weak self] in
            self?.acceptLoop(listenerFD: fd)
        }
    }

    deinit {
        stop()
    }

    var receivedRequests: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func stop() {
        lock.lock()
        guard !stopped else {
            lock.unlock()
            return
        }
        stopped = true
        let fd = listenerFD
        listenerFD = -1
        lock.unlock()

        if fd >= 0 {
            close(fd)
        }
        unlink(path)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop(listenerFD: Int32) {
        while !isStopped {
            let clientFD = accept(listenerFD, nil, nil)
            if clientFD < 0 {
                if isStopped {
                    return
                }
                continue
            }
            handle(clientFD: clientFD)
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        var request = Data()
        while true {
            var byte: UInt8 = 0
            let count = read(clientFD, &byte, 1)
            if count <= 0 {
                return
            }
            request.append(byte)
            if byte == 0x0A {
                break
            }
        }
        guard !request.isEmpty else {
            return
        }
        if let line = String(data: request, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            lock.lock()
            requests.append(line)
            lock.unlock()
        }
        if responseDelay > 0 {
            Thread.sleep(forTimeInterval: responseDelay)
        }
        let payload = response + "\n"
        payload.withCString { pointer in
            _ = write(clientFD, pointer, strlen(pointer))
        }
    }

    private static func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
