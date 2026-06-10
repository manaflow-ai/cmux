@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


final class WorkspaceRemoteSSHCleanupTests: XCTestCase {
    func testOrphanedCMUXRemoteSSHPIDsMatchesOnlyParentOneRelayAndDaemonTransports() {
        let psOutput = """
          101 1 /usr/bin/ssh -N -T -S none -o ControlPath=/tmp/cmux-ssh-501-56080-%C -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          102 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
          107 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-test''
          103 999 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56081:127.0.0.1:64049 cmux-macmini
          104 1 /usr/bin/ssh -tt cmux-macmini
          105 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56082:127.0.0.1:64050 other-host
          106 1 /usr/bin/ssh -T -S none cmux-macmini /bin/sh
        """

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini"
            ),
            [101, 102, 107]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsCanRestrictCleanupToSpecificRelayPort() {
        let psOutput = """
          201 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          202 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56081:127.0.0.1:64049 cmux-macmini
          203 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
          204 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-test''
          205 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-other''
        """

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081,
                persistentDaemonSlot: "ssh-test"
            ),
            [202, 204]
        )

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081
            ),
            [202]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsMatchesBackslashEscapedPersistentDaemonSlot() {
        let psOutput = """
          211 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec '\''.cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote'\'' '\''serve'\'' '\''--stdio'\'' '\''--persistent'\'' '\''--slot'\'' '\''ssh-test'\'''
          212 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec '\''.cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote'\'' '\''serve'\'' '\''--stdio'\'' '\''--persistent'\'' '\''--slot'\'' '\''ssh-other'\'''
        """

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081,
                persistentDaemonSlot: "ssh-test"
            ),
            [211]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsMatchesEqualsQuotedPersistentDaemonSlot() {
        let psOutput = """
          221 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote serve --stdio --persistent --slot='ssh-test''
          222 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote serve --stdio --persistent --slot="ssh-other"'
        """

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                relayPort: 56081,
                persistentDaemonSlot: "ssh-test"
            ),
            [221]
        )
    }

    func testOrphanedCMUXRemoteSSHPIDsWithSlotAndNoRelayKeepsGenericCleanup() {
        let psOutput = """
          301 1 /usr/bin/ssh -N -T -S none -R 127.0.0.1:56080:127.0.0.1:64048 cmux-macmini
          302 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
          303 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-test''
          304 1 /usr/bin/ssh -T -S none -o RequestTTY=no cmux-macmini sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote 'serve' '--stdio' '--persistent' '--slot' 'ssh-other''
          305 1 /usr/bin/ssh -T -S none -o RequestTTY=no other-host sh -c 'exec .cmux/bin/cmuxd-remote/0.63.1/darwin-arm64/cmuxd-remote serve --stdio'
        """

        XCTAssertEqual(
            WorkspaceRemoteSessionController.orphanedCMUXRemoteSSHPIDs(
                psOutput: psOutput,
                destination: "cmux-macmini",
                persistentDaemonSlot: "ssh-test"
            ),
            [301, 302, 303]
        )
    }
}

