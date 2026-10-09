import Foundation

/// The remote configuration for this account and install, served by the
/// control plane (B1, `config.snapshot` in `cmux.mobile/1`). A projection:
/// the app never edits it. Missing fields decode to their defaults so an
/// older or newer server never breaks decoding.
public struct RemoteConfig: Hashable, Sendable, Codable {
    /// Monotonic owner revision. A zero revision means the local empty/default
    /// projection; the HTTP source maps the control-plane `version` to this
    /// field so a reconnect can be compared without looking at flags.
    public var revision: Int
    /// Keyed by the flag's raw name (for example `feedTab`).
    public var flags: [String: RemoteFlagValue]
    /// The oldest `cmux.mobile` protocol a Mac may speak; nil means the
    /// app's own floor.
    public var minimumMacProtocol: Int?
    /// Bumped when the server has What's New entries for this build.
    public var whatsNewRevision: Int?
    /// App Review demo content for this account.
    public var demoContent: Bool

    public init(revision: Int = 0, flags: [String: RemoteFlagValue] = [:], minimumMacProtocol: Int? = nil,
                whatsNewRevision: Int? = nil, demoContent: Bool = false) {
        self.revision = revision
        self.flags = flags
        self.minimumMacProtocol = minimumMacProtocol
        self.whatsNewRevision = whatsNewRevision
        self.demoContent = demoContent
    }

    public static let empty = RemoteConfig()

    private enum CodingKeys: String, CodingKey {
        case revision, flags, minimumMacProtocol, whatsNewRevision, demoContent
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        flags = try container.decodeIfPresent([String: RemoteFlagValue].self, forKey: .flags) ?? [:]
        minimumMacProtocol = try container.decodeIfPresent(Int.self, forKey: .minimumMacProtocol)
        whatsNewRevision = try container.decodeIfPresent(Int.self, forKey: .whatsNewRevision)
        demoContent = try container.decodeIfPresent(Bool.self, forKey: .demoContent) ?? false
    }
}
