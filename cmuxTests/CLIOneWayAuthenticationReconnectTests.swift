import Foundation
import Testing

/// Tests the shipped authentication extension, with only its transport substituted.
struct CLIOneWayAuthenticationReconnectTests {
    @Test(arguments: [false, true], [false, true])
    func reconnectAuthenticatesKnownPasswordWithoutRepeatingLookup(
        deferred: Bool, probeBeforeWrite: Bool
    ) throws {
        let client = SocketClient(path: "/isolated/one-way-reconnect.sock")
        var sourceReads = 0
        client.configureAuthentication(
            password: deferred ? nil : "fixture-password",
            passwordProvider: { _ in
                sourceReads += 1
                return "fixture-password"
            },
            authenticationModeCoordinator: nil
        )
        // A prior server challenge has already established password mode.
        client.authenticationModeCoordinator.recordPasswordRequired()

        if probeBeforeWrite {
            try client.establishAuthenticationForOneWayIfNeeded(responseTimeout: 0.05)
        }
        try client.prepareOneWayAuthentication(responseTimeout: 0.05)
        #expect(client.authenticatedPasswords == ["fixture-password"])
        #expect(client.authenticationPasswordResolutionAttempt.isCompleted == deferred)

        client.close()
        #expect(!client.socketAuthenticated)
        if probeBeforeWrite {
            try client.establishAuthenticationForOneWayIfNeeded(responseTimeout: 0.05)
        }
        try client.prepareOneWayAuthentication(responseTimeout: 0.05)

        #expect(client.socketAuthenticated, "A reconnected one-way socket must authenticate before writing")
        #expect(client.authenticatedPasswords == ["fixture-password", "fixture-password"])
        #expect(sourceReads == (deferred ? 1 : 0), "Reconnect must reuse the credential, not reread its sources")
    }
}
