import CmuxiOSComposerCore
import CmuxiOSFeatureKit
import Foundation

/// The composer's localized copy (en, ja).
enum ComposerText {
    static var title: String { String(localized: "composer.title", defaultValue: "Compose", bundle: .module) }
    static var newTask: String { String(localized: "composer.new-task", defaultValue: "New Task", bundle: .module) }
    static var send: String { String(localized: "composer.send", defaultValue: "Send", bundle: .module) }
    static var sending: String { String(localized: "composer.sending", defaultValue: "Sending…", bundle: .module) }
    static var cancel: String { String(localized: "composer.cancel", defaultValue: "Cancel", bundle: .module) }
    static var close: String { String(localized: "composer.close", defaultValue: "Close", bundle: .module) }
    static var placeholder: String {
        String(localized: "composer.prompt.placeholder", defaultValue: "Describe the task. Type / for templates, @ for files.", bundle: .module)
    }
    static var promptLabel: String { String(localized: "composer.prompt.label", defaultValue: "Prompt", bundle: .module) }
    static var chooseTarget: String { String(localized: "composer.target.choose", defaultValue: "Choose a Mac", bundle: .module) }
    static var newWorkspace: String { String(localized: "composer.target.new-workspace", defaultValue: "New workspace", bundle: .module) }
    static var targetHint: String {
        String(localized: "composer.target.hint", defaultValue: "Opens the Mac and workspace picker", bundle: .module)
    }
    static var agent: String { String(localized: "composer.agent", defaultValue: "Agent", bundle: .module) }
    static var model: String { String(localized: "composer.model", defaultValue: "Model", bundle: .module) }
    static var effort: String { String(localized: "composer.effort", defaultValue: "Effort", bundle: .module) }
    static var noAgent: String { String(localized: "composer.agent.none", defaultValue: "No agent", bundle: .module) }
    static var defaultModel: String { String(localized: "composer.model.default", defaultValue: "Default model", bundle: .module) }
    static var templates: String { String(localized: "composer.templates", defaultValue: "Templates", bundle: .module) }
    static var saveTemplate: String { String(localized: "composer.templates.save", defaultValue: "Save Prompt as Template…", bundle: .module) }
    static var templateName: String { String(localized: "composer.templates.name", defaultValue: "Template name", bundle: .module) }
    static var save: String { String(localized: "composer.save", defaultValue: "Save", bundle: .module) }
    static var deleteTemplate: String { String(localized: "composer.templates.delete", defaultValue: "Delete Saved Template", bundle: .module) }
    static var drafts: String { String(localized: "composer.drafts", defaultValue: "Drafts", bundle: .module) }
    static var attach: String { String(localized: "composer.attach", defaultValue: "Attach", bundle: .module) }
    static var photos: String { String(localized: "composer.attach.photos", defaultValue: "Photos", bundle: .module) }
    static var camera: String { String(localized: "composer.attach.camera", defaultValue: "Camera", bundle: .module) }
    static var files: String { String(localized: "composer.attach.files", defaultValue: "Files", bundle: .module) }
    static var removeAttachment: String { String(localized: "composer.attach.remove", defaultValue: "Remove", bundle: .module) }
    static var uploading: String { String(localized: "composer.attach.uploading", defaultValue: "Uploading", bundle: .module) }
    static var uploadFailedShort: String { String(localized: "composer.attach.failed", defaultValue: "Failed", bundle: .module) }
    static var dictate: String { String(localized: "composer.dictate", defaultValue: "Dictate", bundle: .module) }
    static var stopDictation: String { String(localized: "composer.dictate.stop", defaultValue: "Stop Dictation", bundle: .module) }
    static var dictationDenied: String {
        String(localized: "composer.dictate.denied", defaultValue: "Allow Speech Recognition and the microphone in Settings to dictate.", bundle: .module)
    }
    static var dictationUnavailable: String {
        String(localized: "composer.dictate.unavailable", defaultValue: "Dictation isn't available right now.", bundle: .module)
    }
    static var open: String { String(localized: "composer.outcome.open", defaultValue: "Open", bundle: .module) }
    static var mockData: String { String(localized: "composer.mock", defaultValue: "Mock data", bundle: .module) }
    static var composeButton: String { String(localized: "composer.floating", defaultValue: "New Task", bundle: .module) }

    static func started(_ workspace: String) -> String {
        String(format: String(localized: "composer.outcome.started", defaultValue: "Started in %@", bundle: .module), workspace)
    }

