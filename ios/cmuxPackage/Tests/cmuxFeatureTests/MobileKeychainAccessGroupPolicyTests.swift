import Foundation
import Testing
@testable import cmuxFeature

/// The auth composition shares the same policy, so both keychain consumers
/// accept and reject identically.
@Suite
struct MobileKeychainAccessGroupPolicyTests {
    @Test
    func acceptsDevTagAndProductionGroups() {
        #expect(MobileKeychainAccessGroupPolicy.resolve(
            "7WLXT3NR37.dev.cmux.ios.tflex"
        ) == "7WLXT3NR37.dev.cmux.ios.tflex")
        #expect(MobileKeychainAccessGroupPolicy.resolve(
            "7WLXT3NR37.com.cmux.app"
        ) == "7WLXT3NR37.com.cmux.app")
    }

    @Test
    func trimsWhitespaceAroundAValidGroup() {
        #expect(MobileKeychainAccessGroupPolicy.resolve(
            " 7WLXT3NR37.dev.cmux.app.beta\n"
        ) == "7WLXT3NR37.dev.cmux.app.beta")
    }

    @Test
    func rejectsPrefixLessNilAndMalformedValues() {
        #expect(MobileKeychainAccessGroupPolicy.resolve("dev.cmux.app.beta") == nil)
        #expect(MobileKeychainAccessGroupPolicy.resolve(nil) == nil)
        #expect(MobileKeychainAccessGroupPolicy.resolve("") == nil)
        #expect(MobileKeychainAccessGroupPolicy.resolve(".dev.cmux.app.beta") == nil)
        #expect(MobileKeychainAccessGroupPolicy.resolve(
            "$(AppIdentifierPrefix)dev.cmux.app.beta"
        ) == nil)
    }

    @Test
    func rejectsEmptyBundleComponentsAfterTheTeamIdentifier() {
        // An empty interior or trailing component is a bake gone wrong, not a
        // grantable group; it must fall back rather than resolve.
        #expect(MobileKeychainAccessGroupPolicy.resolve("7WLXT3NR37..dev") == nil)
        #expect(MobileKeychainAccessGroupPolicy.resolve("7WLXT3NR37.dev.") == nil)
        #expect(MobileKeychainAccessGroupPolicy.resolve(
            "7WLXT3NR37.dev..cmux.app.beta"
        ) == nil)
    }
}
