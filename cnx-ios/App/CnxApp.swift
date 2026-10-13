import CnxModel
import CnxShell
#if DEBUG
import CnxTerminal
#endif
import SwiftUI

@main
struct CnxApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if TerminalDemoRoot.isRequested {
                TerminalDemoRoot()
            } else {
                RootView(store: .mock())
            }
            #else
            RootView(store: .mock())
            #endif
        }
    }
}
