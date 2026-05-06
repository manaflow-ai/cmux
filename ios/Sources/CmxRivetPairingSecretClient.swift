import Foundation

struct CmxRivetPairingSecret: Decodable, Equatable, CustomStringConvertible {
    let pairingID: String
    let secret: String
    let expiresAtUnix: UInt64

    var description: String {
        "CmxRivetPairingSecret(pairingID: \(pairingID), secret: redacted, expiresAtUnix: \(expiresAtUnix))"
    }

    enum CodingKeys: String, CodingKey {
        case pairingID = "pairing_id"
        case secret = "pairing_secret"
        case expiresAtUnix = "expires_at_unix"
    }
}

protocol CmxRivetPairingSecretFetching {
    func fetchSecret(
        for auth: CmxBridgeTicketAuth,
        stackSession: CmxStackAuthSession,
        now: Date
    ) async throws -> CmxRivetPairingSecret
}

struct CmxRivetPairingSecretClient: CmxRivetPairingSecretFetching {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchSecret(
        for auth: CmxBridgeTicketAuth,
        stackSession: CmxStackAuthSession,
        now: Date = Date()
    ) async throws -> CmxRivetPairingSecret {
        guard case .rivetStack(let pairingID, let rivetEndpoint, let stackProjectID, _) = auth else {
            throw CmxRivetPairingSecretError.unsupportedAuth
        }

        let url = try secretURL(endpoint: rivetEndpoint, pairingID: pairingID)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(stackProjectID, forHTTPHeaderField: "X-Stack-Project-ID")
        for (field, value) in stackSession.authorizationHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CmxRivetPairingSecretError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw CmxRivetPairingSecretError.badStatus(httpResponse.statusCode)
        }

        let secret: CmxRivetPairingSecret
        do {
            secret = try JSONDecoder().decode(CmxRivetPairingSecret.self, from: data)
        } catch {
            throw CmxRivetPairingSecretError.invalidResponse
        }
        try validate(secret: secret, expectedPairingID: pairingID, now: now)
        return secret
    }

    private func secretURL(endpoint: String, pairingID: String) throws -> URL {
        let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmedEndpoint),
              let scheme = components.scheme,
              ["http", "https"].contains(scheme),
              components.host != nil else {
            throw CmxRivetPairingSecretError.invalidEndpoint
        }

        let trimmedPath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let basePath = trimmedPath.isEmpty ? "" : "/\(trimmedPath)"
        components.percentEncodedPath = "\(basePath)/pairings/\(pairingID.percentEncodedPathSegment)/secret"
        components.percentEncodedQuery = nil
        components.fragment = nil

        guard let url = components.url else {
            throw CmxRivetPairingSecretError.invalidEndpoint
        }
        return url
    }

    private func validate(secret: CmxRivetPairingSecret, expectedPairingID: String, now: Date) throws {
        guard !secret.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CmxRivetPairingSecretError.missingSecret
        }
        guard secret.pairingID == expectedPairingID else {
            throw CmxRivetPairingSecretError.pairingIDMismatch
        }
        guard secret.expiresAtUnix > UInt64(now.timeIntervalSince1970.rounded(.down)) else {
            throw CmxRivetPairingSecretError.expiredSecret
        }
    }
}

enum CmxRivetPairingSecretError: LocalizedError, Equatable {
    case unsupportedAuth
    case invalidEndpoint
    case badStatus(Int)
    case invalidResponse
    case missingSecret
    case pairingIDMismatch
    case expiredSecret

    var errorDescription: String? {
        switch self {
        case .unsupportedAuth:
            return String(localized: "rivet.error.unsupported_auth", defaultValue: "This ticket does not use Rivet pairing auth.")
        case .invalidEndpoint:
            return String(localized: "rivet.error.invalid_endpoint", defaultValue: "The Rivet pairing endpoint is invalid.")
        case .badStatus(let status):
            return String(
                format: String(localized: "rivet.error.bad_status", defaultValue: "Rivet pairing secret request failed (%d)."),
                status
            )
        case .invalidResponse:
            return String(localized: "rivet.error.invalid_response", defaultValue: "Rivet returned an invalid pairing secret response.")
        case .missingSecret:
            return String(localized: "rivet.error.missing_secret", defaultValue: "Rivet did not return a pairing secret.")
        case .pairingIDMismatch:
            return String(localized: "rivet.error.pairing_mismatch", defaultValue: "Rivet returned a pairing secret for a different ticket.")
        case .expiredSecret:
            return String(localized: "rivet.error.expired_secret", defaultValue: "The Rivet pairing secret has expired.")
        }
    }
}

private extension String {
    var percentEncodedPathSegment: String {
        addingPercentEncoding(withAllowedCharacters: .cmxPathSegmentAllowed) ?? self
    }
}

private extension CharacterSet {
    static let cmxPathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()
}
