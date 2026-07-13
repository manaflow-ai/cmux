import CmuxSettings
import Dispatch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserWebExtensionSupportLifecycleTests {
    @Test
    @available(macOS 15.4, *)
    func initialReconciliationWaitsForFirstSettingsValue() async throws {
        let wasBrowserDisabled = BrowserAvailabilitySettings.isDisabled()
        BrowserAvailabilitySettings.setDisabled(false)
        defer { BrowserAvailabilitySettings.setDisabled(wasBrowserDisabled) }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-web-extension-readiness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONConfigStore(fileURL: directory.appendingPathComponent("cmux.json"))
        let catalog = SettingCatalog()
        let entry = BrowserWebExtensionEntry(
            id: "readiness-test",
            kind: .unpackedDirectory,
            path: "/nonexistent/readiness-test",
            enabled: false
        )
        try await store.set([entry], for: catalog.browser.webExtensions)

        let support = BrowserWebExtensionSupport()
        #expect(!support.isInitialReconciliationComplete)
        support.configure(jsonStore: store, catalog: catalog)
        await support.waitForInitialReconciliation()

        #expect(support.isInitialReconciliationComplete)
        #expect(support.configuredSettingsEntries.map(\.id) == [entry.id])
    }

    @Test
    @available(macOS 15.4, *)
    func teardownExplicitlyRemovesPermissionObserverTokens() {
        let notificationCenter = NotificationCenter.default
        let name = Notification.Name("cmuxTests.browserWebExtension.permissionObserver")
        let notificationReceived = DispatchSemaphore(value: 0)
        let token = notificationCenter.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            notificationReceived.signal()
        }
        defer { notificationCenter.removeObserver(token) }

        var support: BrowserWebExtensionSupport? = BrowserWebExtensionSupport()
        weak var weakSupport = support
        support?.permissionObserverTokensByEntryID["test"] = [token]
        support = nil

        #expect(weakSupport == nil)
        notificationCenter.post(name: name, object: nil)
        #expect(notificationReceived.wait(timeout: .now()) == .timedOut)
    }
}
