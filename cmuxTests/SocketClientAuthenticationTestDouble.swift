import CmuxCLISocketAuth
import Foundation

/// Supplies the transport seam for the production SocketClient authentication extension.
/// The extension is compiled unchanged into this test target; this double records
/// authentication, and reconnect invalidates only connection state, not credentials.
final class SocketClient {
    enum UnexpectedTransportCall: Error { case request }

    let socketPath: String
    var authenticationPassword: String?
    var authenticationPasswordProvider: ((Date?) -> String?)?
    var authenticationPasswordResolutionAttempt = SocketCredentialResolutionAttempt()
    var authenticationModeCoordinator = SocketAuthenticationModeCoordinator()
    var authenticationInProgress = false
    var socketAuthenticated = false
    private(set) var authenticatedPasswords: [String] = []

    init(path: String) { socketPath = path }

    func close() { socketAuthenticated = false }

    func authenticateIfNeeded(responseTimeout: TimeInterval?, deadline: Date?) throws {
        guard !socketAuthenticated, !authenticationInProgress else { return }
        if let authenticationPassword {
            authenticatedPasswords.append(authenticationPassword)
        }
        socketAuthenticated = true
    }

    func configureAuthentication(
        password: String?,
        passwordProvider: ((Date?) -> String?)?,
        authenticationModeCoordinator: SocketAuthenticationModeCoordinator?
    ) {
        authenticationPassword = password
        authenticationPasswordProvider = passwordProvider
        if let authenticationModeCoordinator {
            self.authenticationModeCoordinator = authenticationModeCoordinator
        }
        authenticationPasswordResolutionAttempt = SocketCredentialResolutionAttempt()
        socketAuthenticated = password == nil
    }

    func connectWithoutRetry(responseTimeout: TimeInterval?) throws {
        throw UnexpectedTransportCall.request
    }

    func send(
        command: String,
        responseTimeout: TimeInterval?,
        deadline: Date? = nil,
        allowAuthenticationRetry: Bool = true
    ) throws -> String {
        throw UnexpectedTransportCall.request
    }
}
