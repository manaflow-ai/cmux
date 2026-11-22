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
/// The Cloud size ladder's disks (cmux-platform `Sizes.ts`), smallest first ([`planned_size`]). `2xl` has `xl`'s disk,
/// so it is never the smallest; it is here for a plan whose largest size it is.
const LADDER: [(&str, u64); 5] =
    [("sm", 16 * GIB), ("md", 32 * GIB), ("lg", 64 * GIB), ("xl", 128 * GIB), ("2xl", 128 * GIB)];
/// The most disk a Cloud machine has (cmux NEXT Max's largest): a folder whose [`floor_disk`] is past it is too big.
const LARGEST_DISK: u64 = 256 * GIB;
/// A grown disk's step: the disk a start asks beyond its size's own is rounded up to it.
const DISK_STEP_GIB: u64 = 4;

/// The answer for `local`: `{"ok":true,"estimate":{...}}` for any absolute folder, the copy's
/// estimate and decision (whole, first pass or seed) made here, before any machine
/// ([`estimate`]); `estimate` is `null` for a folder it could not read, and the start goes on.
/// With an estimate it also answers the bytes the machine will hold (`estimate_bytes`: what the
/// copy sends, or the whole folder for a seed, whose clone brings all of it) and the size a start
/// with no plan known asks for them ([`needed_size`], null for a folder too big for any machine).
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

/// The least disk that holds `bytes` of folder at all: the folder and [`RESERVED_BYTES`]. The rule every refusal
/// keeps (a machine too small, a folder too big), as before the half-again target (the App's
/// `CloudChatSize.floorDiskBytes`).
pub(super) fn floor_disk(bytes: u64) -> u64 {
    bytes.saturating_add(RESERVED_BYTES)
}

/// The disk a start grows its size toward for `bytes` of folder under a plan known: half again the folder, and at least
/// its [`floor_disk`]. It only grows a disk ([`grown_disk_gib`]): it never picks the size asked nor refuses (the App's
/// `CloudChatSize.neededDiskBytes`).
pub(super) fn needed_disk(bytes: u64) -> u64 {
    let half_again = bytes.saturating_add(bytes.div_ceil(2));
    half_again.max(floor_disk(bytes))
}

/// The ladder index of a plan's largest size `plan_max`; None for none or a size off the ladder (a plan not known).
fn plan_index(plan_max: Option<&str>) -> Option<usize> {
    plan_max.and_then(|plan_max| LADDER.iter().position(|(name, _)| *name == plan_max))
}

/// The size name at ladder index `index`; None off the ladder.
fn size_name(index: usize) -> Option<&'static str> {
    LADDER.get(index).map(|(name, _)| *name)
}

/// The largest disk a plan whose largest size is ladder index `plan` gives: `lg` (cmux NEXT Pro and the classic plans
/// below Max) 128 GiB, `2xl` (Max) [`LARGEST_DISK`], another size its own disk.
fn plan_disk(plan: usize) -> u64 {
    match LADDER.get(plan) {
        Some(("lg", _)) => 128 * GIB,
        Some(("2xl", _)) => LARGEST_DISK,
        Some((_, own)) => *own,
        // `plan` comes from `plan_index`, so it is always on the ladder.
        None => 0,
    }
}

/// The smallest ladder index (`sm` to `xl`; `2xl` has `xl`'s disk, so never the smallest) whose own disk holds the
/// folder's [`floor_disk`]; None above `xl`.
fn floor_index(bytes: u64) -> Option<usize> {
    let floor = floor_disk(bytes);
    LADDER.iter().position(|(_, own)| floor <= *own)
}

/// The size a start with no plan known asks for `bytes` of folder: the smallest whose own disk holds the folder and the
/// reserve ([`floor_disk`]), None above `xl` (the rule before the half-again target). The preflight's `needed_size`.
pub(super) fn needed_size(bytes: u64) -> Option<&'static str> {
    planned_size(bytes, None)
}

/// The size a start asks for `bytes` of folder under a plan whose largest size is `plan_max` (None, or a size off the
/// ladder: not known, [`needed_size`] and no grown disk). With a plan known: [`needed_size`] when the plan gives it;
/// else, when the plan's largest disk holds the floor, the plan's largest size, its disk grown ([`grown_disk_gib`];
/// a platform that ignores it is answered [`outgrown_plan`]); else the size past the plan, which the platform refuses
/// with its upgrade (`cloud.size.locked`): [`needed_size`], or `2xl` above `xl`. None for a folder whose floor is past
/// [`LARGEST_DISK`]. The App's `CloudChatSize.planned(bytes:planMax:)`.
pub(super) fn planned_size(bytes: u64, plan_max: Option<&str>) -> Option<&'static str> {
    let fit = floor_index(bytes);
    let Some(plan) = plan_index(plan_max) else { return fit.and_then(size_name) };
    if let Some(index) = fit.filter(|index| *index <= plan) {
        return size_name(index);
    }
    let floor = floor_disk(bytes);
    if floor > LARGEST_DISK {
        return None;
    }
    if floor <= plan_disk(plan) {
        return size_name(plan);
    }
    Some(fit.and_then(size_name).unwrap_or("2xl"))
}

