public import Foundation

/// Version facts for the About row, read from the app's Info.plist.
public struct ShellAbout: Hashable, Sendable {
    public var version: String
    public var build: String
    /// The DEV tag (`CMUXDevTag`); nil in release builds.
    public var devTag: String?

    public init(version: String, build: String, devTag: String?) {
        self.version = version
        self.build = build
        self.devTag = devTag
    }

    public static func current(bundle: Bundle = .main) -> ShellAbout {
        let info = bundle.infoDictionary ?? [:]
        let tag = (info["CMUXDevTag"] as? String)?.trimmingCharacters(in: .whitespaces)
        return ShellAbout(
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            devTag: tag?.isEmpty == false ? tag : nil
        )
    }

    public var summary: String {
        let base = version + " (" + build + ")"
        return devTag.map { base + " · " + $0 } ?? base
    }
}
