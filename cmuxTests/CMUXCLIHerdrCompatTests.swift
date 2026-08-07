import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testHerdrCompatTranslatesCommandsAndPreservesChildExit() throws {
        let cliPath = try bundledCLIPath()
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-herdr-compat-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fakeHerdr = tempDirectory.appendingPathComponent("herdr")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\"\nexit \"${HERDR_TEST_EXIT:-0}\"\n".write(
            to: fakeHerdr,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHerdr.path)

        var environment = herdrCompatEnvironment(
            searchPath: tempDirectory.path,
            home: tempDirectory
        )
        environment["HERDR_TEST_EXIT"] = "23"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--json", "__herdr-compat", "status", "server"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 23, result.stdout)
        XCTAssertEqual(result.stdout, "status server --json\n")
    }

    @Test func testHerdrCompatAliasesAndUnknownCommand() throws {
        let cliPath = try bundledCLIPath()
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-herdr-aliases-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let fakeHerdr = tempDirectory.appendingPathComponent("herdr")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\"\n".write(to: fakeHerdr, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHerdr.path)

        let environment = herdrCompatEnvironment(
            searchPath: tempDirectory.path,
            home: tempDirectory
        )
        let cases: [([String], String)] = [
            (["--json", "__herdr-compat", "snapshot"], "api snapshot\n"),
            (["--json", "__herdr-compat", "list-workspaces"], "workspace list\n"),
            (["--json", "__herdr-compat", "list-tabs", "--workspace", "w1"], "tab list --workspace w1\n"),
            (["--json", "__herdr-compat", "list-panes"], "pane list\n"),
        ]
        for (arguments, expected) in cases {
            let result = runProcess(
                executablePath: cliPath,
                arguments: arguments,
                environment: environment,
                timeout: 5
            )
            XCTAssertFalse(result.timedOut, result.stdout)
            XCTAssertEqual(result.status, 0, result.stdout)
            XCTAssertEqual(result.stdout, expected)
        }

        let unknown = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "delete-everything"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(unknown.timedOut, unknown.diagnostics)
        XCTAssertEqual(unknown.status, 2, unknown.diagnostics)
        XCTAssertTrue(unknown.stderr.contains("delete-everything"), unknown.diagnostics)
        XCTAssertTrue(
            unknown.stderr.contains("status, snapshot, list-workspaces, list-tabs, list-panes"),
            unknown.diagnostics
        )

        try FileManager.default.removeItem(at: fakeHerdr)
        let help = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "--help"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(help.timedOut, help.stdout)
        XCTAssertEqual(help.status, 0, help.stdout)
        XCTAssertTrue(help.stdout.contains("Usage: cmux __herdr-compat"), help.stdout)
        XCTAssertTrue(
            help.stdout.contains("status, snapshot, list-workspaces, list-tabs, list-panes"),
            help.stdout
        )
    }

    @Test func testHerdrCompatSkipsDirectoryNamedLikeProviderOnPATH() throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-herdr-directory-\(UUID().uuidString)", isDirectory: true)
        let nonExecutableDirectory = root.appendingPathComponent("non-executable", isDirectory: true)
        let executableDirectory = root.appendingPathComponent("executable", isDirectory: true)
        try FileManager.default.createDirectory(
            at: nonExecutableDirectory.appendingPathComponent("herdr", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHerdr = executableDirectory.appendingPathComponent("herdr")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\"\n".write(to: fakeHerdr, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHerdr.path)

        let searchPath = "\(nonExecutableDirectory.path):\(executableDirectory.path)"
        let result = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "status"],
            environment: herdrCompatEnvironment(searchPath: searchPath, home: root),
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.stdout)
        XCTAssertEqual(result.status, 0, result.stdout)
        XCTAssertEqual(result.stdout, "status\n")
    }

    @Test(arguments: ["", ":/usr/bin"])
    func testHerdrCompatHonorsEmptyPATHComponentAsCurrentDirectory(searchPath: String) throws {
        let cliPath = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-herdr-current-directory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fakeHerdr = root.appendingPathComponent("herdr")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\"\n".write(to: fakeHerdr, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeHerdr.path)

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "status"],
            environment: herdrCompatEnvironment(searchPath: searchPath, home: root),
            currentDirectoryURL: root,
            timeout: 5
        )

        XCTAssertFalse(result.timedOut, result.diagnostics)
        XCTAssertEqual(result.status, 0, result.diagnostics)
        XCTAssertEqual(result.stdout, "status\n", result.diagnostics)
    }

    @Test func testHerdrCompatDiagnosticsUseSuppliedPATHAndRemainProviderNeutral() throws {
        let cliPath = try bundledCLIPath()
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-herdr-missing-\(UUID().uuidString)", isDirectory: true)
        let emptyBin = isolatedHome.appendingPathComponent("bin", isDirectory: true)
        let fallbackBin = isolatedHome.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallbackBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

        // General provider discovery searches this fallback under HOME. Compatibility
        // lookup promises the supplied PATH, so this decoy must remain undiscoverable.
        let fallbackHerdr = fallbackBin.appendingPathComponent("herdr")
        try "#!/bin/sh\nprintf 'fallback provider should not run\\n'\n".write(
            to: fallbackHerdr,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fallbackHerdr.path)

        let environment = herdrCompatEnvironment(
            searchPath: emptyBin.path,
            home: isolatedHome,
            locale: "fr"
        )

        let missing = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "status"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(missing.timedOut, missing.diagnostics)
        XCTAssertEqual(missing.status, 127, missing.diagnostics)
        XCTAssertTrue(
            missing.stderr.contains("Impossible de lancer la commande requise."),
            missing.diagnostics
        )
        XCTAssertFalse(missing.stderr.localizedStandardContains("herdr"), missing.diagnostics)
        XCTAssertFalse(missing.stderr.contains(isolatedHome.path), missing.diagnostics)

        let unknown = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "delete-everything"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(unknown.timedOut, unknown.diagnostics)
        XCTAssertEqual(unknown.status, 2, unknown.diagnostics)
        XCTAssertTrue(
            unknown.stderr.contains("Commande de compatibilité inconnue"),
            unknown.diagnostics
        )
        XCTAssertFalse(unknown.stderr.localizedStandardContains("herdr"), unknown.diagnostics)

        let help = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "--help"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(help.timedOut, help.stdout)
        XCTAssertEqual(help.status, 0, help.stdout)
        XCTAssertTrue(help.stdout.contains("Utilisation : cmux __herdr-compat"), help.stdout)
        XCTAssertTrue(help.stdout.contains("Commandes :"), help.stdout)
        XCTAssertFalse(help.stdout.contains("Usage:"), help.stdout)
    }

    private func herdrCompatEnvironment(
        searchPath: String,
        home: URL,
        locale: String = "en"
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") || key.hasPrefix("HERDR_") {
            environment.removeValue(forKey: key)
        }
        environment["PATH"] = searchPath
        environment["HOME"] = home.path
        environment["CFFIXED_USER_HOME"] = home.path
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["AppleLanguages"] = "(\(locale))"
        let posixLocale = locale == "fr" ? "fr_FR.UTF-8" : "en_US.UTF-8"
        environment["AppleLocale"] = locale == "fr" ? "fr_FR" : "en_US"
        environment["LANG"] = posixLocale
        environment["LC_ALL"] = posixLocale
        return environment
    }
}
