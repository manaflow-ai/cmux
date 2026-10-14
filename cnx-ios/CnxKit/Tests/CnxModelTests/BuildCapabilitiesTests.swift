import CnxModel
import Testing

@Suite struct BuildCapabilitiesTests {
    @Test func pushOnlyWhenTheBuildSaysYes() {
        #expect(BuildCapabilities(info: ["CNXPush": "YES"]).push)
        #expect(!BuildCapabilities(info: ["CNXPush": "NO"]).push)
        #expect(!BuildCapabilities(info: ["CNXPush": ""]).push)
        #expect(!BuildCapabilities(info: [:]).push)
    }
}
