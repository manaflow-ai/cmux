public import CmuxiOSFeatureKit

/// The picker's choices for a request: per host (in the user's machine
/// order, hidden machines left out unless the request names one), "New
/// Workspace" first when allowed, then workspaces in the owner's order.
/// Unreachable hosts' rows are disabled, because the composer cannot
/// dispatch to them (nothing queues).
public struct WorkspacePickerModel: Sendable {
    public var preferences: WorkspaceViewPreferences

    public init(preferences: WorkspaceViewPreferences = WorkspaceViewPreferences()) {
        self.preferences = preferences
    }

    public func choices(from hosts: [HostWorkspaces], request: WorkspacePickerRequest) -> [HostID: [WorkspacePickerChoice]] {
        var result: [HostID: [WorkspacePickerChoice]] = [:]
        for section in sections(from: hosts, request: request) { result[section.host.hostID] = section.choices }
        return result
    }

    public func sections(from hosts: [HostWorkspaces], request: WorkspacePickerRequest) -> [WorkspacePickerSection] {
        let ordered = preferences.ordered(hosts, id: \.hostID)
        let included: [HostWorkspaces]
        if let only = request.hostID {
            included = ordered.filter { $0.hostID == only }
        } else {
            included = ordered.filter { !preferences.hiddenHosts.contains($0.hostID) }
        }
        return included.map { WorkspacePickerSection(host: $0, choices: choices(for: $0, request: request)) }
    }

    private func choices(for host: HostWorkspaces, request: WorkspacePickerRequest) -> [WorkspacePickerChoice] {
        var choices: [WorkspacePickerChoice] = []
        if request.allowsNewWorkspace {
            choices.append(WorkspacePickerChoice(
                id: host.hostID.rawValue + "/new",
                selection: WorkspaceSelection(hostID: host.hostID, workspaceID: nil),
                title: nil, hostName: host.hostName, status: nil,
                isEnabled: host.isReachable && host.capabilities.contains(.create)))
        }
        let workspaces = host.workspaces.sorted { a, b in a.order != b.order ? a.order < b.order : a.id < b.id }
        for workspace in workspaces {
            choices.append(WorkspacePickerChoice(
                id: host.hostID.rawValue + "/" + workspace.id,
                selection: WorkspaceSelection(hostID: host.hostID, workspaceID: workspace.id),
                title: workspace.title, hostName: host.hostName, status: workspace.status,
                isEnabled: host.isReachable))
        }
        return choices
    }
}
