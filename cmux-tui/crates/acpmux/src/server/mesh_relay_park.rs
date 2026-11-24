//! Part of the mesh relay (`mesh_relay.rs`): a relayed message whose delivery failed for a cause
//! only something else ends waits, untried, until that cause ends, instead of being tried again
//! at every lease. Two such causes: the session's folder is gone (`session.folder_missing`), until
//! it is a folder again; and a registered chat's Claude Code restarted without registering, or
//! two processes claim it (`bridge.registration_stale`, `bridge.registration_contested`), until
//! the chat's row no longer says it is unreachable (`acpmux register` clears it, `bridge.rs`).
//!
//! The hub leases an unacked message again about once a minute, and each lease was a full attempt
//! (a folder revival, a bridge lookup, a log line): on a busy Mac (2026-11-22) a handful of such
//! messages were each tried 100+ times, 894 log lines. A parked message's lease now costs one stat
//! or one tag read. It is still tried at least every [`RECHECK`], should its cause end some way
//! this check does not see (the app quit, a folder made by hand under another session).
//!
//! In memory only: a daemon restart tries each once again, which parks it again.

use super::*;
use std::collections::HashMap;
use std::time::Instant;

/// How long a parked message waits, its cause unchanged, before it is tried anyway.
pub(super) const RECHECK: Duration = Duration::from_secs(30 * 60);

/// A parked message no lease brought back for this long is forgotten (the hub expired it, or it
/// was delivered elsewhere).
const FORGET: Duration = Duration::from_secs(60 * 60);

/// Most messages parked at once; past it a failing message is tried at each lease, as before.
const MOST: usize = 4096;

/// What a parked message waits for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Cause {
    /// The folder of session `session` to be a folder again.
    Folder { session: String },
    /// Registered chat `session` to be reachable again (its row's `bridge.unreachable` gone).
    Registration { session: String },
}

impl Cause {
    /// The cause a refusal `why` for session id `session` names, when only something else
    /// ends it.
    pub(super) fn of(why: &str, session: &str) -> Option<Self> {
        let session = session.to_owned();
        if why.starts_with("session.folder_missing") {
            return Some(Self::Folder { session });
        }
        if why.starts_with("bridge.registration_stale")
            || why.starts_with("bridge.registration_contested")
        {
            return Some(Self::Registration { session });
        }
        None
    }

    /// Whether the cause still holds on `hub`. A session no longer here holds nothing: the next
    /// attempt says what became of it.
    pub(super) fn holds(&self, hub: &Hub) -> bool {
        match self {
            Self::Folder { session } => {
                hub.resolve(session).is_ok_and(|s| !s.read_meta(|m| m.cwd.clone()).is_dir())
            }
            Self::Registration { session } => {
                hub.resolve(session).is_ok_and(|s| hub.bridge_unreached(&s))
            }
        }
    }
}

impl std::fmt::Display for Cause {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Folder { session } => write!(f, "the folder of {session} is back"),
            Self::Registration { session } => write!(f, "{session} registers again"),
        }
    }
}

#[derive(Debug)]
struct Parked {
    cause: Cause,
    /// When it was parked, or last tried while parked.
    at: Instant,
    /// When a lease last brought it back.
    seen: Instant,
}

/// The relay's parked messages, by message id.
#[derive(Debug, Default)]
pub(super) struct Parking {
    parked: StdMutex<HashMap<String, Parked>>,
}

impl Parking {
    /// Whether message `id`, back on a lease at `now`, waits untried: it is parked, under
    /// [`RECHECK`] since it was last tried, and `holds` says its cause still holds.
    pub(super) fn waits(&self, id: &str, now: Instant, holds: impl FnOnce(&Cause) -> bool) -> bool {
        let cause = {
            let mut parked = self.parked.lock_or_recover();
            let Some(entry) = parked.get_mut(id) else { return false };
            entry.seen = now;
            if now.saturating_duration_since(entry.at) >= RECHECK {
                return false;
            }
            entry.cause.clone()
        };
        if holds(&cause) {
            return true;
        }
        self.parked.lock_or_recover().remove(id);
        false
    }

