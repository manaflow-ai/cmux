//! `cmux link start-chat preflight --local FOLDER`: whether a Cloud chat may start from `FOLDER`
//! at all, asked before any machine or lease is made for it (the App's `CloudStartChat`). Its
//! size never stops it: a folder past what a copy sends whole goes as a first pass, the rest on
//! this Mac until the chat asks for it ([`sync_cli::size_cap`]), so the chat starts at once in the
//! folder the person chose, a repository, a parent of many (`~/Projects`) or neither.
//!
//! Leo, 2026-11-15, on a Cloud chat at `~/Projects` refused as too big to copy (at least 20 GB in
//! 268,121 files) with the repositories inside it to pick from: "why are you guys still blocking
//! on these?"
//!
//! [`sync_cli::size_cap`]: super::super::sync_cli::size_cap

use std::path::Path;

use serde_json::{Value, json};

const GIB: u64 = 1024 * 1024 * 1024;
/// What a machine's image and its own work keep of its disk (the App's `CloudSeedRefusal.reservedDiskBytes`).
const RESERVED_BYTES: u64 = 12 * GIB;
/// The Cloud size ladder's disks (cmux-platform `Sizes.ts`), smallest first: a chat's machine is the
/// smallest whose disk holds the copy and the reserve.
const LADDER: [(&str, u64); 4] =
    [("sm", 16 * GIB), ("md", 32 * GIB), ("lg", 64 * GIB), ("xl", 128 * GIB)];

/// The answer for `local`: `{"ok":true,"estimate":{...}}` for any absolute folder, the copy's
/// estimate and decision (whole, first pass or seed) made here, before any machine
/// ([`estimate`]); `estimate` is `null` for a folder it could not read, and the start goes on.
/// With an estimate it also answers the bytes the machine will hold (`estimate_bytes`: what the
/// copy sends, or the whole folder for a seed, whose clone brings all of it) and the smallest
/// size whose disk holds them (`needed_size`, null above the largest).
///
/// [`estimate`]: super::super::sync_cli::estimate
pub(super) fn run(local: &str) -> Value {
    if !Path::new(local).is_absolute() {
        return super::refused("usage.invalid", "--local must be an absolute folder");
    }
    let Ok(estimate) = super::super::sync_cli::estimate::of_folder(Path::new(local)) else {
        return json!({"ok": true, "estimate": null});
    };
    let bytes = if estimate.mode == super::super::sync_cli::estimate::Mode::Seed {
        estimate.folder_bytes.max(estimate.bytes)
    } else {
        estimate.bytes
    };
    json!({
        "ok": true,
        "estimate": estimate.json(),
        "estimate_bytes": bytes,
        "needed_size": needed_size(bytes),
    })
}

/// The smallest ladder size whose disk holds `bytes` and [`RESERVED_BYTES`]; None above the largest.
pub(super) fn needed_size(bytes: u64) -> Option<&'static str> {
    let disk = bytes.saturating_add(RESERVED_BYTES);
    LADDER.iter().find(|(_, room)| disk <= *room).map(|(name, _)| *name)
}

#[cfg(test)]
#[path = "preflight_tests.rs"]
mod tests;
