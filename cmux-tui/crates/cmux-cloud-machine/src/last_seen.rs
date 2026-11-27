//! The machine list a team last answered, kept on this Mac so a cold start can show the
//! machines it knew at once while the control plane is slow or down, marked "last seen" until a
//! fresh list lands (cmuxterm-hq docs/reading/2026-11-22-tailscale-netmap-caching.md: a client
//! starts from its last good map, never from nothing).
//!
//! Pure: the app's FFI (`cmux-layout-reducer-ffi`, ops `cloud_machine_last_seen_*`) reads and
//! writes the file; this module says what goes in it, which file is whose, and whether a kept
//! list may be shown. A kept list is only ever shown to the user and team it was read for: an
//! account or team switch never shows or acts on another account's machines.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The file format's version: a file of any other version is ignored, never migrated.
pub const VERSION: u32 = 1;
/// Kept lists older than this are not shown: a machine unseen for a month may be long gone.
pub const MAX_AGE_MS: i64 = 30 * 24 * 60 * 60 * 1000;
/// A kept list written this far in the future (a clock moved back) is still fine; further is not.
pub const MAX_SKEW_MS: i64 = 5 * 60 * 1000;
/// Rows kept at most (the picker answers at most 200).
pub const MAX_ROWS: usize = 200;
/// Every kept file's name starts with this, so forgetting removes only these.
pub const FILE_PREFIX: &str = "machines-";
pub const FILE_SUFFIX: &str = ".json";

/// One row as the picker reads it (`cloudMachine.list` `machines[]`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Row {
    pub id: String,
    pub name: String,
    pub stage: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evict_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<Value>,
}

/// A kept list: whose it is, when it was read (epoch ms) and its rows.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub version: u32,
    pub user: String,
    #[serde(default)]
    pub team: Option<String>,
    pub at: i64,
    pub machines: Vec<Row>,
}

/// The file `user` and `team`'s list is kept in: the prefix, a 64-bit FNV-1a of both, the
/// suffix. Ids never appear in the name; the file itself says whose it is and is checked on read.
pub fn file_name(user: &str, team: Option<&str>) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut eat = |bytes: &[u8]| {
        for byte in bytes {
            hash ^= u64::from(*byte);
            hash = hash.wrapping_mul(0x0100_0000_01b3);
        }
    };
    eat(user.as_bytes());
    eat(&[0]);
    match team {
        Some(team) => {
            eat(&[1]);
            eat(team.as_bytes());
        }
        None => eat(&[0]),
    }
    format!("{FILE_PREFIX}{hash:016x}{FILE_SUFFIX}")
}

/// Whether `name` is a kept list's file (what forgetting may remove).
pub fn is_file_name(name: &str) -> bool {
    name.strip_prefix(FILE_PREFIX)
        .and_then(|rest| rest.strip_suffix(FILE_SUFFIX))
        .is_some_and(|hex| hex.len() == 16 && hex.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// The file's text for `user` and `team`'s rows read at `at`; None without a user (signed
/// out: nothing is kept). Rows past [`MAX_ROWS`], and rows without an id, name or stage, are left out.
pub fn encode(user: &str, team: Option<&str>, at: i64, machines: &[Row]) -> Option<String> {
    if user.is_empty() {
        return None;
    }
    let snapshot = Snapshot {
        version: VERSION,
        user: user.to_owned(),
        team: team.map(str::to_owned),
        at,
        machines: machines.iter().filter(|row| usable(row)).take(MAX_ROWS).cloned().collect(),
    };
    serde_json::to_string(&snapshot).ok()
}

/// The kept list in `text` when it may be shown to `user` and `team` at `now`: same version,
/// same user and team, read within [`MAX_AGE_MS`] and not past [`MAX_SKEW_MS`] ahead. An empty
/// list is a list (the team has no machines), and is returned too.
pub fn decode(text: &str, user: &str, team: Option<&str>, now: i64) -> Option<Snapshot> {
    let mut snapshot: Snapshot = serde_json::from_str(text).ok()?;
    if snapshot.version != VERSION
        || user.is_empty()
        || snapshot.user != user
        || snapshot.team.as_deref() != team
        || snapshot.at > now.saturating_add(MAX_SKEW_MS)
        || now.saturating_sub(snapshot.at) > MAX_AGE_MS
    {
        return None;
    }
    snapshot.machines.retain(usable);
    snapshot.machines.truncate(MAX_ROWS);
    Some(snapshot)
}

fn usable(row: &Row) -> bool {
    !row.id.is_empty() && !row.name.is_empty() && !row.stage.is_empty()
}

#[cfg(test)]
mod tests;
