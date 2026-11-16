//! The Cloud flows' waits and start rules: how long a start waits on a machine's link and how it
//! spaces its redials, what counts as the wait being done, which failure is a link dropping under
//! a start, how long a `cmux cloud start-session` run's end is kept, when a machine list still
//! answers, and the start's request and words. The app observes its main-actor state and asks
//! here what that state means; the observation itself stays the app's.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// The waits' deadlines, in milliseconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Deadlines {
    /// A start's redials: the first delay, growing to `start_redial_maximum_ms`, so a new
    /// machine's receiver that answers half a minute after its record runs is dialed again
    /// within seconds.
    pub start_redial_initial_ms: u64,
    pub start_redial_maximum_ms: u64,
    /// How long, after a machine update restarts its daemon, a start or a copy waits for the new
    /// link (its handshake key to change).
    pub relink_ms: u64,
    /// How long a machine's workspace read waits for this connection's first tree.
    pub workspace_tree_ms: u64,
    /// How long a `cmux cloud start-session` run's end is kept for the next same ask.
    pub run_kept_ms: u64,
    /// How many ended runs are kept at most.
    pub runs_kept: usize,
}

pub const DEADLINES: Deadlines = Deadlines {
    start_redial_initial_ms: 1_000,
    start_redial_maximum_ms: 10_000,
    relink_ms: 90_000,
    workspace_tree_ms: 10_000,
    run_kept_ms: 600_000,
    runs_kept: 32,
};

/// One look at a link a start waits on (the app's `CloudWait.linkFailure`).
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LinkLook {
    pub connected: bool,
    /// A failure shows now.
    pub failed: bool,
    /// No failure showed since the wait began, or it cleared: a failure showing now is this connect's.
    pub cleared: bool,
}

/// Whether the wait is done after `look`, and whether a failure has cleared since it began. A
/// failure already showing when the wait begins is the last link's: it ends the wait only once
/// the new connect cleared it and failed again, or at the deadline.
pub fn link_look(look: LinkLook) -> (bool, bool) {
    if look.connected {
        return (true, look.cleared);
    }
    if !look.failed {
        return (false, true);
    }
    (look.cleared, look.cleared)
}

/// How many times one start's link wait connects an ended link again. The wait's beats are 1 s
/// growing to 10 s over its 180 s, so this covers a daemon restart of a minute or more; a link
/// the server refuses every time (a revoke) costs at most this many refused connects.
pub const START_REDIALS: u32 = 12;

/// One beat of a start's link wait (the app's `CloudMachineSession.linkUp`).
#[derive(Clone, Copy, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct RedialLook {
    /// The app link ended (its failure shows) and no connect runs.
    pub ended: bool,
    /// The machine's record reads running.
    pub running: bool,
    /// The machine's record reads paused.
    pub paused: bool,
    /// This wait resumed the machine already.
    pub resumed: bool,
    /// This wait's connects of an ended link so far.
    pub redials: u32,
}

/// What a start's link wait does on one beat.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Redial {
    Nothing,
    /// Resume the paused machine (once per wait: a start that settles back to paused is the
    /// platform's answer).
    Resume,
    /// Connect the ended link again.
    Connect,
}

/// What a start's link wait does on one beat. A running machine's link that ended is connected
/// again, up to [`START_REDIALS`] times: a new machine's updater restarts its services seconds
/// after the machine comes up, which ends the first connect's handshake ("daemon no longer has
/// the requested logical session"), and with no redial the start waited out its 180 s and said
/// the machine didn't connect (staging app-chat probe, 2026-11-08 14:36Z, run 42490252327). The
/// carrier cut (#37210) deleted the redial #32469 had added.
pub fn start_redial(look: RedialLook) -> Redial {
    if look.paused {
        return if look.resumed { Redial::Nothing } else { Redial::Resume };
    }
    if look.ended && look.running && look.redials < START_REDIALS {
        return Redial::Connect;
    }
    Redial::Nothing
}

/// Whether a machine's link came back after an update restarted its daemon: its handshake key is
/// there and differs from the one before (`refused`, a refused handshake, is no new link).
pub fn relinked(before: Option<&str>, now: Option<&str>, refused_counts: bool) -> bool {
    now.is_some_and(|now| Some(now) != before && (refused_counts || now != "refused"))
}

/// The Darwin errno of a socket file that is gone, and of a refused connect (the app's).
pub const ENOENT: i32 = 2;
pub const ECONNREFUSED: i32 = 61;

/// A start's failure, as the app's daemon client named it.
#[derive(Clone, Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StartFailure {
    ConnectionClosed,
    ConnectFailed { code: i32 },
    Other,
}

/// Whether a start's failure is its link dropping under it, which a relink and one more try can
/// help: the connection closed (an EOF right after a resume), or the link socket was gone or
/// refused while its carrier rebound it (start matrix run 42125025387).
pub fn link_dropped(failure: &StartFailure) -> bool {
    match failure {
        StartFailure::ConnectionClosed => true,
        StartFailure::ConnectFailed { code } => *code == ENOENT || *code == ECONNREFUSED,
        StartFailure::Other => false,
    }
}

