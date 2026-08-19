import Foundation
import Testing
@testable import cmuxFeature

/// `CMUXKeychainAccessGroup` is baked from
/// `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`. An unsigned archive
/// build expands the prefix to an empty string, and the signed entitlements
/// never grant that prefix-less group, so requesting it makes every SecItem
/// call fail with errSecMissingEntitlement and the transport dies before any
/// broker fetch. A value without a `TEAMID.` prefix must resolve to nil so
/// SecItem falls back to the app's default entitlement access group, which is
/// the exact group the re-signed entitlements grant.
@MainActor
@Suite
struct MobileKeychainAccessGroupResolutionTests {
    @Test
    func acceptsTeamPrefixedGroup() {
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: [
                "CMUXKeychainAccessGroup": "7WLXT3NR37.dev.cmux.app.internal",
            ]
        ) == "7WLXT3NR37.dev.cmux.app.internal")
    }

    @Test
    func rejectsPrefixLessGroupFromUnsignedArchiveBake() {
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: [
                "CMUXKeychainAccessGroup": "dev.cmux.app.internal",
            ]
        ) == nil)
    }

    @Test
    func rejectsUnexpandedEmptyAndAbsentValues() {
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: [
                "CMUXKeychainAccessGroup": "$(AppIdentifierPrefix)dev.cmux.app.internal",
            ]
        ) == nil)
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: ["CMUXKeychainAccessGroup": "  "]
        ) == nil)
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: nil
        ) == nil)
    }

    @Test
    func rejectsGroupWhoseFirstComponentIsNotATeamIdentifier() {
        // A ten-character first component must be uppercase alphanumeric to be
        // a team identifier; lowercase bundle-id-shaped values are bakes gone
        // wrong, not real groups.
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: [
                "CMUXKeychainAccessGroup": "abcdefghij.dev.cmux.app.internal",
            ]
        ) == nil)
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: ["CMUXKeychainAccessGroup": "7WLXT3NR37."]
        ) == nil)
        #expect(MobileIrohRuntimeComposition.keychainAccessGroup(
            infoDictionary: ["CMUXKeychainAccessGroup": "7WLXT3NR37"]
        ) == nil)
    }
}

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
