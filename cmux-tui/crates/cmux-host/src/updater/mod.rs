//! A Cloud machine keeps its machine software (cmux-tui: the session host,
//! acpmux, the Cloud receiver and `cmux host` itself, plus cmux-tui-hook)
//! on the newest feat-cmux-next build by itself, with no image bake in the
//! way (plans/cmux-next/vm-image.md 4.5). The image is a cache: a machine
//! from a stale image only boots one update later.
//!
//! The `updater` role ([`role`]) checks the signed channel ([`channel`]) 30 s
//! after `cmux host run` starts (a boot, or the restart of an update), on
//! every resume, and every five minutes. When the channel names another
//! build than the current profile links, it:
//!
//! 1. waits until no acpmux session runs a turn or waits on a permission
//!    (checked again right before the flip), never mid-turn;
//! 2. downloads both binaries into the store, each checked against the
//!    signed sha256 and size ([`store::add_entry`]);
//! 3. builds the next profile and flips `/opt/cmux/current` to it with one
//!    rename, after it wrote [`PENDING_FILE`] and armed a guard timer that
//!    runs the previous build's `cmux host update guard` 15 minutes later;
//! 4. restarts what runs the old binary: the work user's `acpmux.service`
//!    (its agents keep running and the new daemon adopts them), other
//!    system services, and last `cmux-host.service` (terminal hosts live in
//!    their own scopes and the new session host adopts them,
//!    docs/cloud-guest-upgrades.md).
//!
//! The new `cmux host run` finds [`PENDING_FILE`] and checks the new build
//! serves: the session host's `identify` and acpmux's `daemon status` both
//! report the channel's commit within five minutes. Then it records the
//! update and disarms the guard; otherwise it flips back and restarts the
//! same services. A build that never starts is rolled back by the guard. A
//! rolled-back build is never tried again; the next one the channel names
//! is. The channel only moves forward (`committed_at`), and a machine never
//! installs a build older than the last one it applied.
//!
//! Off: [`OFF_FILE`] exists (the bake writes it while it runs and removes
//! it before the snapshot; the image smoke writes it on its clones), or the
//! work user's `~/.cmux/bin/cmux-tui` is not the store link (the Mac app's
//! in-place `cmux link machine update` replaced it).
//! `cmux host update status|check|guard` are the operator verbs ([`role::verb`]).

pub mod channel;
#[cfg(target_os = "linux")]
pub mod role;
pub mod store;
#[cfg(all(test, unix))]
mod tests;

use std::fs;
use std::io;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::config::Paths;
use channel::{Binary, CMUX_TUI, CMUX_TUI_HOOK, Payload};

/// While this file exists the machine does not update itself.
pub const OFF_FILE: &str = "/etc/cmux/no-self-update";
pub const STATE_DIR: &str = "/var/lib/cmux/self-update";
pub const STATE_FILE: &str = "/var/lib/cmux/self-update/state.json";
/// An update between its flip and its health check.
pub const PENDING_FILE: &str = "/var/lib/cmux/self-update/pending.json";
pub const DOWNLOAD_DIR: &str = "/var/lib/cmux/self-update/download";
/// The work user's link the session host runs (bake.ts links it into `current`).
pub const WORK_CMUX_TUI_LINK: &str = "/home/cmux/.cmux/bin/cmux-tui";
pub const CURRENT_CMUX_TUI: &str = "/opt/cmux/current/bin/cmux-tui";

/// What the updater keeps between runs.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct State {
    /// The last build this machine applied and kept.
    #[serde(default)]
    pub applied_commit: Option<String>,
    #[serde(default)]
    pub applied_committed_at: u64,
    /// cmux-tui sha256s rolled back here; never installed again.
    #[serde(default)]
    pub rolled_back: Vec<String>,
    /// Store entries updates added (the only ones gc may remove).
    #[serde(default)]
    pub installed: Vec<String>,
    /// The last check's outcome, for `cmux host update status`.
    #[serde(default)]
    pub last: Option<String>,
    #[serde(default)]
    pub last_at: u64,
}

/// An update whose new build has not proved itself yet.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pending {
    pub from: u64,
    pub to: u64,
    pub commit: String,
    pub committed_at: u64,
    pub cmux_tui: String,
    pub cmux_tui_hook: String,
    /// The store entry of the cmux-tui being replaced.
    pub old_cmux_tui: String,
    pub started_at: u64,
}

/// What a check found, before anything changed.
#[derive(Debug, PartialEq, Eq)]
pub enum Decision {
    /// The current profile links the channel's build.
    Current,
    /// The channel's build is older than the last one applied here.
    Older,
    /// The channel's build was rolled back here before.
    RolledBack,
    Update(Box<Plan>),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Plan {
    pub commit: String,
    pub committed_at: u64,
    pub cmux_tui: Binary,
    pub cmux_tui_hook: Binary,
    pub old_cmux_tui: String,
    pub old_cmux_tui_hook: String,
    pub from: u64,
    pub to: u64,
}

impl Plan {
    pub fn pending(&self, now: u64) -> Pending {
        Pending {
            from: self.from,
            to: self.to,
            commit: self.commit.clone(),
            committed_at: self.committed_at,
            cmux_tui: self.cmux_tui.sha256.clone(),
            cmux_tui_hook: self.cmux_tui_hook.sha256.clone(),
            old_cmux_tui: self.old_cmux_tui.clone(),
            started_at: now,
        }
    }

