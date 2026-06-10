import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Auth environment")
struct AuthEnvironmentTests {
    @Test("debug callback scheme uses sanitized tag")
    func debugCallbackSchemeUsesSanitizedTag() {
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "Safari Auth!"],
                bundleIdentifier: "com.cmuxterm.app.debug.safari-auth",
                isDebugBuild: true
            ) == "cmux-dev-safari-auth"
        )
    }

    @Test("release callback scheme ignores ambient tag")
    func releaseCallbackSchemeIgnoresAmbientTag() {
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false
            ) == "cmux"
        )
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app.nightly",
                isDebugBuild: false
            ) == "cmux-nightly"
        )
    }

    @Test("sign-in URL enters native wrapper")
    func signInURLEntersNativeWrapper() {
        let url = AuthEnvironment.signInURL(callbackState: "state-1")
        #expect(url.path == "/handler/native-sign-in")
        #expect(url.query?.contains("after_auth_return_to=") == true)
    }
}
