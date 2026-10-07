import Foundation

/// The QR path: prime the camera, explain a denial, or scan.
enum CameraSheetStage: String, Identifiable {
    case primer
    case denied
    case scanner

    var id: String { rawValue }
}
