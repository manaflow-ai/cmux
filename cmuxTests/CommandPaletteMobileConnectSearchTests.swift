import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Command palette mobile connect search")
struct CommandPaletteMobileConnectSearchTests {
    @Test func mobileConnectCommandIsFoundByMobileDeviceQueries() {
        let mobileConnect = CommandPaletteSearchCorpusEntry(
            payload: "palette.mobileConnect",
            rank: 0,
            title: "Connect iPhone/iPad",
            searchableTexts: ["Connect iPhone/iPad", "Mobile"]
                + ContentView.commandPaletteMobileConnectKeywords
        )
        let decoys = Self.makeCommandEntries(count: 64)
        let corpus = [mobileConnect] + decoys

        for query in ["ios", "ipados", "iphone", "ipad", "pair", "mobile", "phone", "connect"] {
            let firstID = CommandPaletteSearchEngine.search(entries: corpus, query: query) { _, _ in 0 }
                .first?
                .payload
            #expect(
                firstID == "palette.mobileConnect",
                "Expected Connect iPhone/iPad to be the top command palette result for query \"\(query)\""
            )
        }
    }

    private static func makeCommandEntries(count: Int) -> [CommandPaletteSearchCorpusEntry<String>] {
        (0..<count).map { index in
            let title: String
            let subtitle: String
            let keywords: [String]

            switch index % 8 {
            case 0:
                title = "Rename Workspace \(index)"
                subtitle = "Workspace"
                keywords = ["rename", "workspace", "title", "project", "switch"]
            case 1:
                title = "Rename Tab \(index)"
                subtitle = "Tab"
                keywords = ["rename", "tab", "surface", "title"]
            case 2:
                title = "Open Current Directory in IDE \(index)"
                subtitle = "Terminal"
                keywords = ["open", "directory", "cwd", "ide", "vscode"]
            case 3:
                title = "Toggle Sidebar \(index)"
                subtitle = "Layout"
                keywords = ["toggle", "sidebar", "layout", "panel"]
            case 4:
                title = "Apply Update If Available \(index)"
                subtitle = "Global"
                keywords = ["apply", "update", "install", "upgrade"]
            case 5:
                title = "Restart CLI Listener \(index)"
                subtitle = "Global"
                keywords = ["restart", "cli", "listener", "socket", "cmux"]
            case 6:
                title = "Show Notifications \(index)"
                subtitle = "Notifications"
                keywords = ["notifications", "inbox", "unread", "alerts"]
            default:
                title = "Split Browser Right \(index)"
                subtitle = "Layout"
                keywords = ["split", "browser", "right", "layout", "web"]
            }

            return CommandPaletteSearchCorpusEntry(
                payload: "command.\(index)",
                rank: index + 1,
                title: title,
                searchableTexts: [title, subtitle] + keywords
            )
        }
    }
}
