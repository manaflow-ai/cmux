//! The cmux sign-in the app lends this daemon (`_acpmux/github_app_lease`, the unix socket
//! only), so the GitHub broker (`github_broker.rs`) can ask cmux Cloud's token route
//! (`POST /v1/integrations/github/token`, the one Cloud machines use) for a GitHub App token
//! when the Mac's `gh` has no keyring login.
//!
//! - The lent sign-in is held in memory only, until it expires (it is dropped when next looked
//!   at) or the app replaces or clears it (sign-out, a team switch). Nothing answers it back.
//! - Each call carries the app's `seq`, which only grows; an older one is refused, so a lend
//!   that arrives after the sign-out that outdated it never restores the sign-in.
//! - It may name only cmux Cloud's API as where it goes.
//! - Chosen per action: the keyring login when `gh auth status` says it works, else the App,
//!   else the action fails closed and says to connect GitHub in Settings. Which one ran is
//!   recorded (the `github_broker_action` event, the Mac's log line); the token never is.
//! - The minted token lives in this daemon's memory for that one action: it goes to that one
//!   `gh` (as `GH_TOKEN`; the child is killed after `GH_TIMEOUT`) and nowhere else. Not to disk,
//!   a log, argv, the reply or the peer. One minted with a sign-in that was replaced, cleared or
//!   expired by the time `gh` would start is not used.

use crate::github_broker::{GithubAction, GithubActionParams};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Mutex;
use std::time::Duration;

/// How long a mint may take before the action fails.
const MINT_TIMEOUT: Duration = Duration::from_secs(20);
/// How long `gh auth status` may take to say whether the keyring login works.
const KEYRING_TIMEOUT: Duration = Duration::from_secs(10);
/// The label the Cloud ledger shows for these tokens.
const LABEL: &str = "acpmux-github-broker";
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

/// Where an action's GitHub login came from.
pub enum Source {
    /// `gh`'s own keyring login on the Mac.
    Keyring,
    /// A token the cmux GitHub App minted for this action's repository alone, with the lent
    /// sign-in of that `seq`.
    App(String, u64),
}

impl Source {
    pub fn name(&self) -> &'static str {
        match self {
            Self::Keyring => "keyring",
            Self::App(..) => "app",
        }
    }

    /// The token `gh` runs with, when it is not its own login.
    pub fn token(&self) -> Option<&str> {
        match self {
            Self::Keyring => None,
            Self::App(token, _) => Some(token),
        }
    }
}

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
    fn current(&self, now: impl FnOnce() -> u64) -> Option<(u64, Lent)> {
        let held = self.live(now);
        held.lent.clone().map(|l| (held.seq, l))
    }

    /// The lease while the sign-in of `seq` is still the one held and unexpired: no lend or
    /// clear lands until the guard is dropped.
    fn still(
        &self,
        seq: u64,
        now: impl FnOnce() -> u64,
    ) -> Option<std::sync::MutexGuard<'_, Held>> {
        let held = self.live(now);
        (held.seq == seq && held.lent.is_some()).then_some(held)
    }
}

/// `start` (it starts `gh`), run only while `source` may still be used: an App token only while
/// the sign-in it was minted with is still lent (no sign-out, team switch or expiry while it was
/// minted). The lease stays locked through `start`, so none of those lands between the check
/// and the start.
pub fn while_lent<T>(
    source: &Source,
    app: Option<&AppLease>,
    start: impl FnOnce() -> Result<T, RpcError>,
) -> Result<T, RpcError> {
    let Source::App(_, seq) = source else { return start() };
    let Some(_held) = app.and_then(|a| a.still(*seq, crate::store::now_ms)) else {
        return Err(RpcError::new(
            -32045,
            "cmux could not use the GitHub token: the cmux sign-in changed or ended while it was minted; nothing was done",
        )
        .with_data(json!({"reason": "github.app_token", "code": "lease_changed"})));
    };
    start()
}

/// No login to act with: the error the person sees, and the app's Connect GitHub keys on.
pub fn not_connected() -> RpcError {
    RpcError::new(
        -32044,
        "GitHub is not connected on this Mac: connect GitHub in cmux Settings (or sign in with `gh auth login`)",
    )
    .with_data(json!({"reason": "github.not_connected"}))
}

/// The login this action runs with (module docs), and the name of the one it tried (`app`
/// for a mint that failed; None with neither login).
pub async fn choose(
    r: &GithubActionParams,
    app: Option<&AppLease>,
) -> (Option<&'static str>, Result<Source, RpcError>) {
    if keyring_works().await {
        return (Some("keyring"), Ok(Source::Keyring));
    }
    let Some((seq, lent)) = app.and_then(|a| a.current(crate::store::now_ms)) else {
        return (None, Err(not_connected()));
    };
    (Some("app"), mint(&lent, r).await.map(|token| Source::App(token, seq)))
}

