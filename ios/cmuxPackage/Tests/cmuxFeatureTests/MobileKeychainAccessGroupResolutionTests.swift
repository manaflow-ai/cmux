import Testing
@testable import cmuxFeature

@Suite
struct MobileKeychainAccessGroupPolicyTests {
    @Test
    func acceptsDevTagAndProductionGroups() {
        #expect(String.cmuxKeychainAccessGroup(from:
            "7WLXT3NR37.dev.cmux.ios.tflex"
        ) == "7WLXT3NR37.dev.cmux.ios.tflex")
        #expect(String.cmuxKeychainAccessGroup(from:
            "7WLXT3NR37.com.cmux.app"
        ) == "7WLXT3NR37.com.cmux.app")
    }

    @Test
    func trimsWhitespaceAroundAValidGroup() {
        #expect(String.cmuxKeychainAccessGroup(from:
            " 7WLXT3NR37.dev.cmux.app.beta\n"
        ) == "7WLXT3NR37.dev.cmux.app.beta")
    }

    @Test
    func rejectsPrefixLessNilAndMalformedValues() {
        #expect(String.cmuxKeychainAccessGroup(from: "dev.cmux.app.beta") == nil)
        #expect(String.cmuxKeychainAccessGroup(from: nil) == nil)
        #expect(String.cmuxKeychainAccessGroup(from: "") == nil)
        #expect(String.cmuxKeychainAccessGroup(from: ".dev.cmux.app.beta") == nil)
        #expect(String.cmuxKeychainAccessGroup(from:
            "$(AppIdentifierPrefix)dev.cmux.app.beta"
        ) == nil)
    }

    @Test
    func rejectsEmptyBundleComponentsAfterTheTeamIdentifier() {
        // An empty interior or trailing component is a bake gone wrong, not a
        // grantable group; it must fall back rather than resolve.
        #expect(String.cmuxKeychainAccessGroup(from: "7WLXT3NR37..dev") == nil)
        #expect(String.cmuxKeychainAccessGroup(from: "7WLXT3NR37.dev.") == nil)
        #expect(String.cmuxKeychainAccessGroup(from:
            "7WLXT3NR37.dev..cmux.app.beta"
        ) == nil)
    }
}
