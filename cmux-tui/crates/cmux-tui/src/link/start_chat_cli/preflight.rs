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

/// The answer for `local`: `{"ok":true}` for any absolute folder, with the bytes its copy will send
/// (`estimate_bytes`: the folder whole by the copy's rules, `.git` included, or only its first pass past the
/// copy's limits; [`sync_cli::copy_estimate`]) and the smallest size whose disk holds them (`needed_size`, null
/// above the largest). A folder whose size could not be read answers neither: the copy counts it again.
///
/// [`sync_cli::copy_estimate`]: super::super::sync_cli::copy_estimate
pub(super) fn run(local: &str) -> Value {
    if !Path::new(local).is_absolute() {
        return super::refused("usage.invalid", "--local must be an absolute folder");
    }
    match super::super::sync_cli::copy_estimate(Path::new(local)) {
        Ok((_, bytes)) => {
            json!({"ok": true, "estimate_bytes": bytes, "needed_size": needed_size(bytes)})
        }
        Err(_) => json!({"ok": true}),
    }
}

/// The smallest ladder size whose disk holds `bytes` and [`RESERVED_BYTES`]; None above the largest.
pub(super) fn needed_size(bytes: u64) -> Option<&'static str> {
    let disk = bytes.saturating_add(RESERVED_BYTES);
    LADDER.iter().find(|(_, room)| disk <= *room).map(|(name, _)| *name)
}

#[cfg(test)]
#[path = "preflight_tests.rs"]
mod tests;
