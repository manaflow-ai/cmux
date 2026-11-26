//! The native runner passes facts and choices; Rust plans the existing session move and
//! reads its result. Added-machine enumeration and placement stay in acpmux.

use super::{Chat, LOCAL, Peer, Source, action, normalized, peer_of, targets};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// One Move to… an SSH machine (or back here from one), as the app asks it.
#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SshMove {
    pub chat: Chat,
    /// An existing menu id, a canonical acpmux peer name, or `auto`.
    #[serde(default)]
    pub target: Option<String>,
    #[serde(default)]
    pub peers: Vec<Peer>,
    #[serde(default)]
    pub after_turn: bool,
    #[serde(default)]
    pub interrupt: bool,
    #[serde(default)]
    pub carry_changes: bool,
    #[serde(default)]
    pub leave_dirty: bool,
    #[serde(default)]
    pub dry_run: bool,
}

/// What the app runs for an [`SshMove`].
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshMoveCall {
    pub args: Vec<String>,
    /// Compatibility route for a named destination on older daemons. Auto has none; its
    /// actual host and session id must come from the result, never `auto/ID`.
    pub moved: String,
    /// Canonical peer name, `auto`, or `local`; the native view needs this only to open a
    /// successful local move without a host prefix.
    pub destination: String,
    pub source: Option<String>,
}

/// The existing `acpmux session move` command. Explicit choices pass through unchanged;
/// no UI layer duplicates the move's turn, checkout, or placement rules.
pub fn ssh_move(request: &SshMove) -> Result<SshMoveCall, &'static str> {
    if (request.after_turn && request.interrupt) || (request.carry_changes && request.leave_dirty) {
        return Err("conflicting_options");
    }
    let chat = &request.chat;
    if !chat.started || chat.chief || chat.running.is_some() {
        return Err("not_offered");
    }
    let peer =
        |id: &str| chat.ssh.iter().find(|m| m.id == id).and_then(|m| peer_of(m, &request.peers));
    let named_peer = |name: &str| {
        request
            .peers
            .iter()
            .find(|p| p.url.starts_with("ssh://") && normalized(&p.name) == normalized(name))
            .map(|p| p.name.as_str())
    };
    let from = match chat.source() {
        None if chat.elsewhere => return Err("not_offered"),
        None => None,
        Some(Source::Peer(name)) => Some(named_peer(name).ok_or("unknown_peer")?),
        Some(Source::Machine(id)) => Some(peer(id).ok_or("unknown_peer")?),
    };
    let offered = targets(chat);
    let wanted = request.target.as_deref();
    let to = if wanted == Some("auto") {
        "auto"
    } else if let Some(target) = match wanted {
        Some(id) => offered.iter().find(|t| t.id == id && t.action == action::SSH_MOVE),
        None => offered.iter().find(|t| t.kind == "ssh"),
    } {
        if target.kind == "local" { LOCAL } else { peer(&target.id).ok_or("unknown_peer")? }
    } else {
        // The new menu uses the daemon's canonical peer names. Legacy sidebar ids still
        // take the offered-target path above, including their own online gate.
        let wanted = wanted.ok_or("not_offered")?;
        if chat.ssh.iter().any(|m| m.id == wanted) || chat.machines.iter().any(|m| m.id == wanted) {
            return Err("not_offered");
        }
        named_peer(wanted).ok_or("not_offered")?
    };
    if from.is_some_and(|from| normalized(from) == normalized(to)) {
        return Err("not_offered");
    }
    let session = chat.session.as_deref().filter(|s| !s.is_empty()).ok_or("not_started")?;
    // The peer prefix is only transport routing; the source daemon moves its own id.
    let id = match session.split_once('/') {
        Some((prefix, id)) if from.is_some_and(|from| normalized(prefix) == normalized(from)) => id,
        _ => session,
    };
    if id.is_empty() {
        return Err("not_started");
    }
    let mut args: Vec<String> = ["--json", "session", "move", id, "--machine", to]
        .iter()
        .map(|s| (*s).to_owned())
        .collect();
    if let Some(from) = from {
        args.extend(["--from".to_owned(), from.to_owned()]);
    }
    for (enabled, flag) in [
        (request.after_turn, "--after-turn"),
        (request.interrupt, "--interrupt"),
        (request.carry_changes, "--carry-changes"),
        (request.leave_dirty, "--leave-dirty"),
        (request.dry_run, "--dry-run"),
    ] {
        if enabled {
            args.push(flag.to_owned());
        }
    }
    let moved = match to {
        "auto" => String::new(),
        LOCAL => id.to_owned(),
        _ => format!("{to}/{id}"),
    };
    Ok(SshMoveCall { args, moved, destination: to.to_owned(), source: from.map(str::to_owned) })
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
pub struct Preflight {
    pub running: bool,
    pub dirty: Option<bool>,
}

