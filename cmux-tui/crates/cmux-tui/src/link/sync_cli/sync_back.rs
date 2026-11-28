//! No sync-back (RFD 0211, "Read-only projections, and no sync-back"; Leo: "security/sandboxing...
//! how will that work? what about if someone wants to lock down a vm? lock down their app?"): a
//! folder whose work must stay on the Cloud machine. With it off, nothing the machine wrote comes
//! back to this Mac: `cmux link project back`, `cmux link sync pull`, `cmux link seed pull` and
//! `cmux link access sync`'s way back all refuse with `sync_back_off`, before they dial.
//!
//! Two sources, and the tighter wins:
//!
//! - the policy, `projection.syncBack: false` (dotted or nested) in the JSON file
//!   `CMUX_POLICY_FILE` names, else `<state>/policy.json`; it turns sync-back off for every
//!   folder, and nothing local turns it back on. The org policy and MDM pieces of RFD 0211
//!   write this file. The managing team's saved policy layer
//!   (`<state>/settings/team-policy.json`, its `features."projection.syncBack"`) turns it off
//!   the same way: a team that set `projection.syncBack: false` wins over a policy file that
//!   says nothing or `true`.
//! - this Mac's own list (`cmux link project sync-back off|on|status FOLDER`), kept in
//!   `<state>/link-sync/sync-back-off`, one absolute folder per line; a folder inside a listed
//!   one is off too.
//!
//! A fresh-folder transfer (Transfer to This Mac) is refused only by the policy: its new folder
//! is on no list.

use std::path::{Path, PathBuf};

use anyhow::Context as _;
use serde_json::{Value, json};

/// The error code of a refused way back.
pub(crate) const CODE: &str = "sync_back_off";
/// The env that names the policy file.
const POLICY_ENV: &str = "CMUX_POLICY_FILE";

/// Why a way back was refused: [`CODE`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SyncBackOff {
    pub folder: PathBuf,
    /// `policy` or `folder`.
    pub by: &'static str,
}

impl std::fmt::Display for SyncBackOff {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.by {
            "policy" => write!(
                f,
                "sync-back is off by policy (projection.syncBack): nothing on the machine comes back to {}",
                self.folder.display()
            ),
            _ => write!(
                f,
                "sync-back is off for {}: nothing on the machine comes back to it (cmux link project sync-back on FOLDER turns it back on)",
                self.folder.display()
            ),
        }
    }
}

impl std::error::Error for SyncBackOff {}

fn state_dir() -> Option<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir()
}

fn list_path(state: &Path) -> PathBuf {
    state.join("link-sync").join("sync-back-off")
}

fn policy_path(state: Option<&Path>) -> Option<PathBuf> {
    match std::env::var_os(POLICY_ENV) {
        Some(path) if !path.is_empty() => Some(PathBuf::from(path)),
        _ => state.map(|state| state.join("policy.json")),
    }
}

/// The policy's `projection.syncBack`, dotted or nested; None when it says nothing.
pub(crate) fn policy_sync_back(policy: &Value) -> Option<bool> {
    policy
        .get("projection.syncBack")
        .or_else(|| policy.pointer("/projection/syncBack"))
        .and_then(Value::as_bool)
}

/// The managing team's `projection.syncBack` in its saved policy layer (`{value, mode}`, or a
/// bare value); None when the team did not set it.
pub(crate) fn team_sync_back(team: &Value) -> Option<bool> {
    let key = team.get("features")?.get("projection.syncBack")?;
    key.get("value").unwrap_or(key).as_bool()
}

fn read_json(path: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(path).ok()?).ok()
}

/// The policy file, with the team's `projection.syncBack: false` laid over it: the tighter wins.
pub(crate) fn read_policy(state: Option<&Path>) -> Option<Value> {
    let own = policy_path(state).and_then(|path| read_json(&path));
    let team = state.and_then(|state| read_json(&cmux_config::location::team_policy_path(state)));
    if team.as_ref().and_then(team_sync_back) == Some(false) {
        return Some(json!({"projection.syncBack": false}));
    }
    own
}

fn absolute(folder: &Path) -> PathBuf {
    std::fs::canonicalize(folder).unwrap_or_else(|_| folder.to_path_buf())
}

fn listed(state: &Path) -> Vec<PathBuf> {
    std::fs::read_to_string(list_path(state))
        .unwrap_or_default()
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(PathBuf::from)
        .collect()
}

/// Whether a way back into `folder` is refused, given the state folder and the policy.
pub(crate) fn refused_in(
    state: Option<&Path>,
    policy: Option<&Value>,
    folder: &Path,
) -> Option<SyncBackOff> {
    let folder = absolute(folder);
    if policy.and_then(policy_sync_back) == Some(false) {
        return Some(SyncBackOff { folder, by: "policy" });
    }
    let state = state?;
    listed(state)
        .iter()
        .any(|off| folder.starts_with(off))
        .then_some(SyncBackOff { folder, by: "folder" })
}

/// `Err(SyncBackOff)` when nothing may come back into `folder` ([`refused_in`] on this Mac).
pub(crate) fn check(folder: &Path) -> anyhow::Result<()> {
    let state = state_dir();
    let policy = read_policy(state.as_deref());
    match refused_in(state.as_deref(), policy.as_ref(), folder) {
        Some(off) => Err(off.into()),
        None => Ok(()),
    }
}

/// [`CODE`] when `error` is a [`SyncBackOff`].
pub(crate) fn code_of(error: &anyhow::Error) -> Option<&'static str> {
    error.downcast_ref::<SyncBackOff>().map(|_| CODE)
}

/// Turns this Mac's own sync-back for `folder` on or off in `state`.
pub(crate) fn set_in(state: &Path, folder: &Path, on: bool) -> anyhow::Result<()> {
    let folder = absolute(folder);
    let mut list: Vec<PathBuf> = listed(state).into_iter().filter(|off| *off != folder).collect();
    if !on {
        list.push(folder);
    }
    let path = list_path(state);
    std::fs::create_dir_all(path.parent().context("no state folder")?)?;
    let mut text = String::new();
    for off in &list {
        text.push_str(&off.to_string_lossy());
        text.push('\n');
    }
    let temp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&temp, text)?;
    std::fs::rename(&temp, &path)?;
    Ok(())
}

/// `cmux link project sync-back off|on|status FOLDER`.
pub(crate) fn command(args: &[String]) -> anyhow::Result<Value> {
    const USAGE: &str = "usage: cmux link project sync-back off|on|status FOLDER";
    let [verb, folder] = args else { anyhow::bail!(USAGE) };
    let folder = Path::new(folder);
    let state = state_dir().context("this Mac has no state folder")?;
    match verb.as_str() {
        "off" => set_in(&state, folder, false)?,
        "on" => set_in(&state, folder, true)?,
        "status" => {}
        _ => anyhow::bail!(USAGE),
    }
    let policy = read_policy(Some(&state));
    let off = refused_in(Some(&state), policy.as_ref(), folder);
    Ok(json!({
        "ok": true,
        "folder": absolute(folder),
        "syncBack": off.is_none(),
        "by": off.as_ref().map(|off| off.by),
    }))
}

#[cfg(test)]
#[path = "sync_back_tests.rs"]
mod tests;
