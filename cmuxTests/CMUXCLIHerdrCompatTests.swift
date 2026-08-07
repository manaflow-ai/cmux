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
        XCTAssertEqual(result.stdout, "status --json server\n")
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
        XCTAssertFalse(unknown.timedOut, unknown.stdout)
        XCTAssertEqual(unknown.status, 2, unknown.stdout)
        XCTAssertTrue(unknown.stdout.contains("delete-everything"), unknown.stdout)
        XCTAssertTrue(
            unknown.stdout.contains("status, snapshot, list-workspaces, list-tabs, list-panes"),
            unknown.stdout
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

    @Test func testHerdrCompatDiagnosticsAreProviderNeutralAndFrenchLocalized() throws {
        let cliPath = try bundledCLIPath()
        let isolatedHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-herdr-missing-\(UUID().uuidString)", isDirectory: true)
        let emptyBin = isolatedHome.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyBin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: isolatedHome) }

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
        XCTAssertFalse(missing.timedOut, missing.stdout)
        XCTAssertEqual(missing.status, 127, missing.stdout)
        XCTAssertTrue(missing.stdout.contains("Impossible de lancer la commande requise."), missing.stdout)
        XCTAssertFalse(missing.stdout.localizedStandardContains("herdr"), missing.stdout)
        XCTAssertFalse(missing.stdout.contains(isolatedHome.path), missing.stdout)

        let unknown = runProcess(
            executablePath: cliPath,
            arguments: ["__herdr-compat", "delete-everything"],
            environment: environment,
            timeout: 5
        )
        XCTAssertFalse(unknown.timedOut, unknown.stdout)
        XCTAssertEqual(unknown.status, 2, unknown.stdout)
        XCTAssertTrue(unknown.stdout.contains("Commande de compatibilité inconnue"), unknown.stdout)
        XCTAssertFalse(unknown.stdout.localizedStandardContains("herdr"), unknown.stdout)

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
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
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
