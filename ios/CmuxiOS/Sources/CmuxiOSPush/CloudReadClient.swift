import CMUXMobileCore
public import CmuxFeedPushCore
public import Foundation

/// An agent's permission request the person's Mac posted to the feed
/// (cx-aocz): what the phone shows before an allow, and what it signs.
public struct FeedApproveRequest: Hashable, Sendable {
    public var item: String
    public var title: String
    public var shown: FeedApproveShownText
    /// The scopes the request offers (`once`, `session`).
    public var scopes: [String]
    /// The Mac that posted it (`context.host`), the install a proof names.
    public var macInstall: String
    public var isOpen: Bool

    /// From a `feed.get` item. Nil when it is not an approve request a Mac
    /// posted for an agent (no `context.host`): those keep the plain answer.
    public init?(item object: [String: Any]) {
        guard let id = object["id"] as? String, object["kind"] as? String == "approve",
              let host = (object["context"] as? [String: Any])?["host"] as? String, !host.isEmpty,
              let prompt = object["prompt"] as? [String: Any], let action = prompt["action"] as? [String: Any]
        else { return nil }
        item = id
        title = object["title"] as? String ?? ""
        shown = FeedApproveShownText(action: action)
        scopes = prompt["scopes"] as? [String] ?? ["once"]
        macInstall = host
        isOpen = object["state"] as? String == "open"
    }
}

/// Reads one feed item (`POST /v1/read feed.get`) as this install.
public protocol FeedItemReading: Sendable {
    func approveRequest(item: String) async throws -> FeedApproveRequest?
}

/// `/v1/read` with the install token; redirects are refused, as for ops.
public struct CloudReadClient: FeedItemReading {
    public let baseURL: URL
    public let tokens: any InstallTokenProviding
    private let session = CmxCredentialedHTTPSession()

    public init(baseURL: URL, tokens: any InstallTokenProviding) {
        self.baseURL = baseURL
        self.tokens = tokens
    }

    public func approveRequest(item: String) async throws -> FeedApproveRequest? {
        guard let found = try await read("feed.get", params: ["item": item])["item"] as? [String: Any] else {
            throw CloudOpsError.transport
        }
        return FeedApproveRequest(item: found)
    }

    /// This install's presence key as the owner holds it
    /// (`user.text_confirm.get`): missing, in its 24 h cooldown, or ready.
    public func presenceKeyState(install: String, now: Date = Date()) async throws -> FeedApproveKeyState {
        let value = try await read("user.text_confirm.get", params: [:])
        guard let key = (value["presence_keys"] as? [String: Any])?[install] as? [String: Any],
              key["revoked_at"] is NSNull else { return .missing }
        // Fail closed: no usable_from is no usable key.
        guard let usableFrom = (key["usable_from"] as? NSNumber)?.doubleValue else { return .missing }
        let until = Date(timeIntervalSince1970: usableFrom / 1000)
        return until > now ? .coolingDown(until: until) : .ready
    }

    /// One `/v1/read` op: its `value` object.
    private func read(_ op: String, params: [String: Any]) async throws -> [String: Any] {
        let token: String
        do { token = try await tokens.installToken(for: nil) } catch { throw CloudOpsError.installTokenUnavailable }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/read"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["op": op, "params": params])
        request.timeoutInterval = 15
        let body: Data
        let response: URLResponse
        do { (body, response) = try await session.data(for: request) } catch { throw CloudOpsError.transport }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CloudOpsError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let value = object["value"] as? [String: Any] else {
            throw CloudOpsError.transport
        }
        return value
    }
}

/// Whether this phone can sign an approve answer now.
public enum FeedApproveKeyState: Hashable, Sendable {
    /// No presence key yet: set it up first.
    case missing
    /// Registered, but in the owner's 24 h cooldown until this time.
    case coolingDown(until: Date)
    case ready
}

/// The phone's side of a signed approve answer (cx-aocz): its identity, its
/// presence key (Secure Enclave, user presence), and its registration.
public protocol FeedApproveSigning: Sendable {
    func keyState() async throws -> FeedApproveKeyState
    /// Creates and registers the presence key (App Attest), then reports
    /// its state (the cooldown starts now).
    func enroll() async throws -> FeedApproveKeyState
    /// (environment, user, this phone's install).
    func identity() async throws -> (environment: String, user: String, install: String)
    /// Signs after Face ID, Touch ID or the passcode; raw P-256 (r || s).
    func sign(_ message: Data) async throws -> Data
}

extension FeedApproveRequest {
    /// The signed answer for `allow` and `scope`, after user presence.
    public func signedAnswer(allow: Bool, scope: String, signer: any FeedApproveSigning,
                             now: Date = Date()) async throws -> FeedAnswer {
        let me = try await signer.identity()
        let ts = Int64(now.timeIntervalSince1970 * 1000)
        let message = FeedApproveProofMessage(
            environment: me.environment, user: me.user, phoneInstall: me.install, macInstall: macInstall,
            item: item, shownSHA256: shown.sha256, decision: allow ? "allow" : "deny", scope: scope,
            timestampMs: ts)
        let signature = try await signer.sign(message.bytes)
        let proof = FeedApproveProof(install: me.install, timestampMs: ts, signature: signature.base64URL)
        return .signedDecision(allow: allow, scope: scope == "once" ? nil : scope, proof: proof)
    }
}

extension Data {
    /// base64url without padding.
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
