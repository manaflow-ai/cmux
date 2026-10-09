import CNCore
import Foundation
import Observation
import SwiftUI

/// Root app state. The shell owner replaces this skeleton.
@MainActor
@Observable
public final class AppModel {
    public enum Shell: String { case drawer, tabs }
    public let shell: Shell

    public init(shell: Shell) { self.shell = shell }

    public static func live(bundle: Bundle) -> AppModel {
        let raw = bundle.object(forInfoDictionaryKey: "CmuxNextShell") as? String
        return AppModel(shell: Shell(rawValue: raw ?? "") ?? .tabs)
    }
}

public struct AppRoot: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View { Text("cmux next: \(model.shell.rawValue)") }
}
