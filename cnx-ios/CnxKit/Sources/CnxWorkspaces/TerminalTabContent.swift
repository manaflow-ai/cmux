#if os(iOS)
import CnxDesign
import CnxModel
import SwiftUI

/// What a terminal tab's page needs to know from the tabs chrome.
public struct TerminalTabContext {
    /// Status bar (top) and tab toolbar (bottom) over the page.
    public var safeAreaInsets: EdgeInsets
    /// The page is settled full screen and takes input.
    public var isInteractive: Bool
    /// A pinch is driving the tab zoom: suspend the terminal's own pinch.
    public var isZoomGestureActive: Bool
    /// Finger travel on the page (positive = finger down); collapses and
    /// expands the tab toolbar.
    public var reportScroll: @MainActor (CGFloat) -> Void

    public init(safeAreaInsets: EdgeInsets, isInteractive: Bool, isZoomGestureActive: Bool,
                reportScroll: @escaping @MainActor (CGFloat) -> Void) {
        self.safeAreaInsets = safeAreaInsets
        self.isInteractive = isInteractive
        self.isZoomGestureActive = isZoomGestureActive
        self.reportScroll = reportScroll
    }
}

/// The seam CnxTerminal plugs into: a workspace's terminal tabs ask this for
/// their page (laid out at full screen size, drawn under the status bar and
/// the tab toolbar), their grid card, and an optional row above the toolbar
/// (the key bar and composer of SPEC 10.2, riding the keyboard).
@MainActor
public protocol TerminalTabContent: AnyObject {
    func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView
    func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView
    func accessory(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView?
}

extension TerminalTabContent {
    public func accessory(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView? { nil }
}

/// Stand-in until CnxTerminal lands: a static terminal-looking page.
public final class PlaceholderTerminalTabContent: TerminalTabContent {
    public init() {}

    public func page(for tab: WorkspaceTab, in workspace: Workspace, context: TerminalTabContext) -> AnyView {
        AnyView(PlaceholderTerminalPage(tab: tab, workspace: workspace, insets: context.safeAreaInsets))
    }

    public func card(for tab: WorkspaceTab, in workspace: Workspace) -> AnyView {
        AnyView(PlaceholderTerminalPage(tab: tab, workspace: workspace, insets: EdgeInsets(top: 62, leading: 0, bottom: 90, trailing: 0)))
    }
}

struct PlaceholderTerminalPage: View {
    let tab: WorkspaceTab
    let workspace: Workspace
    let insets: EdgeInsets

    private var lines: [String] {
        let dir = tab.subtitle ?? workspace.directory
        return [
            "Last login: Sun Oct 12 09:41:07 on ttys004",
            "\(dir) \(workspace.branch.map { "(\($0)) " } ?? "")$ \(tab.title)",
            "",
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? " " : line)
            }
            HStack(spacing: 0) {
                Text("\(tab.subtitle ?? workspace.directory) $ ")
                Rectangle().fill(Color.white.opacity(0.85)).frame(width: 8, height: 15)
            }
            Spacer(minLength: 0)
            Text("Live terminal arrives with CnxTerminal")
                .font(.footnote)
                .foregroundStyle(Color.white.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.bottom, 12)
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(Color.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.top, insets.top + 8)
        .padding(.bottom, insets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}
#endif
