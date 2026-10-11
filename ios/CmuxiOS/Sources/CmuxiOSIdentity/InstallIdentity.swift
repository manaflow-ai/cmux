import CMUXMobileCore
public import CmuxInstallAuthCore
public import Foundation
import Security

/// The iPhone's install principal for the API Worker. One owner for every
/// account change (an actor, so sign-in, sign-out and switches apply in
/// order). Each Stack user has its own InstallAuthClient; the (user, install)
/// record lives in the Keychain next to the key, so a background launch or a
/// sign-out cleanup can mint a token without a Stack session.
public actor InstallIdentity {
    private let baseURL: URL
    private let signer: SecureEnclaveInstallSigner
    private let records: InstallRecordStore
    private let deviceName: String
    private let clientVersion: String?
    private var clients: [String: InstallAuthClient] = [:]
    public private(set) var current: String?
    /// Set while the owner refuses this app as too old; nil otherwise.
    public private(set) var updateRequired: ClientUpdateRequired?
    private var onUpdateRequired: (@Sendable (ClientUpdateRequired?) async -> Void)?

    /// - Parameter clientVersion: sent as `x-cmux-client-version`; defaults
    ///   to the app's `CFBundleShortVersionString`.
    public init(baseURL: URL, bundleID: String, deviceName: String,
                clientVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) {
        self.baseURL = baseURL
        let host = baseURL.host ?? "unknown"
        signer = SecureEnclaveInstallSigner(bundleID: bundleID, environment: host)
        records = InstallRecordStore(service: "\(bundleID).install-record.\(host)")
        self.deviceName = deviceName
        self.clientVersion = clientVersion
    }

    /// Called with the minimum version when the owner starts refusing this
    /// app as too old, and with nil when a later mint succeeds (the team
    /// lowered its minimum). Called only on a change.
    public func observeUpdateRequired(_ handler: @escaping @Sendable (ClientUpdateRequired?) async -> Void) async {
        onUpdateRequired = handler
        if let updateRequired { await handler(updateRequired) }
    }

    /// At launch, before auth restores: bind the last signed-in user so a
    /// background banner answer can act as the install.
    public func restoreLast() {
        guard current == nil, let last = records.lastUser() else { return }
        current = last
    }

    /// The signed-in user. Returns the previous user when the account changed
    /// (the caller cleans up its push target first).
    public func signedIn(stackUser: String, sessionToken: @escaping InstallAuthClient.SessionToken) -> String? {
        let previous = current
        current = stackUser
        records.setLastUser(stackUser)
        clients[stackUser] = makeClient(stackUser, session: sessionToken)
        return previous == stackUser ? nil : previous
    }

    /// Sign-out of one user; a no-op when another user is current now.
    public func signedOut(of stackUser: String) async {
        await clients[stackUser]?.reset()
        clients[stackUser] = nil
        if current == stackUser {
            current = nil
            records.setLastUser(nil)
            // The refusal was the signed-out team's policy; the next account's
            // first mint decides again.
            if updateRequired != nil { await setUpdateRequired(nil) }
        }
    }

    /// Revokes `stackUser`'s install with its Stack session (sign-out), then
    /// forgets it. Throws when the session is gone; the caller logs and continues.
    public func revoke(_ stackUser: String) async throws {
        try await client(for: stackUser).revoke()
        await signedOut(of: stackUser)
    }

    /// A valid install token for `stackUser` (default: the current user).
    public func token(for stackUser: String? = nil) async throws -> String {
        guard let user = stackUser ?? current else { throw InstallAuthError.noSession }
        return try await mint(client(for: user))
    }

    /// The current user's owner ids, backend environment and host, with the
    /// install token minted for them (one actor step, so an account switch
    /// cannot pair one user's ids with another's token). For requests the
    /// install key signs, such as presence-key registration.
    public func ownerInstall() async throws
        -> (user: String, install: String, environment: String, host: String, token: String) {
        guard let user = current else { throw InstallAuthError.noSession }
        let client = client(for: user)
        let token = try await mint(client)
        guard let record = await client.currentRecord, let environment = await client.environment else {
            throw InstallAuthError.noSession
        }
        return (record.user, record.install, environment, baseURL.host ?? "unknown", token)
    }

    /// ES256 with this device's install key (raw r||s or DER).
    public func signWithInstallKey(_ message: Data) async throws -> Data {
        try await signer.sign(message)
    }

    /// POSTs `json` to the API Worker with `bearer` (and the client version).
    public func post(_ path: String, json: Data, bearer: String) async throws -> (status: Int, body: Data) {
        try await CredentialedTransport(baseURL: baseURL).post(path, json: json, bearer: bearer,
                                                              headers: InstallAuthClient.headers(clientVersion: clientVersion))
    }

    /// One mint; a too-old refusal (or the first success after one) is
    /// reported to the observer before the result returns.
    private func mint(_ client: InstallAuthClient) async throws -> String {
        do {
            let token = try await client.installToken()
            if updateRequired != nil { await setUpdateRequired(nil) }
            return token
        } catch InstallAuthError.clientTooOld(let minimum) {
            let required = ClientUpdateRequired(minimumVersion: minimum)
            if updateRequired != required { await setUpdateRequired(required) }
            throw InstallAuthError.clientTooOld(minimumVersion: minimum)
        }
    }

    private func setUpdateRequired(_ value: ClientUpdateRequired?) async {
        updateRequired = value
        await onUpdateRequired?(value)
    }

    /// The owner refused the token (401): mint again next time.
    public func invalidate(for stackUser: String? = nil) async {
        guard let user = stackUser ?? current else { return }
        await clients[user]?.invalidate()
    }

    private func client(for user: String) -> InstallAuthClient {
        if let existing = clients[user] { return existing }
        // No session here (background or cleanup): only an existing record can mint.
        let made = makeClient(user, session: nil)
        clients[user] = made
        return made
    }

    private func makeClient(_ user: String, session: InstallAuthClient.SessionToken?) -> InstallAuthClient {
        let records = self.records
        return InstallAuthClient(transport: CredentialedTransport(baseURL: baseURL), signer: signer,
                                 sessionToken: session, stackUser: user,
                                 deviceName: deviceName, clientVersion: clientVersion, record: records.record(for: user),
                                 onRecord: { records.setRecord($0, for: user) })
    }
}

