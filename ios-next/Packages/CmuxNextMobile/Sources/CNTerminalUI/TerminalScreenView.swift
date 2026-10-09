#if os(iOS)
public import CNTransport
import CNCore
import Foundation
import CNDesign
public import SwiftUI
import UIKit

/// Where a terminal screen points: an existing terminal, or a new one the
/// screen creates once it knows the grid that fits it.
enum TerminalRoute: Hashable {
    case existing(String)
    case new(UUID)

    var existingId: String? {
        if case .existing(let id) = self { return id }
        return nil
    }
}

/// State of one terminal screen, shared by the SwiftUI chrome and the UIKit
/// controller that hosts the Ghostty surface.
@MainActor
@Observable
final class TerminalScreenModel {
    enum Status: Equatable {
        case attaching, live, reconnecting, exited
        /// The terminal no longer exists on the Mac (host restarted, closed).
        case ended
        case failed(String)
    }

    var terminal: Terminal?
    var status: Status = .attaching
    var grid = ""
    var fontSize = TerminalFontSize.stored
    var outputBytes = 0
    var keyboardShift: CGFloat = 0
    /// The composer row is shown (else typing goes straight to the terminal).
    var composerMode = false
    var composerText = ""
    /// The composer's desired focus; `composerFocusRequest` bumps to apply it.
    var composerWantsFocus = false
    var composerFocusRequest = 0
    var uploading = 0
    var uploadError: String?
    @ObservationIgnored weak var controller: TerminalViewController?

    init() {}
}

/// One terminal, full-bleed under a compact navigation bar: Ghostty draws
/// the host's terminal; tap shows the keyboard and the glass key bar; one
/// finger scrolls the scrollback; pinch changes the text size; long press
/// selects and copies. Reconnects re-attach (the host replays scrollback).
public struct TerminalScreenView: View {
    let connection: HostConnection
    /// The terminal shown; "New Terminal" from the ended state replaces it.
    @State private var route: TerminalRoute
    @State private var model = TerminalScreenModel()
    @State private var createdId: String?
    @Environment(\.dismiss) private var dismiss

    public init(connection: HostConnection, terminalId: String) {
        self.init(connection: connection, route: .existing(terminalId))
    }

    init(connection: HostConnection, route: TerminalRoute) {
        self.connection = connection
        _route = State(initialValue: route)
    }

    private var terminalId: String? {
        if case .existing(let id) = route { return id }
        return createdId
    }

    public var body: some View {
        TerminalSurfaceRepresentable(connection: connection, terminalId: route.existingId, model: model,
                                     generation: connection.generation, onCreated: { createdId = $0 })
            .id(route)
            .ignoresSafeArea(.keyboard)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color.cn(\.terminalBackground).ignoresSafeArea())
            .overlay(alignment: .top) { statusBanner }
            .overlay { if model.status == .ended { endedState } }
            .navigationTitle(model.terminal?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        model.controller?.paste()
                    } label: {
                        Label(TerminalText.paste, systemImage: "doc.on.clipboard")
                    }
                    .accessibilityIdentifier("terminal.paste")
                    Menu {
                        Button(TerminalText.copy, systemImage: "doc.on.doc") { model.controller?.copySelection() }
                        Button(TerminalText.selectAll, systemImage: "selection.pin.in.out") { model.controller?.selectAll() }
                        Divider()
                        Button(TerminalText.increaseFontSize, systemImage: "textformat.size.larger") { model.controller?.stepFontSize(by: 1) }
                        Button(TerminalText.decreaseFontSize, systemImage: "textformat.size.smaller") { model.controller?.stepFontSize(by: -1) }
                        Button(TerminalText.resetFontSize, systemImage: "textformat.size") { model.controller?.resetFontSize() }
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["CMUX_NEXT_TERMINAL_DEBUG"] == "1" {
                            // DEBUG: drop the link to exercise reconnect and re-attach.
                            Button("Drop Connection", systemImage: "bolt.horizontal") { connection.client?.close() }
                            // DEBUG: as if the Mac's host restarted (the PTY is gone, then the link drops).
                            Button("Simulate Host Restart", systemImage: "arrow.clockwise") {
                                guard let client = connection.client, let id = terminalId else { return }
                                Task {
                                    try? await client.closeTerminal(id)
                                    client.close()
                                }
                            }
                        }
                        #endif
                    } label: {
                        Label(TerminalText.more, systemImage: "ellipsis")
                    }
                }
            }
            .task(id: terminalId) {
                for await push in connection.pushes() {
                    switch push {
                    case .terminalUpdated(let terminal) where terminal.id == terminalId && model.status != .ended:
                        model.terminal = terminal
                        if !terminal.running { model.status = .exited }
                    case .terminalExited(let id, _) where id == terminalId:
                        model.status = .exited
                    default:
                        break
                    }
                }
            }
    }

    /// The PTY is gone on the Mac: say so and offer a way forward.
    private var endedState: some View {
        ContentUnavailableView {
            Label(TerminalText.endedTitle, systemImage: "apple.terminal")
        } description: {
            Text(TerminalText.endedMessage)
        } actions: {
            Button(TerminalText.newTerminal) {
                // A fresh screen state and controller for a new terminal.
                model = TerminalScreenModel()
                createdId = nil
                route = .new(UUID())
            }
            .buttonStyle(.glassProminent)
            .tint(.cn(\.ink))
            .foregroundStyle(.cn(\.background))
            .accessibilityIdentifier("terminal.ended.new")
            Button(TerminalText.backToTerminals) { dismiss() }
                .buttonStyle(.glass)
                .accessibilityIdentifier("terminal.ended.back")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cn(\.terminalBackground))
    }

    @ViewBuilder private var statusBanner: some View {
        let status: String? = switch model.status {
        case .reconnecting: TerminalText.reconnecting
        case .exited: TerminalText.processExited
        case .ended: nil
        case .failed(let message): message
        case .attaching, .live: connection.state.isConnected ? nil : TerminalText.reconnecting
        }
        let text = model.uploadError ?? status
        if let text {
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.cn(\.textSecondary))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 8)
                .transition(.opacity)
                .accessibilityIdentifier("terminal.status")
                .onTapGesture { model.uploadError = nil }
        }
    }
}

/// Hosts the UIKit terminal controller; passes connection generation changes on.
struct TerminalSurfaceRepresentable: UIViewControllerRepresentable {
    let connection: HostConnection
    let terminalId: String?
    let model: TerminalScreenModel
    let generation: Int
    var onCreated: (String) -> Void = { _ in }

    func makeUIViewController(context: Context) -> TerminalViewController {
        let controller = TerminalViewController(connection: connection, terminalId: terminalId, model: model)
        controller.onCreated = onCreated
        return controller
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {
        _ = generation
        controller.sync()
    }
}
#endif
