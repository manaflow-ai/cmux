#if os(iOS)
import CNDesign
import SwiftUI

public struct AppRoot: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }

    public var body: some View {
        let roots = ModuleRoots(connection: model.connection)
        switch model.devScreen {
        case .conversations: roots.conversations()
        case .agents: roots.agents()
        case .terminal: roots.terminals()
        case .browser: roots.browser()
        default: Text("cmux next: \(model.shell.rawValue)")
        }
    }
}
#endif
