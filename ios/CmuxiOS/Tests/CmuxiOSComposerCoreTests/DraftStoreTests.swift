import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import Foundation
import Testing

@MainActor
@Suite("drafts, preferences and templates")
struct DraftStoreTests {
    func defaults() -> UserDefaults {
        let name = "composer-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func draftsArePerTargetAndSurviveAReload() {
        let defaults = defaults()
        let store = ComposerDraftStore(defaults: defaults)
        let existing = ComposerTarget(hostID: MockFixtures.studio, workspaceID: "ws_studio1")
        let fresh = ComposerTarget(hostID: MockFixtures.studio)
        store.save(ComposerDraft(target: existing, prompt: "fix the tests", updatedAt: Date(timeIntervalSince1970: 1)))
        store.save(ComposerDraft(target: fresh, prompt: "new idea", updatedAt: Date(timeIntervalSince1970: 2)))
        let reloaded = ComposerDraftStore(defaults: defaults)
        #expect(reloaded.draft(for: existing)?.prompt == "fix the tests")
        #expect(reloaded.draft(for: fresh)?.prompt == "new idea")
        #expect(reloaded.latest?.target == fresh)
    }

    @Test func emptyDraftsAreRemovedButAPendingKeyIsKept() {
        let store = ComposerDraftStore(defaults: defaults())
        let target = ComposerTarget(hostID: MockFixtures.studio)
        store.save(ComposerDraft(target: target, prompt: "x"))
        store.save(ComposerDraft(target: target, prompt: "  "))
        #expect(store.draft(for: target) == nil)
        store.save(ComposerDraft(target: target, prompt: "", pendingKey: "k-unknown-outcome"))
        #expect(store.draft(for: target)?.pendingKey == "k-unknown-outcome")
        store.clear(target)
        #expect(store.all.isEmpty)
    }

    @Test func preferencesRememberPerMac() {
        let defaults = defaults()
        let preferences = ComposerPreferences(defaults: defaults)
        preferences.remember(ComposerSelection(agentID: "codex", model: "gpt-5.6", effort: "xhigh"), for: MockFixtures.studio)
        preferences.remember(target: ComposerTarget(hostID: MockFixtures.studio, workspaceID: "ws_studio1"))
        let reloaded = ComposerPreferences(defaults: defaults)
        #expect(reloaded.selection(for: MockFixtures.studio)?.effort == "xhigh")
        #expect(reloaded.selection(for: MockFixtures.mini) == nil)
        #expect(reloaded.lastTarget?.workspaceID == "ws_studio1")
    }

    @Test func templatesMatchBySlugAndSaveReplacesByName() {
        let defaults = defaults()
        let library = PromptTemplateLibrary(builtIns: [
            PromptTemplate(id: "builtin.review", name: "review", title: "Review", body: "Review the diff", isBuiltIn: true),
            PromptTemplate(id: "builtin.fix", name: "fix-tests", title: "Fix tests", body: "Fix failing tests", isBuiltIn: true),
        ], defaults: defaults)
        #expect(library.matching("fi").map(\.name) == ["fix-tests"])
        #expect(library.matching("test").map(\.name) == ["fix-tests"])
        let saved = library.save(name: "Ship It!", body: "Open a PR")
        #expect(saved?.name == "ship-it")
        _ = library.save(name: "ship it", body: "Open a draft PR")
        let reloaded = PromptTemplateLibrary(builtIns: library.builtIns, defaults: defaults)
        #expect(reloaded.saved.count == 1)
        #expect(reloaded.saved.first?.body == "Open a draft PR")
        #expect(library.save(name: "!!", body: "x") == nil)
    }
}