/// Whether `gh` on this Mac is signed in to github.com (it prints nothing of the token here).
async fn keyring_works() -> bool {
    let mut gh = tokio::process::Command::new("gh");
    gh.args(["auth", "status", "--hostname", "github.com"]);
    // As the action would run: no GitHub token from this daemon's env counts as a login.
    crate::github_broker::login_env(gh.as_std_mut(), None);
    let status = gh
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .status();
    matches!(tokio::time::timeout(KEYRING_TIMEOUT, status).await, Ok(Ok(s)) if s.success())
}

/// What each action needs of the App, and no more.
pub fn permissions(action: GithubAction) -> Value {
    match action {
        GithubAction::Read => json!({"metadata": "read", "pull_requests": "read"}),
        GithubAction::Issue => json!({"metadata": "read", "issues": "write"}),
        // `gh issue comment` posts through the issues API (a pull request's conversation
        // too); it reads a pull request to find which it is.
        GithubAction::Comment => {
            json!({"metadata": "read", "issues": "write", "pull_requests": "read"})
        }
        GithubAction::DraftPr => {
            json!({"metadata": "read", "contents": "read", "pull_requests": "write"})
        }
    }
}

/// The error for Cloud's `code`, in fixed words: nothing Cloud wrote goes on to the machine.
/// Only a code this list names is passed on; any other is `unknown`.
fn app_error(code: &str) -> RpcError {
    let (code, number, reason, message) = match code {
        "integration.not_found" => (
            "integration.not_found",
            -32044,
            "github.not_connected",
            "GitHub is not connected for this team: connect GitHub in cmux Settings",
        ),
        "needs_reauth" => (
            "needs_reauth",
            -32044,
            "github.not_connected",
            "GitHub needs to be connected again: reconnect GitHub in cmux Settings",
        ),
        "policy.denied" => (
            "policy.denied",
            -32045,
            "github.app_token",
            "cmux could not get a GitHub token: the team's GitHub connection does not cover this repository",
        ),
        "rate_limited" => (
            "rate_limited",
            -32045,
            "github.app_token",
            "cmux could not get a GitHub token: GitHub is rate limiting it",
        ),
        "unreachable" => (
            "unreachable",
            -32045,
            "github.app_token",
            "cmux could not get a GitHub token: cmux Cloud did not answer",
        ),
        "invalid_reply" => (
            "invalid_reply",
            -32045,
            "github.app_token",
            "cmux could not get a GitHub token: the token cmux Cloud sent is not for this repository",
        ),
        _ => ("unknown", -32045, "github.app_token", "cmux could not get a GitHub token"),
    };
    RpcError::new(number, message).with_data(json!({"reason": reason, "code": code}))
}

/// Whether the permissions a token says it has (`got`, GitHub's own list) are no more than
/// `asked`: each one asked for, at no higher level. A token that says nothing is refused.
fn within(got: Option<&Value>, asked: &Value) -> bool {
    let level = |v: &Value| match v.as_str() {
        Some("read") => Some(1),
        Some("write") => Some(2),
        _ => None,
    };
    let Some(got) = got.and_then(Value::as_object).filter(|g| !g.is_empty()) else {
        return false;
    };
    got.iter().all(|(name, have)| match (level(have), asked.get(name).and_then(level)) {
        (Some(have), Some(max)) => have <= max,
        _ => false,
    })
}

/// How much of Cloud's answer is read: a token reply is well under this.
const REPLY_MAX: usize = 16 * 1024;

/// Cloud's answer as JSON, read only up to `REPLY_MAX` (Null past it or if it is not JSON).
async fn bounded_json(mut res: reqwest::Response) -> Value {
    let mut bytes = Vec::new();
    while let Ok(Some(chunk)) = res.chunk().await {
        if bytes.len() + chunk.len() > REPLY_MAX {
            return Value::Null;
        }
        bytes.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&bytes).unwrap_or(Value::Null)
}

