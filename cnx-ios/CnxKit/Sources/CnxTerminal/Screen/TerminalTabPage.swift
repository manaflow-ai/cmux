#if os(iOS)
import SwiftUI
import UIKit

/// One terminal tab inside a workspace (CmuxTabsKit): the model and its
/// controller, kept alive while the tab exists so the Ghostty surface, the
/// scrollback and the input state survive tab switches and the grid.
@MainActor
public final class TerminalTabHost {
    public let model: TerminalModel
    private(set) lazy var controller = TerminalViewController(model: model, chrome: .embedded)

    public init(model: TerminalModel) {
        self.model = model
    }

    /// The tab grid is about to show this tab's card.
    public func prepareCard() {
        model.captureSnapshot()
    }
}

/// The embedded terminal page (SPEC 10 inside a workspace). TabsKit owns the
/// chrome: no navigation bar, the title and tab switching live in TabsKit's
/// toolbar and grid, and the terminal's actions in the page menu. The key bar
/// and composer rest where TabsKit puts a tab accessory (8 pt above the
/// toolbar) and ride the keyboard; in TUI mode the grid's bottom is pinned to
/// the composer and its top is clipped under the status bar.
public struct TerminalTabPage: View {
    let host: TerminalTabHost
    /// Status bar (top) and toolbar (bottom) over the page.
    let insets: EdgeInsets
    /// The page is settled full screen (no zoom, swipe or open menu).
    let isInteractive: Bool

    public init(host: TerminalTabHost, insets: EdgeInsets, isInteractive: Bool) {
        self.host = host
        self.insets = insets
        self.isInteractive = isInteractive
    }

    public var body: some View {
        @Bindable var model = host.model
        EmbeddedTerminalControllerView(host: host, insets: insets, isInteractive: isInteractive)
            .ignoresSafeArea()
            .background(Color.black)
            // Presented by the controller (UIKit), not with `.sheet` here: a
            // SwiftUI sheet presented from inside the TabsKit page left the
            // controller's keyboard layout guide at 172 pt with no keyboard
            // (the stack jumped to the top) until the next keyboard change.
            .onChange(of: model.showArtifacts) { _, shown in
                if shown { host.controller.presentArtifacts() } else { host.controller.dismissArtifacts() }
            }
    }
}

/// The tab's grid card: the last snapshot of the page (no second live
/// surface), or a quiet placeholder before the page has been on screen.
public struct TerminalTabCard: View {
    let model: TerminalModel
    let insets: EdgeInsets

    public init(model: TerminalModel, insets: EdgeInsets) {
        self.model = model
        self.insets = insets
    }

    public var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(uiColor: CnxGhosttyApp.background)
                if let image = model.snapshot {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: geo.size.width, height: geo.size.width * image.size.height / max(1, image.size.width))
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                        .clipped()
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(model.programName) — \(model.title)")
                            .foregroundStyle(Color.white.opacity(0.45))
                        HStack(spacing: 0) {
                            Text("$ ")
                            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 8, height: 15)
                        }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.top, insets.top + 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

struct EmbeddedTerminalControllerView: UIViewControllerRepresentable {
    let host: TerminalTabHost
    let insets: EdgeInsets
    let isInteractive: Bool

    func makeUIViewController(context: Context) -> TerminalViewController {
        let controller = host.controller
        // The same controller comes back when the tab is shown again; a page
        // being replaced may still hold it for a moment.
        if controller.parent != nil {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        return controller
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {
        controller.setEmbeddedInsets(UIEdgeInsets(top: insets.top, left: 0, bottom: insets.bottom, right: 0))
        // A zoom to the grid, a swipe or the page menu takes the page: the
        // keyboard goes, as in Safari.
        if !isInteractive, host.model.keyboardVisible {
            controller.hideKeyboard()
        }
    }

    static func dismantleUIViewController(_ controller: TerminalViewController, coordinator: ()) {}
}
#endif
