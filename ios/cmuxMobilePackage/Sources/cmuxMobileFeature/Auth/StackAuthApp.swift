import Foundation
import StackAuth

enum StackAuthApp {
    static let shared = StackClientApp(
        projectId: AppEnvironment.current.stackAuthProjectId,
        publishableClientKey: AppEnvironment.current.stackAuthPublishableKey,
        tokenStore: .keychain
    )
}
