public import Foundation

/// How the bytes reach the phone; shown as a badge (spec sync-and-transport 6.5).
public enum TerminalPath: String, Hashable, Sendable {
    case directLAN, directWAN, relayed, durableObjectRelay, viaCloudRegion
}
