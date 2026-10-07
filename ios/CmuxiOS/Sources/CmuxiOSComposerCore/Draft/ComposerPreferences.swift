public import CmuxiOSFeatureKit
import Foundation

/// The last agent, model and effort picked per Mac, and the last target.
/// Client view state in `UserDefaults`.
@MainActor
public final class ComposerPreferences {
    private struct Stored: Codable {
        var selections: [String: ComposerSelection] = [:]
        var lastTarget: ComposerTarget?
    }

    private let defaults: UserDefaults
    private let key: String
    private var stored: Stored

    public init(defaults: UserDefaults = .standard, key: String = "cmux.composer.preferences.v1") {
        self.defaults = defaults
        self.key = key
        stored = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
    }

    public func selection(for host: HostID) -> ComposerSelection? { stored.selections[host.rawValue] }

    public var lastTarget: ComposerTarget? { stored.lastTarget }

    public func remember(_ selection: ComposerSelection, for host: HostID) {
        guard stored.selections[host.rawValue] != selection else { return }
        stored.selections[host.rawValue] = selection
        persist()
    }

    public func remember(target: ComposerTarget) {
        guard stored.lastTarget != target else { return }
        stored.lastTarget = target
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: key) }
    }
}
