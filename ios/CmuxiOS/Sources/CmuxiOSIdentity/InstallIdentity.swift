import CMUXMobileCore
public import CmuxInstallAuthCore
public import Foundation

/// The iPhone's install principal for the API Worker: an InstallAuthClient
/// bound to one signed-in Stack user, with the install binding kept per
/// (API origin, Stack user). The token stays in memory only.
public actor InstallIdentity {
    private let baseURL: URL
    private let signer: SecureEnclaveInstallSigner
    private let defaults: UserDefaults
    private var client: InstallAuthClient?
    private var stackUser: String?

    public init(baseURL: URL, bundleID: String, defaults: UserDefaults = .standard) {
        self.baseURL = baseURL
        signer = SecureEnclaveInstallSigner(bundleID: bundleID, environment: baseURL.host ?? "unknown")
        self.defaults = defaults
    }

    /// Binds to a signed-in user. `sessionToken` returns a Stack access token.
    public func signedIn(stackUser: String, deviceName: String,
                         sessionToken: @escaping InstallAuthClient.SessionToken) {
        guard stackUser != self.stackUser else { return }
        self.stackUser = stackUser
        let key = recordKey(stackUser)
        let record = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(InstallRecord.self, from: $0) }
        client = InstallAuthClient(transport: CredentialedTransport(baseURL: baseURL), signer: signer,
                                   sessionToken: sessionToken, deviceName: deviceName, record: record)
    }

    public func signedOut() async {
        await client?.reset()
        client = nil
        stackUser = nil
    }

    /// A valid install token (mints or refreshes as needed).
    public func token() async throws -> String {
        guard let client, let stackUser else { throw InstallAuthError.noSession }
        let value = try await client.installToken()
        if let record = await client.currentRecord, let data = try? JSONEncoder().encode(record) {
            defaults.set(data, forKey: recordKey(stackUser))
        }
        return value
    }

    private func recordKey(_ stackUser: String) -> String {
        "cmux.install.record.\(baseURL.host ?? "").\(stackUser)"
    }
}

/// POSTs over the redirect-refusing credentialed session.
struct CredentialedTransport: InstallAuthTransport {
    let baseURL: URL
    private let session = CmxCredentialedHTTPSession()

    func post(_ path: String, json: Data, bearer: String?) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.drop(while: { $0 == "/" }))))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = json
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
