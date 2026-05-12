import CMUXAuthCore
import Foundation
import OSLog

private let environmentLog = Logger(subsystem: "ai.manaflow.cmux.ios", category: "environment")

enum AppEnvironment {
    case development
    case production

    private static let secureAPIBaseURL = "https://api.cmux.sh"
    private static let processEnvironment = ProcessInfo.processInfo.environment

    static var current: AppEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }

    nonisolated(unsafe) private static let localConfig: [String: Any]? = {
        guard let path = Bundle.main.path(forResource: "LocalConfig", ofType: "plist"),
              let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return nil
        }
        return dict
    }()

    private func localOverride(devKey: String, prodKey: String, legacyKey: String? = nil) -> String? {
        Self.stringOverride(
            devKey: devKey,
            prodKey: prodKey,
            legacyKey: legacyKey,
            environment: self,
            environmentVariables: Self.processEnvironment,
            localConfig: Self.localConfig
        )
    }

    var stackAuthConfig: CMUXAuthConfig {
        CMUXAuthConfig.resolve(
            environment: currentAuthEnvironment,
            overrides: localConfigStringOverrides,
            developmentProjectId: "454ecd03-1db2-4050-845e-4ce5b0cd9895",
            productionProjectId: "9790718f-14cd-4f7e-824d-eaf527a82b82",
            developmentPublishableClientKey: "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g",
            productionPublishableClientKey: "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"
        )
    }

    var stackAuthProjectId: String {
        stackAuthConfig.projectId
    }

    var stackAuthPublishableKey: String {
        stackAuthConfig.publishableClientKey
    }

    var apiBaseURL: String {
        let configuredValue = localOverride(
            devKey: "API_BASE_URL_DEV",
            prodKey: "API_BASE_URL_PROD",
            legacyKey: "API_BASE_URL"
        ) ?? defaultAPIBaseURL

        return Self.resolvedAPIBaseURL(
            candidate: configuredValue,
            environment: self,
            allowInsecureLocalOverride: Self.allowsInsecureLocalAPIBaseURL
        )
    }

    var name: String {
        switch self {
        case .development:
            return "Development"
        case .production:
            return "Production"
        }
    }

    private var currentAuthEnvironment: CMUXAuthEnvironment {
        switch self {
        case .development:
            return .development
        case .production:
            return .production
        }
    }

    private var localConfigStringOverrides: [String: String] {
        guard let localConfig = Self.localConfig else {
            return [:]
        }

        var overrides: [String: String] = [:]
        for (key, value) in localConfig {
            if let stringValue = value as? String, !stringValue.isEmpty {
                overrides[key] = stringValue
            }
        }
        return overrides
    }

    private var defaultAPIBaseURL: String {
        switch self {
        case .development:
            return "http://localhost:3000"
        case .production:
            return Self.secureAPIBaseURL
        }
    }

    private static var allowsInsecureLocalAPIBaseURL: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func resolvedAPIBaseURL(
        candidate: String,
        environment: AppEnvironment,
        allowInsecureLocalOverride: Bool
    ) -> String {
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased() else {
            return secureFallbackAPIBaseURL(for: environment)
        }

        #if DEBUG && !targetEnvironment(simulator)
        if let host = url.host?.lowercased(),
           host == "localhost" || host == "127.0.0.1" {
            environmentLog.warning("API base URL '\(candidate, privacy: .public)' uses localhost, unreachable from physical device. Run ./scripts/reload.sh to auto-detect Mac IP.")
        }
        #endif

        if scheme == "https" || allowInsecureLocalOverride {
            return candidate
        }

        environmentLog.info("Ignoring insecure API base URL on device: \(candidate, privacy: .public)")
        return secureFallbackAPIBaseURL(for: environment)
    }

    private static func secureFallbackAPIBaseURL(for environment: AppEnvironment) -> String {
        switch environment {
        case .development, .production:
            return secureAPIBaseURL
        }
    }

    static func stringOverride(
        devKey: String,
        prodKey: String,
        legacyKey: String? = nil,
        environment: AppEnvironment,
        environmentVariables: [String: String],
        localConfig: [String: Any]?
    ) -> String? {
        let environmentKey = environment == .development ? devKey : prodKey
        for key in [environmentKey, legacyKey].compactMap({ $0 }) {
            if let value = environmentVariables[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        for key in [environmentKey, legacyKey].compactMap({ $0 }) {
            if let value = (localConfig?[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
