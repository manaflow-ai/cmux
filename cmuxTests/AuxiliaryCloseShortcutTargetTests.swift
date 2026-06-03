import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for ``auxiliaryCloseShortcutTarget(candidates:isAuxiliary:isKey:)`` — the rule that an
/// auxiliary window only owns the focused Close shortcut when it is the key window. Regression
/// coverage for issue #5321 (a stale/background auxiliary window must not absorb Cmd+W).
@Suite struct AuxiliaryCloseShortcutTargetTests {
    private struct FakeWindow {
        let id: String
        let auxiliary: Bool
        let key: Bool
    }

    private func target(_ windows: [FakeWindow?]) -> FakeWindow? {
        auxiliaryCloseShortcutTarget(
            candidates: windows,
            isAuxiliary: { $0.auxiliary },
            isKey: { $0.key }
        )
    }

    @Test func selectsAuxiliaryWindowThatIsKey() {
        let aux = FakeWindow(id: "cmux.settings", auxiliary: true, key: true)
        #expect(target([aux])?.id == "cmux.settings")
    }

    /// The #5321 regression: a background/stale auxiliary window (not key) must not be selected.
    /// Without the key requirement this returns the auxiliary window and absorbs Cmd+W.
    @Test func ignoresNonKeyAuxiliaryWindow() {
        let mainKey = FakeWindow(id: "cmux.main", auxiliary: false, key: true)
        let staleAux = FakeWindow(id: "cmux.settings", auxiliary: true, key: false)
        #expect(target([mainKey, staleAux])?.id == nil)
    }

    @Test func ignoresKeyNonAuxiliaryWindow() {
        let mainKey = FakeWindow(id: "cmux.main", auxiliary: false, key: true)
        #expect(target([mainKey])?.id == nil)
    }

    @Test func returnsNilForEmptyCandidates() {
        #expect(target([nil, nil])?.id == nil)
    }

    @Test func picksFirstAuxiliaryKeyCandidate() {
        let about = FakeWindow(id: "cmux.about", auxiliary: true, key: true)
        let settings = FakeWindow(id: "cmux.settings", auxiliary: true, key: true)
        #expect(target([about, settings])?.id == "cmux.about")
    }
}
