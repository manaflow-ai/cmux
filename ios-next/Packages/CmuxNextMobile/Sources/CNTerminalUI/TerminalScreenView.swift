#if os(iOS)
public import CNTransport
import CNCore
import Foundation
import CNDesign
public import SwiftUI
import UIKit

/// State of one terminal screen, shared by the SwiftUI chrome and the UIKit
/// controller that hosts the Ghostty surface.
@MainActor
@Observable
final class TerminalScreenModel {
    enum Status: Equatable {
        case attaching, live, reconnecting, exited
        case failed(String)
    }

    var terminal: Terminal?
    var status: Status = .attaching
    var grid = ""
    var fontSize = TerminalFontSize.stored
    var outputBytes = 0
    var keyboardShift: CGFloat = 0
    @ObservationIgnored weak var controller: TerminalViewController?

    init() {}
}

/// One terminal, full-bleed under a compact navigation bar: Ghostty draws
/// the host's terminal; tap shows the keyboard and the glass key bar; one
/// finger scrolls the scrollback; pinch changes the text size; long press
/// selects and copies. Reconnects re-attach (the host replays scrollback).
public struct TerminalScreenView: View {
    let connection: HostConnection
    let terminalId: String
    @State private var model = TerminalScreenModel()

    public init(connection: HostConnection, terminalId: String) {
        self.connection = connection
        self.terminalId = terminalId
    }

    public var body: some View {
        TerminalSurfaceRepresentable(connection: connection, terminalId: terminalId, model: model,
                                     generation: connection.generation)
            .ignoresSafeArea(.keyboard)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color.cn(\.terminalBackground).ignoresSafeArea())
            .overlay(alignment: .top) { statusBanner }
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
                    case .terminalUpdated(let terminal) where terminal.id == terminalId:
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

    @ViewBuilder private var statusBanner: some View {
        let text: String? = switch model.status {
        case .reconnecting: TerminalText.reconnecting
        case .exited: TerminalText.processExited
        case .failed(let message): message
        case .attaching, .live: connection.state.isConnected ? nil : TerminalText.reconnecting
        }
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
        }
    }
}

/// Hosts the UIKit terminal controller; passes connection generation changes on.
struct TerminalSurfaceRepresentable: UIViewControllerRepresentable {
    let connection: HostConnection
    let terminalId: String
    let model: TerminalScreenModel
    let generation: Int

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController(connection: connection, terminalId: terminalId, model: model)
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {
        _ = generation
        controller.sync()
    }
}
#endif
