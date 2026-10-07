import CmuxiOSFeatureKit
import SwiftUI

/// Option chips per question, Other (composer), Submit when complete.
struct FeedChoiceControls: View {
    let model: FeedCardModel
    let choice: FeedChoice
    let actions: FeedCardActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(choice.questions) { question in
                questionView(question)
            }
            Button(FeedText.submit) { actions.answer(model.item.id, .choice(model.choiceDraft)) }
                .buttonStyle(FeedButtonStyle(role: .primary))
                .disabled(!choice.isComplete(model.choiceDraft))
        }
        .disabled(!model.canAnswer)
    }

    private func questionView(_ question: FeedChoiceQuestion) -> some View {
        let selection = model.choiceDraft[question.id] ?? FeedChoiceSelection()
        return VStack(alignment: .leading, spacing: 6) {
            if choice.questions.count > 1 || question.question != model.item.title {
                HStack(spacing: 6) {
                    if let header = question.header {
                        Text(header).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    if question.multi {
                        Text(FeedText.multiSelect).font(.caption).foregroundStyle(.tertiary)
                    }
                }
                Text(question.question).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
            FeedFlowLayout {
                ForEach(question.options) { option in
                    let isSelected = selection.selected.contains(option.id)
                    Button(option.label) { actions.toggleChoice(model.item.id, question, option.id) }
                        .buttonStyle(FeedChipStyle(isSelected: isSelected))
                        .accessibilityHint(option.detail ?? "")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
                if question.allowOther {
                    Button(selection.other ?? FeedText.other) {
                        actions.compose(.choiceOther(itemID: model.item.id, question: question))
                    }
                    .buttonStyle(FeedChipStyle(isSelected: selection.other != nil))
                }
            }
            if model.expanded {
                ForEach(question.options.filter { $0.detail != nil }) { option in
                    Text("\(option.label): \(option.detail ?? "")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
