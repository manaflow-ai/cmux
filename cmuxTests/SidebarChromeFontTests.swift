import AppKit
import CmuxFoundation
import CmuxSettings
import CmuxSidebar
import Testing
@testable import cmux_DEV

/// The interface font setting (`app.chromeFont`) follows the terminal font by
/// default, which changes the metrics every sidebar row is measured with. These
/// tests pin the default, the resolution the rows see, and the title room that
/// survives the switch to a monospaced family.
@Suite
@MainActor
struct SidebarChromeFontTests {
    private static func defaultsSuite() -> UserDefaults {
        let suiteName = "cmux.chrome-font.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test
    func theSettingDefaultsToFollowingTheTerminal() {
        let key = AppCatalogSection().chromeFont

        #expect(key.defaultValue == CmuxChromeFontSource.terminalSettingValue)
        #expect(CmuxChromeFontSource(settingValue: key.defaultValue) == .terminal)
    }

    @Test
    func theSettingIsWritableFromCmuxJSON() {
        // Without the supported path the key is accepted in cmux.json and then
        // silently dropped, which reads as the setting not working at all.
        #expect(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("app.chromeFont"))
    }

    @Test
    func rowsFollowTheTerminalFamilyByDefault() {
        let defaults = Self.defaultsSuite()

        let snapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            terminalFontFamilies: ["Definitely Not An Installed Family", "Menlo"]
        )

        // The family the terminal actually resolves, not merely the first
        // `font-family` line in the config.
        #expect(snapshot.chromeTypeface == .family("Menlo"))
    }

    @Test
    func rowsKeepTheSystemFontWhenTheSettingSaysSystem() {
        let defaults = Self.defaultsSuite()
        defaults.set(
            CmuxChromeFontSource.systemSettingValue,
            forKey: AppCatalogSection().chromeFont.userDefaultsKey
        )

        let snapshot = SidebarTabItemSettingsSnapshot(defaults: defaults, terminalFontFamilies: ["Menlo"])

        #expect(snapshot.chromeTypeface == .system)
    }

    @Test
    func rowsFallBackToMonospaceWhenTheTerminalFamilyIsMissing() {
        let defaults = Self.defaultsSuite()

        let snapshot = SidebarTabItemSettingsSnapshot(
            defaults: defaults,
            terminalFontFamilies: ["Definitely Not An Installed Family"]
        )

        #expect(snapshot.chromeTypeface == .monospacedSystem)
    }

    /// The header's measured height is derived from its name font, so the
    /// typeface has to reach the measuring font and the drawn font together.
    @Test
    func groupHeaderMeasuresTheFontItDraws() {
        var model = Self.groupHeaderModel()
        model.chromeTypeface = .family("Menlo")
        let metrics = SidebarWorkspaceGroupHeaderMetrics(fontScale: model.fontScale)

        let font = SidebarGroupHeaderRowView.nameFont(model: model, metrics: metrics)

        #expect(font.familyName == "Menlo")
        // `preferredHeight` builds its line height from this same call, so a
        // family with taller metrics cannot be drawn into a row measured for
        // the system font.
        #expect(SidebarGroupHeaderRowView.preferredHeight(model: model) > 0)
    }

    @Test
    func groupHeaderHeightTracksTheTypefaceItWasMeasuredWith() {
        var system = Self.groupHeaderModel()
        system.chromeTypeface = .system
        var monospaced = Self.groupHeaderModel()
        monospaced.chromeTypeface = .monospacedSystem

        let systemHeight = SidebarGroupHeaderRowView.preferredHeight(model: system)
        let monospacedHeight = SidebarGroupHeaderRowView.preferredHeight(model: monospaced)
        let systemFont = SidebarGroupHeaderRowView.nameFont(
            model: system,
            metrics: SidebarWorkspaceGroupHeaderMetrics(fontScale: system.fontScale)
        )
        let monospacedFont = SidebarGroupHeaderRowView.nameFont(
            model: monospaced,
            metrics: SidebarWorkspaceGroupHeaderMetrics(fontScale: monospaced.fontScale)
        )
        func lineHeight(_ font: NSFont) -> CGFloat {
            ceil(font.ascender - font.descender + font.leading)
        }

        // Whatever the two families measure, the row heights differ exactly
        // where their line heights do.
        #expect((systemHeight == monospacedHeight) == (lineHeight(systemFont) == lineHeight(monospacedFont)))
    }

