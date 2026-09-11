import Testing

@Suite struct CLIChildEnvironmentTests {
    @Test
    func scrubbedChildStillGetsItsOwnConfigurationRoots() {
        let normalizer = CLIChildEnvironment(appHostEnvironment: ["CMUX_APP_HOST_ISOLATION_REQUIRED": "1"])
        let child = normalizer.normalizing([
            "HOME": "/tmp/cli-fixture",
            "CFFIXED_USER_HOME": "/tmp/shared-app-host",
            "XDG_CONFIG_HOME": "/tmp/shared-app-host/.config",
        ])
        #expect(child["CFFIXED_USER_HOME"] == "/tmp/cli-fixture")
        #expect(child["XDG_CONFIG_HOME"] == "/tmp/cli-fixture/.config")
        #expect(child["CMUX_APP_HOST_ISOLATION_REQUIRED"] == nil)
    }

    @Test
    func localRunsPreserveExplicitConfigurationRoots() {
        let child = ["HOME": "/tmp/local", "CFFIXED_USER_HOME": "/tmp/explicit"]
        #expect(CLIChildEnvironment(appHostEnvironment: [:]).normalizing(child) == child)
    }

    @Test(arguments: ["", "  "])
    func missingChildHomeDoesNotInventAConfigurationRoot(home: String) {
        let normalizer = CLIChildEnvironment(appHostEnvironment: ["CMUX_APP_HOST_ISOLATION_REQUIRED": "1"])
        let child = ["HOME": home, "CFFIXED_USER_HOME": "/tmp/app-host"]
        #expect(normalizer.normalizing(child) == child)
    }
}