/// The owner refuses this app version for the signed-in team
/// (`client.too_old`); the user must update the app.
public struct ClientUpdateRequired: Hashable, Sendable {
    /// The team's `updates.minimumVersion`, when the owner named it.
    public let minimumVersion: String?

    public init(minimumVersion: String?) {
        self.minimumVersion = minimumVersion
    }
}

/// (user, install) records and the last signed-in user, in the Keychain
/// (this device only, after first unlock). Identifiers only; no secrets.
struct InstallRecordStore: Sendable {
    let service: String

    func record(for user: String) -> InstallRecord? {
        read("record.\(user)").flatMap { try? JSONDecoder().decode(InstallRecord.self, from: $0) }
    }

    func setRecord(_ record: InstallRecord?, for user: String) {
        write("record.\(user)", record.flatMap { try? JSONEncoder().encode($0) })
    }

    func lastUser() -> String? { read("last-user").map { String(decoding: $0, as: UTF8.self) } }
    func setLastUser(_ user: String?) { write("last-user", user.map { Data($0.utf8) }) }

    private func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    private func read(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }

    private func write(_ account: String, _ data: Data?) {
        SecItemDelete(base(account) as CFDictionary)
        guard let data else { return }
        var query = base(account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }
}

/// POSTs over the redirect-refusing credentialed session.
struct CredentialedTransport: InstallAuthTransport {
    let baseURL: URL
    private let session = CmxCredentialedHTTPSession()

    func post(_ path: String, json: Data, bearer: String?, headers: [String: String]) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.drop(while: { $0 == "/" }))))
        request.httpMethod = "POST"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        request.httpBody = json
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}