/// The disk in GiB a start asks beyond `size`'s own (the ensure body's `disk_gib`) under a plan known by its largest
/// size `plan_max`: the folder's [`needed_disk`] rounded up to [`DISK_STEP_GIB`], at most the plan's largest disk
/// ([`plan_disk`]), only when that is more than the size's own disk. None with no plan known (none, or a size off the
/// ladder: the start asks exactly what it did before the half-again target), no size, a size off the ladder, unknown
/// bytes or a folder the size's own disk holds. The App's `CloudChatSize.grownDiskMb`.
pub(super) fn grown_disk_gib(
    size: Option<&str>,
    bytes: Option<u64>,
    plan_max: Option<&str>,
) -> Option<u64> {
    let plan = plan_index(plan_max)?;
    let (_, own) = LADDER.iter().find(|(name, _)| Some(*name) == size)?;
    let needed = needed_disk(bytes?);
    if needed <= *own {
        return None;
    }
    let cap = plan_disk(plan) / GIB;
    let gib = needed.div_ceil(DISK_STEP_GIB * GIB).saturating_mul(DISK_STEP_GIB).min(cap);
    (gib.saturating_mul(GIB) > *own).then_some(gib)
}

/// The refusal of a start that asked the plan's largest size `size` grown for `bytes` of folder no size within the plan
/// holds ([`planned_size`]), when the platform made `machine` with a disk below the folder's [`floor_disk`] (it ignored
/// `disk_gib`): the size refusal the platform answers a start past the plan's sizes (`cloud.size.locked`), naming the
/// size the folder needs ([`needed_size`], else the size above the plan) and the plan's largest, so the App's start card
/// offers the upgrade, never [`too_small`]. None for no plan known, a size other than the plan's largest, a size within
/// the plan that holds the floor, no size above the plan, unknown bytes or disk, or a disk that holds the floor.
pub(super) fn outgrown_plan(
    size: Option<&str>,
    bytes: Option<u64>,
    plan_max: Option<&str>,
    machine: &Machine<'_>,
) -> Option<Value> {
    let plan = plan_index(plan_max)?;
    let largest = size_name(plan)?;
    if size != Some(largest) {
        return None;
    }
    let bytes = bytes?;
    if floor_index(bytes).is_some_and(|index| index <= plan) {
        return None;
    }
    let disk = machine.disk_bytes?;
    if floor_disk(bytes) <= disk {
        return None;
    }
    let needed = floor_index(bytes).or_else(|| (plan + 1 < LADDER.len()).then_some(plan + 1))?;
    let needed = size_name(needed)?;
    let mut line = super::refused(
        SIZE_LOCKED,
        format!(
            "{} has a {} GiB disk, too small for this folder: it needs a {needed} machine, which the plan does not give",
            machine.title,
            disk / GIB
        ),
    );
    super::with_handling(&mut line, 403, SIZE_LOCKED, None);
    if let Value::Object(object) = &mut line {
        object.insert("size_locked".into(), json!({"needed": needed, "allowed": largest}));
        object.insert("copy_bytes".into(), json!(bytes));
        object.insert("machine_id".into(), json!(machine.id));
        object.insert("machine_title".into(), json!(machine.title));
    }
    Some(line)
}

/// The platform's code for a size the plan does not give (cmux-platform `admitSize`).
const SIZE_LOCKED: &str = "cloud.size.locked";

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

/// The refusal of a start that asked `size` for `bytes` of folder when `machine` has a smaller disk than the folder's
/// [`floor_disk`]: an existing machine the platform answered at its own size (the workspace already had it, or a
/// platform that ignored `disk_gib`) or a pinned one. Nothing is cloned or copied there: the clone would fill its disk.
/// A plan upgrade does not help, the workspace's machine is fixed, so it is the folder too big for this machine, never
/// `cloud.size.locked`. None for the chat size or none asked, a size off the ladder, a machine whose disk is unknown
/// (an older platform) or a disk with room for the folder and the reserve (at least the size's, when the folder's
/// bytes are unknown). Never the half-again [`needed_disk`]: that is what a start asks, not what it refuses.
pub(super) fn too_small(
    size: Option<&str>,
    bytes: Option<u64>,
    machine: &Machine<'_>,
) -> Option<Value> {
    let size = size.filter(|size| *size != "sm")?;
    let (_, asked) = LADDER.iter().find(|(name, _)| *name == size)?;
    let disk = machine.disk_bytes?;
    // A disk between two sizes (a machine grown by hand or by `disk_gib`) has room when the folder and the reserve fit
    // it; the size's own disk decides only when the folder's bytes are unknown.
    let fits = match bytes {
        Some(bytes) => floor_disk(bytes) <= disk,
        None => disk >= *asked,
    };
    if fits {
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