/// Parsed CLI result, including whether a refusal is the single running/dirty-work question.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SshMoveResult {
    pub moved: bool,
    pub dry_run: bool,
    pub ready: bool,
    pub needs_confirmation: bool,
    pub error: Option<String>,
    pub error_code: Option<String>,
    pub preflight: Option<Preflight>,
    pub host: Option<String>,
    pub target_session_id: Option<String>,
}

fn row(stdout: &str) -> Option<Value> {
    let answer = serde_json::from_str::<Value>(stdout.trim()).ok().or_else(|| {
        stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
    })?;
    answer.get("moves")?.as_array()?.first().cloned()
}

/// Supports pretty JSON and the CLI's one-line error envelope, preserving old error text.
pub fn ssh_move_result(stdout: &str, stderr: &str, status: i32) -> SshMoveResult {
    let row = row(stdout).unwrap_or(Value::Null);
    let text = |key: &str| {
        row.get(key).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_owned)
    };
    let error = text("error");
    let dry_run = row.get("dryRun").and_then(Value::as_bool) == Some(true);
    let moved = status == 0
        && error.is_none()
        && row.get("moved").and_then(Value::as_bool) == Some(true)
        && !dry_run;
    let ready = status == 0 && error.is_none() && dry_run;
    let preflight: Option<Preflight> =
        row.get("preflight").cloned().and_then(|v| serde_json::from_value(v).ok());
    let error_code = text("errorCode");
    let needs_confirmation = !moved
        && !ready
        && match (error_code.as_deref(), preflight.as_ref()) {
            (Some("running_turn"), Some(p)) => p.running && p.dirty.is_some(),
            (Some("dirty_worktree"), Some(p)) => p.dirty == Some(true),
            _ => false,
        };
    SshMoveResult {
        moved,
        dry_run,
        ready,
        needs_confirmation,
        error: if moved || ready {
            None
        } else {
            Some(error.unwrap_or_else(|| stderr_error(stderr)))
        },
        error_code,
        preflight,
        host: text("host"),
        target_session_id: text("targetSessionId"),
    }
}

/// What one move means for the person: the session the tab opens, the one running/dirty-work
/// question, or why it failed. `dry_run` is the request's own flag.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum SshMoveRun {
    Moved { session: String },
    NeedsConfirmation { code: String, dirty: Option<bool> },
    Failed { message: String },
}

/// Reads `result` of the call the app ran (its [`SshMoveCall`] `moved` and `destination`). Auto opens only the host and session the move
/// reported; a local move opens the bare session id; a named one, `host/id`, or the call's route
/// when an older daemon reports no session id.
pub fn ssh_move_run(
    moved_route: &str,
    destination: &str,
    dry_run: bool,
    result: &SshMoveResult,
) -> SshMoveRun {
    if let (true, Some(code)) = (result.needs_confirmation, &result.error_code) {
        let dirty = result.preflight.as_ref().and_then(|p| p.dirty);
        return SshMoveRun::NeedsConfirmation { code: code.clone(), dirty };
    }
    if result.error.is_some() || !(result.moved || (dry_run && result.ready)) {
        return SshMoveRun::Failed { message: result.error.clone().unwrap_or_default() };
    }
    let moved = |session: String| SshMoveRun::Moved { session };
    if dry_run {
        return moved(moved_route.to_owned());
    }
    let host = result.host.as_deref().filter(|h| !h.is_empty());
    let id = result.target_session_id.as_deref().filter(|id| !id.is_empty());
    match (destination, host, id) {
        ("auto", Some(host), Some(id)) => moved(format!("{host}/{id}")),
        ("auto", _, _) => {
            SshMoveRun::Failed { message: "Move did not report its destination.".to_owned() }
        }
        ("local", _, Some(id)) | (_, None, Some(id)) => moved(id.to_owned()),
        (_, Some(host), Some(id)) => moved(format!("{host}/{id}")),
        (_, _, None) => moved(moved_route.to_owned()),
    }
}

fn stderr_error(stderr: &str) -> String {
    let last =
        stderr.lines().rev().map(str::trim).find(|line| !line.is_empty()).unwrap_or_default();
    let envelope = serde_json::from_str::<Value>(last).ok();
    let error = envelope.as_ref().and_then(|e| e.get("error"));
    error
        .and_then(|e| {
            e.get("message")
                .and_then(Value::as_str)
                .or_else(|| e.get("detail").and_then(Value::as_str))
                .or_else(|| e.as_str())
        })
        .unwrap_or_else(|| last.strip_prefix("Error: ").unwrap_or(last))
        .to_owned()
}

#[cfg(test)]
#[path = "ssh_move_tests.rs"]
mod tests;
