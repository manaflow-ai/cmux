//! Where a chat is placed, as a person picks it from the place menu: `PlaceMode`, what a move
//! would leave behind (`left_behind`), and the state a pick lands in (`plan`). Pure: the
//! daemon's glue (`server/place_set.rs`) gathers the inputs and does the moving.
//!
//! The pick is the chat's pin, kept in its metadata so it moves with it
//! (`SessionMeta::place_mode`). A chat with no pin reads as `place_pin::effective` says: pinned
//! to the machine it is on until this machine's one-time migration pinned every older chat
//! there, Auto after it (a chat created since), so nothing moves unasked when this ships.
//! `Auto` is only stored here: its later move to Cloud (lid closed, offline, overloaded) is not
//! built yet and never goes back on its own. `Cloud` moves the chat to a fresh Cloud machine,
//! started for it through the `cmux` CLI's own machine start ([`cloud_new_words`]).

use crate::place_mode::PlaceMode;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// `place` as a request carries it (`PlaceMode`'s wire shape, `place_mode.rs`).
pub fn parse(place: &Value) -> Result<PlaceMode, String> {
    PlaceMode::from_params(place)
}

/// What the chat's move line names: `Cloud`, `Auto` or the machine.
pub fn label(mode: &PlaceMode) -> String {
    match mode {
        PlaceMode::Auto => "Auto".into(),
        PlaceMode::Cloud => "Cloud".into(),
        PlaceMode::Machine { id } => id.clone(),
    }
}

/// What a move leaves on this machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum LeftKind {
    LocalhostServer,
    OutsideRepo,
    SshTunnel,
}

/// One thing that does not come along, and what it is.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct LeftBehind {
    pub kind: LeftKind,
    pub detail: String,
}

/// A process of the chat's tree, from a source that knows which processes a chat owns.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    pub command: String,
}

/// A TCP listener on this machine and the process holding it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Listener {
    pub pid: u32,
    pub port: u16,
}

/// What `left_behind` reads. Every field is read off this machine now; a field whose source is
/// not available is empty and its kind reports nothing (no fake answer).
pub struct Inputs<'a> {
    pub cwd: &'a Path,
    /// The chat's folder is inside a git work tree.
    pub in_repo: bool,
    /// The chat's agent process: its descendants are the chat's.
    pub root: Option<u32>,
    pub procs: &'a [Proc],
    pub listeners: &'a [Listener],
    /// Files the chat touched outside its repo. Nothing records these yet, so callers pass none.
    pub outside: &'a [PathBuf],
}

/// Everything under `root` in `procs`, not `root` itself.
pub fn descendants(procs: &[Proc], root: u32) -> BTreeSet<u32> {
    let mut found = BTreeSet::new();
    let mut frontier = vec![root];
    while let Some(pid) = frontier.pop() {
        for p in procs.iter().filter(|p| p.ppid == pid && p.pid != root) {
            if found.insert(p.pid) {
                frontier.push(p.pid);
            }
        }
    }
    found
}

/// `-L 8080:host:80` and the like in an `ssh` command line; the forward as typed.
pub fn ssh_tunnel(command: &str) -> Option<String> {
    let mut tokens = command.split_whitespace();
    let program = tokens.next()?.rsplit('/').next()?;
    if program != "ssh" {
        return None;
    }
    let rest: Vec<&str> = tokens.collect();
    for (i, t) in rest.iter().enumerate() {
        for flag in ["-L", "-R", "-D"] {
            if *t == flag
                && let Some(spec) = rest.get(i + 1)
            {
                return Some(format!("{flag} {spec}"));
            }
            if let Some(spec) = t.strip_prefix(flag)
                && !spec.is_empty()
            {
                return Some(format!("{flag} {spec}"));
            }
        }
    }
    None
}

/// What would not come along with the chat. Empty when nothing is known to stay.
pub fn left_behind(i: &Inputs) -> Vec<LeftBehind> {
    let mut out = Vec::new();
    let tree = i.root.map(|r| descendants(i.procs, r)).unwrap_or_default();
    let mut ports: Vec<u16> =
        i.listeners.iter().filter(|l| tree.contains(&l.pid)).map(|l| l.port).collect();
    ports.sort_unstable();
    ports.dedup();
    for port in ports {
        out.push(LeftBehind {
            kind: LeftKind::LocalhostServer,
            detail: format!("a server listening on localhost:{port}"),
        });
    }
    for p in i.procs.iter().filter(|p| tree.contains(&p.pid)) {
        if let Some(forward) = ssh_tunnel(&p.command) {
            out.push(LeftBehind {
                kind: LeftKind::SshTunnel,
                detail: format!("an ssh tunnel ({forward})"),
            });
        }
    }
    if !i.in_repo {
        out.push(LeftBehind {
            kind: LeftKind::OutsideRepo,
            detail: format!(
                "{} is not in a git repository: only the folder's files are copied, and what \
                 else the chat uses on this machine stays",
                i.cwd.display()
            ),
        });
    }
    for path in i.outside {
        out.push(LeftBehind {
            kind: LeftKind::OutsideRepo,
            detail: format!("{} is outside the repository", path.display()),
        });
    }
    out
}

/// Where a pick lands.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    /// Stored; the chat stays where it is.
    Pinned,
    /// The move runs now (for Cloud: its fresh machine starts now, and the chat moves once it is
    /// up and the chat is between turns).
    Moving,
    /// The chat is mid-turn: it moves when the turn ends.
    AfterTurn,
    /// Something stays behind and the pick was not confirmed: nothing moved.
    NeedsConfirm,
    /// Nothing was stored or moved; `Plan::reason` says why.
    Refused,
}

