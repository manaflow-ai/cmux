import CmuxiOSFeatureKit
import SwiftUI

/// One feed card: header (glyph, source, time, unread dot), title, body,
/// kind-specific inline controls or the resolution line.
struct FeedCardView: View {
    let model: FeedCardModel
    let actions: FeedCardActions

    private var item: FeedItem { model.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            Text(item.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            prompt
            if !item.body.isEmpty {
                Text(bodyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(model.expanded ? nil : 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
            footer
        }
        .padding(.vertical, 4)
    }

    private var bodyText: AttributedString {
        (try? AttributedString(markdown: item.body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(item.body)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: FeedGlyph.symbol(item.kind))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(item.isOpenRequest ? Color.orange : Color.secondary)
                .accessibilityHidden(true)
            Text(item.source.isEmpty ? FeedText.title : item.source)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(item.createdAt.formatted(.relative(presentation: .named)))
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            if !item.isRead {
                Circle().fill(Color.primary).frame(width: 8, height: 8)
                    .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder private var prompt: some View {
        switch item.kind {
        case .permission(let permission):
            FeedPermissionSummary(permission: permission, expanded: model.expanded)
        case .question(let question) where !question.question.isEmpty && question.question != item.title:
            Text(question.question).font(.body).fixedSize(horizontal: false, vertical: true)
        case .confirm(let confirm) where !confirm.statement.isEmpty:
            Text(confirm.statement).font(.body).fixedSize(horizontal: false, vertical: true)
        case .planApproval(let plan) where model.expanded && !plan.checklist.isEmpty:
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(plan.checklist.enumerated()), id: \.offset) { _, step in
                    Label(step, systemImage: "circle").font(.subheadline)
                }
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var controls: some View {
        if item.isOpenRequest {
            switch item.kind {
            case .permission(let permission):
                FeedPermissionControls(model: model, permission: permission, actions: actions)
            case .question(let question):
                FeedQuestionControls(model: model, question: question, actions: actions)
            case .choice(let choice):
                FeedChoiceControls(model: model, choice: choice, actions: actions)
            case .planApproval:
                FeedPlanControls(model: model, actions: actions)
            case .confirm(let confirm):
                FeedConfirmControls(model: model, confirm: confirm, actions: actions)
            case .unsupported(_, let needsMac):
                FeedUnsupportedControls(model: model, needsMac: needsMac, actions: actions)
            case .done:
                EmptyView()
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if model.isPending {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(FeedText.sending).font(.footnote).foregroundStyle(.secondary)
            }
        } else if let resolution = FeedText.resolution(item) {
            Label(resolution, systemImage: FeedGlyph.resolutionSymbol(item))
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
