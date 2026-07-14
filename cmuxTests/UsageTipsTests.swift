import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Usage tips")
struct UsageTipsTests {
    private let catalog = UsageTipsCatalog(tips: [
        UsageTip(id: .globalSearch, title: "Global", body: "Global body", shortcutAction: .globalSearch),
        UsageTip(id: .canvasLayout, title: "Canvas", body: "Canvas body", shortcutAction: .toggleCanvasLayout),
        UsageTip(id: .splitZoom, title: "Zoom", body: "Zoom body", shortcutAction: .toggleSplitZoom),
    ])

    @Test func selectionUsesCuratedOrderAndUnseenTipsOnly() {
        #expect(catalog.nextUnseenTip(seenTipIDs: [])?.id == .globalSearch)
        #expect(catalog.nextUnseenTip(seenTipIDs: [UsageTipID.globalSearch.rawValue])?.id == .canvasLayout)
        #expect(catalog.unseenTips(seenTipIDs: [UsageTipID.canvasLayout.rawValue]).map(\.id) == [
            .globalSearch,
            .splitZoom,
        ])
    }

    @Test func selectionExhaustsWhenEveryTipWasSeen() {
        let seen = Set(catalog.tips.map { $0.id.rawValue })
        #expect(catalog.nextUnseenTip(seenTipIDs: seen) == nil)
    }

    @MainActor
    @Test func shortcutResolverUsesTheCurrentResolvedBinding() {
        let rebound = StoredShortcut(
            key: "x",
            command: true,
            shift: false,
            option: true,
            control: false
        )
        let resolver = UsageTipShortcutResolver { action in
            action == .globalSearch ? rebound : nil
        }

        #expect(resolver.displayString(for: .globalSearch) == "⌥⌘X")
    }

    @MainActor
    @Test func shortcutResolverGracefullySkipsUnboundActions() {
        let resolver = UsageTipShortcutResolver { _ in .unbound }
        #expect(resolver.displayString(for: .globalSearch) == nil)
    }

    @MainActor
    @Test func reenablingBeforePresentationReschedulesTheTip() throws {
        let suiteName = "UsageTipsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        AccountCatalogSection().welcomeShown.set(true, in: defaults)
        let resolver = UsageTipShortcutResolver { _ in
            StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
        }
        var scheduledActions: [UsageTipScheduler.Action] = []
        let scheduler = UsageTipScheduler { _, action in
            let index = scheduledActions.count
            scheduledActions.append(action)
            return { scheduledActions[index] = {} }
        }
        let controller = UsageTipsController(
            store: UsageTipsStore(defaults: defaults),
            catalog: catalog,
            shortcutResolver: resolver,
            scheduler: scheduler
        )
        let windowID = UUID()

        controller.register(windowID: windowID)
        controller.windowDidBecomeKey(windowID: windowID)
        controller.updateEnabled(false)
        controller.updateEnabled(true)
        #expect(scheduledActions.count == 2)
        scheduledActions.last?()

        #expect(controller.presentation?.tip.id == .globalSearch)
        #expect(controller.presentation?.windowID == windowID)
        controller.unregister(windowID: windowID)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    @Test func deadlineTargetsTheCurrentKeyWindowAndResumesWithoutOne() throws {
        let suiteName = "UsageTipsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        AccountCatalogSection().welcomeShown.set(true, in: defaults)
        let resolver = UsageTipShortcutResolver { _ in
            StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
        }
        var scheduledActions: [UsageTipScheduler.Action] = []
        let scheduler = UsageTipScheduler { _, action in
            let index = scheduledActions.count
            scheduledActions.append(action)
            return { scheduledActions[index] = {} }
        }
        let controller = UsageTipsController(
            store: UsageTipsStore(defaults: defaults),
            catalog: catalog,
            shortcutResolver: resolver,
            scheduler: scheduler
        )
        let currentWindowID = UUID()
        let otherWindowID = UUID()

        controller.register(windowID: otherWindowID)
        controller.register(windowID: currentWindowID)
        controller.windowDidBecomeKey(windowID: currentWindowID)
        controller.windowDidResignKey(windowID: currentWindowID)
        scheduledActions.last?()
        #expect(controller.presentation == nil)

        controller.windowDidBecomeKey(windowID: otherWindowID)
        #expect(scheduledActions.count == 2)
        scheduledActions.last?()
        #expect(controller.presentation?.windowID == otherWindowID)

        controller.unregister(windowID: currentWindowID)
        controller.unregister(windowID: otherWindowID)
        defaults.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    @Test func enablingBeforeFirstWindowSchedulesTheInitialTip() throws {
        let suiteName = "UsageTipsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        AccountCatalogSection().welcomeShown.set(true, in: defaults)
        AppCatalogSection().showUsageTips.set(false, in: defaults)
        let store = UsageTipsStore(defaults: defaults)
        let resolver = UsageTipShortcutResolver { _ in
            StoredShortcut(key: "f", command: true, shift: false, option: true, control: false)
        }
        var scheduledActions: [UsageTipScheduler.Action] = []
        let scheduler = UsageTipScheduler { _, action in
            let index = scheduledActions.count
            scheduledActions.append(action)
            return { scheduledActions[index] = {} }
        }
        let controller = UsageTipsController(
            store: store,
            catalog: catalog,
            shortcutResolver: resolver,
            scheduler: scheduler
        )
        let windowID = UUID()

        #expect(!store.isEnabled)
        store.setEnabled(true)
        controller.register(windowID: windowID)
        controller.windowDidBecomeKey(windowID: windowID)

        #expect(scheduledActions.count == 1)
        controller.unregister(windowID: windowID)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
