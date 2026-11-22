//! The line merge of a pull ([`super::pull`]): a text file changed both
//! here and on the machine is merged line by line against the version the
//! last sync left (diff3, against its blob in this Mac's snapshots,
//! [`super::history`]). Edits to different lines merge cleanly and the
//! merged file is placed like any other the pull brings back. Edits that
//! overlap are a conflict: this Mac's file stays as it is and the merge,
//! with conflict markers (`<<<<<<< ours` is this Mac's, `>>>>>>> theirs`
//! the machine's, `||||||| original` the last sync's), is written beside it
//! as `NAME.cmux-sync-conflict`, which syncs never send.
//!
//! A file is text when none of the three versions has a NUL byte; binary
//! files, files over [`TEXT_MAX`] (the merge holds all three in memory),
//! permission changes on both sides that differ, and files whose last
//! synced version this Mac no longer keeps stay whole-file conflicts.

use std::path::Path;

use super::history;
use super::place::{self, Dir, Entry};

/// The suffix of a conflict's merge file.
pub(super) const CONFLICT_SUFFIX: &str = ".cmux-sync-conflict";

/// Largest file (each version) that is merged by line: the merge holds all
/// three in memory. A bigger one stays a whole-file conflict.
pub(super) const TEXT_MAX: u64 = 64 * 1024 * 1024;

/// One version of a file: its SHA-256 and permissions.
pub(super) struct Version<'a> {
    pub sha256: &'a str,
    pub permissions: u32,
}

/// What a line merge gave.
pub(super) enum Merged {
    /// The merged bytes and permissions: no overlapping edit.
    Clean { bytes: Vec<u8>, permissions: u32 },
    /// Overlapping edits: the merge with conflict markers.
    Overlap(Vec<u8>),
    /// Not merged by line (binary, too big, permissions, no base).
    Whole,
}

/// Whether `relative` is a conflict's merge file.
pub(super) fn is_conflict_file(relative: &str) -> bool {
    relative.to_ascii_lowercase().ends_with(CONFLICT_SUFFIX)
}

/// The merged permissions: the one side that changed them, or both alike.
fn permissions(base: u32, here: u32, machine: u32) -> Option<u32> {
    if here == machine || here == base {
        Some(machine)
    } else if machine == base {
        Some(here)
    } else {
        None
    }
}

fn read_capped(reader: impl std::io::Read) -> anyhow::Result<Option<Vec<u8>>> {
    use std::io::Read as _;
    let mut bytes = Vec::new();
    reader.take(TEXT_MAX + 1).read_to_end(&mut bytes)?;
    Ok((bytes.len() as u64 <= TEXT_MAX).then_some(bytes))
}

fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::Digest as _;
    sha2::Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Merges `relative` by line: `base` as the last sync left it, this Mac's
/// (`here`, read under `root`) and the machine's (`machine`, its copy at
/// `machine_copy`). Every version is checked against its hash.
pub(super) fn merge(
    root: &Dir,
    relative: &str,
    base: &Version<'_>,
    here: &Version<'_>,
    machine: &Version<'_>,
    machine_copy: &Path,
) -> anyhow::Result<Merged> {
    let Some(permissions) = permissions(base.permissions, here.permissions, machine.permissions)
    else {
        return Ok(Merged::Whole);
    };
    let Some(base_blob) = history::blob(base.sha256) else { return Ok(Merged::Whole) };
    let Some(base_bytes) = read_capped(std::fs::File::open(base_blob)?)? else {
        return Ok(Merged::Whole);
    };
    let Some((dir, name)) = place::parent_of(root, relative)? else { return Ok(Merged::Whole) };
    if !matches!(dir.entry(&name)?, Entry::File { .. }) {
        return Ok(Merged::Whole);
    }
    let Some(here_bytes) = read_capped(dir.open_file(&name)?)? else { return Ok(Merged::Whole) };
    let Some(machine_bytes) = read_capped(std::fs::File::open(machine_copy)?)? else {
        return Ok(Merged::Whole);
    };
    if sha256_hex(&base_bytes) != base.sha256
        || sha256_hex(&here_bytes) != here.sha256
        || sha256_hex(&machine_bytes) != machine.sha256
    {
        return Ok(Merged::Whole);
    }
    if [&base_bytes, &here_bytes, &machine_bytes].iter().any(|bytes| bytes.contains(&0)) {
        return Ok(Merged::Whole);
    }
    let mut options = diffy::MergeOptions::new();
    options.set_conflict_style(diffy::ConflictStyle::Diff3);
    Ok(match options.merge_bytes(&base_bytes, &here_bytes, &machine_bytes) {
        Ok(bytes) => Merged::Clean { bytes, permissions },
        Err(bytes) => Merged::Overlap(bytes),
    })
}

/// How many conflict file names a file gets: `NAME.cmux-sync-conflict`,
/// then `NAME.2.cmux-sync-conflict` up to this.
const CONFLICT_NAMES: u32 = 9;

/// Writes `bytes` beside `relative` under `root` as a conflict file, its
/// path relative to the folder. It never replaces anything: a name that is
/// taken (a merge from an earlier pull, the user's own file, a folder or a
/// symlink) is left as it is and the next name is used, except that a
/// regular file already holding exactly these bytes is the answer.
pub(super) fn write_conflict(root: &Dir, relative: &str, bytes: &[u8]) -> anyhow::Result<String> {
    let Some((dir, name)) = place::parent_of(root, relative)? else {
        anyhow::bail!("{relative} has no folder here");
    };
    for n in 1..=CONFLICT_NAMES {
        let side = if n == 1 {
            format!("{name}{CONFLICT_SUFFIX}")
        } else {
            format!("{name}.{n}{CONFLICT_SUFFIX}")
        };
        // Owner-only: it holds this Mac's, the machine's and the base's text.
        let placed = match dir.new_file(&side, bytes, 0o600) {
            Ok(()) => true,
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                matches!(dir.entry(&side)?, Entry::File { .. })
                    && dir
                        .open_file(&side)
                        .ok()
                        .and_then(|file| read_capped(file).ok().flatten())
                        .is_some_and(|there| there == bytes)
            }
            Err(error) => return Err(error.into()),
        };
        if placed {
            return Ok(match relative.rsplit_once('/') {
                Some((folder, _)) => format!("{folder}/{side}"),
                None => side,
            });
        }
    }
    anyhow::bail!("every conflict file name for {relative} is taken; nothing was replaced")
}
