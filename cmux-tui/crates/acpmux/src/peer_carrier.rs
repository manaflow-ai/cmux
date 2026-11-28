//! What a peer's link knows besides its `Link` history, for `_acpmux/peer_state_changed`
//! (`protocol/peer_state.rs`): the carrier the open link runs over, whether the peer refused
//! this daemon's token, why it is down, and since when its state holds. acpmux owns this
//! state; every surface renders it and keeps no clock of its own.

use crate::protocol::peer_state::{
    CREDENTIAL_UNAVAILABLE, Carrier, DialFail, DownCause, MachineLink, OfflineReason,
};

use crate::no_panic::LockExt;
use crate::peer_link::{Link, PeerState};

/// One peer instance's link facts, kept under one lock (`Peer::facts`).
#[derive(Debug, Default)]
pub(crate) struct LinkFacts {
    /// The carrier of the link that is open now, or of the attempt running now.
    pub carrier: Option<Carrier>,
    /// The last attempt was refused for its token (HTTP 401 or 403).
    pub refused: bool,
    /// Why the route last went down (`downReason`): kept across a reconnect, replaced by the
    /// next failure that has a type.
    pub down_reason: Option<DialFail>,
    /// The whole state last reported and when it began.
    since: Option<(MachineLink, u64)>,
}

impl LinkFacts {
    /// The whole state of a link in `state` whose last attempt failed with `reason` (if any),
    /// and when it began (`now` when it just changed).
    pub fn observe(
        &mut self,
        state: PeerState,
        reason: Option<OfflineReason>,
        now: u64,
    ) -> (MachineLink, u64) {
        let link = whole(state, self.refused, reason);
        match self.since {
            Some((was, at)) if was == link => (link, at),
            _ => {
                self.since = Some((link, now));
                (link, now)
            }
        }
    }

    /// The carrier to report: only an open link has one.
    pub fn live_carrier(&self, state: PeerState) -> Option<Carrier> {
        matches!(state, PeerState::Connected | PeerState::Degraded)
            .then_some(self.carrier)
            .flatten()
    }
}

impl super::Peer {
    /// The route went down for `why` (`downReason`). A failure with no type keeps the reason
    /// before it: it says nothing new about the route.
    pub(super) fn went_down(&self, why: Option<DialFail>) {
        if let Some(why) = why {
            self.facts.lock_or_recover().down_reason = Some(why);
        }
    }

    /// The open link ended because a deadline of acpmux's own passed (the silence budget, a
    /// send the peer never read, a probe or handshake with no answer): `timeout`. Returns
    /// `text`, the link's error.
    pub(super) fn deadline_passed(&self, text: String) -> String {
        self.went_down(Some(DialFail::Timeout));
        text
    }

    /// The link's whole state now, as the peer's state notes carry it.
    pub(super) fn observed(&self, link: &Link) -> crate::peer_states::Observed {
        let error = self.last_error.lock_or_recover().clone();
        let state = link.state();
        let mut facts = self.facts.lock_or_recover();
        let reason = reason(state, facts.refused, error.as_deref());
        // The reason is always reported; a down link turns `offline` for it only with the
        // preview switch on (default off). Read only when a reason is named, which is rare.
        let offline_for = reason.filter(|_| reasons_turn_offline());
        let (whole, since) = facts.observe(state, offline_for, crate::store::now_ms());
        crate::peer_states::Observed {
            link: whole,
            carrier: facts.live_carrier(state),
            cause: cause(whole, error.as_deref()),
            reason,
            down_reason: facts.down_reason,
            since,
            next_retry_at: link.retry_at.filter(|_| !link.is_ready()),
            last_seen: link.last_seen,
            error,
        }
    }
}

/// A dial's failure: the text the link reports (`error`), and its kind when the error that
/// raised it had a type (`downReason`). A bare `String` error converts with no kind, and back
/// to its text, so the dial steps that only have text keep using `?`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DialError {
    pub fail: Option<DialFail>,
    pub text: String,
}

impl DialError {
    pub fn new(fail: Option<DialFail>, text: impl Into<String>) -> Self {
        Self { fail, text: text.into() }
    }

    /// A dial step's I/O error, typed by its `ErrorKind`.
    pub fn io(error: &std::io::Error) -> Self {
        Self::new(fail_of_io(error), error.to_string())
    }

    /// A WebSocket upgrade's error, typed by its status or I/O error.
    pub fn ws(error: &tokio_tungstenite::tungstenite::Error) -> Self {
        Self::new(fail_of_ws(error), error.to_string())
    }

    /// A dial that ran past its deadline.
    pub fn timeout(text: String) -> Self {
        Self::new(Some(DialFail::Timeout), text)
    }
}

impl From<String> for DialError {
    fn from(text: String) -> Self {
        Self { fail: None, text }
    }
}

impl From<DialError> for String {
    fn from(error: DialError) -> Self {
        error.text
    }
}

impl std::fmt::Display for DialError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.text)
    }
}