/// A token for `r.repo` alone, with `permissions(r.action)`; checked to be an App installation
/// token for that repository before anything uses it.
async fn mint(lent: &Lent, r: &GithubActionParams) -> Result<String, RpcError> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(MINT_TIMEOUT)
        .user_agent(concat!("acpmux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| RpcError::internal(format!("no HTTP client: {e}")))?;
    let body = json!({"team": lent.team, "repo": r.repo, "permissions": permissions(r.action),
        "label": LABEL});
    let res = client
        .post(format!("{}/v1/integrations/github/token", lent.origin))
        .bearer_auth(&lent.bearer)
        .json(&body)
        .send()
        .await
        .map_err(|e| {
            tracing::warn!("github app token: cmux Cloud did not answer: {}", e.without_url());
            app_error("unreachable")
        })?;
    let ok = res.status().is_success();
    let answer = bounded_json(res).await;
    if !ok {
        let code = answer.pointer("/error/code").and_then(Value::as_str);
        return Err(app_error(code.unwrap_or("unknown")));
    }
    let token = answer.get("token").and_then(Value::as_str).unwrap_or("");
    let repo = answer.get("repo").and_then(Value::as_str).unwrap_or("");
    let installation = token.starts_with("ghs_")
        && token.len() <= 255
        && token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_');
    if !installation
        || !repo.eq_ignore_ascii_case(&r.repo)
        || !within(answer.get("permissions"), &permissions(r.action))
    {
        return Err(app_error("invalid_reply"));
    }
    Ok(token.to_owned())
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

    /// Review of the App token at 15a905b: a token minted with a sign-in that was then cleared,
    /// replaced or expired was still used.
    #[test]
    fn a_token_minted_with_a_sign_in_that_changed_is_unused() {
        let lease = AppLease::default();
        let lend = |seq: u64| {
            json!({"seq": seq, "origin": "https://cloud-api.cmux.dev", "bearer": format!("b{seq}"),
                "team": "team_0", "expiresAtMs": u64::MAX})
        };
        lease.set(&lend(2)).unwrap();
        let minted = Source::App("ghs_t".into(), 2);
        assert!(while_lent(&minted, Some(&lease), || Ok(())).is_ok());
        assert!(while_lent(&Source::Keyring, None, || Ok(())).is_ok());
        lease.set(&lend(3)).unwrap();
        let e = while_lent(&minted, Some(&lease), || Ok(())).unwrap_err();
        assert_eq!(e.data.unwrap()["code"], "lease_changed", "a team switch while it was minted");
        let minted = Source::App("ghs_t".into(), 3);
        lease.set(&json!({"seq": 4, "clear": true})).unwrap();
        assert!(
            while_lent(&minted, Some(&lease), || Ok(())).is_err(),
            "a sign-out while it was minted"
        );
    }

    /// Review of the App token at e318f53: the sign-in was checked and let go before `gh`
    /// started, so a sign-out between the two still let it start.
    #[test]
    fn no_sign_out_lands_between_the_check_and_the_start() {
        let lease = std::sync::Arc::new(AppLease::default());
        lease
            .set(&json!({"seq": 2, "origin": "https://cloud-api.cmux.dev", "bearer": "b",
                "team": "team_0", "expiresAtMs": u64::MAX}))
            .unwrap();
        let minted = Source::App("ghs_t".into(), 2);
        let mut sign_out = None;
        let landed = while_lent(&minted, Some(&*lease), || {
            let l = lease.clone();
            let t = std::thread::spawn(move || l.set(&json!({"seq": 3, "clear": true})).unwrap());
            std::thread::sleep(Duration::from_millis(200));
            let landed = t.is_finished();
            sign_out = Some(t);
            Ok(landed)
        });
        assert!(!landed.unwrap(), "the sign-out waits until gh has started");
        sign_out.unwrap().join().unwrap();
        assert!(while_lent(&minted, Some(&*lease), || Ok(())).is_err(), "and then holds");
    }

    /// Review of the App token at a57885c: Cloud's own words went on to the machine.
    #[test]
    fn cloud_errors_go_on_in_fixed_words_only() {
        let e = app_error("needs_reauth");
        assert_eq!(
            (e.code, e.data.as_ref().unwrap()["reason"].clone()),
            (-32044, json!("github.not_connected"))
        );
        // Review at d3f3103: a code shaped like the API's own (a token name) went on.
        for odd in ["ghs_secret0123 Bearer x", "ghs_minted0123", "some.other_code"] {
            let e = app_error(odd);
            assert_eq!(e.data.as_ref().unwrap()["code"], "unknown", "{odd}");
            assert!(!e.data.as_ref().unwrap().to_string().contains("ghs_"));
        }
        let odd = app_error("ghs_minted0123");
        assert!(!odd.message.contains("ghs_") && !odd.data.unwrap().to_string().contains("ghs_"));
    }

    /// Review of the App token at 1f49357: a token broader than asked was used, and a comment
    /// asked for pull-request write.
    #[test]
    fn a_token_with_more_than_its_action_asked_is_refused() {
        let asked = permissions(GithubAction::Comment);
        assert_eq!(asked["pull_requests"], "read", "a comment edits no pull request");
        let ok = json!({"metadata": "read", "issues": "write"});
        assert!(within(Some(&ok), &asked));
        for broad in [
            json!({"metadata": "read", "issues": "write", "contents": "write"}),
            json!({"metadata": "read", "pull_requests": "write"}),
            json!({"issues": "admin"}),
            json!({}),
            json!("all"),
        ] {
            assert!(!within(Some(&broad), &asked), "{broad}");
        }
        assert!(!within(None, &asked));
    }

    #[test]
    fn each_action_asks_the_app_for_its_own_permissions_only() {
        assert_eq!(permissions(GithubAction::Read)["issues"], Value::Null);
        assert_eq!(permissions(GithubAction::Issue)["issues"], "write");
        assert_eq!(permissions(GithubAction::DraftPr)["contents"], "read");
        for a in
            [GithubAction::Read, GithubAction::Issue, GithubAction::Comment, GithubAction::DraftPr]
        {
            let p = permissions(a);
            assert!(p.get("workflows").is_none() && p.get("actions").is_none(), "{p}");
            assert_ne!(p.get("contents").and_then(Value::as_str), Some("write"), "{p}");
        }
    }
}
