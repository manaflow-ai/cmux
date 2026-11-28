import CNMProtocol
import SwiftUI

/// The AI-app composer: a floating glass box with the prompt on top and a
/// row of chips (mode, model) under it; the round button sends, and turns
/// into stop while the agent works. Typing "/" lists the agent's commands.
struct AgentComposer: View {
    @Binding var text: String
    @Binding var attachments: [ComposerImage]
    var focused: FocusState<Bool>.Binding
    let placeholder: String
    let working: Bool
    let canSend: Bool
    let modes: [AgentChoice]
    let currentMode: String?
    let models: [AgentChoice]
    let currentModel: String?
    let commands: [SlashCommand]
    let onMode: (String) -> Void
    let onModel: (String) -> Void
    let send: () -> Void
    let stop: () -> Void

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty }

    private var matchingCommands: [SlashCommand] {
        guard text.hasPrefix("/"), !text.contains(" ") else { return [] }
        let query = text.dropFirst().lowercased()
        return commands.filter { query.isEmpty || $0.name.lowercased().hasPrefix(query) }.prefix(6).map { $0 }
    }

    var body: some View {
        VStack(spacing: 8) {
            if !matchingCommands.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matchingCommands) { command in
                        Button {
                            text = "/\(command.name) "
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Text("/\(command.name)").font(.system(size: 15, weight: .medium, design: .monospaced))
                                Text(command.description).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .frame(height: 40)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.thickMaterial, in: .rect(cornerRadius: 18))
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            VStack(alignment: .leading, spacing: 6) {
                if !attachments.isEmpty { AttachmentStrip(attachments: $attachments) }
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.system(size: 17))
                    .lineLimit(1...8)
                    .focused(focused)
                    .padding(.horizontal, 6)
                    .padding(.top, 4)
                    .accessibilityIdentifier("agent.field")
                HStack(spacing: 8) {
                    AttachButton(attachments: $attachments)
                    // Full chip names scroll sideways instead of truncating.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            if !modes.isEmpty {
                                chipMenu(
                                    title: modes.first { $0.id == currentMode }?.name ?? String(localized: "Mode"),
                                    symbol: "slider.horizontal.3", choices: modes, current: currentMode, pick: onMode
                                )
                                .accessibilityIdentifier("agent.mode")
                            }
                            if !models.isEmpty {
                                chipMenu(
                                    title: models.first { $0.id == currentModel }?.name ?? String(localized: "Model"),
                                    symbol: "cpu", choices: models, current: currentModel, pick: onModel
                                )
                            }
                        }
                    }
                    actionButton
                }
            }
            .padding(10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26))
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.snappy(duration: 0.2), value: matchingCommands.map(\.name))
    }

    private var actionButton: some View {
        Button {
            if working, !hasText { stop() } else { send() }
        } label: {
            Image(systemName: working && !hasText ? "stop.fill" : "arrow.up")
                .font(.system(size: working && !hasText ? 13 : 16, weight: .bold))
                .foregroundStyle(Color(.systemBackground))
                .frame(width: 34, height: 34)
                .background(Circle().fill(buttonEnabled ? Color.primary : Color.primary.opacity(0.2)))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!buttonEnabled)
        .animation(.snappy(duration: 0.2), value: working)
        .animation(.snappy(duration: 0.2), value: hasText)
        .accessibilityLabel(working && !hasText ? "Stop" : "Send")
        .accessibilityIdentifier("agent.send")
    }

    private var buttonEnabled: Bool { (working && !hasText) || (hasText && canSend) }

    private func chipMenu(title: String, symbol: String, choices: [AgentChoice], current: String?, pick: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button {
                    pick(choice.id)
                } label: {
                    if choice.id == current {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                    if let detail = choice.detail { Text(detail) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                Text(title).font(.system(size: 14, weight: .medium)).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color(.tertiarySystemFill), in: .capsule)
        }
        .tint(.primary)
    }
}
