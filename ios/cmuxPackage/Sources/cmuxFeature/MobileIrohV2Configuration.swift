import CMUXMobileCore
import Foundation

/// Explicit backend and installed-build scope for the new IROH generation.
public struct MobileIrohV2Configuration: Sendable {
    public let baseURL: URL
    public let environment: String
    public let projectID: String
    public let appNamespace: String
    public let buildTag: String
    public let appVersion: String
    public let displayName: String
    public let stateDirectory: URL
    public let forceRelayOnly: Bool

    public init(baseURL: URL, environment: String, projectID: String,
                appNamespace: String, buildTag: String, appVersion: String,
                displayName: String, stateDirectory: URL, forceRelayOnly: Bool = false) {
        self.baseURL = baseURL
        self.environment = environment
        self.projectID = projectID
        self.appNamespace = appNamespace
        self.buildTag = buildTag
        self.appVersion = appVersion
        self.displayName = displayName
        self.stateDirectory = stateDirectory
        self.forceRelayOnly = forceRelayOnly
    }

    /// Resolves dedicated Worker origins independently of Stack sign-in's web origin.
    @MainActor
    public static func current(projectID: String, bundle: Bundle = .main,
                               environment values: [String: String] = ProcessInfo.processInfo.environment,
                               defaults: UserDefaults = .standard) -> Self {
        let namespace = bundle.bundleIdentifier ?? "dev.cmux.ios"
        let tag = MobileIOSBuildScope.current(infoDictionary: bundle.infoDictionary,
                                              bundleIdentifier: namespace)?.value ?? "default"
        #if DEBUG
        let defaultEnvironment = "development"
        #else
        let defaultEnvironment = namespace.contains("staging") ? "staging" : "production"
        #endif
        // Persist only explicitly supplied v2 overrides for env-less simulator relaunches.
        for key in ["CMUX_IROH_V2_ENVIRONMENT", "CMUX_IROH_V2_BASE_URL", "CMUX_IROH_V2_FORCE_RELAY"] {
            if let value = values[key] { defaults.set(value, forKey: "cmux.iroh.v2.config." + key) }
        }
        func override(_ key: String) -> String? {
            values[key] ?? defaults.string(forKey: "cmux.iroh.v2.config." + key)
                ?? bundle.object(forInfoDictionaryKey: key) as? String
        }
        let environment = override("CMUX_IROH_V2_ENVIRONMENT") ?? defaultEnvironment
        let origin: String
        switch environment {
        case "production": origin = "https://cmux-iroh-v2.cmux-presence-worker.workers.dev"
        case "staging": origin = "https://cmux-iroh-v2-staging.cmux-presence-worker.workers.dev"
        default: origin = "https://cmux-iroh-v2-development.cmux-presence-worker.workers.dev"
        }
        guard let url = URL(string: override("CMUX_IROH_V2_BASE_URL") ?? origin),
              url.scheme == "https", url.host != nil else {
            preconditionFailure("Invalid IROH v2 Worker origin")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Self(baseURL: url, environment: environment, projectID: projectID,
                    appNamespace: namespace, buildTag: tag,
                    appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
                    displayName: "iPhone", stateDirectory: support,
                    forceRelayOnly: override("CMUX_IROH_V2_FORCE_RELAY") == "1")
    }
}
