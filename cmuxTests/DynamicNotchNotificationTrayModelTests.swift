import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Dynamic Notch notification tray")
struct DynamicNotchNotificationTrayModelTests {
    @Test("Notifications accumulate newest first and resolve independently")
    func notificationsAccumulateAndResolveIndependently() {
        let model = DynamicNotchNotificationTrayModel()
        let first = makeNotification(title: "First")
        let second = makeNotification(title: "Second")

        #expect(model.enqueue(first))
        #expect(model.enqueue(second))
        #expect(model.notifications.map(\.id) == [second.id, first.id])

        model.transition(to: .expanded)
        #expect(model.phase == .expanded)
        #expect(model.remove(id: second.id) == second)
        #expect(model.notifications == [first])
        #expect(model.phase == .expanded)

        #expect(model.remove(id: first.id) == first)
        #expect(model.notifications.isEmpty)
        #expect(model.phase == .retracted)
    }

    @Test("Duplicate notification identifiers do not create duplicate rows")
    func duplicateIdentifiersAreIgnored() {
        let model = DynamicNotchNotificationTrayModel()
        let notification = makeNotification(title: "Approval")

        #expect(model.enqueue(notification))
        #expect(!model.enqueue(notification))
        #expect(model.notifications == [notification])
    }

    @Test("Atomic upsert replaces a row without an empty intermediate tray")
    func atomicUpsertReplacesSupersededRow() {
        let model = DynamicNotchNotificationTrayModel()
        let first = makeNotification(title: "Step 1")
        let replacement = makeNotification(title: "Step 2")
        #expect(model.enqueue(first))
        model.transition(to: .expanded)

        let removed = model.upsert(
            replacement,
            superseding: [first.id]
        )

        #expect(removed == [first])
        #expect(model.notifications == [replacement])
        #expect(model.phase == .expanded)
    }

    @Test("Newest notification controls the tray while rows retain their overrides")
    func appearancePrecedenceFollowsNewestNotification() throws {
        let global = DynamicNotchAppearance()
            .replacing(.number(520), for: .expandedWidth)
            .replacing(.color(.hex("#112233")), for: .primaryTextColor)
        let model = DynamicNotchNotificationTrayModel(globalAppearance: global)
        let first = makeNotification(
            title: "First",
            appearance: try DynamicNotchAppearanceOverrides(assignments: [
                "expandedWidth=600",
                "accentColor=#FF0000",
            ])
        )
        let second = makeNotification(
            title: "Second",
            appearance: try DynamicNotchAppearanceOverrides(assignments: [
                "expandedWidth=700",
                "bodyLineLimit=8",
            ])
        )

        #expect(model.enqueue(first))
        #expect(model.enqueue(second))
        #expect(model.trayAppearance[.expandedWidth] == .number(700))
        #expect(model.appearance(for: first)[.expandedWidth] == .number(600))
        #expect(model.appearance(for: first)[.primaryTextColor] == .color(.hex("#112233")))
        #expect(model.appearance(for: second)[.bodyLineLimit] == .integer(8))

        _ = model.remove(id: second.id)
        #expect(model.trayAppearance[.expandedWidth] == .number(600))
    }

    @Test("Global appearance changes re-resolve inherited row values")
    func globalAppearanceUpdatesRows() {
        let model = DynamicNotchNotificationTrayModel()
        let notification = makeNotification(title: "Inherited")
        #expect(model.enqueue(notification))

        model.setGlobalAppearance(
            DynamicNotchAppearance().replacing(
                .number(720),
                for: .expandedWidth
            )
        )

        #expect(model.trayAppearance[.expandedWidth] == .number(720))
        #expect(model.appearance(for: notification)[.expandedWidth] == .number(720))
    }

    private func makeNotification(
        title: String,
        appearance: DynamicNotchAppearanceOverrides = DynamicNotchAppearanceOverrides()
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: UUID(),
            surfaceId: UUID(),
            title: title,
            subtitle: "",
            body: "",
            createdAt: Date(timeIntervalSince1970: 0),
            isRead: false,
            presentation: TerminalNotificationPresentation(
                appearance: appearance
            )
        )
    }
}

@Suite("Dynamic Notch appearance settings file", .serialized)
struct DynamicNotchAppearanceSettingsFileTests {
    private let backupsKey = "cmux.settingsFile.backups.v1"
    private let importedKey = "cmux.settingsFile.importedManagedDefaults.v1"

    @Test("cmux.json applies validated appearance and advertises every leaf path")
    func settingsFileAppliesAppearance() throws {
        let setting = SettingCatalog().notifications.dynamicNotch
        let defaults = UserDefaults.standard
        let keys = [setting.userDefaultsKey, backupsKey, importedKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in saved {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "cmux-dynamic-notch-appearance-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("cmux.json")
        try """
        {
          "notifications": {
            "dynamicNotch": {
              "expandedWidth": 680,
              "accentColor": "#AABBCC",
              "showScrollIndicators": false
            }
          }
        }
        """.write(to: file, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: file.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        let appearance = UserDefaultsSettingsClient(defaults: defaults).value(
            for: setting
        )
        #expect(appearance[.expandedWidth] == .number(680))
        #expect(appearance[.accentColor] == .color(.hex("#AABBCC")))
        #expect(appearance[.showScrollIndicators] == .boolean(false))
        #expect(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains(
                "notifications.dynamicNotch"
            )
        )
        for token in DynamicNotchAppearanceToken.allCases {
            #expect(
                CmuxSettingsFileStore.supportedSettingsJSONPaths.contains(
                    "notifications.dynamicNotch.\(token.rawValue)"
                )
            )
        }
        #expect(
            CmuxSettingsFileStore.defaultTemplate().contains(
                #""dynamicNotch""#
            )
        )
    }
}
