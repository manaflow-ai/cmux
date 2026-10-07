import Foundation

/// A throwaway `UserDefaults` suite per test.
struct TestDefaults {
    let defaults: UserDefaults
    let name: String

    init() {
        name = "c11-settings-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: name)!
    }
}
