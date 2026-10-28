//! The cmux sign-in the app lends this daemon (`_acpmux/github_app_lease`, the unix socket
//! only), so the GitHub broker (`github_broker.rs`) can ask cmux Cloud's token route
//! (`POST /v1/integrations/github/token`, the one Cloud machines use) for a GitHub App token
//! when the Mac's `gh` has no keyring login. The mint that uses it comes on top of this.
//!
//! - The lent sign-in is held in memory only, until it expires (it is dropped when next looked
//!   at) or the app replaces or clears it (sign-out, a team switch). Nothing answers it back.
//! - Each call carries the app's `seq`, which only grows; an older one is refused, so a lend
//!   that arrives after the sign-out that outdated it never restores the sign-in.
//! - It may name only cmux Cloud's API as where it goes.

use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Mutex;

/// How far past now a lease's `seq` may be.
const SEQ_AHEAD_MAX_MS: u64 = 24 * 60 * 60 * 1000;
/// The cmux Cloud APIs the sign-in may be sent to (the app's `ownerAPIBaseURL`); a loopback
/// one is for a local API in development and tests.
const CMUX_APIS: [&str; 2] = ["https://cloud-api.cmux.dev", "https://cloud-api-staging.cmux.dev"];

/// `origin` if it is cmux Cloud's API (or one on this machine's loopback), else refused: the
/// lent sign-in goes nowhere else.
fn cmux_api(origin: &str) -> Result<String, RpcError> {
    let checked = crate::hand::pair::check_api(origin)
        .map_err(|e| RpcError::invalid_params(e.to_string()))?;
    let url = reqwest::Url::parse(&checked).map_err(|e| RpcError::invalid_params(e.to_string()))?;
    let loopback = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    let bare = url.path() == "/" && url.query().is_none() && url.username().is_empty();
    if bare && (loopback || CMUX_APIS.contains(&checked.as_str())) {
        Ok(checked)
    } else {
        Err(RpcError::invalid_params(format!("{checked} is not cmux Cloud's API")))
    }
}

// Read by the mint, which comes on top of this.
#[allow(dead_code)]
#[derive(Clone)]
struct Lent {
    origin: String,
    bearer: String,
    team: String,
    expires_at_ms: u64,
}

#[derive(Default)]
struct Held {
    /// The newest `seq` taken, a lend's or a clear's.
    seq: u64,
    lent: Option<Lent>,
}

/// The cmux sign-in the app lends this daemon for minting (module docs).
#[derive(Default)]
pub struct AppLease(Mutex<Held>);

