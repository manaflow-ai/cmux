//! Where a chat is placed, as a person picks it from the place menu: `PlaceMode`, what a move
//! would leave behind (`left_behind`), and the state a pick lands in (`plan`). Pure: the
//! daemon's glue (`server/place_set.rs`) gathers the inputs and does the moving.
//!
//! The pick is the chat's pin, kept in its metadata so it moves with it
//! (`SessionMeta::place_mode`). A chat with no pin reads as `place_pin::effective` says: pinned
//! to the machine it is on until this machine's one-time migration pinned every older chat
//! there, Auto after it (a chat created since), so nothing moves unasked when this ships.
//! `Auto` is only stored here: its later move to Cloud (lid closed, offline, overloaded) is not
//! built yet and never goes back on its own.

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
    /// The move runs now.
    Moving,
    /// The chat is mid-turn: it moves when the turn ends.
    AfterTurn,
    /// Something stays behind and the pick was not confirmed: nothing moved.
    NeedsConfirm,
    /// Nothing was stored or moved; `Plan::reason` says why.
    Refused,
}

/// What to do with a pick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub state: State,
    /// The machine to move to, for `Moving` and `AfterTurn`.
    pub move_to: Option<String>,
    /// Whether the pick is stored as the chat's pin.
    pub store: bool,
    pub reason: Option<String>,
}

/// Why Cloud only is refused today: a fresh VM is made by the app, not reachable from acpmux.
pub const CLOUD_UNREACHABLE: &str = "Cloud only needs a fresh cloud machine, which only the app \
can start today; pick a machine, or start the cloud move from the app";

/// The state `want` lands in for a chat on `here`. `left` is read only when a move would run
/// (`needs_left`).
pub fn needs_left(want: &PlaceMode, here: &str) -> bool {
    matches!(want, PlaceMode::Machine { id } if id != here)
}

pub fn plan(
    want: &PlaceMode,
    here: &str,
    running: bool,
    left: &[LeftBehind],
    confirm: bool,
) -> Plan {
    let done = |state, store, move_to: Option<String>, reason: Option<String>| Plan {
        state,
        move_to,
        store,
        reason,
    };
    match want {
        PlaceMode::Auto => done(State::Pinned, true, None, None),
        PlaceMode::Cloud => done(State::Refused, false, None, Some(CLOUD_UNREACHABLE.to_owned())),
        PlaceMode::Machine { id } if id == here => done(State::Pinned, true, None, None),
        PlaceMode::Machine { .. } if !left.is_empty() && !confirm => {
            done(State::NeedsConfirm, false, None, None)
        }
        PlaceMode::Machine { id } => {
            let state = if running { State::AfterTurn } else { State::Moving };
            done(state, false, Some(id.clone()), None)
        }
    }
}

/// The line a move writes in the chat: `Moved to Cloud · Mac went to sleep`.
pub fn move_line(to: &str, why: &str) -> String {
    format!("Moved to {to} · {why}")
}

#[cfg(test)]
#[path = "place_move_tests.rs"]
mod tests;
