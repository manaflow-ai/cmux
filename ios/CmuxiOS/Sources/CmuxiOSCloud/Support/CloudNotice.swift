import Foundation

/// A one-off alert on the Cloud tab.
struct CloudNotice: Identifiable, Hashable {
    let id = UUID()
    var message: String
}
