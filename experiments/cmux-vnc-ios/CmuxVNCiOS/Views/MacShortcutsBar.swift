import CmuxVNC
import SwiftUI

/// One-tap Mac shortcuts under the session toolbar (Spotlight, Mission
/// Control, the app switcher, editing keys), sent as key chords.
struct MacShortcutsBar: View {
    let session: RemoteSession

    struct Shortcut: Identifiable {
        let id: String
        let symbol: String
        let modifiers: [VNCKeysym]
        let key: VNCKeysym
    }

    static func letter(_ character: Character) -> VNCKeysym { VNCKeysym(character: character) }

    static let shortcuts: [Shortcut] = [
        Shortcut(id: "Spotlight", symbol: "magnifyingglass", modifiers: [.command], key: .space),
        Shortcut(id: "Mission Control", symbol: "rectangle.3.group", modifiers: [.control], key: .up),
        Shortcut(id: "App Windows", symbol: "macwindow.on.rectangle", modifiers: [.control], key: .down),
        Shortcut(id: "Switch App", symbol: "square.stack.3d.up", modifiers: [.command], key: .tab),
        Shortcut(id: "Copy", symbol: "doc.on.doc", modifiers: [.command], key: letter("c")),
        Shortcut(id: "Paste", symbol: "doc.on.clipboard", modifiers: [.command], key: letter("v")),
        Shortcut(id: "Undo", symbol: "arrow.uturn.backward", modifiers: [.command], key: letter("z")),
        Shortcut(id: "Select All", symbol: "selection.pin.in.out", modifiers: [.command], key: letter("a")),
        Shortcut(id: "New Tab", symbol: "plus.square.on.square", modifiers: [.command], key: letter("t")),
        Shortcut(id: "Close Window", symbol: "xmark.square", modifiers: [.command], key: letter("w")),
        Shortcut(id: "Quit App", symbol: "power", modifiers: [.command], key: letter("q")),
        Shortcut(id: "Screenshot", symbol: "camera.viewfinder", modifiers: [.command, .shift], key: letter("4")),
        Shortcut(id: "Force Quit", symbol: "exclamationmark.octagon", modifiers: [.command, .option], key: .escape),
        Shortcut(id: "Lock Screen", symbol: "lock", modifiers: [.control, .command], key: letter("q")),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.shortcuts) { shortcut in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        session.tap(shortcut.key, modifiers: shortcut.modifiers)
                    } label: {
                        Label(shortcut.id, systemImage: shortcut.symbol)
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Sends the Mac shortcut")
                }
            }
            .padding(.horizontal, 10)
        }
    }
}
