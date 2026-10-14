import CnxModel
import Testing

@Suite struct BuildCapabilitiesTests {
    @Test func pushOnlyWhenTheBuildSaysYes() {
        #expect(BuildCapabilities(info: ["CNXPush": "YES"]).push)
        #expect(!BuildCapabilities(info: ["CNXPush": "NO"]).push)
        #expect(!BuildCapabilities(info: ["CNXPush": ""]).push)
        #expect(!BuildCapabilities(info: [:]).push)
    }

    @Test func appleSignInOnlyWhenTheBuildSaysYes() {
        #expect(BuildCapabilities(info: ["CNXAppleSignIn": "YES"]).appleSignIn)
        #expect(!BuildCapabilities(info: ["CNXAppleSignIn": "NO"]).appleSignIn)
        #expect(!BuildCapabilities(info: ["CNXPush": "YES"]).appleSignIn)
        #expect(!BuildCapabilities(info: [:]).appleSignIn)
    }
}