    /// The profile links to move: `(old entry, new entry)`.
    pub fn replacements(&self) -> Vec<(String, String)> {
        let mut out = Vec::new();
        if self.old_cmux_tui != self.cmux_tui.sha256 {
            out.push((self.old_cmux_tui.clone(), self.cmux_tui.sha256.clone()));
        }
        if self.old_cmux_tui_hook != self.cmux_tui_hook.sha256 {
            out.push((self.old_cmux_tui_hook.clone(), self.cmux_tui_hook.sha256.clone()));
        }
        out
    }
}

/// Compares the channel's build for `target` with the current profile.
pub fn decide(
    paths: &Paths,
    state: &State,
    payload: &Payload,
    target: &str,
) -> Result<Decision, String> {
    let (tui, hook) = payload.binaries_for(target)?;
    let from = store::current_generation(paths).map_err(|e| e.to_string())?;
    let old_tui = store::linked_package(paths, from, CMUX_TUI)
        .map_err(|e| format!("current profile: {e}"))?;
    let old_hook = store::linked_package(paths, from, CMUX_TUI_HOOK)
        .map_err(|e| format!("current profile: {e}"))?;
    if old_tui == tui.sha256 && old_hook == hook.sha256 {
        return Ok(Decision::Current);
    }
    if payload.committed_at < state.applied_committed_at {
        return Ok(Decision::Older);
    }
    if state.rolled_back.contains(&tui.sha256) {
        return Ok(Decision::RolledBack);
    }
    let to = store::generations(paths).last().copied().unwrap_or(from).max(from) + 1;
    Ok(Decision::Update(Box::new(Plan {
        commit: payload.commit.clone(),
        committed_at: payload.committed_at,
        cmux_tui: tui.clone(),
        cmux_tui_hook: hook.clone(),
        old_cmux_tui: old_tui,
        old_cmux_tui_hook: old_hook,
        from,
        to,
    })))
}

/// Why the machine does not update itself now, if it does not.
pub fn off_reason(paths: &Paths) -> Option<String> {
    if paths.at(OFF_FILE).exists() {
        return Some(format!("{OFF_FILE} exists"));
    }
    let link = paths.at(WORK_CMUX_TUI_LINK);
    match fs::read_link(&link) {
        Ok(target) if target == Path::new(CURRENT_CMUX_TUI) => None,
        Ok(target) => Some(format!("{WORK_CMUX_TUI_LINK} points at {}", target.display())),
        Err(_) => Some(format!("{WORK_CMUX_TUI_LINK} is not the store link")),
    }
}

pub fn load_state(paths: &Paths) -> State {
    fs::read(paths.at(STATE_FILE))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

pub fn save_state(paths: &Paths, state: &State) -> io::Result<()> {
    write_json(&paths.at(STATE_FILE), state)
}

pub fn load_pending(paths: &Paths) -> Option<Pending> {
    fs::read(paths.at(PENDING_FILE)).ok().and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

pub fn save_pending(paths: &Paths, pending: &Pending) -> io::Result<()> {
    write_json(&paths.at(PENDING_FILE), pending)
}

pub fn clear_pending(paths: &Paths) {
    let _ = fs::remove_file(paths.at(PENDING_FILE));
}

/// Written beside and renamed, so a reader never sees half a file.
fn write_json<T: Serialize>(path: &Path, value: &T) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let text = serde_json::to_vec_pretty(value).map_err(io::Error::other)?;
    let part = path.with_extension("json.part");
    fs::write(&part, text)?;
    fs::rename(&part, path)
}

/// Keeps a record of what an update installed and what it rolled back.
pub fn record_rollback(state: &mut State, pending: &Pending) {
    if !state.rolled_back.contains(&pending.cmux_tui) {
        state.rolled_back.push(pending.cmux_tui.clone());
    }
    // Only the newest few matter: a build the channel moved past is never named again.
    let excess = state.rolled_back.len().saturating_sub(20);
    state.rolled_back.drain(..excess);
}

/// The daemon's own sessions (not its peers') that run a turn or wait on a
/// permission, by name, from its `acpmux --json ls` (the rule of acpmux's
/// `host update --if-idle`); None when that is not a session list.
pub fn busy_sessions_in(ls: &str) -> Option<Vec<String>> {
    use serde_json::Value;
    let v: Value = serde_json::from_str(ls.trim()).ok()?;
    let busy = v
        .get("sessions")?
        .as_array()?
        .iter()
        .filter(|s| s.get("peer").is_none())
        .filter(|s| {
            s.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0
                || !s.get("turn").unwrap_or(&Value::Null).is_null()
                || matches!(s.get("status").and_then(Value::as_str), Some("running" | "waiting"))
        })
        .map(|s| s.get("name").and_then(Value::as_str).unwrap_or("?").to_owned())
        .collect();
    Some(busy)
}

pub fn record_installed(state: &mut State, plan: &Plan) {
    for sha in [&plan.cmux_tui.sha256, &plan.cmux_tui_hook.sha256] {
        if !state.installed.contains(sha) {
            state.installed.push(sha.clone());
        }
    }
}
