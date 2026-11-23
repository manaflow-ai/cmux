//! `cmux github` on a machine joined to a cmux hub (`acpmux machine join`) that is not a cmux
//! Cloud machine: no Cloud agent socket, so the ask goes to the hub itself. Leo, 2026-11-23:
//! setup "needs to be like automatically doable/setupabble for any non-me users too. like [it]
//! just works." (hq RFD 0053, cmuxterm-hq#19720: no login on any machine.)
//!
//! The machine proves itself with the `cmm_` credential it made at its join:
//! `POST <hub origin>/v1/machines/github/token` with `Authorization: Bearer cmm_...` and the
//! ask's `{repo, permissions, label?}` (never a team: the hub knows the machine's). The hub's
//! answer has the Cloud API's token shape (`{token, expires_at, repo, permissions, token_id}`, or
//! `{error: {code, message, configure_url?, reason?}}`), so it is read by the same rules the
//! Cloud agent reads its API's answer with (`cloud::github::reply_for`) and then as the agent's
//! reply line (`github_cli::minted_from_reply`): git and gh see the same output either way.
//!
//! Which machine is joined, its hub origin and its credential are acpmux's to say
//! (`acpmux::joined_model_plane::github_machine`: `machine-credential.json` in acpmux's home,
//! its `hub_origin` and `credential`, refused when revoked, copied from another box, for another
//! hub or not `cmm_`). acpmux depends on this crate, not the reverse, so the binary that has both
//! installs that reader here once ([`set_joined_source`]); with none installed, or no join, an
//! ask with no agent socket keeps its `vm.agent_unreachable`.
//!
//! The credential and the token live in this process only: never written, never logged.

use std::sync::OnceLock;

use serde_json::Value;
use zeroize::Zeroizing;

use crate::cloud::github::{TokenAsk, reply_for};
use crate::cloud::sender::Answer;
use crate::github_cli::{Minted, Refused, minted_from_reply};

/// The hub's route for a joined machine's GitHub token (cmux-platform).
pub const MACHINE_TOKEN_PATH: &str = "/v1/machines/github/token";

/// This machine's join, as the hub route needs it: the hub's `https://` origin (no trailing
/// slash) and the machine's `cmm_` credential (Debug redacts it).
pub struct JoinedMachine {
    pub hub_origin: String,
    pub credential: Zeroizing<String>,
}

impl std::fmt::Debug for JoinedMachine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "JoinedMachine({}, <redacted {} bytes>)", self.hub_origin, self.credential.len())
    }
}

/// Reads this machine's join now; None when it is not joined (or the join is unusable).
pub type JoinedSource = fn() -> Option<JoinedMachine>;

static SOURCE: OnceLock<JoinedSource> = OnceLock::new();

/// Installs the join reader (once per process; a later call keeps the first).
pub fn set_joined_source(source: JoinedSource) {
    let _ = SOURCE.set(source);
}

/// This machine's join by the installed reader; None with no reader or no join.
pub fn joined_now() -> Option<JoinedMachine> {
    SOURCE.get().and_then(|source| source())
}

/// One JSON POST of `body` to `url` with `Authorization: Bearer <bearer>`: `(status, body)` or a
/// transport error (`JsonPoster::post`'s shape).
pub type Post<'a> = dyn Fn(&str, &Value, &str) -> Result<(u16, Value), String> + 'a;

/// The production POST: HTTPS only, bounded to 20 s and 1 MiB (`cloud_http::JsonPoster`).
pub fn https_post(url: &str, body: &Value, bearer: &str) -> Result<(u16, Value), String> {
    cmux_server::cloud_http::JsonPoster::new()?.post(url, body, Some(bearer))
}

/// One ask to the hub `machine` joined, answered as the Cloud agent answers it.
pub fn ask_hub(
    machine: &JoinedMachine,
    ask: &TokenAsk,
    post: &Post<'_>,
) -> Result<Minted, Refused> {
    let url = format!("{}{MACHINE_TOKEN_PATH}", machine.hub_origin.trim_end_matches('/'));
    // The body is the ask itself, never a team: the hub knows the machine's.
    let body = serde_json::from_str::<Value>(&ask.to_line())
        .ok()
        .and_then(|mut line| line.get_mut(crate::cloud::github::REQUEST_KEY).map(Value::take))
        .unwrap_or_default();
    let answer = match post(&url, &body, machine.credential.as_str()) {
        Ok((status, body)) => Answer::Http { status, body },
        Err(_) => Answer::Transport,
    };
    let status = match &answer {
        Answer::Http { status, .. } => Some(*status),
        Answer::Transport => None,
    };
    minted_from_reply(&reply_for(ask, &answer)).map_err(|mut e| {
        if let Some(why) = status.and_then(|s| hub_note(s, &machine.hub_origin)) {
            e.message = if e.message.is_empty() { why } else { format!("{} ({why})", e.message) };
        }
        e
    })
}

/// What a joined machine's refusal means beyond the hub's own words: a refused credential
/// (revoked, or unknown to that hub) and a hub with no such route.
fn hub_note(status: u16, origin: &str) -> Option<String> {
    match status {
        401 => Some(format!(
            "{origin} refused this machine's join credential (revoked or unknown); join this \
             machine again with a new join line"
        )),
        404 => Some(format!("{origin} does not serve GitHub tokens to joined machines yet")),
        _ => None,
    }
}

#[cfg(test)]
#[path = "github_cli_joined_tests.rs"]
mod tests;
