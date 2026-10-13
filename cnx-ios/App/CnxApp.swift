import CnxModel
import CnxShell
import SwiftUI

@main
struct CnxApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(store: .mock())
        }
    }
}
