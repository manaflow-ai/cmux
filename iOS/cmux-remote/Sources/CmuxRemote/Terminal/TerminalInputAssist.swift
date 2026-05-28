import Foundation
import UIKit

/// Centralised state machine for sticky modifier keys (Ctrl, Alt, Esc) on
/// touch-only iPhones / iPads with no HW keyboard.
///
/// Contract:
/// * Single tap → modifier is **armed** for the next normal key only, then
///   auto-releases.
/// * Double tap within 400 ms → modifier is **locked** until the next tap
///   on the same modifier.
/// * Sending `Return` (\r) auto-releases armed modifiers so the next
///   command's first key doesn't carry a leftover Ctrl.
/// * Lock survives `Return`.
///
/// The state machine itself is UI-free; the bar view subscribes to changes
/// via `onChange` to redraw badges.
@MainActor
final class TerminalModifierState: ObservableObject {
    enum Modifier: String, CaseIterable {
        case ctrl, alt, shift
    }

    enum Status: Equatable {
        case off
        case armed
        case locked
    }

    @Published private(set) var ctrl: Status = .off
    @Published private(set) var alt: Status = .off
    @Published private(set) var shift: Status = .off

    private var lastTap: [Modifier: Date] = [:]
    private let lockThreshold: TimeInterval = 0.4

    func status(_ m: Modifier) -> Status {
        switch m {
        case .ctrl: return ctrl
        case .alt: return alt
        case .shift: return shift
        }
    }

    func tap(_ m: Modifier) {
        let now = Date()
        let recent = lastTap[m]
        lastTap[m] = now
        let isDouble = recent.map { now.timeIntervalSince($0) < lockThreshold } ?? false

        let next: Status = {
            switch (status(m), isDouble) {
            case (.off, false): return .armed
            case (.armed, true): return .locked
            case (.armed, false): return .off
            case (.locked, _): return .off
            case (.off, true): return .armed
            }
        }()
        write(m, to: next)
    }

    func consume() {
        if ctrl == .armed { ctrl = .off }
        if alt == .armed { alt = .off }
        if shift == .armed { shift = .off }
    }

    func clearAll() {
        ctrl = .off
        alt = .off
        shift = .off
    }

    private func write(_ m: Modifier, to status: Status) {
        switch m {
        case .ctrl: ctrl = status
        case .alt: alt = status
        case .shift: shift = status
        }
    }
}

/// Maps a key the accessory bar fires to either:
/// * a `cmux send-key` key name (when the cmux v1 API has a name for it),
///   or
/// * a raw byte / escape sequence to write through `cmux send` verbatim.
enum AccessoryKey {
    case named(String)             // -> cmux send-key
    case raw(String)               // -> cmux send

    static let arrowLeft = AccessoryKey.raw("\u{001B}[D")
    static let arrowRight = AccessoryKey.raw("\u{001B}[C")
    static let arrowUp = AccessoryKey.raw("\u{001B}[A")
    static let arrowDown = AccessoryKey.raw("\u{001B}[B")
    static let escape = AccessoryKey.named("escape")
    static let tab = AccessoryKey.named("tab")
    static let home = AccessoryKey.raw("\u{001B}[H")
    static let end = AccessoryKey.raw("\u{001B}[F")
    static let pageUp = AccessoryKey.raw("\u{001B}[5~")
    static let pageDown = AccessoryKey.raw("\u{001B}[6~")
    static func functionKey(_ n: Int) -> AccessoryKey {
        switch n {
        case 1: return .raw("\u{001B}OP")
        case 2: return .raw("\u{001B}OQ")
        case 3: return .raw("\u{001B}OR")
        case 4: return .raw("\u{001B}OS")
        case 5: return .raw("\u{001B}[15~")
        case 6: return .raw("\u{001B}[17~")
        case 7: return .raw("\u{001B}[18~")
        case 8: return .raw("\u{001B}[19~")
        case 9: return .raw("\u{001B}[20~")
        case 10: return .raw("\u{001B}[21~")
        case 11: return .raw("\u{001B}[23~")
        case 12: return .raw("\u{001B}[24~")
        default: return .raw("")
        }
    }
}

// `ModifierEncoder` and `SmartPasteSanitiser` live in CmuxKit so they
// remain unit-testable from the CmuxKit test target.
