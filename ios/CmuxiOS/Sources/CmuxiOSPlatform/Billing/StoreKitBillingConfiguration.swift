import Foundation

/// Product identifiers are configuration, never credentials.  A release
/// build gets them from Info.plist (`CMUXStoreKitProductIDs`) or the build
/// environment (`CMUX_IOS_STOREKIT_PRODUCTS`, comma separated), which lets
/// App Store, TestFlight and development products use separate IDs.
public struct StoreKitBillingConfiguration: Hashable, Sendable {
    public static let maxProductCount = 16
    public static let maxProductIDLength = 128

    public let productIDs: [String]
    public let fallbackToMockWhenUnavailable: Bool

    public init(productIDs: [String], fallbackToMockWhenUnavailable: Bool = false) {
        var seen = Set<String>()
        var normalized: [String] = []
        for raw in productIDs {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= Self.maxProductIDLength,
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_" )).contains($0) }),
                  seen.insert(value).inserted else { continue }
            normalized.append(value)
            if normalized.count == Self.maxProductCount { break }
        }
        self.productIDs = normalized
        self.fallbackToMockWhenUnavailable = fallbackToMockWhenUnavailable
    }

    public static func fromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fallbackToMockWhenUnavailable: Bool = false
    ) -> Self {
        let fromEnvironment = environment["CMUX_IOS_STOREKIT_PRODUCTS"]
            .map { $0.split(separator: ",", omittingEmptySubsequences: true).map(String.init) } ?? []
        let fromInfo: [String]
        if let values = bundle.object(forInfoDictionaryKey: "CMUXStoreKitProductIDs") as? [String] {
            fromInfo = values
        } else if let value = bundle.object(forInfoDictionaryKey: "CMUXStoreKitProductIDs") as? String {
            fromInfo = value.split(separator: ",", omittingEmptySubsequences: true).map(String.init)
        } else {
            fromInfo = []
        }
        // An explicit launch environment is useful for simulator StoreKit
        // configuration and must win over the bundled channel defaults.
        return Self(productIDs: fromEnvironment.isEmpty ? fromInfo : fromEnvironment,
                    fallbackToMockWhenUnavailable: fallbackToMockWhenUnavailable)
    }
}
