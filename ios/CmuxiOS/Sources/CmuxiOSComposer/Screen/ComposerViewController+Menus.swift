import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import UIKit

extension ComposerViewController {
    func makePills() -> [ComposerPill] {
        let agents = session.agents
        let agent = session.selectedAgent
        let model = session.selectedModel
        var pills = [
            ComposerPill(id: "agent", symbol: "sparkles", title: agent?.name ?? ComposerText.noAgent, label: ComposerText.agent,
                         menu: agents.isEmpty ? nil : agentMenu(agents, selected: agent?.id)),
        ]
        if let agent, !agent.modelOptions.isEmpty {
            pills.append(ComposerPill(id: "model", symbol: "cpu", title: model?.label ?? ComposerText.defaultModel,
                                      label: ComposerText.model, menu: modelMenu(agent, selected: model?.id)))
        }
        if let model, !model.efforts.isEmpty {
            let effort = session.draft?.effort
            pills.append(ComposerPill(id: "effort", symbol: "gauge.with.dots.needle.50percent",
                                      title: effort.map(ComposerText.effortName) ?? ComposerText.effort,
                                      label: ComposerText.effort, menu: effortMenu(model, selected: effort)))
        }
        pills.append(ComposerPill(id: "templates", symbol: "text.badge.plus", title: ComposerText.templates,
                                  label: ComposerText.templates, menu: templatesMenu()))
        return pills
    }

    private func agentMenu(_ agents: [ComposerAgent], selected: String?) -> UIMenu {
        UIMenu(title: ComposerText.agent, children: agents.map { agent in
            let action = UIAction(title: agent.name, subtitle: agent.unavailableReason,
                                  attributes: agent.isAvailable ? [] : .disabled,
                                  state: agent.id == selected ? .on : .off) { [weak self] _ in
                self?.session.selectAgent(agent.id)
            }
            return action
        })
    }

    private func modelMenu(_ agent: ComposerAgent, selected: String?) -> UIMenu {
        UIMenu(title: ComposerText.model, children: agent.modelOptions.map { model in
            UIAction(title: model.label, state: model.id == selected ? .on : .off) { [weak self] _ in
                self?.session.selectModel(model.id)
            }
        })
    }

    private func effortMenu(_ model: ComposerModel, selected: String?) -> UIMenu {
        UIMenu(title: ComposerText.effort, children: model.efforts.map { effort in
            UIAction(title: ComposerText.effortName(effort), state: effort == selected ? .on : .off) { [weak self] _ in
                self?.session.selectEffort(effort)
            }
        })
    }

    private func templatesMenu() -> UIMenu {
        let library = feature.templates
        let insert = library.all.map { template in
            UIAction(title: template.title, subtitle: "/" + template.name,
                     image: UIImage(systemName: template.isBuiltIn ? "text.quote" : "star")) { [weak self] _ in
                self?.insertTemplate(template, replacing: nil)
            }
        }
        var children: [UIMenuElement] = [UIMenu(options: .displayInline, children: insert)]
        children.append(UIAction(title: ComposerText.saveTemplate, image: UIImage(systemName: "square.and.arrow.down"),
                                 attributes: (session.draft?.prompt.isEmpty ?? true) ? .disabled : []) { [weak self] _ in
            self?.promptForTemplateName()
        })
        if !library.saved.isEmpty {
            children.append(UIMenu(title: ComposerText.deleteTemplate, image: UIImage(systemName: "trash"),
                                   options: .destructive, children: library.saved.map { template in
                UIAction(title: template.title, attributes: .destructive) { [weak self] _ in
                    self?.feature.templates.delete(template.id)
                    self?.render()
                }
            }))
        }
        return UIMenu(title: ComposerText.templates, children: children)
    }

    func attachMenu() -> UIMenu? {
        guard feature.uploader != nil, let picker else { return nil }
        return UIMenu(children: [
            UIAction(title: ComposerText.photos, image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                guard let self else { return }
                picker.presentPhotos(from: self)
            },
            UIAction(title: ComposerText.camera, image: UIImage(systemName: "camera")) { [weak self] _ in
                guard let self else { return }
                picker.presentCamera(from: self)
            },
            UIAction(title: ComposerText.files, image: UIImage(systemName: "folder")) { [weak self] _ in
                guard let self else { return }
                picker.presentFiles(from: self)
            },
        ])
    }

    func draftsMenu() -> UIMenu {
        let current = session.draft?.target
        let catalog = session.catalog?.value
        let items = session.savedDrafts.prefix(20).map { draft in
            let host = catalog?.host(draft.target.hostID)
            let workspace = draft.target.workspaceID.flatMap { id in host?.workspaces.first { $0.id == id }?.title }
                ?? (draft.target.workspaceID == nil ? ComposerText.newWorkspace : draft.target.workspaceID ?? "")
            let title = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)
            return UIAction(title: title.isEmpty ? workspace : String(title),
                            subtitle: (host?.hostName ?? draft.target.hostID.rawValue) + " · " + workspace,
                            state: draft.target == current ? .on : .off) { [weak self] _ in
                self?.session.setTarget(draft.target)
            }
        }
        return UIMenu(title: ComposerText.drafts, children: items)
    }

    func insertTemplate(_ template: PromptTemplate, replacing trigger: PromptTrigger?) {
        let text = promptView.text ?? ""
        let next: (text: String, cursor: Int)
        if let trigger {
            next = trigger.applying(template.body, to: text)
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            next = (template.body, (template.body as NSString).length)
        } else {
            let joined = text.hasSuffix("\n") ? text + template.body : text + "\n" + template.body
            next = (joined, (joined as NSString).length)
        }
        promptView.setPrompt(next.text)
        promptView.selectedRange = NSRange(location: next.cursor, length: 0)
        session.updatePrompt(next.text)
        session.setTemplate(template.name)
        suggestions.show([])
    }

    private func promptForTemplateName() {
        let alert = UIAlertController(title: ComposerText.saveTemplate, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = ComposerText.templateName
            field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: ComposerText.cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: ComposerText.save, style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text else { return }
            self.feature.templates.save(name: name, body: self.session.draft?.prompt ?? "")
            self.render()
        })
        present(alert, animated: true)
    }
}
