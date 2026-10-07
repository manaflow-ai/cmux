public import UIKit
import SwiftUI

/// Presents the DEV sources screen outside Settings (the shake menu).
@MainActor
public enum DevSourcesScreen {
    public static func make(model: DevSourcesModel) -> UIViewController {
        UIHostingController(rootView: NavigationStack { DevSourcesView(model: model) })
    }
}