/// The kind of an I/O error, from its `ErrorKind` alone; None for a kind that says nothing
/// about the route (a reset mid-stream, a broken pipe).
pub(crate) fn fail_of_io(error: &std::io::Error) -> Option<DialFail> {
    use std::io::ErrorKind as K;
    match error.kind() {
        K::TimedOut => Some(DialFail::Timeout),
        K::ConnectionRefused => Some(DialFail::Refused),
        // `happy_dial::connect_tcp` raises NotFound for a name with no address.
        K::NetworkUnreachable | K::HostUnreachable | K::AddrNotAvailable | K::NotFound => {
            Some(DialFail::Unreachable)
        }
        _ => None,
    }
}

/// The kind of a WebSocket dial's error: a refused token (`tokens::refused`, 401 or 403) is
/// `auth`, an I/O error its kind.
pub(crate) fn fail_of_ws(error: &tokio_tungstenite::tungstenite::Error) -> Option<DialFail> {
    match error {
        _ if super::tokens::refused(error) => Some(DialFail::Auth),
        tokio_tungstenite::tungstenite::Error::Io(error) => fail_of_io(error),
        _ => None,
    }
}

/// The kind an `anyhow` error chain carries: its first I/O error's (the WireGuard transport's
/// connect wraps the socket's).
pub(crate) fn fail_of_chain(error: &anyhow::Error) -> Option<DialFail> {
    error.chain().find_map(|cause| cause.downcast_ref::<std::io::Error>()).and_then(fail_of_io)
}

/// The connect's kind when every path failed: the most telling of theirs ([`DialFail::rank`]).
pub(crate) fn connect_fail<'a>(
    failed: impl IntoIterator<Item = &'a DialError>,
) -> Option<DialFail> {
    failed.into_iter().filter_map(|error| error.fail).min_by_key(|fail| fail.rank())
}

/// `state` as the whole link state: a down link whose last attempt was refused for its token
/// is `authFailed`, which a person fixes, not a retry. A down link with an [`OfflineReason`] is
/// `offline`, never `reconnecting`: retrying alone will not heal it, and the reason says what
/// will (attempts still go on behind it).
pub(crate) fn whole(state: PeerState, refused: bool, reason: Option<OfflineReason>) -> MachineLink {
    match state {
        PeerState::Reconnecting | PeerState::Offline if refused => MachineLink::AuthFailed,
        PeerState::Reconnecting | PeerState::Offline if reason.is_some() => MachineLink::Offline,
        other => other.wire(),
    }
}

/// Why a down link will not heal by retrying alone, from what acpmux knows: a refused token
/// (`login-needed`), or its last attempt's error. Null for a link that is up or on its way, and
/// for an error a retry may well fix (a timeout, a refused connection).
pub(crate) fn reason(
    state: PeerState,
    refused: bool,
    error: Option<&str>,
) -> Option<OfflineReason> {
    if !matches!(state, PeerState::Reconnecting | PeerState::Offline) {
        return None;
    }
    if refused {
        return Some(OfflineReason::LoginNeeded);
    }
    let error = error?.to_ascii_lowercase();
    let named = |needles: &[&str]| needles.iter().any(|n| error.contains(n));
    // The words each reason's producer writes into the attempt's error.
    if named(&["no space left on device", "os error 28)", "disk-full"]) {
        Some(OfflineReason::DiskFull)
    } else if named(&["restart-budget-exceeded"]) {
        Some(OfflineReason::RestartBudgetExceeded)
    } else if named(&["vm.agent_stopping", "machine-stopped", "machine is stopped"]) {
        Some(OfflineReason::MachineStopped)
    } else if named(&[CREDENTIAL_UNAVAILABLE, "relay credential source "]) {
        Some(OfflineReason::CredentialUnavailable)
    } else {
        None
    }
}

/// Whether a named [`OfflineReason`] turns a down link `offline` (instead of `reconnecting`):
/// Settings > Experimental > Labs > Show Preview Features (`labs.previewFeatures`), off by
/// default. The reason itself is reported either way.
pub(crate) fn reasons_turn_offline() -> bool {
    use crate::user_settings::{self, Settings};
    matches!(user_settings::read(), Settings::Parsed(doc)
        if user_settings::value(&doc, "labs.previewFeatures") == Some(serde_json::Value::Bool(true)))
}

/// Why a link in `link` is down, from what acpmux knows today: its last attempt's error, and
/// whether the peer refused the token. A link that is up, or on its way the first time, has
/// no cause.
///
/// TODO(carrier slice 3): decide `localNetwork` against `peerDown` with a test request over a
/// second carrier (the hub or Cloud relay), and report `hubDown` from the hub carrier's probe.
/// Until then `localNetwork` comes from an error that never left this host.
pub(crate) fn cause(link: MachineLink, error: Option<&str>) -> Option<DownCause> {
    match link {
        MachineLink::AuthFailed => Some(DownCause::Auth),
        MachineLink::Reconnecting | MachineLink::Offline => Some(if error.is_some_and(local) {
            DownCause::LocalNetwork
        } else {
            DownCause::PeerDown
        }),
        _ => None,
    }
}

/// An error raised before a packet could leave this host: no route out, or no name service.
fn local(error: &str) -> bool {
    const LOCAL: [&str; 6] = [
        "network is unreachable",
        "os error 51",
        "os error 101",
        "failed to lookup address",
        "nodename nor servname",
        "could not resolve hostname",
    ];
    let error = error.to_ascii_lowercase();
    LOCAL.iter().any(|needle| error.contains(needle))
}

#[cfg(test)]
#[path = "peer_carrier_tests.rs"]
mod tests;
