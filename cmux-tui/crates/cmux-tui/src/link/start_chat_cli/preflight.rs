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

/// The least a machine is taken to have room for, whatever its disk (the App's `CloudSeedRefusal.leastRoomBytes`).
const LEAST_ROOM_BYTES: u64 = 4 * GIB;
/// The seed refusal's code the App turns into "This folder is X, more than Y has room for" (`CloudSeedRefusal`).
pub(super) const SEED_REFUSED: &str = "seed_refused";
/// Its `fallback_code` for a machine whose disk is smaller than the size the start asked.
pub(super) const MACHINE_TOO_SMALL: &str = "machine.too_small";

/// The machine a start runs on, as far as the start knows its disk.
pub(super) struct Machine<'a> {
    pub(super) id: &'a str,
    pub(super) title: &'a str,
    /// The machine's disk in bytes; None when the platform or the App's list named none.
    pub(super) disk_bytes: Option<u64>,
}

/// The refusal of a start that asked `size` (the folder's `needed_size`) for `bytes` of folder when `machine` has a
/// smaller disk than that size's: an existing machine the platform answered at its own size (the workspace already had
/// it) or a pinned one. Nothing is cloned or copied there: the clone would fill its disk. A plan upgrade does not help,
/// the workspace's machine is fixed, so it is the folder too big for this machine, never `cloud.size.locked`. None for
/// the chat size or none asked, a size off the ladder, a machine whose disk is unknown (an older platform) or a disk at
/// least the size's.
pub(super) fn too_small(
    size: Option<&str>,
    bytes: Option<u64>,
    machine: &Machine<'_>,
) -> Option<Value> {
    let size = size.filter(|size| *size != "sm")?;
    let (_, asked) = LADDER.iter().find(|(name, _)| *name == size)?;
    let disk = machine.disk_bytes?;
    if disk >= *asked {
        return None;
    }
    let room = disk.saturating_sub(RESERVED_BYTES).max(LEAST_ROOM_BYTES);
    let mut line = super::refused(
        SEED_REFUSED,
        format!(
            "{} has a {} GiB disk, too small for this folder: it needs a {size} machine ({} GiB)",
            machine.title,
            disk / GIB,
            asked / GIB
        ),
    );
    if let Value::Object(object) = &mut line {
        object.insert("fallback_code".into(), json!(MACHINE_TOO_SMALL));
        object.insert("copy_bytes".into(), json!(bytes));
        object.insert("room_bytes".into(), json!(room));
        object.insert("needed".into(), json!(size));
        object.insert("machine_id".into(), json!(machine.id));
        object.insert("machine_title".into(), json!(machine.title));
    }
    Some(line)
}

/// The disk an ensure answer names for its machine (`machine.shape.diskGiB`), in bytes; None when it names none.
pub(super) fn ensured_disk_bytes(body: &Value) -> Option<u64> {
    body.pointer("/machine/shape/diskGiB")
        .and_then(Value::as_u64)
        .map(|gib| gib.saturating_mul(GIB))
}

#[cfg(test)]
#[path = "preflight_tests.rs"]
mod tests;
