import Foundation
import Combine
import CmuxKit

/// Persisted AFK policy backed by UserDefaults (App Group suite so the
/// widget extension can read the same values).
@MainActor
final class AFKPolicyStore: ObservableObject {
    static let shared = AFKPolicyStore()

    private let key = "cmux.afk.policy.v1"
    private let defaults: UserDefaults

    @Published var policy: AFKPolicy

    private init() {
        let suite = UserDefaults(suiteName: "group.com.cmuxterm.remote") ?? .standard
        self.defaults = suite
        if let data = suite.data(forKey: key),
           let decoded = try? JSONDecoder().decode(AFKPolicy.self, from: data) {
            self.policy = decoded
        } else {
            self.policy = AFKPolicy()
        }
    }

    func update(_ transform: (inout AFKPolicy) -> Void) {
        var working = policy
        transform(&working)
        policy = working
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(policy) {
            defaults.set(data, forKey: key)
        }
    }
}
