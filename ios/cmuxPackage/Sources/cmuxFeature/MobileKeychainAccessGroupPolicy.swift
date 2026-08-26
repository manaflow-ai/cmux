import Foundation

/// Resolves the keychain access group baked into Info.plist as
/// `CMUXKeychainAccessGroup` from `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`.
///
/// An archive built with code signing disabled expands `$(AppIdentifierPrefix)`
/// to an empty string, baking a team-prefix-less group. The signed
/// entitlements grant only `TEAMID.bundle-id`, so requesting the prefix-less
/// group makes every SecItem call fail with errSecMissingEntitlement before a
/// single broker fetch. Resolving such a value to nil leaves
/// kSecAttrAccessGroup unset, and SecItem then uses the app's default
/// entitlement access group, which is the group the signature actually grants.
enum MobileKeychainAccessGroupPolicy {
    static func resolve(_ raw: String?) -> String? {
        guard
            let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            !value.contains("$(")
        else { return nil }
        let components = value.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        guard
            components.count > 1,
            let team = components.first,
            team.count == 10,
            team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
            components.dropFirst().allSatisfy({ !$0.isEmpty })
        else { return nil }
        return value
    }
}
