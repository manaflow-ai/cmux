import CmuxiOSSettingsCore
import CmuxTerminalRenderCore
import Foundation
import Testing

@MainActor
@Suite struct TerminalPreferencesStoreTests {
    @Test func persistsAcrossInstances() {
        let suite = TestDefaults()
        let store = TerminalPreferencesStore(defaults: suite.defaults)
        store.update { $0.theme = .monokai; $0.fontSize = 18 }
        let reloaded = TerminalPreferencesStore(defaults: suite.defaults)
        #expect(reloaded.preferences.theme == .monokai)
        #expect(reloaded.preferences.fontSize == 18)
    }

    @Test func corruptStoredDataReadsAsDefaults() {
        let suite = TestDefaults()
        suite.defaults.set(Data("not json".utf8), forKey: TerminalPreferencesStore.defaultsKey)
        #expect(TerminalPreferencesStore(defaults: suite.defaults).preferences == TerminalPreferences())
    }

    @Test func updatesStartWithCurrentAndFollowChanges() async {
        let store = TerminalPreferencesStore(defaults: TestDefaults().defaults)
        var iterator = store.appearanceUpdates().makeAsyncIterator()
        #expect(await iterator.next() == TerminalPreferences().appearance)
        store.update { $0.cursorStyle = .underline }
        #expect(await iterator.next()?.cursorStyle == .underline)
    }

    @Test func updateNormalizesBeforeStoring() {
        let store = TerminalPreferencesStore(defaults: TestDefaults().defaults)
        store.update { $0.fontSize = 200 }
        #expect(store.preferences.fontSize == TerminalPreferences.fontSizeRange.upperBound)
        #expect(store.appearance.baseFontSize == 24)
    }

    @Test func resetRemovesTheStoredValue() {
        let suite = TestDefaults()
        let store = TerminalPreferencesStore(defaults: suite.defaults)
        store.update { $0.font = .menlo }
        store.reset()
        #expect(store.preferences == TerminalPreferences())
        #expect(suite.defaults.data(forKey: TerminalPreferencesStore.defaultsKey) == nil)
    }
}
