//! A chat's pin (its stored [`PlaceMode`], `SessionMeta::place_mode`) and the one-time migration
//! that pins every chat that existed before place modes to the machine it is on, so nothing moves
//! unasked when they ship (approved MVP, Leo 2026-11-24: "i think so. i think this is good as a
//! start."; "when this ships every existing chat is migrated to pinned on its current machine").
//!
//! - The cutoff ([`start`]): when this machine's migration began, set before the daemon answers
//!   anything. A chat with no pin made before it reads as pinned here, even while the migration
//!   is still saving its pin; one made after it is new and reads as Auto: new chats always start
//!   on Auto, and a pick never becomes the default. No cutoff (a memory store): every chat
//!   with no pin is Auto.
//! - The migration ([`plan`]) gives every chat without a pin `Machine { here }`. A pick kept in
//!   the older `place-modes.json` (the first `place_set`'s own file) wins over that, so no pick is
//!   lost. A chat that has a pin keeps it. It runs once per daemon home: its marker
//!   (`place-modes-migrated.json`) is written only after every chat's pin was saved, so a start
//!   that failed part way runs it again, and a chat it already pinned keeps that pin.
//!
//! Pure except [`read_legacy`], [`read_marker`] and [`write_marker`]; the daemon's glue is
//! `hub/place_migrate.rs`.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

use crate::place_mode::PlaceMode;

/// The first `place_set`'s pin file in the daemon's home: `{chat id: mode}`.
pub const LEGACY_PINS: &str = "place-modes.json";
/// Written once this machine's chats were migrated.
pub const MARKER: &str = "place-modes-migrated.json";

static CUTOFF: AtomicU64 = AtomicU64::new(0);

/// The cutoff in unix ms ([`start`]); 0 when none was set.
pub fn cutoff() -> u64 {
    CUTOFF.load(Ordering::SeqCst)
}

#[doc(hidden)]
pub fn set_cutoff(at: u64) {
    CUTOFF.store(at, Ordering::SeqCst);
}

/// The daemon's start, before it answers: sets the cutoff, from the marker when this home was
/// migrated before (no migration then: None), else now (Some: the migration to run, with it).
pub fn start(home: &Path, now: u64) -> Option<u64> {
    match read_marker(home) {
        Some(done) => {
            set_cutoff(done.at);
            None
        }
        None => {
            set_cutoff(now);
            Some(now)
        }
    }
}

/// What a chat's mode is: its pin; with none, pinned to the machine it is on (`here`) when it
/// was made before `cutoff` (every chat older than place modes), else Auto.
pub fn effective(stored: Option<PlaceMode>, here: &str, created_at: u64, cutoff: u64) -> PlaceMode {
    stored.unwrap_or_else(|| {
        if created_at < cutoff {
            PlaceMode::Machine { id: here.to_owned() }
        } else {
            PlaceMode::Auto
        }
    })
}

/// The pin the migration gives one chat, or None to leave it as it is: a pin it has stays; else
/// its pick in the older pin file; else this machine.
pub fn plan(
    stored: Option<&PlaceMode>,
    legacy: Option<&PlaceMode>,
    here: &str,
) -> Option<PlaceMode> {
    match (stored, legacy) {
        (Some(_), _) => None,
        (None, Some(pick)) => Some(pick.clone()),
        (None, None) => Some(PlaceMode::Machine { id: here.to_owned() }),
    }
}

/// The older pin file's picks; none when it is missing or unreadable.
pub fn read_legacy(home: &Path) -> BTreeMap<String, PlaceMode> {
    std::fs::read(home.join(LEGACY_PINS))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

/// What the migration did, kept in its marker.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Report {
    /// The machine the chats were pinned to.
    pub here: String,
    /// Its cutoff, unix ms: every chat made before it was weighed.
    pub at: u64,
    /// Chats pinned to `here`.
    pub pinned: usize,
    /// Chats given their pick from the older pin file.
    pub from_legacy: usize,
    /// Chats that had a pin already.
    pub kept: usize,
    /// Chats whose pin could not be saved (a marker is never written with any).
    pub failed: usize,
}

/// The marker's report, when this home's chats were migrated.
pub fn read_marker(home: &Path) -> Option<Report> {
    let raw = std::fs::read(home.join(MARKER)).ok()?;
    serde_json::from_slice(&raw).ok()
}

/// Writes the marker (atomically) and retires the older pin file, renamed beside it, never
/// deleted.
pub fn write_marker(home: &Path, report: &Report) -> std::io::Result<()> {
    let bytes = serde_json::to_vec_pretty(report).map_err(std::io::Error::other)?;
    let path = home.join(MARKER);
    let tmp = path.with_extension("json.tmp");
    crate::home_fs::write_synced(&tmp, &bytes)?;
    crate::home_fs::rename(&tmp, &path)?;
    let legacy = home.join(LEGACY_PINS);
    match crate::home_fs::rename(&legacy, home.join("place-modes.json.migrated")) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

#[cfg(test)]
#[path = "place_pin_tests.rs"]
mod tests;
