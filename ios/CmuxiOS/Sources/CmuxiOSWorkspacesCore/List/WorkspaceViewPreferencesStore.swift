import Foundation

/// Persists `WorkspaceViewPreferences` in `UserDefaults` under one key.
public final class WorkspaceViewPreferencesStore: @unchecked Sendable {
    // UserDefaults is thread-safe; the class holds no other state.
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "cmux.workspaces.viewPreferences") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> WorkspaceViewPreferences {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(WorkspaceViewPreferences.self, from: data) else {
            return WorkspaceViewPreferences()
        }
        return stored
    }

    public func save(_ preferences: WorkspaceViewPreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}