/// Where a move goes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Target {
    /// One of the person's machines, by its id.
    Machine(String),
    /// A fresh Cloud machine, started for this chat ([`cloud_new_words`]).
    NewCloud,
}

impl Target {
    /// What the move line and a failure name: the machine, or `Cloud`.
    pub fn label(&self) -> &str {
        match self {
            Self::Machine(id) => id,
            Self::NewCloud => "Cloud",
        }
    }
}

/// What to do with a pick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub state: State,
    /// Where to move, for `Moving` and `AfterTurn`.
    pub move_to: Option<Target>,
    /// Whether the pick is stored as the chat's pin.
    pub store: bool,
    pub reason: Option<String>,
}

/// Whether a pick of `want` for a chat on `here` would move it, so what stays behind is read
/// first. `on_cloud`: this daemon runs on a Cloud machine, where Cloud only already holds.
pub fn needs_left(want: &PlaceMode, here: &str, on_cloud: bool) -> bool {
    match want {
        PlaceMode::Machine { id } => id != here,
        PlaceMode::Cloud => !on_cloud,
        PlaceMode::Auto => false,
    }
}

/// The state `want` lands in for a chat on `here` (`on_cloud`: here is a Cloud machine). `left`
/// is read only when a move would run ([`needs_left`]).
pub fn plan(
    want: &PlaceMode,
    here: &str,
    on_cloud: bool,
    running: bool,
    left: &[LeftBehind],
    confirm: bool,
) -> Plan {
    let done = |state, store, move_to: Option<Target>| Plan { state, move_to, store, reason: None };
    let target = match want {
        PlaceMode::Auto => return done(State::Pinned, true, None),
        // Already on a Cloud machine: Cloud only holds, and is kept as the pin.
        PlaceMode::Cloud if on_cloud => return done(State::Pinned, true, None),
        PlaceMode::Cloud => Target::NewCloud,
        PlaceMode::Machine { id } if id == here => return done(State::Pinned, true, None),
        PlaceMode::Machine { id } => Target::Machine(id.clone()),
    };
    if !left.is_empty() && !confirm {
        return done(State::NeedsConfirm, false, None);
    }
    let state = if running { State::AfterTurn } else { State::Moving };
    done(state, false, Some(target))
}

/// The fresh machine of a Cloud move: `cmux vm new --wait`, the create and wait a hybrid start's
/// driver runs (cmux-tui `cli/vm_ready.rs` `new_and_wait`, `cli/chat_start/hybrid_start.rs`
/// `ready_machine`). The app's sign-in carries it; acpmux reads no credential.
pub fn cloud_new_words() -> Vec<String> {
    ["vm", "new", "--wait", "--json"].map(str::to_owned).to_vec()
}

/// The move onto that machine: the app's Move to Cloud as the hybrid driver runs it
/// (`hybrid_start.rs` `move_words`): the folder copied, the chat moved with its history, and
/// shown there. No `--interrupt`: it runs between turns.
pub fn cloud_move_words(session: &str, machine: &str) -> Vec<String> {
    ["move", session, "--to", &format!("vm:{machine}"), "--json"].map(str::to_owned).to_vec()
}

/// The pause of a fresh machine the chat did not move to (`hybrid_start.rs` `pause_words`), so
/// none is left running with no chat on it.
pub fn cloud_pause_words(machine: &str) -> Vec<String> {
    ["cloud", "pause-machine", "--target", &format!("machine:{machine}"), "--json"]
        .map(str::to_owned)
        .to_vec()
}

/// The last JSON object in `text` (a `--json` step prints one, maybe after other lines).
fn json_of(text: &str) -> Option<Value> {
    let text = text.trim();
    serde_json::from_str::<Value>(text).ok().filter(Value::is_object).or_else(|| {
        text.lines().rev().find_map(|line| {
            serde_json::from_str::<Value>(line.trim()).ok().filter(Value::is_object)
        })
    })
}

/// A `cmux --json` step's answer, read as the Cloud start reads one (cmux-tui
/// `cloud_start_chat.rs` `step_result`): its `result` (or the whole object) when it exited 0,
/// else its error's message, else its last line.
pub fn step_answer(ok: bool, stdout: &str, stderr: &str) -> Result<Value, String> {
    if ok && let Some(value) = json_of(stdout) {
        return Ok(value.get("result").cloned().unwrap_or(value));
    }
    let error = json_of(stderr).or_else(|| json_of(stdout));
    let message = error.as_ref().and_then(|e| {
        e.pointer("/error/message").or_else(|| e.get("message")).and_then(Value::as_str)
    });
    if let Some(message) = message {
        return Err(message.to_owned());
    }
    let text = if stderr.trim().is_empty() { stdout } else { stderr };
    Err(text
        .lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .map_or_else(|| "it failed and said nothing".to_owned(), |l| l.trim().to_owned()))
}

/// The machine `cmux vm new --wait` made: its answer's `machine_id`.
pub fn machine_of(answer: &Value) -> Result<String, String> {
    answer
        .get("machine_id")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| "the fresh machine's answer names no machine_id".to_owned())
}

/// The line a move writes in the chat: `Moved to Cloud · Mac went to sleep`.
pub fn move_line(to: &str, why: &str) -> String {
    format!("Moved to {to} · {why}")
}

#[cfg(test)]
#[path = "place_move_tests.rs"]
mod tests;
