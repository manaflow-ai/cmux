import Foundation
import StackAuth

enum StackAuthApp {
    static let shared = StackClientApp(
        projectId: Environment.current.stackAuthProjectId,
        publishableClientKey: Environment.current.stackAuthPublishableKey,
        tokenStore: .keychain
    )
}
