import CmuxInboxCore
import Foundation

// The pure terminal value model (TerminalWorkspace, TerminalPane, the TerminalWorkspaceDeviceSection
// grouping, and the UUID.terminalShortID helper) now lives in the CmuxTerminalCore package. The
// UnifiedInboxWorkspaceDeviceSection grouping below stays here because it depends on the iOS-only
// UnifiedInboxItem; it moves down when the inbox value types are extracted in a later wave.

struct UnifiedInboxWorkspaceDeviceSection: Identifiable, Equatable {
    let machineID: String
    let title: String
    let subtitle: String?
    let items: [UnifiedInboxItem]

    var id: String { machineID }
}

enum UnifiedInboxWorkspaceDeviceSectionBuilder {
    static func makeSections(
        items: [UnifiedInboxItem]
    ) -> [UnifiedInboxWorkspaceDeviceSection] {
        let filtered = items
            .filter { $0.kind == .workspace }
            .sorted { $0.sortDate > $1.sortDate }

        var orderedMachineIDs: [String] = []
        var grouped: [String: [UnifiedInboxItem]] = [:]

        for item in filtered {
            let machineID = normalizedMachineID(for: item)
            if grouped[machineID] == nil {
                orderedMachineIDs.append(machineID)
            }
            grouped[machineID, default: []].append(item)
        }

        return orderedMachineIDs.compactMap { machineID in
            guard let items = grouped[machineID],
                  let first = items.first else {
                return nil
            }

            return UnifiedInboxWorkspaceDeviceSection(
                machineID: machineID,
                title: displayTitle(for: first, machineID: machineID),
                subtitle: subtitle(for: first, machineID: machineID),
                items: items
            )
        }
    }

    private static func normalizedMachineID(for item: UnifiedInboxItem) -> String {
        let machineID = item.machineID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let machineID, !machineID.isEmpty else {
            return item.id
        }
        return machineID
    }

    private static func displayTitle(for item: UnifiedInboxItem, machineID: String) -> String {
        let label = item.accessoryLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let label, !label.isEmpty else { return machineID }
        return label
    }

    private static func subtitle(for item: UnifiedInboxItem, machineID: String) -> String? {
        let candidates = [
            item.tailscaleHostname?.trimmingCharacters(in: .whitespacesAndNewlines),
            item.tailscaleIPs.first?.trimmingCharacters(in: .whitespacesAndNewlines),
            machineID,
        ]

        let title = displayTitle(for: item, machineID: machineID)
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            guard candidate.caseInsensitiveCompare(title) != .orderedSame else { continue }
            return candidate
        }

        return nil
    }
}
