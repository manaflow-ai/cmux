public import UIKit
import SwiftUI

extension DevSourcesModel {
    /// The DEV sources screen outside Settings (the shake menu).
    public func makeScreen() -> UIViewController {
        UIHostingController(rootView: NavigationStack { DevSourcesView(model: self) })
    }
}
