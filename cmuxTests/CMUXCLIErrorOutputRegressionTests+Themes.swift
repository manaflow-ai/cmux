import CmuxSocketControl
import Darwin
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Themes set and interactive themes reload
extension CMUXCLIErrorOutputRegressionTests {
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

}
