import Testing
import Darwin
import Foundation

@Suite struct CLIChildEnvironmentTests {
    @Test
    func immediateChildExitIsObservedWithoutAWaitWorker() {
        let result = CLINotifyProcessIntegrationRegressionTests.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf ready; printf diagnostic >&2; exit 0"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 2
        )
        #expect(!result.timedOut)
        #expect(result.status == 0)
        #expect(result.stdout == "ready")
        #expect(result.stderr == "diagnostic")
    }

    @Test
    func runningChildIsTerminatedAtTheDeadline() {
        let result = CLINotifyProcessIntegrationRegressionTests.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf ready; exec /bin/sleep 30"],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: 0.5
        )
        #expect(result.timedOut)
        #expect(result.status == SIGTERM || result.status == SIGKILL)
        #expect(result.stdout == "ready")
    }

    @Test
    func scrubbedChildStillGetsItsOwnConfigurationRoots() {
        let normalizer = CLIChildEnvironment(
            appHostEnvironment: ["HOME": "/tmp/app-host", "CFFIXED_USER_HOME": "/tmp/app-host"]
        )
        let child = normalizer.normalizing([
            "HOME": "/tmp/cli-fixture",
            "CFFIXED_USER_HOME": "/tmp/shared-app-host",
            "XDG_CONFIG_HOME": "/tmp/shared-app-host/.config",
        ])
        #expect(child["CFFIXED_USER_HOME"] == "/tmp/cli-fixture")
        #expect(child["XDG_CONFIG_HOME"] == "/tmp/cli-fixture/.config")
        #expect(child["CMUX_APP_HOST_ISOLATION_REQUIRED"] == nil)
    }

    /// A fixture that points XDG_CONFIG_HOME inside its own home is testing
    /// that override; the isolated lane must not move it back to `.config`.
    @Test
    func aFixtureOwnedConfigurationRootIsKept() {
        let normalizer = CLIChildEnvironment(
            appHostEnvironment: ["HOME": "/tmp/app-host", "CFFIXED_USER_HOME": "/tmp/app-host"]
        )
        let child = normalizer.normalizing([
            "HOME": "/tmp/cli-fixture",
            "XDG_CONFIG_HOME": "/tmp/cli-fixture/xdg config",
        ])
        #expect(child["CFFIXED_USER_HOME"] == "/tmp/cli-fixture")
        #expect(child["XDG_CONFIG_HOME"] == "/tmp/cli-fixture/xdg config")
    }

    /// An app-host root nested in the fixture home is still the app host's.
    @Test
    func anInheritedHostRootNestedInTheHomeIsReplaced() {
        let normalizer = CLIChildEnvironment(
            appHostEnvironment: ["HOME": "/tmp/app-host", "CFFIXED_USER_HOME": "/tmp/app-host"]
        )
        let child = normalizer.normalizing([
            "HOME": "/tmp/cli-fixture",
            "CFFIXED_USER_HOME": "/tmp/cli-fixture/inherited-app-host",
            "XDG_CONFIG_HOME": "/tmp/cli-fixture/inherited-app-host/.config",
        ])
        #expect(child["CFFIXED_USER_HOME"] == "/tmp/cli-fixture")
        #expect(child["XDG_CONFIG_HOME"] == "/tmp/cli-fixture/.config")
    }

    /// An in-home symlink to a shared directory is not a fixture-owned root.
    @Test
    func anInHomeSymlinkToASharedRootIsReplaced() throws {
        let fileManager = FileManager.default
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("cli-child-env-\(UUID().uuidString)", isDirectory: true)
        let home = base.appendingPathComponent("home", isDirectory: true)
        let shared = base.appendingPathComponent("shared", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: base) }
        let link = home.appendingPathComponent("config-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: shared)

        let normalizer = CLIChildEnvironment(
            appHostEnvironment: ["HOME": "/tmp/app-host", "CFFIXED_USER_HOME": "/tmp/app-host"]
        )
        let child = normalizer.normalizing([
            "HOME": home.path,
            "XDG_CONFIG_HOME": link.appendingPathComponent("xdg", isDirectory: true).path,
        ])
        #expect(child["XDG_CONFIG_HOME"] == home.appendingPathComponent(".config", isDirectory: true).path)
    }

    @Test
    func anUnpinnedHostLeavesTheChildAlone() {
        // A stray CFFIXED_USER_HOME that does not match HOME is a developer's
        // machine, not an isolated lane: rewriting the child's roots there
        // would move a real person's configuration.
        let normalizer = CLIChildEnvironment(
            appHostEnvironment: ["HOME": "/Users/dev", "CFFIXED_USER_HOME": "/tmp/stray"]
        )
        let child = ["HOME": "/tmp/cli-fixture", "CFFIXED_USER_HOME": "/tmp/explicit"]
        #expect(normalizer.normalizing(child) == child)
    }

    @Test
    func localRunsPreserveExplicitConfigurationRoots() {
        let child = ["HOME": "/tmp/local", "CFFIXED_USER_HOME": "/tmp/explicit"]
        #expect(CLIChildEnvironment(appHostEnvironment: [:]).normalizing(child) == child)
    }

    @Test(arguments: ["", "  "])
    func missingChildHomeDoesNotInventAConfigurationRoot(home: String) {
        let normalizer = CLIChildEnvironment(
            appHostEnvironment: ["HOME": "/tmp/app-host", "CFFIXED_USER_HOME": "/tmp/app-host"]
        )
        let child = ["HOME": home, "CFFIXED_USER_HOME": "/tmp/app-host"]
        #expect(normalizer.normalizing(child) == child)
    }
}
