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
