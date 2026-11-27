//! Which leg won each race, and why each loser lost, counted per dial for the whole process:
//! "how often does each leg win" as a number. A leg is a coarse name for a target ([`Leg`]:
//! `v6` or `v4` for an address, the scheme for a route), never the address itself. Each race
//! records one [`Outcome`] per leg it dialed: [`Outcome::Won`] for the winner,
//! [`Outcome::Outrun`] for one still dialing when the winner answered, and the failure's kind
//! for one that failed ([`Outcome::of`]). [`snapshot`] is what a reader counts; [`render`] is
//! its one-line text form (`dial leg outcome=n ...`).

use std::collections::BTreeMap;
use std::io;
use std::net::SocketAddr;
use std::sync::Mutex;

/// Why a leg ended the way it did.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Outcome {
    /// It connected first.
    Won,
    /// It was still dialing when another leg won.
    Outrun,
    /// No answer in time (a black hole, or UDP dropped on the way: what a blocked UDP leg
    /// looks like).
    Timeout,
    /// The far end refused or reset it.
    Refused,
    /// No route to the host or network (unreachable, address not available).
    Unreachable,
    /// The TLS (or Noise) handshake failed.
    Tls,
    /// Anything else.
    Other,
}

impl Outcome {
    /// The name a reader counts.
    #[must_use]
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Won => "won",
            Self::Outrun => "outrun",
            Self::Timeout => "timeout",
            Self::Refused => "refused",
            Self::Unreachable => "unreachable",
            Self::Tls => "tls",
            Self::Other => "other",
        }
    }

    /// The kind of a failed attempt's `error`.
    #[must_use]
    pub fn of(error: &io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock => Self::Timeout,
            io::ErrorKind::ConnectionRefused
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted => Self::Refused,
            io::ErrorKind::NetworkUnreachable
            | io::ErrorKind::HostUnreachable
            | io::ErrorKind::AddrNotAvailable
            | io::ErrorKind::NetworkDown => Self::Unreachable,
            _ => Self::of_text(&error.to_string()),
        }
    }

    /// The kind a failure's text names (a route's error is often only text).
    #[must_use]
    pub fn of_text(text: &str) -> Self {
        let text = text.to_ascii_lowercase();
        let has = |words: &[&str]| words.iter().any(|word| text.contains(word));
        if has(&["timed out", "timeout", "no answer within"]) {
            Self::Timeout
        } else if has(&["refused", "reset by peer", "connection reset"]) {
            Self::Refused
        } else if has(&["unreachable", "no route to host", "not available"]) {
            Self::Unreachable
        } else if has(&["tls", "certificate", "handshake", "noise"]) {
            Self::Tls
        } else {
            Self::Other
        }
    }
}

/// A coarse name for a race target, counted in place of the target.
pub trait Leg {
    /// The leg's name (`v6`, `v4`, `wss`, `quic`, ...).
    fn leg(&self) -> String;
}

impl Leg for SocketAddr {
    fn leg(&self) -> String {
        if self.is_ipv6() { "v6" } else { "v4" }.to_string()
    }
}

impl Leg for &str {
    fn leg(&self) -> String {
        (*self).to_string()
    }
}

impl Leg for String {
    fn leg(&self) -> String {
        self.clone()
    }
}

/// Counts per (dial, leg, outcome).
pub type Snapshot = BTreeMap<(String, String, Outcome), u64>;

static TALLY: Mutex<BTreeMap<(String, String, Outcome), u64>> = Mutex::new(BTreeMap::new());

/// Counts one `outcome` of `leg` in a race of `dial` (`cmux-remote.tcp`, `remote.route`, ...).
pub fn record(dial: &str, leg: &str, outcome: Outcome) {
    let mut tally = TALLY.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    *tally.entry((dial.to_string(), leg.to_string(), outcome)).or_default() += 1;
}

/// Every count so far in this process.
#[must_use]
pub fn snapshot() -> Snapshot {
    TALLY.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
}

/// `snapshot`'s counts, one line per (dial, leg): `remote.route wss won=12 timeout=1`.
#[must_use]
pub fn render(snapshot: &Snapshot) -> String {
    let mut lines: BTreeMap<(&str, &str), Vec<String>> = BTreeMap::new();
    for ((dial, leg, outcome), count) in snapshot {
        lines.entry((dial, leg)).or_default().push(format!("{}={count}", outcome.as_str()));
    }
    lines
        .into_iter()
        .map(|((dial, leg), counts)| format!("{dial} {leg} {}", counts.join(" ")))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failures_are_named_by_kind_or_text() {
        assert_eq!(Outcome::of(&io::Error::from(io::ErrorKind::TimedOut)), Outcome::Timeout);
        assert_eq!(
            Outcome::of(&io::Error::from(io::ErrorKind::ConnectionRefused)),
            Outcome::Refused
        );
        assert_eq!(
            Outcome::of(&io::Error::from(io::ErrorKind::HostUnreachable)),
            Outcome::Unreachable
        );
        assert_eq!(Outcome::of(&io::Error::other("invalid peer certificate")), Outcome::Tls);
        assert_eq!(Outcome::of_text("quic: no answer within 3000 ms"), Outcome::Timeout);
        assert_eq!(Outcome::of_text("something odd"), Outcome::Other);
    }

    #[test]
    fn counts_render_one_line_per_leg() {
        let mut snapshot = Snapshot::new();
        snapshot.insert(("d".into(), "v4".into(), Outcome::Won), 3);
        snapshot.insert(("d".into(), "v6".into(), Outcome::Timeout), 2);
        snapshot.insert(("d".into(), "v6".into(), Outcome::Outrun), 1);
        assert_eq!(render(&snapshot), "d v4 won=3\nd v6 outrun=1 timeout=2");
    }
}
