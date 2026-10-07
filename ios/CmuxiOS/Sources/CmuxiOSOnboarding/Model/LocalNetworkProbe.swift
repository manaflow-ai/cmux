import CmuxiOSOnboardingCore
import Foundation
import Network
import UIKit

/// Raises the local network prompt by browsing for the Bonjour service in
/// Info.plist (`NSBonjourServices`) and reads the answer: a policy-denied
/// browser means denied; the app becoming active again after the prompt, or
/// the bounded wait ending without a denial, means allowed. The wait is an
/// intentional, cancellable delay on the injected clock.
@MainActor
final class LocalNetworkProbe {
    static let serviceType = "_cmux-iroh._udp"
    static let wait: Duration = .seconds(6)

    private let clock: any Clock<Duration>

    init(clock: any Clock<Duration>) {
        self.clock = clock
    }

    func run() async -> PermissionStatus {
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: .init())
        let (events, continuation) = AsyncStream<PermissionStatus>.makeStream()
        browser.stateUpdateHandler = { state in
            if case .waiting(let error) = state, case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied {
                continuation.yield(.denied)
            }
        }
        browser.start(queue: .main)
        let clock = clock
        let observer = Self.returnedFromPrompt { continuation.yield(.granted) }
        let timeout = Task {
            try? await clock.sleep(for: Self.wait)
            continuation.yield(.granted)
        }
        var answer = PermissionStatus.granted
        for await event in events {
            answer = event
            break
        }
        timeout.cancel()
        NotificationCenter.default.removeObserver(observer)
        browser.cancel()
        return answer
    }

    /// The system prompt resigns the app; the next activation follows the answer.
    private static func returnedFromPrompt(_ fire: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in fire() }
    }
}
