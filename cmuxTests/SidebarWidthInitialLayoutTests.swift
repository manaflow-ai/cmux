import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct SidebarWidthInitialLayoutTests {
    @Test func sanitizedWidthUsesConfiguredMinimumWhenNoWidthWasPersisted() {
        let suiteName = "SidebarWidthInitialLayoutTests.minimumSidebarWidth.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(160.0, forKey: SessionPersistencePolicy.sidebarMinimumWidthKey)
        #expect(
            SessionPersistencePolicy.sanitizedSidebarWidth(nil, defaults: defaults) == 160
        )
        #expect(
            SessionPersistencePolicy.sanitizedSidebarWidth(140, defaults: defaults) == 160
        )
        #expect(
            SessionPersistencePolicy.sanitizedSidebarWidth(184, defaults: defaults) == 184
        )
    }

    @Test func newWindowUsesConfiguredMinimumWhenNoWidthWasPersisted() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            let key = SessionPersistencePolicy.sidebarMinimumWidthKey
            let savedValue = defaults.object(forKey: key)
            let previousAppDelegate = AppDelegate.shared

            defaults.set(160.0, forKey: key)
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate
            var windowId: UUID?
            defer {
                if let windowId {
                    _ = appDelegate.closeMainWindow(windowId: windowId, recordHistory: false)
                }
                if let savedValue {
                    defaults.set(savedValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
                AppDelegate.shared = previousAppDelegate
            }

            let createdWindowId = appDelegate.createMainWindow(shouldActivate: false)
            windowId = createdWindowId
            let context = try #require(
                appDelegate.mainWindowContexts.values.first { $0.windowId == createdWindowId }
            )

            #expect(context.sidebarState.persistedWidth == 160)
        }
    }

#if DEBUG
    @Test func contentViewReadsConfiguredWidthBeforeItsAppearActions() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            _ = NSApplication.shared
            let defaults = UserDefaults.standard
            let key = SessionPersistencePolicy.sidebarMinimumWidthKey
            let savedValue = defaults.object(forKey: key)
            let capture = SidebarWidthRenderCapture()

            defaults.set(160.0, forKey: key)
            defer {
                if let savedValue {
                    defaults.set(savedValue, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }

            let tabManager = TabManager()
            let root = ContentView(updateViewModel: UpdateStateModel(), windowId: UUID())
                .environmentObject(tabManager)
                .environmentObject(TerminalNotificationStore.shared)
                .environmentObject(SidebarState(persistedWidth: 160))
                .environmentObject(SidebarSelectionState())
                .environmentObject(FileExplorerState())
                .environmentObject(CmuxConfigStore())
                .environment(
                    \.sidebarWidthRenderProbe,
                    SidebarWidthRenderProbe(widthRead: { width in
                        capture.widths.append(width)
                    })
                )

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = MainWindowHostingView(rootView: root)
            defer {
                window.contentView = nil
                window.close()
            }

            await Self.drainMainRunLoop(for: window)
            let firstWidth = try #require(capture.widths.first)
            #expect(firstWidth == 160)
        }
    }

    private final class SidebarWidthRenderCapture {
        var widths: [CGFloat] = []
    }

    private static func drainMainRunLoop(for window: NSWindow, iterations: Int = 20) async {
        for _ in 0..<iterations {
            window.contentView?.layoutSubtreeIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            await Task.yield()
        }
    }
#endif
}
