#if DEBUG
public import CmuxAuthRuntime
import CMUXMobileCore
public import Foundation

/// DEBUG only: the dogfood launcher's proof that this install is signed in
/// (readiness mode `app-receipt-v1`, declared by the Info.plist key
/// `CMUXDogfoodReadiness`). After sign-in and one successful authenticated
/// API call, the app writes a receipt with no secrets into its data
/// container; the launcher copies it off the device and checks the nonce,
/// client id, bundle id and account.
public enum DogfoodReadinessReceipt {
    public static let relativePath = "Library/Application Support/cmux-dogfood/readiness.json"

    struct Body: Encodable {
        let schema = 1
        let nonce: String
        let client_id: String
        let bundle_id: String
        let dev_tag: String
        let git_sha: String
        let api_base_url: String
        let account_email: String
        let user_id: String
        let session_source: String
        let written_at: String
    }

    /// Writes the receipt when the launcher asked for one (env nonce present).
    /// Returns the file URL, or nil when no receipt was requested or the
    /// authenticated call failed (the gate then fails closed).
    @MainActor
    @discardableResult
    public static func writeIfRequested(
        coordinator: AuthCoordinator,
        apiBaseURL: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) async -> URL? {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(relativePath)
        // A receipt from an earlier launch must never answer this one.
        try? FileManager.default.removeItem(at: url)
        guard let nonce = environment["CMUX_DOGFOOD_READINESS_NONCE"], !nonce.isEmpty,
              coordinator.isAuthenticated, let user = coordinator.currentUser,
              let bundleID = bundle.bundleIdentifier else { return nil }
        guard await authenticatedCallSucceeds(coordinator: coordinator, apiBaseURL: apiBaseURL,
                                              bundleID: bundleID) else { return nil }
        let hasCredentials = !(environment["CMUX_UITEST_STACK_EMAIL"] ?? "").isEmpty
        let body = Body(
            nonce: nonce,
            client_id: environment["CMUX_DOGFOOD_CLIENT_ID"] ?? "",
            bundle_id: bundleID,
            dev_tag: bundle.object(forInfoDictionaryKey: "CMUXDevTag") as? String ?? "",
            git_sha: bundle.object(forInfoDictionaryKey: "CMUXGitSHA") as? String ?? "",
            api_base_url: apiBaseURL,
            account_email: (user.primaryEmail ?? "").lowercased(),
            user_id: user.id,
            session_source: hasCredentials ? "auto_login" : "restored",
            written_at: ISO8601DateFormatter().string(from: Date())
        )
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(body).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// One authenticated GET proves the stored token is valid on the server.
    private static func authenticatedCallSucceeds(
        coordinator: AuthCoordinator, apiBaseURL: String, bundleID: String
    ) async -> Bool {
        guard let token = try? await coordinator.accessToken(),
              let url = URL(string: apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/device-tokens")
        else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let refresh = await coordinator.refreshToken() {
            request.setValue(refresh, forHTTPHeaderField: "X-Stack-Refresh-Token")
        }
        request.setValue(bundleID, forHTTPHeaderField: "X-Cmux-App-Namespace")
        request.timeoutInterval = 15
        // The credentialed session refuses redirects, so the bearer and refresh
        // tokens never reach another origin.
        guard let (_, response) = try? await CmxCredentialedHTTPSession().data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
#endif
