import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers whether Cmd+F selects the whole find query when it focuses the
/// find field, including `app.findSelectsExistingQuery` for a bar that is
/// already open (#22549).
@Suite("Find focus select-all")
struct FindFocusSelectAllTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "cmux-find-select-all-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Verifies that the setting is off by default so refocus keeps restoring the caret.
    @Test func settingDefaultsToRestoringTheCaret() {
        #expect(AppCatalogSection().findSelectsExistingQuery.defaultValue == false)
        #expect(!cmuxFindFocusShouldSelectAll(barWasOpen: true, recoveredNeedle: "", defaults: makeDefaults()))
    }

    /// Verifies that an open bar selects its query when the setting is on.
    @Test func openBarSelectsQueryWhenSettingIsOn() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AppCatalogSection().findSelectsExistingQuery.userDefaultsKey)
        #expect(cmuxFindFocusShouldSelectAll(barWasOpen: true, recoveredNeedle: "", defaults: defaults))
    }

    /// Verifies that reopening a closed bar selects only a recovered query, regardless of the setting.
    @Test(arguments: [false, true])
    func reopenedBarSelectsOnlyRecoveredQuery(settingOn: Bool) {
        let defaults = makeDefaults()
        defaults.set(settingOn, forKey: AppCatalogSection().findSelectsExistingQuery.userDefaultsKey)
        #expect(cmuxFindFocusShouldSelectAll(barWasOpen: false, recoveredNeedle: "query", defaults: defaults))
        #expect(!cmuxFindFocusShouldSelectAll(barWasOpen: false, recoveredNeedle: "", defaults: defaults))
    }
}
