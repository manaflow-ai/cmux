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
/// smallest whose disk holds the folder's [`needed_disk`]. `2xl` has `xl`'s disk, so it is never the
/// smallest; it is here for the room check and a grown disk on a plan whose largest size it is.
const LADDER: [(&str, u64); 5] =
    [("sm", 16 * GIB), ("md", 32 * GIB), ("lg", 64 * GIB), ("xl", 128 * GIB), ("2xl", 128 * GIB)];
/// A grown disk's step: the disk a start asks beyond its size's own is rounded up to it.
const DISK_STEP_GIB: u64 = 4;

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

/// The disk a machine needs for `bytes` of folder: half again the folder, and at least the folder and
/// [`RESERVED_BYTES`]. The one rule for the size a start asks, the disk it grows and the room check
/// (the App's `CloudChatSize.neededDiskBytes`).
pub(super) fn needed_disk(bytes: u64) -> u64 {
    let half_again = bytes.saturating_add(bytes.div_ceil(2));
    half_again.max(bytes.saturating_add(RESERVED_BYTES))
}

/// The most bytes of folder a `disk` has room for under [`needed_disk`]: the disk less the reserve, and at
/// most two thirds of it.
fn room_on(disk: u64) -> u64 {
    disk.saturating_sub(RESERVED_BYTES).min(disk - disk.div_ceil(3))
}

/// The smallest ladder size whose disk holds the folder's [`needed_disk`]; None above the largest.
pub(super) fn needed_size(bytes: u64) -> Option<&'static str> {
    let disk = needed_disk(bytes);
    LADDER.iter().find(|(_, room)| disk <= *room).map(|(name, _)| *name)
}

/// The disk in GiB a start asks beyond `size`'s own (the ensure body's `disk_gib`): the folder's [`needed_disk`]
/// rounded up to [`DISK_STEP_GIB`], only when it is more than that size's disk (a plan's largest size grown to hold
/// the folder). None for no size, a size off the ladder, unknown bytes or a folder the size's own disk holds.
pub(super) fn grown_disk_gib(size: Option<&str>, bytes: Option<u64>) -> Option<u64> {
    let size = size?;
    let (_, disk) = LADDER.iter().find(|(name, _)| *name == size)?;
    let needed = needed_disk(bytes?);
    if needed <= *disk {
        return None;
    }
    Some(needed.div_ceil(DISK_STEP_GIB * GIB).saturating_mul(DISK_STEP_GIB))
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
/// the chat size or none asked, a size off the ladder, a machine whose disk is unknown (an older platform) or a disk
/// with room for the folder's [`needed_disk`] (at least the size's, when the folder's bytes are unknown).
pub(super) fn too_small(
    size: Option<&str>,
    bytes: Option<u64>,
    machine: &Machine<'_>,
) -> Option<Value> {
    let size = size.filter(|size| *size != "sm")?;
    let (_, asked) = LADDER.iter().find(|(name, _)| *name == size)?;
    let disk = machine.disk_bytes?;
    // A disk between two sizes (a machine grown by hand or by `disk_gib`) has room when the folder's needed disk
    // fits it; the size's own disk decides only when the folder's bytes are unknown.
    let fits = match bytes {
        Some(bytes) => needed_disk(bytes) <= disk,
        None => disk >= *asked,
    };
    if fits {
        return None;
    }
    let room = room_on(disk).max(LEAST_ROOM_BYTES);
    // A folder past its size's own disk needs that size grown: the message names the disk it needs.
    let needs = bytes.map_or(0, needed_disk).max(*asked);
    let mut line = super::refused(
        SEED_REFUSED,
        format!(
            "{} has a {} GiB disk, too small for this folder: it needs a {size} machine ({} GiB)",
            machine.title,
            disk / GIB,
            needs.div_ceil(GIB)
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
