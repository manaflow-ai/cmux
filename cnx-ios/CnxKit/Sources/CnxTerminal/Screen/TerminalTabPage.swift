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
            // Zoomed into the grid or mid-swipe, the page is a picture: its
            // composer and key bar are not controls then (R4-3).
            .accessibilityHidden(!isInteractive)
            .ignoresSafeArea()
            .background(Color.black)
            // Not attached yet: the honest placeholder over the empty surface.
            .overlay {
                if case .reattaching = model.connectionState {
                    // Reattaching: a warm surface keeps its last frame live
                    // under no overlay; a cold tab shows its frame dimmed. The
                    // title pill says "Reattaching…" after 400 ms (SPEC P5).
                    if let frame = model.coldFrame {
                        TerminalConnectingView(state: model.connectionState, topInset: insets.top, lastFrame: frame, showsLabel: false)
                            .ignoresSafeArea()
                            .padding(.bottom, insets.bottom)
                            .transition(.opacity)
                    }
                } else if !model.connectionState.isAttached || model.coldFrame != nil {
                    // One view from "Connecting…" to live (R2-5): a tab back
                    // from the warm set or a cold restore shows its last frame
                    // at once; once attached the label goes, the frame stays
                    // until the live rows are drawn, then goes in one frame: a cut,
                    // never a fade over live rows at other positions (R3-4).
                    // (Two views crossfading here flashed the title pill grey.)
                    TerminalConnectingView(state: model.connectionState, topInset: insets.top, lastFrame: model.coldFrame,
                                           showsLabel: !model.connectionState.isAttached)
                        .ignoresSafeArea()
                        .padding(.bottom, insets.bottom)
                        .transition(.identity)
                }
            }
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

    private var isReattaching: Bool {
        if case .reattaching = model.connectionState { return true }
        return false
    }

    public init(model: TerminalModel, insets: EdgeInsets) {
        self.model = model
        self.insets = insets
    }

    /// The connecting placeholder (spinner and label) only for a tab whose
    /// session was started (its page was laid out). A tab not opened in this
    /// launch has no session yet, so a spinner there never ends (D5,
    /// T-TABS-02): it shows its saved frame, or the static placeholder.
    static func showsConnecting(state: TerminalConnectionState, sessionStarted: Bool) -> Bool {
        !state.isAttached && sessionStarted
    }

    public var body: some View {
        // A picture of the page: TabsKit labels the card; nothing inside it
        // is a control (R4-3).
        cardContent.accessibilityHidden(true)
    }

    private var cardContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color(uiColor: CnxGhosttyApp.background)
                if Self.showsConnecting(state: model.connectionState, sessionStarted: model.controller?.started == true) {
                    TerminalConnectingView(state: model.connectionState, topInset: insets.top, lastFrame: model.snapshot,
                                           showsLabel: !isReattaching)
                } else if let image = model.snapshot {
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
