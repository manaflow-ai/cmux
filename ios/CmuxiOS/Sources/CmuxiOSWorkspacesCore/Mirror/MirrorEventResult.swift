import Foundation

/// What applying one owner event did to a mirror.
public enum MirrorEventResult: Hashable, Sendable {
    /// Contiguous and applied; the mirror is at the event's seq.
    case applied
    /// At or below the mirror's seq: already applied, ignored.
    case duplicate
    /// A seq jump, or an event the mirror cannot apply: the mirror needs a
    /// snapshot and ignores events until one arrives.
    case gap
    /// No snapshot yet; events wait for it.
    case awaitingSnapshot
}
