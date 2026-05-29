import Foundation

enum MobileGhosttyMirrorOutputPolicy {
    enum Decision: Equatable, Sendable {
        case forwardToRemote
        case suppressMirroredOutputReply
    }

    enum CallbackOrigin: Equatable, Sendable {
        case mirroredOutputQueue
        case other
    }

    /// The iOS Ghostty surface is a display mirror for the Mac-owned PTY.
    /// Ghostty can generate terminal replies while parsing mirrored output
    /// (for example OSC or CSI query responses). The Mac Ghostty surface has
    /// already handled those replies for the real PTY, so forwarding the iOS
    /// copy would inject duplicate control bytes and corrupt the live session.
    static func decision(
        for data: Data,
        isProcessingMirroredOutput: Bool,
        callbackOrigin: CallbackOrigin
    ) -> Decision {
        if isTerminalQueryReply(data) {
            return .suppressMirroredOutputReply
        }
        if isProcessingMirroredOutput, callbackOrigin == .mirroredOutputQueue {
            return .suppressMirroredOutputReply
        }
        return .forwardToRemote
    }

    private static func isTerminalQueryReply(_ data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        if isOSCColorReply(text) {
            return true
        }
        if text == "\u{1B}[0n" {
            return true
        }
        if text.hasPrefix("\u{1B}[?997;"), text.hasSuffix("n") {
            return true
        }
        if isCursorPositionReport(text) {
            return true
        }
        if isDeviceAttributesReport(text) {
            return true
        }
        return false
    }

    private static func isOSCColorReply(_ text: String) -> Bool {
        guard text.hasPrefix("\u{1B}]") else { return false }
        guard text.hasSuffix("\u{7}") || text.hasSuffix("\u{1B}\\") else { return false }
        return text.contains(";rgb:")
    }

    private static func isCursorPositionReport(_ text: String) -> Bool {
        guard text.hasPrefix("\u{1B}["), text.hasSuffix("R") else { return false }
        let payload = text.dropFirst(2).dropLast()
        let parts = payload.split(separator: ";")
        guard parts.count == 2 else { return false }
        return parts.allSatisfy { Int($0) != nil }
    }

    private static func isDeviceAttributesReport(_ text: String) -> Bool {
        guard text.hasPrefix("\u{1B}["), text.hasSuffix("c") else { return false }
        let payload = text.dropFirst(2).dropLast()
        guard payload.hasPrefix("?") || payload.hasPrefix(">") else { return false }
        let parts = payload.dropFirst().split(separator: ";")
        return !parts.isEmpty && parts.allSatisfy { Int($0) != nil }
    }
}