    private static func groupHeaderModel() -> SidebarGroupHeaderRowModel {
        SidebarGroupHeaderRowModel(
            groupId: UUID(),
            anchorWorkspaceId: UUID(),
            name: "Release 0.42",
            iconSymbol: "folder",
            tintHex: nil,
            isCollapsed: false,
            isPinned: false,
            isAnchorActive: false,
            isMultiSelected: false,
            multiSelectionBackgroundStyle: .clear,
            memberCount: 2,
            anchorUnreadCount: 0,
            canMarkRead: false,
            canMarkUnread: true,
            hasLatestNotifications: false,
            canMarkAllRead: false,
            canMarkAllUnread: true,
            shortcutHintText: nil,
            shortcutHintXOffset: 0,
            shortcutHintYOffset: 0,
            fontScale: 1,
            globalFontMagnificationPercent: 100,
            cwdContextMenuItems: [],
            rowSpacing: 2,
            isFirstRow: true,
            isBeingDragged: false,
            topDropIndicatorVisible: false,
            bottomDropIndicatorVisible: false,
            colorSchemeIsDark: false,
            notificationBadgeColorHex: nil
        )
    }
}

/// A monospaced family is wider per character than the system font, so the
/// truncation work has to be re-measured with the font the chrome now follows.
///
/// The titles include a CJK title and an emoji title because those are the
/// cases where a monospaced family hands rendering to a fallback font with
/// different advances.
@Suite
@MainActor
struct SidebarChromeFontTitleRoomTests {
    static let titles = SidebarWorkspaceTitleRoomTests.titles + [
        "サイドバーのタイトル切り詰め",
        "🚀 Release 0.42 shipping checklist",
    ]

    /// Leading characters of `title` that fit on the title line at the default
    /// sidebar width, drawn in `typeface`.
    static func visibleCharacters(of title: String, typeface: CmuxChromeTypeface) -> Int {
        let font = CmuxChromeFont.appKitFont(
            typeface: typeface,
            size: SidebarRowTitleMetrics.fontSize,
            weight: .regular
        )
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let limit = SidebarWorkspaceTitleRoomTests.current.titleWidth
        var fitting = 0
        for count in 1...title.count {
            let prefix = String(title.prefix(count))
            if ceil((prefix as NSString).size(withAttributes: attributes).width) <= limit {
                fitting = count
            } else {
                break
            }
        }
        return fitting
    }

    @Test
    func monospacedTitlesStillReadPastADozenCharacters() {
        var report = ["title | system | monospaced"]
        for title in Self.titles {
            let system = Self.visibleCharacters(of: title, typeface: .system)
            let monospaced = Self.visibleCharacters(of: title, typeface: .monospacedSystem)
            report.append("\(title) | \(system) | \(monospaced)")
            // The complaint this work answers was titles cutting off around a
            // dozen characters. A wider family may cost characters; it may not
            // put the titles back where they were.
            #expect(monospaced > 12, "\(title) cuts off at \(monospaced) monospaced characters")
        }
        print(
            "sidebar title room at \(Int(SessionPersistencePolicy.defaultSidebarWidth))pt "
                + "by typeface\n" + report.joined(separator: "\n")
        )
    }

    @Test
    func monospacedFamiliesDrawCJKAndEmoji() {
        // A monospaced family covers Latin only; the rest is drawn by fallback
        // fonts, which is fine as long as the glyphs are not dropped.
        for typeface in [CmuxChromeTypeface.monospacedSystem, .family("Menlo")] {
            let font = CmuxChromeFont.appKitFont(
                typeface: typeface,
                size: SidebarRowTitleMetrics.fontSize,
                weight: .regular
            )
            for title in ["サイドバー", "🚀 workspace", "prototype run"] {
                let width = (title as NSString).size(withAttributes: [.font: font]).width
                #expect(width > 0, "\(title) measured as empty in \(font.fontName)")
            }
        }
    }
}
