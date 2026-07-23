import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

/// Keyword → color rules that tint workspaces by title
/// (`workspaceColors.autoColorRules`).
struct WorkspaceTabAutoColorRulesTests {
    private func withDefaults<T>(
        _ label: String,
        _ body: (UserDefaults) throws -> T
    ) throws -> T {
        let suiteName = "cmux.workspace.autoColorRules.\(label).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        return try body(defaults)
    }

    @Test
    func paletteNameRuleColorsMatchingTitle() throws {
        try withDefaults("paletteName") { defaults in
            let ruleSet = WorkspaceTabAutoColorRules.ruleSet(raw: ["deploy": "Red"], defaults: defaults)
            #expect(ruleSet.colorHex(forTitle: "deploy staging") == "#C0392B")
            #expect(ruleSet.colorHex(forTitle: "unrelated workspace") == nil)
        }
    }

    @Test
    func hexRuleIsNormalizedAndMatchingIgnoresCaseAccentsAndWidth() throws {
        try withDefaults("folding") { defaults in
            let ruleSet = WorkspaceTabAutoColorRules.ruleSet(
                raw: ["déploiement": "#1565c0"],
                defaults: defaults
            )
            #expect(ruleSet.colorHex(forTitle: "Déploiement prod") == "#1565C0")
            #expect(ruleSet.colorHex(forTitle: "DEPLOIEMENT prod") == "#1565C0")
            #expect(ruleSet.colorHex(forTitle: "ｄéｐｌｏｉｅｍｅｎｔ") == "#1565C0")
        }
    }

    /// Rules are stored as an unordered map, so specificity — not authoring
    /// order — decides: the longest matching keyword wins.
    @Test
    func longestMatchingKeywordWins() throws {
        try withDefaults("longest") { defaults in
            let ruleSet = WorkspaceTabAutoColorRules.ruleSet(
                raw: ["api": "Red", "api-gateway": "Blue"],
                defaults: defaults
            )
            #expect(ruleSet.colorHex(forTitle: "api-gateway prod") == "#1565C0")
            #expect(ruleSet.colorHex(forTitle: "api prod") == "#C0392B")
        }
    }

    /// Equal-length keywords resolve on a locale-independent order, so the same
    /// config paints the same color on every machine.
    @Test
    func equalLengthKeywordsResolveDeterministically() throws {
        try withDefaults("ties") { defaults in
            let raw = ["zzz": "Red", "aaa": "Blue"]
            let first = WorkspaceTabAutoColorRules.ruleSet(raw: raw, defaults: defaults)
            let second = WorkspaceTabAutoColorRules.ruleSet(raw: raw, defaults: defaults)
            #expect(first.rules.map(\.keyword) == ["aaa", "zzz"])
            #expect(first.rules.map(\.keyword) == second.rules.map(\.keyword))
            #expect(first.colorHex(forTitle: "aaa zzz") == "#1565C0")
        }
    }

    /// Two keywords that fold to the same string still get a total order, so
    /// the winner never depends on dictionary iteration order.
    ///
    /// Asserted as a concrete expected order rather than "two runs agree":
    /// equal runs stay equal even if the raw-keyword tie-break is dropped, so
    /// only naming the winner proves the secondary ordering is still there.
    @Test
    func keywordsFoldingToTheSameStringStillOrderDeterministically() throws {
        try withDefaults("foldedTies") { defaults in
            var oneOrder: [String: String] = [:]
            oneOrder["Deploy"] = "Red"
            oneOrder["déploy"] = "Blue"

            var otherOrder: [String: String] = [:]
            otherOrder["déploy"] = "Blue"
            otherOrder["Deploy"] = "Red"

            for raw in [oneOrder, otherOrder] {
                let ruleSet = WorkspaceTabAutoColorRules.ruleSet(raw: raw, defaults: defaults)
                // Both fold to "deploy", so the raw keyword decides: "D" sorts
                // before "d".
                #expect(ruleSet.rules.map(\.keyword) == ["Deploy", "déploy"])
                #expect(ruleSet.colorHex(forTitle: "deploy prod") == "#C0392B")
            }
        }
    }

    /// `raw` is keyed by the keyword *as typed*, so `"deploy"` and `" deploy "`
    /// are two entries that trim down to one keyword. Duplicates that agree
    /// collapse to a single rule; duplicates that disagree are dropped, because
    /// no tie-break can pick a non-arbitrary winner and painting the wrong
    /// color is worse than painting none.
    @Test
    func duplicateTrimmedKeywordsCollapseWhenTheyAgreeAndAreDroppedWhenTheyConflict() throws {
        try withDefaults("duplicates") { defaults in
            let agreeing = WorkspaceTabAutoColorRules.ruleSet(
                raw: ["deploy": "Red", "  deploy  ": "Red"],
                defaults: defaults
            )
            #expect(agreeing.rules.map(\.keyword) == ["deploy"])
            #expect(agreeing.colorHex(forTitle: "deploy staging") == "#C0392B")

            let conflicting = WorkspaceTabAutoColorRules.ruleSet(
                raw: ["deploy": "Red", "  deploy  ": "Blue"],
                defaults: defaults
            )
            #expect(conflicting.rules.isEmpty)
            #expect(conflicting.colorHex(forTitle: "deploy staging") == nil)

            // One ambiguous keyword must not take the unambiguous ones down.
            let mixed = WorkspaceTabAutoColorRules.ruleSet(
                raw: ["deploy": "Red", " deploy ": "Blue", "docs": "Blue"],
                defaults: defaults
            )
            #expect(mixed.rules.map(\.keyword) == ["docs"])
            #expect(mixed.colorHex(forTitle: "deploy docs") == "#1565C0")
        }
    }

