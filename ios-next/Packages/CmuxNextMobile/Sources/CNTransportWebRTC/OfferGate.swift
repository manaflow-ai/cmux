import Foundation

/// When to (re)send a link's offer and when a missing answer is a failure.
/// An offer sent while the host's own signaling socket is reconnecting is
/// lost, so while the host is known offline (welcome/presence, or a
/// `host_offline` error for the offer) the link waits for its presence to
/// come back and resends at once; otherwise a missing answer fails after the
/// answer timeout. Platform independent so it is unit tested.
struct OfferGate: Sendable, Equatable {
    enum Action: Sendable, Equatable { case none, send, fail }

    private(set) var answered = false
    private(set) var waitingForHost = false
    private(set) var sends = 0

    /// Before the first offer. `hostOnline` is the last known presence.
    mutating func start(hostOnline: Bool?) -> Action {
        if hostOnline == false {
            waitingForHost = true
            return .none
        }
        sends += 1
        return .send
    }

    /// The backend answered the offer with `host_offline`.
    mutating func hostOffline() -> Action {
        guard !answered else { return .none }
        waitingForHost = true
        return .none
    }

    /// A presence (or welcome) entry for this link's host.
    mutating func presence(online: Bool) -> Action {
        guard !answered else { return .none }
        if !online {
            waitingForHost = true
            return .none
        }
        guard waitingForHost else { return .none }
        waitingForHost = false
        sends += 1
        return .send
    }

    mutating func answerReceived() {
        answered = true
        waitingForHost = false
    }

    /// The answer timer for the latest send fired.
    mutating func answerTimedOut() -> Action {
        answered || waitingForHost ? .none : .fail
    }
}
