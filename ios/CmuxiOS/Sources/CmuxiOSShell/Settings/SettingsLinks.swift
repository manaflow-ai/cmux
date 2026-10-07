import Foundation

/// The legal and support destinations (same as the shipping app).
enum SettingsLinks {
    static let privacyPolicy = URL(string: "https://cmux.com/privacy-policy")!
    static let termsOfService = URL(string: "https://cmux.com/terms-of-service")!

    static var support: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "feedback@manaflow.com"
        components.queryItems = [URLQueryItem(name: "subject", value: SettingsText.supportSubject)]
        return components.url!
    }
}
