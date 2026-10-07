import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import Foundation

/// Localized strings of the Cloud tab.
enum CloudText {
    static var title: String { String(localized: "cloud.title", defaultValue: "Cloud", bundle: .module) }
    static var newMachine: String { String(localized: "cloud.new", defaultValue: "New Machine", bundle: .module) }
    static var loading: String { String(localized: "cloud.loading", defaultValue: "Loading machines…", bundle: .module) }
    static var emptyTitle: String { String(localized: "cloud.empty.title", defaultValue: "No Cloud Machines", bundle: .module) }
    static var emptyBody: String {
        String(localized: "cloud.empty.body", defaultValue: "Create a machine to run agents and terminals in the cloud.", bundle: .module)
    }
    static var offlineTitle: String { String(localized: "cloud.offline.title", defaultValue: "Cloud Unavailable", bundle: .module) }
    static var offlineBody: String {
        String(localized: "cloud.offline.body", defaultValue: "Changes are paused until cmux Cloud is reachable again.", bundle: .module)
    }
    static var mockData: String { String(localized: "cloud.mock", defaultValue: "Sample data", bundle: .module) }

    // Sections
    static func section(_ kind: CloudMachineSectionKind) -> String {
        switch kind {
        case .active: String(localized: "cloud.section.active", defaultValue: "Running", bundle: .module)
        case .paused: String(localized: "cloud.section.paused", defaultValue: "Paused", bundle: .module)
        case .failed: String(localized: "cloud.section.failed", defaultValue: "Needs Attention", bundle: .module)
        }
    }

    static var usage: String { String(localized: "cloud.section.usage", defaultValue: "Usage", bundle: .module) }
    static func activeUsage(_ used: Int, _ limit: Int) -> String {
        String(localized: "cloud.usage.active", defaultValue: "\(used) of \(limit) running", bundle: .module)
    }
    static func savedUsage(_ used: Int, _ limit: Int) -> String {
        String(localized: "cloud.usage.saved", defaultValue: "\(used) of \(limit) paused", bundle: .module)
    }
    static func hours(_ used: String, _ included: String) -> String {
        String(localized: "cloud.usage.hours", defaultValue: "\(used) of \(included) VM hours", bundle: .module)
    }
    static func hoursUsed(_ used: String) -> String {
        String(localized: "cloud.usage.hoursUsed", defaultValue: "\(used) VM hours", bundle: .module)
    }
    static func plan(_ name: String) -> String { String(localized: "cloud.usage.plan", defaultValue: "Plan: \(name)", bundle: .module) }
    static var noPlan: String { String(localized: "cloud.usage.noPlan", defaultValue: "No Cloud plan", bundle: .module) }

    // Status
    static func status(_ status: CloudMachineStatus?) -> String {
        switch status {
        case nil: String(localized: "cloud.status.creating", defaultValue: "Creating…", bundle: .module)
        case .provisioning?: String(localized: "cloud.status.provisioning", defaultValue: "Setting up…", bundle: .module)
        case .starting?: String(localized: "cloud.status.starting", defaultValue: "Resuming…", bundle: .module)
        case .running?: String(localized: "cloud.status.running", defaultValue: "Running", bundle: .module)
        case .pausing?: String(localized: "cloud.status.pausing", defaultValue: "Pausing…", bundle: .module)
        case .paused?: String(localized: "cloud.status.paused", defaultValue: "Paused", bundle: .module)
        case .deleting?: String(localized: "cloud.status.deleting", defaultValue: "Deleting…", bundle: .module)
        case .failed?: String(localized: "cloud.status.failed", defaultValue: "Failed", bundle: .module)
        }
    }

    static func pauseReason(_ reason: CloudPauseReason) -> String {
        switch reason {
        case .idle: String(localized: "cloud.pause.idle", defaultValue: "Paused while idle", bundle: .module)
        case .noReport: String(localized: "cloud.pause.noReport", defaultValue: "Paused after 24 hours without activity", bundle: .module)
        case .providerStopped, .providerPaused:
            String(localized: "cloud.pause.provider", defaultValue: "Stopped from inside the machine", bundle: .module)
        }
    }

    static var classic: String { String(localized: "cloud.classic", defaultValue: "Classic", bundle: .module) }
    static var unnamed: String { String(localized: "cloud.unnamed", defaultValue: "New machine", bundle: .module) }