    /// The settings card keys its rows by keyword, so a duplicate keyword would
    /// mean duplicate `ForEach` IDs. Canonicalization is what guarantees it.
    @Test
    func resolvedRulesNeverRepeatAKeyword() throws {
        try withDefaults("uniqueKeywords") { defaults in
            let ruleSet = WorkspaceTabAutoColorRules.ruleSet(
                raw: ["deploy": "Red", " deploy": "Red", "deploy ": "Red", "docs": "Blue"],
                defaults: defaults
            )
            let keywords = ruleSet.rules.map(\.keyword)
            #expect(keywords.count == Set(keywords).count)
            #expect(keywords.sorted() == ["deploy", "docs"])
        }
    }

    @Test
    func explicitWorkspaceColorWinsOverRules() throws {
        try withDefaults("explicit") { defaults in
            let ruleSet = WorkspaceTabAutoColorRules.ruleSet(raw: ["deploy": "Red"], defaults: defaults)
            #expect(ruleSet.effectiveColorHex(explicit: "#196F3D", title: "deploy staging") == "#196F3D")
            #expect(ruleSet.effectiveColorHex(explicit: nil, title: "deploy staging") == "#C0392B")
            // A workspace with an unusable stored color still falls back to rules.
            #expect(ruleSet.effectiveColorHex(explicit: "nonsense", title: "deploy staging") == "#C0392B")
            #expect(ruleSet.effectiveColorHex(explicit: nil, title: "scratch") == nil)
        }
    }

    @Test
    func unusableRulesAreDropped() throws {
        try withDefaults("invalid") { defaults in
            let ruleSet = WorkspaceTabAutoColorRules.ruleSet(
                raw: [
                    "   ": "Red",
                    "docs": "Not A Color",
                    "infra": "Orange",
                ],
                defaults: defaults
            )
            #expect(ruleSet.rules.map(\.keyword) == ["infra"])
            #expect(ruleSet.colorHex(forTitle: "docs site") == nil)
        }
    }

    @Test
    func keywordsAreTrimmedAndCustomPaletteEntriesResolve() throws {
        try withDefaults("customPalette") { defaults in
            defaults.set(["Neon Mint": "#00F5D4"], forKey: WorkspaceTabColorSettings.paletteKey)
            let ruleSet = WorkspaceTabAutoColorRules.ruleSet(
                raw: ["  release  ": "neon mint"],
                defaults: defaults
            )
            #expect(ruleSet.rules.map(\.keyword) == ["release"])
            #expect(ruleSet.colorHex(forTitle: "release 1.2") == "#00F5D4")
        }
    }

    @Test
    func ruleSetReadsStoredDefaultsAndEmptyStorageMatchesNothing() throws {
        try withDefaults("storage") { defaults in
            #expect(WorkspaceTabAutoColorRules.ruleSet(defaults: defaults).isEmpty)
            #expect(WorkspaceTabAutoColorRules.ruleSet(defaults: defaults).colorHex(forTitle: "deploy") == nil)

            defaults.set(["deploy": "Red"], forKey: WorkspaceTabAutoColorRules.rulesKey)
            #expect(WorkspaceTabAutoColorRules.ruleSet(defaults: defaults).colorHex(forTitle: "deploy") == "#C0392B")
        }
    }

    @Test
    func rulesKeyMatchesCatalogEntry() {
        #expect(WorkspaceTabAutoColorRules.rulesKey == WorkspaceColorsCatalogSection().autoColorRules.userDefaultsKey)
        #expect(WorkspaceColorsCatalogSection().autoColorRules.id == "workspaceColors.autoColorRules")
    }

    /// The sidebar reads rules once per settings change, through the row
    /// settings snapshot — never per row render.
    @Test
    @MainActor
    func sidebarSettingsSnapshotCarriesStoredRules() throws {
        try withDefaults("sidebarSnapshot") { defaults in
            #expect(SidebarTabItemSettingsSnapshot(defaults: defaults).workspaceAutoColorRules.isEmpty)

            defaults.set(["deploy": "Red"], forKey: WorkspaceTabAutoColorRules.rulesKey)
            let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults)
            #expect(
                snapshot.workspaceAutoColorRules.effectiveColorHex(explicit: nil, title: "deploy prod")
                    == "#C0392B"
            )
        }
    }

    @Test
    func normalizedRuleMapTrimsAndKeepsPaletteNames() {
        let normalized = WorkspaceTabAutoColorRules.normalizedRuleMap([
            "  deploy ": " Red ",
            "docs": "#1565c0",
            " ": "Red",
            "empty": "   ",
        ])
        #expect(normalized == ["deploy": "Red", "docs": "#1565C0"])
    }
}
