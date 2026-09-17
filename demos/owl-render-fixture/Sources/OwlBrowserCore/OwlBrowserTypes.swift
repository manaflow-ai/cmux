import Foundation

public struct OwlBrowserSurfaceCapture {
    public let path: String
    public let mode: String
    public let width: UInt32
    public let height: UInt32
}

public enum OwlBrowserError: Error, CustomStringConvertible {
    case bridge(String)
    case launch(String)
    case capture(String)

    public var description: String {
        switch self {
        case .bridge(let message),
             .launch(let message),
             .capture(let message):
            return message
        }
    }
}