    /// Parks message `id` on `cause`, tried at `now`. True when it was not parked on that cause
    /// already (worth a log line).
    pub(super) fn park(&self, id: &str, cause: Cause, now: Instant) -> bool {
        let mut parked = self.parked.lock_or_recover();
        parked.retain(|_, p| now.saturating_duration_since(p.seen) < FORGET);
        if let Some(entry) = parked.get_mut(id) {
            let new = entry.cause != cause;
            *entry = Parked { cause, at: now, seen: now };
            return new;
        }
        if parked.len() >= MOST {
            return false;
        }
        parked.insert(id.to_owned(), Parked { cause, at: now, seen: now });
        true
    }

    /// Message `id` was delivered, refused, or failed for a passing cause: no longer parked.
    pub(super) fn clear(&self, id: &str) {
        self.parked.lock_or_recover().remove(id);
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.parked.lock_or_recover().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder() -> Cause {
        Cause::Folder { session: "s1".into() }
    }

    /// A parked message waits while its cause holds, and is tried at once when it ends.
    #[test]
    fn a_parked_message_waits_until_its_cause_ends() {
        let parking = Parking::default();
        let t0 = Instant::now();
        assert!(!parking.waits("m", t0, |_| true), "a message never parked is tried");
        assert!(parking.park("m", folder(), t0));
        assert!(!parking.park("m", folder(), t0), "parked again on the same cause: no new log");
        let minute = Duration::from_secs(60);
        assert!(parking.waits("m", t0 + minute, |c| *c == folder()));
        assert!(!parking.waits("m", t0 + 2 * minute, |_| false), "the folder is back: tried now");
        assert_eq!(parking.len(), 0, "a message whose cause ended is no longer parked");
    }

    /// A cause this check cannot see end still gets an attempt every `RECHECK`.
    #[test]
    fn a_parked_message_is_tried_again_after_recheck() {
        let parking = Parking::default();
        let t0 = Instant::now();
        parking.park("m", folder(), t0);
        assert!(parking.waits("m", t0 + RECHECK - Duration::from_secs(1), |_| true));
        assert!(!parking.waits("m", t0 + RECHECK, |_| true));
    }

    /// A delivered message is cleared; one no lease brings back is forgotten.
    #[test]
    fn delivered_and_forgotten_messages_leave_the_park() {
        let parking = Parking::default();
        let t0 = Instant::now();
        parking.park("a", folder(), t0);
        parking.park("b", folder(), t0);
        parking.clear("a");
        assert_eq!(parking.len(), 1);
        parking.park("c", Cause::Registration { session: "s2".into() }, t0 + FORGET);
        assert_eq!(parking.len(), 1, "b, unseen for an hour, is forgotten");
    }

    /// Only the two causes something else ends park a message; a passing one does not.
    #[test]
    fn only_folder_missing_and_registration_refusals_park() {
        let of = |why: &str| Cause::of(why, "s1");
        assert_eq!(
            of("session.folder_missing: the folder of x (/tmp/x) no longer exists"),
            Some(folder())
        );
        let registration = Some(Cause::Registration { session: "s1".into() });
        assert_eq!(
            of("bridge.registration_stale: desk-chat is unreachable, registration stale"),
            registration
        );
        assert_eq!(of("bridge.registration_contested: desk-chat is unreachable"), registration);
        assert_eq!(of("no answer within 50 s"), None);
        assert_eq!(of("bridge.not_running: x's app is not running it now"), None);
    }

    /// The harness behind the PR's numbers: one message whose folder is gone, leased again every
    /// minute for an hour. Before, each lease was an attempt; now the first is, then one every
    /// `RECHECK`; and a folder back at minute 45 is tried at that very lease.
    #[test]
    fn an_hour_of_leases_is_two_attempts_not_sixty() {
        let t0 = Instant::now();
        let hour = |back_at: Option<u64>| {
            let parking = Parking::default();
            let mut attempts = Vec::new();
            for minute in 0..60u64 {
                let now = t0 + Duration::from_secs(minute * 60);
                let gone = back_at.is_none_or(|back| minute < back);
                if parking.waits("m", now, |_| gone) {
                    continue;
                }
                attempts.push(minute);
                if gone {
                    parking.park("m", folder(), now);
                } else {
                    parking.clear("m");
                    break;
                }
            }
            attempts
        };
        let still_gone = hour(None);
        eprintln!("attempts in an hour, the folder still gone: before 60, now {still_gone:?}");
        assert_eq!(still_gone, vec![0, 30]);
        let back = hour(Some(45));
        assert_eq!(back, vec![0, 30, 45], "the lease after the folder returns delivers it");
    }
}
