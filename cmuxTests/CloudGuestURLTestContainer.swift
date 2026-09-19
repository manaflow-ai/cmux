import CmuxSettings
import Foundation
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class CloudGuestURLTestContainer: TerminalLinkOpenContainer {
    let terminalLinkContainerDebugName = "cloud-fixture"
    var opened: [URL] = []
    var focus = true
    var accepts = true
    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? { nil }
    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool { true }
    func cloudTerminalLinkTarget(url: URL, sourcePanelId: UUID) -> CloudTerminalLinkTarget? { nil }
    func deferTerminalFileLinkOpen(sourcePanelId: UUID, filePath: String, fallback: @escaping @MainActor @Sendable () -> Void) -> Bool { false }
    func openTerminalBrowserLink(
        url: URL,
        sourcePanelId: UUID,
        placement: TerminalLinkBrowserPlacement,
        focus: Bool
    ) -> Bool {
        self.focus = focus
        opened.append(url)
        return accepts
    }
}
