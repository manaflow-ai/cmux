//! The projection's whiteouts log (`state/whiteouts`): the lower paths a layer deleted, as
//! NUL-ended entries replayed in order. A path whites out; `/` and a path is its tombstone (the
//! path made again). [`crate::overlay`] appends one entry per change and compacts the log by the
//! rules here; [`crate::layer`] and [`crate::reap`] read it with [`parse_whiteouts`].

use std::collections::BTreeSet;
use std::fs;

/// The whiteouts log is compacted (written again as its live paths) once it holds more than this
/// many times its live paths ...
pub(crate) const WHITEOUTS_COMPACT_FACTOR: usize = 2;
/// ... plus this many entries, so a log stays linear in the changes made, and a small one is never
/// rewritten.
pub(crate) const WHITEOUTS_COMPACT_SLACK: usize = 1024;

/// The whiteouts `bytes` leave, replayed in order (each entry ended by a NUL, or by a newline in an
/// older file; a path whites out, `/` and a path is its tombstone); a last entry without its end is
/// a torn append, cut off as bytes (a crash can tear a name inside a multi-byte character). Each
/// entry is decoded alone: one that is not UTF-8 is skipped, never the file with it. Says too how
/// many whole entries the log holds, and whether the file must be written again (a torn tail to
/// cut, an entry skipped, or the older format, so the next append starts an entry of its own).
pub(crate) fn parse_whiteouts(bytes: &[u8]) -> (BTreeSet<String>, usize, bool) {
    let ends = if bytes.contains(&0) { 0 } else { b'\n' };
    let mut skipped = false;
    let mut logged = 0;
    let mut live = BTreeSet::new();
    for entry in bytes
        .split_inclusive(|byte| *byte == ends)
        .filter_map(|path| path.strip_suffix(&[ends]))
        .filter(|path| !path.is_empty())
    {
        let Ok(entry) = std::str::from_utf8(entry) else {
            skipped = true;
            continue;
        };
        logged += 1;
        match entry.strip_prefix('/') {
            Some(gone) => {
                live.remove(gone);
            }
            None => {
                live.insert(entry.to_owned());
            }
        }
    }
    (live, logged, !bytes.is_empty() && (ends != 0 || bytes.last() != Some(&0) || skipped))
}

/// Whether a whiteouts log of `logged` entries leaving `live` paths is due to be compacted.
pub(crate) fn whiteouts_due(logged: usize, live: usize) -> bool {
    logged > live.saturating_mul(WHITEOUTS_COMPACT_FACTOR).saturating_add(WHITEOUTS_COMPACT_SLACK)
}

/// Appends `bytes` to `file` through `write`; when that fails part way (a full disk), cuts the
/// file back to where it was, so no unterminated entry is left for the next append to glue onto.
pub(crate) fn append_entry(
    file: &mut fs::File,
    bytes: &[u8],
    write: impl FnOnce(&mut fs::File, &[u8]) -> std::io::Result<()>,
) -> std::io::Result<()> {
    let len = file.metadata()?.len();
    let written = write(file, bytes);
    if written.is_err() {
        // A cut that fails too leaves the caller's full rewrite to end the torn entry.
        file.set_len(len)?;
    }
    written
}