impl AppLease {
    fn lock(&self) -> std::sync::MutexGuard<'_, Held> {
        self.0.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// `_acpmux/github_app_lease {seq, origin, bearer, team, expiresAtMs}`, or
    /// `{seq, clear: true}`. Answers whether one is held, never the bearer; a `seq` older than
    /// one already taken changes nothing (`stale: true`).
    pub fn set(&self, params: &Value) -> Result<Value, RpcError> {
        let seq = params
            .get("seq")
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::invalid_params("seq is required"))?;
        // The app's are about now in ms: one far ahead would shut out every later lend.
        if seq > crate::store::now_ms() + SEQ_AHEAD_MAX_MS {
            return Err(RpcError::invalid_params("seq is too far ahead"));
        }
        // `held` is the lease with an expired sign-in already dropped (`live`).
        let take = |held: &mut Held, lent: Option<Lent>| {
            // At the newest `seq`, only a clear or a renewal of the sign-in held now (unexpired,
            // the same API and team) is taken: a token minted under that `seq` stays the sign-in's
            // it was minted with, and a cleared or expired one never comes back under it.
            let renews = |l: &Lent| {
                held.lent.as_ref().is_some_and(|h| h.origin == l.origin && h.team == l.team)
            };
            if seq < held.seq || (seq == held.seq && lent.as_ref().is_some_and(|l| !renews(l))) {
                // The newest `seq` (a time, no secret): the app goes on from past it.
                return json!({"lent": held.lent.is_some(), "stale": true, "seq": held.seq});
            }
            held.seq = seq;
            // One that expired on its way here moves `seq` on and is not kept (the lock is held,
            // so this is the time it lands).
            let now = crate::store::now_ms();
            held.lent = lent.filter(|l| l.expires_at_ms > now);
            json!({"lent": held.lent.is_some()})
        };
        if params.get("clear") == Some(&Value::Bool(true)) {
            return Ok(take(&mut self.live(crate::store::now_ms), None));
        }
        let text = |k: &str| {
            params
                .get(k)
                .and_then(Value::as_str)
                .filter(|v| !v.is_empty() && v.len() <= 8192)
                .ok_or_else(|| RpcError::invalid_params(format!("{k} is required")))
        };
        let origin = cmux_api(text("origin")?)?;
        let bearer = text("bearer")?;
        if !bearer.bytes().all(|b| b.is_ascii_graphic()) {
            return Err(RpcError::invalid_params("bearer must be printable ASCII"));
        }
        let team = text("team")?;
        if team.len() > 64 || !team.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_') {
            return Err(RpcError::invalid_params("team must be a cmux team id"));
        }
        let expires_at_ms = params
            .get("expiresAtMs")
            .and_then(Value::as_u64)
            .ok_or_else(|| RpcError::invalid_params("expiresAtMs is required"))?;
        let lent = Lent { origin, bearer: bearer.to_owned(), team: team.to_owned(), expires_at_ms };
        Ok(take(&mut self.live(crate::store::now_ms), Some(lent)))
    }

    /// The lease, with a sign-in that expired by `now()` dropped from memory. The clock is read
    /// once the lock is held, so a wait for it never lets an expired sign-in through.
    fn live(&self, now: impl FnOnce() -> u64) -> std::sync::MutexGuard<'_, Held> {
        let mut held = self.lock();
        let now_ms = now();
        if held.lent.as_ref().is_some_and(|l| l.expires_at_ms <= now_ms) {
            held.lent = None;
        }
        held
    }

    /// The sign-in held now and its `seq`.
    #[cfg_attr(not(test), allow(dead_code))]
    fn current(&self, now: impl FnOnce() -> u64) -> Option<(u64, Lent)> {
        let held = self.live(now);
        held.lent.clone().map(|l| (held.seq, l))
    }

    /// The lease while the sign-in of `seq` is still the one held and unexpired: no lend or
    /// clear lands until the guard is dropped.
    #[cfg_attr(not(test), allow(dead_code))]
    fn still(
        &self,
        seq: u64,
        now: impl FnOnce() -> u64,
    ) -> Option<std::sync::MutexGuard<'_, Held>> {
        let held = self.live(now);
        (held.seq == seq && held.lent.is_some()).then_some(held)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lease_takes_only_a_cmux_origin_and_sign_in_and_never_answers_it() {
        let lease = AppLease::default();
        let t = crate::store::now_ms() + 60_000;
        let ok = json!({"seq": 1, "origin": "https://cloud-api.cmux.dev/", "bearer": "b.e.r",
            "team": "team_0123", "expiresAtMs": t + 10});
        let far = crate::store::now_ms() + 2 * SEQ_AHEAD_MAX_MS;
        assert_eq!(lease.set(&ok).unwrap(), json!({"lent": true}));
        assert_eq!(lease.current(|| t + 9).unwrap().1.origin, "https://cloud-api.cmux.dev");
        assert!(lease.current(|| t + 10).is_none(), "an expired sign-in is not used");
        for bad in [
            json!({"seq": 2, "origin": "http://example.com", "bearer": "b", "team": "t", "expiresAtMs": 1}),
            json!({"seq": 2, "origin": "https://evil.example", "bearer": "b", "team": "t", "expiresAtMs": 1}),
            json!({"seq": 2, "origin": "https://cloud-api.cmux.dev.evil.example", "bearer": "b",
                "team": "t", "expiresAtMs": 1}),
            json!({"seq": 2, "origin": "https://cloud-api.cmux.dev/x", "bearer": "b", "team": "t",
                "expiresAtMs": 1}),
            json!({"seq": far, "origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t",
                "expiresAtMs": 1}),
            json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b c", "team": "t", "expiresAtMs": 1}),
            json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t/x", "expiresAtMs": 1}),
            json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t"}),
            json!({"origin": "https://cloud-api.cmux.dev", "bearer": "b", "team": "t", "expiresAtMs": 1}),
        ] {
            assert_eq!(lease.set(&bad).unwrap_err().code, -32602, "{bad}");
        }
        assert_eq!(lease.set(&json!({"seq": 2, "clear": true})).unwrap(), json!({"lent": false}));
        assert!(lease.current(|| 0).is_none());
    }

    /// Review of the App token at d8a663b: a lend that reached the daemon after the sign-out
    /// that outdated it restored the sign-in, and a late clear could drop the next one's.
    #[test]
    fn a_lend_or_clear_that_arrives_after_a_newer_one_changes_nothing() {
        let lease = AppLease::default();
        let lend = |seq: u64| {
            json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": u64::MAX})
        };
        // Signed in (1), signed out (2): the lend for 1 arrives last.
        lease.set(&json!({"seq": 2, "clear": true})).unwrap();
        assert_eq!(lease.set(&lend(1)).unwrap(), json!({"lent": false, "stale": true, "seq": 2}));
        assert!(lease.current(|| 0).is_none(), "the sign-out holds");
        // Signed in again (3): the earlier clear arrives after it.
        lease.set(&lend(3)).unwrap();
        assert_eq!(lease.set(&json!({"seq": 2, "clear": true})).unwrap()["stale"], true);
        assert_eq!(lease.current(|| 0).unwrap().1.bearer, "b3", "the newer sign-in holds");
        // A renewal of the same sign-in is taken.
        assert_eq!(lease.set(&lend(3)).unwrap(), json!({"lent": true}));
    }

    /// Review of the App token at e318f53: a lend at the newest `seq` replaced the sign-in, so a
    /// token minted under that `seq` stayed usable for another team, and a cleared or expired
    /// sign-in came back under its `seq`.
    #[test]
    fn a_lend_at_the_newest_seq_only_renews_the_sign_in_held_now() {
        let lease = AppLease::default();
        let lend = |seq: u64, team: &str, expires: u64| {
            json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}{team}"),
                "team": team, "expiresAtMs": expires})
        };
        lease.set(&lend(3, "team_a", u64::MAX)).unwrap();
        assert_eq!(lease.set(&lend(3, "team_b", u64::MAX)).unwrap()["stale"], true);
        assert_eq!(lease.current(|| 0).unwrap().1.team, "team_a", "another team needs a newer seq");
        assert_eq!(lease.set(&lend(4, "team_a", u64::MAX)).unwrap(), json!({"lent": true}));
        assert_eq!(lease.set(&json!({"seq": 4, "clear": true})).unwrap(), json!({"lent": false}));
        assert_eq!(lease.set(&lend(4, "team_a", u64::MAX)).unwrap()["stale"], true);
        assert!(lease.current(|| 0).is_none(), "a cleared sign-in stays cleared at its seq");
        lease.set(&lend(5, "team_a", 1)).unwrap();
        assert_eq!(lease.set(&lend(5, "team_a", u64::MAX)).unwrap()["stale"], true);
        assert!(lease.current(|| 2).is_none(), "an expired one does not come back at its seq");
    }

    /// Review of the App token at 15a905b: an expired sign-in stayed in memory.
    #[test]
    fn an_expired_or_replaced_sign_in_is_dropped() {
        let lease = AppLease::default();
        let lend = |seq: u64, expires: u64| {
            json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": expires})
        };
        let t = crate::store::now_ms() + 60_000;
        lease.set(&lend(1, t + 100)).unwrap();
        assert!(lease.current(|| t + 100).is_none());
        assert!(lease.lock().lent.is_none(), "an expired sign-in is dropped from memory");

        lease.set(&lend(2, u64::MAX)).unwrap();
        assert!(lease.still(2, || 0).is_some());
        lease.set(&lend(3, u64::MAX)).unwrap();
        assert!(lease.still(2, || 0).is_none(), "a team switch replaces the sign-in");
        lease.set(&json!({"seq": 4, "clear": true})).unwrap();
        assert!(lease.still(3, || 0).is_none(), "a sign-out ends it");
        lease.set(&lend(5, t + 50)).unwrap();
        assert!(lease.still(5, || t + 49).is_some());
        assert!(lease.still(5, || t + 50).is_none(), "an expired one is not still lent");
    }

    /// Review of the lease at 0fdead6: a call that came after the sign-in expired answered that
    /// one was lent and kept it in memory, and the clock was read before the lock was taken.
    #[test]
    fn an_expired_sign_in_is_gone_for_every_call_and_the_clock_is_read_under_the_lock() {
        let lease = AppLease::default();
        lease
            .set(&json!({"seq": 5, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
                "team": "team_0", "expiresAtMs": 1}))
            .unwrap();
        let stale = lease.set(&json!({"seq": 4, "clear": true})).unwrap();
        assert_eq!(stale, json!({"lent": false, "stale": true, "seq": 5}));
        assert!(lease.lock().lent.is_none(), "dropped from memory");
        lease
            .set(&json!({"seq": 6, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
                "team": "team_0", "expiresAtMs": u64::MAX}))
            .unwrap();
        let under_lock = || {
            assert!(lease.0.try_lock().is_err(), "the clock is read with the lease locked");
            0
        };
        assert!(lease.still(6, under_lock).is_some());
    }

    /// Review of the lease at 0bb52d0: a lend that had expired on its way in was kept and
    /// answered `lent: true`.
    #[test]
    fn a_lend_that_expired_on_its_way_moves_seq_on_and_is_not_kept() {
        let lease = AppLease::default();
        let expired = json!({"seq": 7, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
            "team": "team_0", "expiresAtMs": 1});
        assert_eq!(lease.set(&expired).unwrap(), json!({"lent": false}));
        assert!(lease.lock().lent.is_none());
        let older = json!({"seq": 6, "clear": true});
        assert_eq!(lease.set(&older).unwrap()["stale"], true, "its seq still counts");
    }
}
