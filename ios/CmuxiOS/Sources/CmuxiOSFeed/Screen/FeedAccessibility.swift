import CmuxiOSFeatureKit
import UIKit

/// VoiceOver for a card cell: one element with a combined label and a
/// custom action per inline control, so every answer is reachable without
/// hunting for buttons inside the card.
@MainActor
enum FeedAccessibility {
    static func label(_ item: FeedItem) -> String {
        var parts: [String] = []
        if item.isOpenRequest { parts.append(FeedText.openRequest) }
        if !item.isRead { parts.append(FeedText.unread) }
        parts.append(item.title)
        switch item.kind {
        case .permission(let permission):
            parts.append(permission.summary.isEmpty ? FeedText.actionType(permission.actionType) : permission.summary)
            if let command = permission.command { parts.append(command) }
        case .question(let question) where question.question != item.title:
            parts.append(question.question)
        case .confirm(let confirm):
            parts.append(confirm.statement)
        default:
            break
        }
        if !item.body.isEmpty { parts.append(item.body) }
        if !item.source.isEmpty { parts.append(item.source) }
        parts.append(item.createdAt.formatted(.relative(presentation: .named)))
        if let resolution = FeedText.resolution(item) { parts.append(resolution) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }

    static func actions(_ model: FeedCardModel, card: FeedCardActions, markRead: @escaping @MainActor () -> Void,
                        archive: @escaping @MainActor () -> Void) -> [UIAccessibilityCustomAction] {
        let item = model.item
        var actions: [UIAccessibilityCustomAction] = []
        func add(_ name: String, _ handler: @escaping @MainActor () -> Void) {
            actions.append(UIAccessibilityCustomAction(name: name) { _ in
                handler()
                return true
            })
        }
        if model.canAnswer {
            switch item.kind {
            case .permission(let permission):
                for scope in permission.offeredScopes {
                    add(permission.offeredScopes.count > 1 ? FeedText.allowScope(scope) : FeedText.allow) {
                        card.answer(item.id, .permission(allow: true, scope: scope))
                    }
                }
                add(FeedText.deny) { card.answer(item.id, .permission(allow: false, scope: nil)) }
            case .question(let question):
                for suggestion in question.suggestions {
                    add(suggestion) { card.answer(item.id, .text(suggestion)) }
                }
                add(FeedText.reply) { card.compose(.questionReply(itemID: item.id, prompt: question.question)) }
            case .choice(let choice):
                for question in choice.questions {
                    for option in question.options {
                        let picked = model.choiceDraft[question.id]?.selected.contains(option.id) == true
                        add(picked ? "\(option.label), \(FeedText.selected)" : option.label) {
                            card.toggleChoice(item.id, question, option.id)
                        }
                    }
                    if question.allowOther {
                        add(FeedText.other) { card.compose(.choiceOther(itemID: item.id, question: question)) }
                    }
                }
                if choice.isComplete(model.choiceDraft) {
                    add(FeedText.submit) { card.answer(item.id, .choice(model.choiceDraft)) }
                }
            case .planApproval:
                add(FeedText.approvePlan) { card.answer(item.id, .plan(approved: true, comment: nil)) }
                add(FeedText.requestChanges) { card.compose(.planChanges(itemID: item.id)) }
            case .confirm(let confirm):
                add(confirm.confirmLabel ?? FeedText.confirm) { card.answer(item.id, .confirm(true)) }
                add(confirm.cancelLabel ?? FeedText.cancel) { card.answer(item.id, .confirm(false)) }
            case .done, .unsupported:
                break
            }
        }
        if model.canDecline { add(FeedText.decline) { card.decline(item.id) } }
        if !item.isRead { add(FeedText.markRead, markRead) }
        if !item.isOpenRequest, !item.isArchived, model.isLive { add(FeedText.archive, archive) }
        return actions
    }
}
