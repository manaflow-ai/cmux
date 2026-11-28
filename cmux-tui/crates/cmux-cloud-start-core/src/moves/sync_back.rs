//! No sync-back and read-only projections (RFD 0211, "Read-only projections, and no sync-back";
//! Leo: "security/sandboxing... how will that work? what about if someone wants to lock down a vm?
//! lock down their app?"): the one rule both the `cmux link` CLI (cmux-tui
//! `link/sync_cli/sync_back.rs`, which refuses the way back) and the app (which hides Bring Back
//! Local, op `cloud_move_sync_back`) read, so the menu and the refusal never disagree.
//!
//! Pure: the caller reads the files and hands their text here.
//!
//! - The policy (`<state>/policy.json`, or the file `CMUX_POLICY_FILE` names), dotted or nested:
//!   `projection.syncBack: false` turns the way back off for every folder;
//!   `projection.readOnly: true` projects every folder read-only. Nothing local loosens either.
//! - This Mac's own lists, one absolute folder per line, a folder inside a listed one included:
//!   [`SYNC_BACK_OFF_LIST`] (`cmux link project sync-back off FOLDER`) and [`READ_ONLY_LIST`]
//!   (`cmux link project read-only on FOLDER`).
//!
//! A read-only folder has no sync-back either: its mount has no upper layer, so nothing the
//! machine did could come back.

use std::path::Path;

use serde_json::Value;

/// The env that names the policy file.
pub const POLICY_ENV: &str = "CMUX_POLICY_FILE";
/// The policy file in the state folder.
pub const POLICY_FILE: &str = "policy.json";
/// The folders this Mac turned sync-back off for, below the state folder.
pub const SYNC_BACK_OFF_LIST: &str = "link-sync/sync-back-off";
/// The folders this Mac projects read-only, below the state folder.
pub const READ_ONLY_LIST: &str = "link-sync/read-only";

/// Why the way back is off: `policy` (`projection.syncBack: false`), `folder` (this Mac's
/// sync-back list), or `read_only` (the folder is projected read-only, by policy or list).
pub type By = &'static str;

fn key<'a>(policy: &'a Value, dotted: &str, pointer: &str) -> Option<&'a Value> {
    policy.get(dotted).or_else(|| policy.pointer(pointer))
}

/// The policy's `projection.syncBack`; None when it says nothing.
pub fn policy_sync_back(policy: &Value) -> Option<bool> {
    key(policy, "projection.syncBack", "/projection/syncBack").and_then(Value::as_bool)
}

/// The policy's `projection.readOnly`; None when it says nothing.
pub fn policy_read_only(policy: &Value) -> Option<bool> {
    key(policy, "projection.readOnly", "/projection/readOnly").and_then(Value::as_bool)
}

/// Whether `folder` (absolute) is `list`'s, or inside one of its folders.
pub fn listed(list: &str, folder: &Path) -> bool {
    list.lines().map(str::trim).filter(|line| !line.is_empty()).any(|off| folder.starts_with(off))
}

/// Why `folder` is projected read-only, or None: `policy` or `folder`.
pub fn read_only(policy: Option<&Value>, read_only_list: &str, folder: &Path) -> Option<By> {
    if policy.and_then(policy_read_only) == Some(true) {
        return Some("policy");
    }
    listed(read_only_list, folder).then_some("folder")
}

/// Why nothing may come back into `folder`, or None (module docs).
pub fn refused(
    policy: Option<&Value>,
    sync_back_list: &str,
    read_only_list: &str,
    folder: &Path,
) -> Option<By> {
    if policy.and_then(policy_sync_back) == Some(false) {
        return Some("policy");
    }
    if read_only(policy, read_only_list, folder).is_some() {
        return Some("read_only");
    }
    listed(sync_back_list, folder).then_some("folder")
}

#[cfg(test)]
#[path = "sync_back_tests.rs"]
mod tests;
