import CmuxMobileContract
import Foundation

// MobileMachineStatus, MobileMachineRow, and MobileInboxWorkspaceRow now live in
// CmuxMobileContract as pure wire DTOs. The terminal-domain mapping below stays here because it
// reaches up into TerminalHost; it moves to the domain layer in Wave 3.

extension MobileMachineRow {
    func asTerminalHost() -> TerminalHost {
        let address = preferredAddress
        let host = TerminalHost(
            stableID: machineId,
            name: displayName,
            hostname: address,
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: Self.palette(for: machineId),
            source: .discovered,
            transportPreference: .remoteDaemon,
            teamID: teamId,
            serverID: preferredServerID,
            allowsSSHFallback: true,
            wsPort: wsPort,
            wsSecret: wsSecret,
            machineStatus: status
        )
        return host
    }

    private static func palette(for machineId: String) -> TerminalHostPalette {
        let palettes = TerminalHostPalette.allCases
        let index = abs(machineId.hashValue) % palettes.count
        return palettes[index]
    }
}
