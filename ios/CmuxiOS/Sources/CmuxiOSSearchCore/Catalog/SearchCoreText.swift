import Foundation

/// Localized labels the providers and the catalog put on items.
struct SearchCoreText {
    static var needsInput: String {
        String(localized: "search.badge.needs-input", defaultValue: "Needs input", bundle: .module)
    }
    static var running: String {
        String(localized: "search.badge.running", defaultValue: "Running", bundle: .module)
    }
    static var failed: String {
        String(localized: "search.badge.failed", defaultValue: "Failed", bundle: .module)
    }
    static var pairedMac: String {
        String(localized: "search.host.paired-mac", defaultValue: "Paired Mac", bundle: .module)
    }
    static var ssh: String {
        String(localized: "search.host.ssh", defaultValue: "SSH", bundle: .module)
    }
    static var direct: String {
        String(localized: "search.host.direct", defaultValue: "Direct", bundle: .module)
    }

    /// "<first> · <second>", skipping empty parts.
    static func joined(_ parts: [String?]) -> String? {
        let present = parts.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return present.isEmpty ? nil : present.joined(separator: " · ")
    }

    /// The first non-empty line of Markdown or terminal text.
    static func firstLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}
