#if os(iOS)
import CmuxAgentQuestion
import CnxAgentChat
import CnxDesign
import SwiftUI
import UIKit

/// Under the chat header while Chief asks something: one glass bar, as
/// Messages shows a business chat's pending request, that opens the
/// question. It says where an answer is ("Waiting for Face ID…",
/// "Sending…") and goes away once the Mac stored it.
struct ChiefQuestionBar: View {
    let session: ChiefSession
    let open: (AgentQuestion) -> Void
    /// The bar grew, shrank or went away: its UIKit host lays it out again.
    var resized: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) { content }
            .animation(.snappy, value: session.openQuestion?.id)
            .onChange(of: layoutKey) { resized() }
    }

    /// What changes the bar's height: the question, and its status line.
    private var layoutKey: String {
        guard let question = session.openQuestion else { return "" }
        return question.id + (session.answers[question.id]?.statusText ?? "")
    }

    @ViewBuilder private var content: some View {
        if let question = session.openQuestion {
            let flow = session.answers[question.id] ?? ChiefAnswerFlow()
            Button { open(question) } label: {
                HStack(spacing: 10) {
                    if flow.isBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "questionmark.bubble.fill").font(.body)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Chief is asking").font(.footnote.weight(.semibold))
                        Text(flow.statusText ?? question.items.first?.prompt ?? "")
                            .font(.footnote)
                            .foregroundStyle(isFailed(flow) ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    if !flow.isBusy {
                        Text("Answer").font(.footnote.weight(.semibold))
                    }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("chief.question.bar")
            .accessibilityHint("Opens Chief's question")
            .transition(.opacity.combined(with: .offset(y: -8)))
        }
    }

    private func isFailed(_ flow: ChiefAnswerFlow) -> Bool {
        if case .failed = flow.state { return true }
        return false
    }
}

/// Chief's question, answered here: the Feed's question card, then the
/// answer's state under it. Answer asks for Face ID; the sheet closes only
/// once the Mac stored the answer.
struct ChiefQuestionSheet: View {
    let session: ChiefSession
    let questionID: String
    @Environment(\.dismiss) private var dismiss

    private var question: AgentQuestion? { session.questions.first { $0.id == questionID } }
    private var flow: ChiefAnswerFlow { session.answers[questionID] ?? ChiefAnswerFlow() }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        ChiefAvatar(text: session.avatar, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title ?? session.identity.title).font(.headline)
                            Text("Your answer is signed with Face ID on this iPhone.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if let question {
                        QuestionCard(question: question, showsHeader: false) { answer in
                            session.answer(question, with: answer)
                        }
                        .disabled(flow.isBusy)
                    }
                    if let text = flow.statusText {
                        statusRow(text)
                    }
                }
                .padding(16)
            }
            .navigationTitle("Chief's Question")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("chief.question.close")
                }
            }
        }
        .onChange(of: flow.state) { _, state in
            if state == .sent { dismiss() }
        }
        .accessibilityIdentifier("chief.question.sheet")
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            if flow.isBusy {
                ProgressView().controlSize(.small)
            } else if flow.state == .sent {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(flow.isBusy ? Color.secondary : Color.primary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chief.question.status")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
#endif