    static func refused(_ reason: String) -> String {
        String(format: String(localized: "composer.outcome.refused", defaultValue: "The Mac refused: %@", bundle: .module), reason)
    }

    static var notDelivered: String {
        String(localized: "composer.outcome.not-delivered",
               defaultValue: "Not confirmed. Your draft is kept; sending again won't start a second task.", bundle: .module)
    }

    static var unsupported: String {
        String(localized: "composer.outcome.unsupported", defaultValue: "This Mac doesn't accept tasks yet.", bundle: .module)
    }

    static func state(_ state: TaskState) -> String {
        switch state {
        case .queued: String(localized: "composer.task.queued", defaultValue: "Queued", bundle: .module)
        case .running: String(localized: "composer.task.running", defaultValue: "Running", bundle: .module)
        case .needsInput: String(localized: "composer.task.needs-input", defaultValue: "Needs input", bundle: .module)
        case .done: String(localized: "composer.task.done", defaultValue: "Done", bundle: .module)
        case .failed: String(localized: "composer.task.failed", defaultValue: "Failed", bundle: .module)
        }
    }

    static func effortName(_ effort: String) -> String {
        switch effort {
        case "low": String(localized: "composer.effort.low", defaultValue: "Low", bundle: .module)
        case "medium": String(localized: "composer.effort.medium", defaultValue: "Medium", bundle: .module)
        case "high": String(localized: "composer.effort.high", defaultValue: "High", bundle: .module)
        case "xhigh": String(localized: "composer.effort.xhigh", defaultValue: "Extra High", bundle: .module)
        case "max": String(localized: "composer.effort.max", defaultValue: "Max", bundle: .module)
        default: effort
        }
    }

    static func blocker(_ blocker: ComposerSendBlocker) -> String {
        switch blocker {
        case .noTarget: chooseTarget
        case .offline(let reason):
            reason ?? String(localized: "composer.blocker.offline", defaultValue: "Offline. Your draft is kept.", bundle: .module)
        case .hostUnreachable(let reason):
            reason ?? String(localized: "composer.blocker.unreachable", defaultValue: "This Mac is unreachable. Your draft is kept.", bundle: .module)
        case .dispatchUnsupported: unsupported
        case .noAgents:
            String(localized: "composer.blocker.no-agents", defaultValue: "This Mac hasn't reported any agents.", bundle: .module)
        case .noAgent: String(localized: "composer.blocker.no-agent", defaultValue: "Choose an agent.", bundle: .module)
        case .agentUnavailable(let name, let reason): name + ": " + reason
        case .emptyPrompt: String(localized: "composer.blocker.empty", defaultValue: "Write a prompt to send.", bundle: .module)
        case .uploadsPending:
            String(localized: "composer.blocker.uploads", defaultValue: "Waiting for attachments to upload.", bundle: .module)
        case .uploadFailed:
            String(localized: "composer.blocker.upload-failed", defaultValue: "An attachment failed to upload. Remove it to send.", bundle: .module)
        case .sending: sending
        }
    }

    /// Built-in `/` templates: prompt text only.
    static var builtInTemplates: [PromptTemplate] {
        [
            PromptTemplate(id: "builtin.fix-tests", name: "fix-tests",
                           title: String(localized: "composer.template.fix-tests.title", defaultValue: "Fix failing tests", bundle: .module),
                           body: String(localized: "composer.template.fix-tests.body",
                                        defaultValue: "Run the test suite, find the failing tests, fix the cause, and rerun until they pass.",
                                        bundle: .module), isBuiltIn: true),
            PromptTemplate(id: "builtin.review", name: "review",
                           title: String(localized: "composer.template.review.title", defaultValue: "Review changes", bundle: .module),
                           body: String(localized: "composer.template.review.body",
                                        defaultValue: "Review the uncommitted changes for bugs and risky edge cases. List findings by severity.",
                                        bundle: .module), isBuiltIn: true),
            PromptTemplate(id: "builtin.explain", name: "explain",
                           title: String(localized: "composer.template.explain.title", defaultValue: "Explain code", bundle: .module),
                           body: String(localized: "composer.template.explain.body",
                                        defaultValue: "Explain how this part of the code works and where its state lives:", bundle: .module),
                           isBuiltIn: true),
            PromptTemplate(id: "builtin.pr", name: "pr",
                           title: String(localized: "composer.template.pr.title", defaultValue: "Open a pull request", bundle: .module),
                           body: String(localized: "composer.template.pr.body",
                                        defaultValue: "Commit the work on a new branch, push it, and open a pull request with a short summary.",
                                        bundle: .module), isBuiltIn: true),
        ]
    }
}
