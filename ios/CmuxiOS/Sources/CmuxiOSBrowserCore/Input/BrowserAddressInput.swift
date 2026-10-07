public import Foundation

/// What the URL bar sends: typed text becomes an http(s) URL. A bare host
/// gets `https://`; any other scheme is refused on the phone with the same
/// reason the Mac would give (the Mac refuses again regardless).
public struct BrowserAddressInput: Hashable, Sendable {
    public enum Refusal: String, Error, Hashable, Sendable {
        case empty, scheme, invalid
    }

    public init() {}

    public func url(from text: String) -> Result<URL, Refusal> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard !trimmed.contains(where: \.isWhitespace) else { return .failure(.invalid) }
        let candidate: String
        if let colon = trimmed.firstIndex(of: ":"), trimmed[..<colon].allSatisfy({ $0.isLetter || $0 == "+" || $0 == "-" || $0 == "." }),
           !trimmed[trimmed.index(after: colon)...].first.map(\.isNumber).orFalse {
            candidate = trimmed
        } else {
            candidate = "https://" + trimmed
        }
        guard let components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased() else {
            return .failure(.invalid)
        }
        guard scheme == "http" || scheme == "https" else { return .failure(.scheme) }
        guard let host = components.host, !host.isEmpty, let url = components.url else { return .failure(.invalid) }
        return .success(url)
    }
}

extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
