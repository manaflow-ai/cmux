//! Whether this Mac is busy, from acpmux's cached placement verdict, so New Workspace reads it
//! with no request on Cmd-N's turn.
//!
//! acpmux's `_acpmux/place` (the composer's Auto row and "This Mac is busy" chip, remote-spin-up
//! piece 1, and `acpmux machine pick`) writes each plain verdict it gives to
//! `<ACPMUX_HOME>/place-verdict.json` as `{"at": MS, "verdict": {pick, local, overloaded, room,
//! localOver}}` (`acpmux/src/server/place.rs` `remember`). The app's FFI reads that file and
//! asks [`from_cache`] what it means: this Mac is busy when its `localOver` names a reason, and
//! the pick is one of your own machines when it is not this Mac, has room for a lane and was
//! not taken past its limits (`overloaded`). A verdict older than [`MAX_AGE_MS`] says nothing:
//! a Mac's load moves in minutes, and a stale "busy" must not send work away.

use serde::Deserialize;
use serde_json::Value;

/// The file under acpmux's home that holds the last verdict.
pub const FILE: &str = "place-verdict.json";

/// A verdict older than this (two minutes) is not read.
pub const MAX_AGE_MS: u64 = 120_000;

/// This Mac is over its budget.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize, serde::Serialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Busy {
    /// Why, in placement's words ("over its budget (load1 29.8 >= 15)").
    pub over: String,
    /// Your own connected machine with room (app machine id), when placement picked one.
    pub machine: Option<String>,
}

/// One of your own machines the app has connected now (an SSH machine or a paired server, never
/// a Cloud machine): its app machine id and the names acpmux may know it by (its label, its ssh
/// host).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct OwnMachine {
    pub id: String,
    pub names: Vec<String>,
}

impl OwnMachine {
    /// Whether acpmux's host name `host` is this machine: a name equal to it, ignoring case and
    /// any `user@` and `:port`, or whose first DNS label is it (`gcp-3` for `gcp-3.tail.ts.net`).
    fn is(&self, host: &str) -> bool {
        let bare = |name: &str| {
            let name = name.trim();
            let name = name.rsplit_once('@').map_or(name, |(_, h)| h);
            let name = name.split_once(':').map_or(name, |(h, _)| h);
            name.to_ascii_lowercase()
        };
        let host = bare(host);
        !host.is_empty()
            && self
                .names
                .iter()
                .map(|n| bare(n))
                .any(|name| name == host || name.split('.').next() == Some(host.as_str()))
    }
}

/// What the cached file `cache` says at `now_ms`, with `machines` your own connected ones. None
/// when this Mac is not busy, or the file is malformed or older than [`MAX_AGE_MS`].
pub fn from_cache(cache: &Value, now_ms: u64, machines: &[OwnMachine]) -> Option<Busy> {
    let at = cache.get("at")?.as_u64()?;
    if now_ms.saturating_sub(at) > MAX_AGE_MS || at > now_ms.saturating_add(MAX_AGE_MS) {
        return None;
    }
    let verdict = cache.get("verdict")?;
    let over = verdict.get("localOver")?.as_str()?.trim();
    if over.is_empty() {
        return None;
    }
    let flag = |key: &str| verdict.get(key).and_then(Value::as_bool).unwrap_or(false);
    let roomy = verdict.get("room").and_then(Value::as_f64).is_some_and(|room| room >= 1.0);
    let machine = verdict
        .get("pick")
        .and_then(Value::as_str)
        .filter(|_| !flag("local") && !flag("overloaded") && roomy)
        .and_then(|pick| machines.iter().find(|m| m.is(pick)))
        .map(|m| m.id.clone());
    Some(Busy { over: over.to_owned(), machine })
}
