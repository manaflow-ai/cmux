import CNAppShell
import SwiftUI

@main
struct CmuxNextApp: App {
    @State private var model = AppModel.live(bundle: .main)

    var body: some Scene {
        WindowGroup {
            AppRoot(model: model)
        }
    }
}