/// The CLIs' error code for a daemon too old for the verb.
pub const OUTDATED: &str = "machine_outdated";

/// Whether an answer is the machine's older daemon refusing it: `machine_outdated` about the
/// machine, never this Mac's own daemon (`side` `source`). A chat start's copy refused that way
/// updates the machine and copies once more, on its new link.
pub fn updates_before_copying_again(
    ok: bool,
    error_code: Option<&str>,
    side: Option<&str>,
) -> bool {
    !ok && error_code == Some(OUTDATED) && side != Some("source")
}

/// A kept run's end is handed to the next same ask while it is at most this old.
pub fn run_reusable(age_ms: u64) -> bool {
    age_ms <= DEADLINES.run_kept_ms
}

/// One ended run kept for the next same ask, by the app's id for it.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct KeptRun {
    pub id: u64,
    pub age_ms: u64,
}

/// The kept runs to drop: the expired ones, then the oldest beyond `keeping`.
pub fn runs_to_drop(kept: &[KeptRun], keeping: usize) -> Vec<u64> {
    let (expired, mut live): (Vec<&KeptRun>, Vec<&KeptRun>) =
        kept.iter().partition(|run| run.age_ms >= DEADLINES.run_kept_ms);
    // Oldest first: the largest age.
    live.sort_by(|a, b| b.age_ms.cmp(&a.age_ms).then(a.id.cmp(&b.id)));
    let over = live.len().saturating_sub(keeping);
    expired.iter().chain(live.iter().take(over)).map(|run| run.id).collect()
}

/// Whether a loaded Cloud machine list still answers for `account`: loaded for it, less than
/// `within_ms` ago.
pub fn list_current(
    loaded_ago_ms: Option<u64>,
    loaded_for: Option<&[Option<String>]>,
    account: &[Option<String>],
    within_ms: u64,
) -> bool {
    loaded_ago_ms.is_some_and(|ago| ago < within_ms) && loaded_for == Some(account)
}

/// Whether a Cloud start that is not an agent chat's (a terminal's or a script's `cmux cloud
/// start-session`) starts as the person's Start would: their gesture, or any run while they let
/// agents start Cloud sessions without asking (`cloud.agentsStartWithoutAsking`), since an agent
/// in a terminal looks like the person there. Leo, 2026-11-04: "it had this prompt idk if we want that".
pub fn starts_as_person(by_person: bool, delegated: bool) -> bool {
    by_person || !crate::ask::agent_asks_first(delegated)
}

/// A personal send (the account's team none) on a non-production sign-in copies through the
/// content-addressed store.
pub fn copies_through_store(account: &[Option<String>], production_auth: bool) -> bool {
    account.last().is_none_or(Option::is_none) && !production_auth
}

/// `text` as one shell word: as it is when it is a plain name, else in single quotes.
pub fn shell_quoted(text: &str) -> String {
    let plain = |c: char| c.is_ascii_alphanumeric() || "._-".contains(c);
    if !text.is_empty() && text.chars().all(plain) {
        return text.to_owned();
    }
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// The facts of a `cloud.startChat` send's plan request (`cmux link start-chat plan --request`).
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PlanFacts {
    pub key: String,
    pub account: Vec<Option<String>>,
    pub workspace: Option<String>,
    pub user: Option<String>,
    /// The machines the account's list named, as the pick reads them.
    pub machines: Vec<Value>,
    pub local: Option<String>,
    /// The store's others: kept for a pin, never picked.
    pub stored: Vec<String>,
    pub environment: Option<String>,
    /// The cmux access token goes on stdin.
    pub access: bool,
    pub reservation_key: Option<String>,
    pub platform: Option<String>,
    pub team: Option<String>,
    pub ensure_project: Option<bool>,
}

/// The plan's request: the send's key, account and Mac workspace, who is signed in, the machines,
/// the store's others, and the chat's folder, environment and token flag.
pub fn plan_request(facts: &PlanFacts) -> String {
    let mut request = Map::new();
    request.insert("key".into(), Value::String(facts.key.clone()));
    request.insert("account".into(), Value::String(crate::start::account_text(&facts.account)));
    request.insert("loaded".into(), Value::Bool(true));
    request.insert("machines".into(), Value::Array(facts.machines.clone()));
    request.insert("stored".into(), facts.stored.iter().cloned().map(Value::String).collect());
    request.insert("credential_on_stdin".into(), Value::Bool(facts.access));
    for (name, value) in [
        ("user", &facts.user),
        ("workspace", &facts.workspace),
        ("local", &facts.local),
        ("environment", &facts.environment),
        ("reservation_key", &facts.reservation_key),
        ("platform", &facts.platform),
        ("team", &facts.team),
    ] {
        if let Some(value) = value {
            request.insert(name.into(), Value::String(value.clone()));
        }
    }
    if let Some(ensure) = facts.ensure_project {
        request.insert("ensure_project".into(), Value::Bool(ensure));
    }
    Value::Object(request).to_string()
}

#[cfg(test)]
mod tests;
