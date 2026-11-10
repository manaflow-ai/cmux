//! Move to another Cloud machine for a folder a Move to Cloud seeded from this Mac: the chat's
//! folder hops through this Mac's own copy of it, Bring Back Local's seed pull from the first
//! machine, then Move to Cloud's seed push to the second. Each machine clones the history from
//! GitHub on its own network, so only the diffs cross this Mac's links. `link_relay_bench`
//! measured 3.8 s and 6 MB on the wire this way, against 131 s and 953 MB to copy the folder
//! machine to machine (`cmux link sync relay`) for 3,192 files and 365 MB over two 8 MB/s links.
//!
//! `cmux link agent move --sync relay --sync-seed-local LOCAL` runs [`hop`] twice: the bulk before
//! the chat freezes (a full seed of the second machine), then the frozen pass (each side's delta).
//! This Mac keeps one seed record per folder and machine folder, and both machines may hold the
//! folder at the same path: between the two passes the second machine's record waits under its
//! own key ([`side_key`]), and the first machine's stays the record the next pull merges against.
//! [`land`] makes the second machine's the record once the move commits, so Bring Back Local
//! from there merges against it.

use std::path::Path;

use super::record;
use super::sync_cli::Back;
use super::{SeedError, bring_back, push, push_since_last};

/// Where the second machine's record waits for the commit.
fn side_key(to_root: &str) -> String {
    format!("hop-target:{to_root}")
}

/// One pass of the hop (module docs): the first machine's changes into `local`, then `local`
/// onto the second machine, as a full seed the first time and a delta after.
pub(in crate::link) fn hop(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    local: &Path,
) -> anyhow::Result<()> {
    let local = std::fs::canonicalize(local)?;
    let side = side_key(to_root);
    let waiting = record::load(&local, &side)?;
    // Refused before anything moves, this Mac's folder included.
    if waiting.is_none() {
        refuse_theirs(to, to_root)?;
    }
    match bring_back(from, &local, from_root) {
        Back::Done(_) => {}
        Back::Conflict(conflicts, _) => {
            return Err(SeedError::new(
                "sync_conflict",
                format!("{} changed both here and on the machine", conflicts.join(", ")),
            )
            .into());
        }
        Back::Failed { code, error } => return Err(SeedError::new(code, error).into()),
    }
    let from_record = record::load(&local, from_root)?;
    let pushed = match &waiting {
        // A retry to another machine than the waiting record's seeds that one whole.
        Some(kept) => record::save(&local, to_root, kept)
            .and_then(|()| push_since_last(to, &local, to_root).map(|_| ()))
            .or_else(|error| match super::failure_code(&error).as_str() {
                "seed.no_previous" => {
                    refuse_theirs(to, to_root).and_then(|()| seed_whole(to, &local, to_root))
                }
                _ => Err(error),
            }),
        None => seed_whole(to, &local, to_root),
    };
    // The second machine's record waits aside; the first machine's is the one a pull merges against.
    let to_record = record::load(&local, to_root)?;
    if let Some(kept) = &to_record
        && pushed.is_ok()
    {
        record::save(&local, &side, kept)?;
    }
    if let Some(kept) = &from_record {
        record::save(&local, from_root, kept)?;
    }
    pushed
}

/// A full seed of `to_root`, into a folder the second machine does not have ([`refuse_theirs`]).
fn seed_whole(to: &Path, local: &Path, to_root: &str) -> anyhow::Result<()> {
    push(to, local, to_root, None).map(|_| ())
}

/// A full seed into a checkout the second machine has would reset its work (a forced checkout
/// and a clean), so one that is there is refused as a relay refuses it (`relay.target_exists`).
fn refuse_theirs(to: &Path, to_root: &str) -> anyhow::Result<()> {
    if super::sync_cli::remote_kind(to, to_root)?.is_some() {
        return Err(SeedError::new(
            "relay.target_exists",
            format!("{to_root} is already on the machine"),
        )
        .into());
    }
    Ok(())
}

/// Whether a hop's bulk pass already ran for `to_root`: its frozen pass hops too.
pub(in crate::link) fn started(local: &Path, to_root: &str) -> bool {
    std::fs::canonicalize(local)
        .ok()
        .and_then(|local| record::load(&local, &side_key(to_root)).ok().flatten())
        .is_some()
}

/// The move committed: the second machine's record is this Mac's record of `to_root` now.
pub(in crate::link) fn land(local: &Path, to_root: &str) -> anyhow::Result<bool> {
    let local = std::fs::canonicalize(local)?;
    let side = side_key(to_root);
    let Some(kept) = record::load(&local, &side)? else { return Ok(false) };
    record::save(&local, to_root, &kept)?;
    record::forget(&local, &side)?;
    Ok(true)
}
