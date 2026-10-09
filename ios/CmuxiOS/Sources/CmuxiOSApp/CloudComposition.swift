import CmuxiOSCloud
import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import CmuxiOSIdentity
import CmuxiOSOnboarding
import Foundation

/// Lane C12 (plans/cmux-next/ios-next/c12-cloud.md): the Cloud seam over
/// `CloudDO`, and the onboarding hook that creates the first machine.
@MainActor
enum CloudComposition {
    /// Registers the real Cloud source when an API origin exists.
    static func adding(to factories: RealFeatureFactories, base: URL?, identity: InstallIdentity?,
                       sessionToken: @escaping @Sendable () async throws -> String) -> RealFeatureFactories {
        guard let base, let identity else { return factories }
        var factories = factories
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let credentials = AppCloudCredentials(identity: identity, sessionToken: sessionToken)
        factories.cloud = {
            WireCloudMachineSource(
                apiBaseURL: base,
                api: URLSessionCloudAPIClient(baseURL: base, credentials: credentials, clientVersion: version),
                credentials: credentials, clientVersion: version)
        }
        return factories
    }

    /// The Cloud step's hook while the `cloudOnboarding` flag is on.
    static func onboardingHook(container: AppContainer) -> OnboardingCloudHook? {
        guard container.flags.isEnabled(.cloudOnboarding) else { return nil }
        return OnboardingCloudHook { @MainActor [weak container] in
            guard let container, case .signedIn(let account) = container.auth.state else {
                return .refused(message: CloudFeature.message(for: .offline) ?? "")
            }
            let outcome = await CloudFirstMachine(source: container.featureSources(for: account).cloud).create()
            return CloudFeature.message(for: outcome).map { .refused(message: $0) } ?? .created
        }
    }
}

/// Install token for reads and the event socket; the Stack session for
/// lifecycle ops, which `CloudDO` accepts only from a signed-in person.
struct AppCloudCredentials: CloudCredentials {
    let identity: InstallIdentity
    let sessionToken: @Sendable () async throws -> String

    func token(for principal: CloudPrincipal) async throws -> String {
        switch principal {
        case .install: try await identity.token(for: nil)
        case .session: try await sessionToken()
        }
    }

    func invalidate(_ principal: CloudPrincipal) async {
        // The Stack coordinator refreshes its own session token.
        if principal == .install { await identity.invalidate(for: nil) }
    }
}
