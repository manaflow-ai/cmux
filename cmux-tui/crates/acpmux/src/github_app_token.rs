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
#[cfg_attr(not(test), allow(dead_code))]
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
        let take = |held: &mut Held, lent: Option<Lent>| {
            if seq < held.seq {
                // The newest `seq` (a time, no secret): the app goes on from past it.
                return json!({"lent": held.lent.is_some(), "stale": true, "seq": held.seq});
            }
            held.seq = seq;
            held.lent = lent;
            json!({"lent": held.lent.is_some()})
        };
        if params.get("clear") == Some(&Value::Bool(true)) {
            return Ok(take(&mut self.lock(), None));
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
        Ok(take(&mut self.lock(), Some(lent)))
    }

    /// The sign-in held now and its `seq`; one that expired is dropped from memory.
    #[cfg_attr(not(test), allow(dead_code))]
    fn current(&self, now_ms: u64) -> Option<(u64, Lent)> {
        let mut held = self.lock();
        if held.lent.as_ref().is_some_and(|l| l.expires_at_ms <= now_ms) {
            held.lent = None;
        }
        held.lent.clone().map(|l| (held.seq, l))
    }

    /// Whether the sign-in of `seq` is still the one held and unexpired.
    #[cfg_attr(not(test), allow(dead_code))]
    fn still(&self, seq: u64, now_ms: u64) -> bool {
        self.current(now_ms).is_some_and(|(held, _)| held == seq)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_lease_takes_only_a_cmux_origin_and_sign_in_and_never_answers_it() {
        let lease = AppLease::default();
        let ok = json!({"seq": 1, "origin": "https://cloud-api.cmux.dev/", "bearer": "b.e.r",
            "team": "team_0123", "expiresAtMs": 10});
        let far = crate::store::now_ms() + 2 * SEQ_AHEAD_MAX_MS;
        assert_eq!(lease.set(&ok).unwrap(), json!({"lent": true}));
        assert_eq!(lease.current(9).unwrap().1.origin, "https://cloud-api.cmux.dev");
        assert!(lease.current(10).is_none(), "an expired sign-in is not used");
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
        assert!(lease.current(0).is_none());
    }

    /// Review of the App token at d8a663b: a lend that reached the daemon after the sign-out
    /// that outdated it restored the sign-in, and a late clear could drop the next one's.
    #[test]
    fn a_lend_or_clear_that_arrives_after_a_newer_one_changes_nothing() {
        let lease = AppLease::default();
        let lend = |seq: u64| {
            json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": 100})
        };
        // Signed in (1), signed out (2): the lend for 1 arrives last.
        lease.set(&json!({"seq": 2, "clear": true})).unwrap();
        assert_eq!(lease.set(&lend(1)).unwrap(), json!({"lent": false, "stale": true, "seq": 2}));
        assert!(lease.current(0).is_none(), "the sign-out holds");
        // Signed in again (3): the earlier clear arrives after it.
        lease.set(&lend(3)).unwrap();
        assert_eq!(lease.set(&json!({"seq": 2, "clear": true})).unwrap()["stale"], true);
        assert_eq!(lease.current(0).unwrap().1.bearer, "b3", "the newer sign-in holds");
        // A renewal of the same sign-in is taken.
        assert_eq!(lease.set(&lend(3)).unwrap(), json!({"lent": true}));
    }

    /// Review of the App token at 15a905b: an expired sign-in stayed in memory.
    #[test]
    fn an_expired_or_replaced_sign_in_is_dropped() {
        let lease = AppLease::default();
        let lend = |seq: u64, expires: u64| {
            json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": expires})
        };
        lease.set(&lend(1, 100)).unwrap();
        assert!(lease.current(100).is_none());
        assert!(lease.lock().lent.is_none(), "an expired sign-in is dropped from memory");

        lease.set(&lend(2, u64::MAX)).unwrap();
        assert!(lease.still(2, 0));
        lease.set(&lend(3, u64::MAX)).unwrap();
        assert!(!lease.still(2, 0), "a team switch replaces the sign-in");
        lease.set(&json!({"seq": 4, "clear": true})).unwrap();
        assert!(!lease.still(3, 0), "a sign-out ends it");
        lease.set(&lend(5, 50)).unwrap();
        assert!(lease.still(5, 49) && !lease.still(5, 50), "an expired one is not still lent");
    }
}