    static func size(_ size: CloudMachineSize) -> String {
        var parts: [String] = []
        if let cpu = size.cpu { parts.append(String(localized: "cloud.size.cpu", defaultValue: "\(cpu) CPU", bundle: .module)) }
        if let memory = size.memoryMB { parts.append(memoryText(memory)) }
        return parts.joined(separator: " · ")
    }

    static func memoryText(_ memoryMB: Int) -> String {
        let gigabytes = memoryMB / 1024
        return memoryMB % 1024 == 0
            ? String(localized: "cloud.size.memoryGB", defaultValue: "\(gigabytes) GB memory", bundle: .module)
            : String(localized: "cloud.size.memoryMB", defaultValue: "\(memoryMB) MB memory", bundle: .module)
    }

    // Actions
    static func action(_ action: CloudMachineAction) -> String {
        switch action {
        case .resume: String(localized: "cloud.action.resume", defaultValue: "Resume", bundle: .module)
        case .pause: String(localized: "cloud.action.pause", defaultValue: "Pause", bundle: .module)
        case .delete: String(localized: "cloud.action.delete", defaultValue: "Delete", bundle: .module)
        }
    }

    static func deleteTitle(_ name: String) -> String {
        String(localized: "cloud.delete.title", defaultValue: "Delete “\(name)”?", bundle: .module)
    }
    static var deleteMessage: String {
        String(localized: "cloud.delete.message", defaultValue: "The machine and everything on its disk are removed. Snapshots stay.", bundle: .module)
    }
    static var cancel: String { String(localized: "cloud.action.cancel", defaultValue: "Cancel", bundle: .module) }
    static var ok: String { String(localized: "cloud.action.ok", defaultValue: "OK", bundle: .module) }

    // Create
    static var name: String { String(localized: "cloud.create.name", defaultValue: "Name", bundle: .module) }
    static var namePrompt: String { String(localized: "cloud.create.namePrompt", defaultValue: "Optional", bundle: .module) }
    static var sizeHeader: String { String(localized: "cloud.create.size", defaultValue: "Size", bundle: .module) }
    static var lockedFooter: String {
        String(localized: "cloud.create.locked", defaultValue: "Larger sizes need another plan.", bundle: .module)
    }
    static var create: String { String(localized: "cloud.create.create", defaultValue: "Create", bundle: .module) }
    static var noRoom: String {
        String(localized: "cloud.create.noRoom", defaultValue: "Your plan has no room for another running machine. Pause one first.", bundle: .module)
    }

    // Errors
    static var failedTitle: String { String(localized: "cloud.error.title", defaultValue: "Couldn’t Complete", bundle: .module) }

    /// The owner's error code as a sentence (cloud-client-contract.md 1.3, 1.5).
    static func refusal(_ code: String) -> String {
        switch code {
        case "cloud.plan.required":
            String(localized: "cloud.error.planRequired", defaultValue: "Cloud machines need a plan.", bundle: .module)
        case "cloud.quota.exceeded":
            String(localized: "cloud.error.quota", defaultValue: "Your plan’s machine limit is reached.", bundle: .module)
        case "cloud.size.locked":
            String(localized: "cloud.error.sizeLocked", defaultValue: "This size needs another plan.", bundle: .module)
        case "cloud.provider.unavailable", "cloud.no_snapshot_configured", "owner.unreachable":
            String(localized: "cloud.error.unavailable", defaultValue: "cmux Cloud is not available right now. Try again later.", bundle: .module)
        case "cloud.rate_limited":
            String(localized: "cloud.error.rateLimited", defaultValue: "Too many changes at once. Try again in a minute.", bundle: .module)
        case "cloud.machine.not_found":
            String(localized: "cloud.error.notFound", defaultValue: "This machine no longer exists.", bundle: .module)
        case "mutation.indeterminate":
            String(localized: "cloud.error.indeterminate", defaultValue: "cmux Cloud did not confirm the change yet. Check the list in a moment.", bundle: .module)
        case "auth.forbidden", "auth.unauthenticated":
            String(localized: "cloud.error.forbidden", defaultValue: "You can’t change this machine with this account.", bundle: .module)
        case "client.too_old":
            String(localized: "cloud.error.tooOld", defaultValue: "Update cmux to manage Cloud machines.", bundle: .module)
        default:
            String(localized: "cloud.error.generic", defaultValue: "cmux Cloud refused the change (\(code)).", bundle: .module)
        }
    }

    static var offlineError: String {
        String(localized: "cloud.error.offline", defaultValue: "Not connected to cmux Cloud. Nothing was changed.", bundle: .module)
    }
}
