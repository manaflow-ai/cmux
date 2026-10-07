import CmuxiOSComposerCore
import UIKit

extension ComposerViewController {
    /// Shows `/` templates or `@` file names for the word under the cursor.
    func updateSuggestions() {
        mentionLookup?.cancel()
        let text = promptView.text ?? ""
        guard promptView.selectedRange.length == 0,
              let trigger = PromptTrigger(text: text, cursor: promptView.selectedRange.location) else {
            activeTrigger = nil
            suggestions.show([])
            return
        }
        activeTrigger = trigger
        switch trigger.kind {
        case .template:
            suggestions.show(feature.templates.matching(trigger.query).map {
                ComposerSuggestionBar.Item(id: "template:" + $0.id, title: "/" + $0.name, subtitle: $0.title)
            })
        case .mention:
            guard let target = session.draft?.target else { return }
            let files = feature.files
            let query = trigger.query
            mentionLookup = Task { [weak self] in
                let names = await files.suggestions(for: query, target: target, limit: 8)
                guard !Task.isCancelled, let self, self.activeTrigger == trigger else { return }
                self.suggestions.show(names.map { ComposerSuggestionBar.Item(id: "file:" + $0, title: "@" + $0) })
            }
        }
    }

    func pickSuggestion(_ id: String) {
        guard let trigger = activeTrigger else { return }
        if id.hasPrefix("template:"), let template = feature.templates.template(String(id.dropFirst("template:".count))) {
            insertTemplate(template, replacing: trigger)
            return
        }
        if id.hasPrefix("file:") {
            let path = String(id.dropFirst("file:".count))
            let next = trigger.applying("@" + path + " ", to: promptView.text ?? "")
            promptView.setPrompt(next.text)
            promptView.selectedRange = NSRange(location: next.cursor, length: 0)
            session.updatePrompt(next.text)
            suggestions.show([])
        }
    }
}
