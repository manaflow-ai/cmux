import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux vpn` shells out to system tools by absolute path, and sudo resolves
/// those paths literally — nothing searches PATH and nothing validates them
/// until the command runs.
///
/// `/usr/sbin/install` shipped here once. macOS puts install(1) in `/usr/bin`,
/// so `vpn hosts` died with "sudo: /usr/sbin/install: command not found" —
/// and because the hosts sync runs *after* wg-quick, the tunnel was already up
/// and healthy. It read as "the VPN is broken" when routing was fine and only
/// the `.internal` names were missing.
@Suite
struct VPNToolPathTests {
    @Test
    func everyToolPathExistsAndIsExecutable() {
        for path in CMUXCLI.VPNTool.all {
            #expect(
                FileManager.default.isExecutableFile(atPath: path),
                "cmux vpn shells out to \(path), which is not an executable on this machine"
            )
        }
    }

    /// Pins the specific mistake: install(1) lives in /usr/bin on macOS.
    @Test
    func installComesFromUsrBinNotUsrSbin() {
        #expect(CMUXCLI.VPNTool.install == "/usr/bin/install")
        #expect(!FileManager.default.fileExists(atPath: "/usr/sbin/install"))
    }
}
