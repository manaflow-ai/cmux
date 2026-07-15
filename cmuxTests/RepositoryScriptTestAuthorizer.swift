import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class RepositoryScriptTestAuthorizer: RepositoryScriptAuthorizing {
    private let trusted: Bool
    private var didCheckTrust = false
    private var didReceiveRequest = false
    private var onAuthorized: (() -> Void)?
    private var onDenied: (() -> Void)?

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func isTrusted(_: CmuxActionTrustDescriptor) -> Bool {
        didCheckTrust = true
        return trusted
    }

    func authorize(
        descriptor _: CmuxActionTrustDescriptor,
        configSourcePath _: String?,
        globalConfigPath _: String,
        displayCommand _: String,
        displayTitle _: String,
        onAuthorized: @escaping () -> Void,
        onDenied: @escaping () -> Void
    ) -> Bool {
        didReceiveRequest = true
        self.onAuthorized = onAuthorized
        self.onDenied = onDenied
        return true
    }

    func waitForRequest() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if didReceiveRequest { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return didReceiveRequest
    }

    func waitForTrustCheck() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if didCheckTrust { return true }
            try? await clock.sleep(for: .milliseconds(10))
        }
        return didCheckTrust
    }

    func authorizePendingRequest() {
        let callback = onAuthorized
        onAuthorized = nil
        onDenied = nil
        callback?()
    }
}
