//! Segments zstd'd in place: `events/NNNNNN.ndjson.zst` where `NNNNNN.ndjson` was.
//!
//! A shipped acpmux never writes these. On one host every segment of 133 closed chats was
//! compressed in place during a disk-pressure episode (cmuxterm-hq
//! docs/findings/2026-11-23-acpmux-orphan-zst-chats.md), most likely by an unmerged build that
//! compressed closed chats' logs (level 9, long-distance matching, a 2^27 window). The listing saw no `.ndjson`, a closed
//! chat with no log reads as a purged one (`LocalStore::has_records`), and the chats were gone
//! from the list and from `acpmux last`.
//!
//! Now the segment listing notes a sealed segment with no plain one of its name
//! (`store/segment_table.rs`), such a chat has records, and its first read of the log decodes
//! each one back to `NNNNNN.ndjson` ([`LocalStore::thaw_sealed`]) before anything else reads or
//! appends: an append never starts a new `000001.ndjson` beside a sealed `000001.ndjson.zst`.
//! Decoding is beside the segment under a temporary name, synced, renamed into place, the folder
//! synced, and only then the sealed copy removed: a crash leaves the sealed copy, a whole plain
//! segment, or both, and a plain segment always wins over a sealed one of the same name. A
//! sealed segment that does not decode (cut short, not zstd) is renamed `.unreadable` and kept,
//! so it is not tried again on every read; the chat reads with the segments that did.

use super::*;

/// A sealed segment's suffix.
pub(super) const SUFFIX: &str = ".ndjson.zst";
/// A decode in progress, beside the sealed segment.
const THAW_SUFFIX: &str = ".ndjson.zst-thaw";
/// A sealed segment that did not decode, kept as it was.
const UNREADABLE_SUFFIX: &str = ".ndjson.zst.unreadable";

/// The plain segment name a sealed segment's name stands for (`000003.ndjson.zst` to
/// `000003.ndjson`), or None for any other name.
pub(super) fn plain_name(name: &str) -> Option<&str> {
    let stem = name.strip_suffix(SUFFIX)?;
    if !stem.bytes().all(|b| b.is_ascii_digit()) || stem.parse::<u32>().is_err() {
        return None;
    }
    name.strip_suffix(".zst")
}

/// Decodes the zstd file `from` into a new owner-only file `to`, synced; the bytes written.
fn decode_into(from: &Path, to: &Path) -> Result<u64> {
    let file = crate::home_fs::private_state_file(from)?;
    let mut decoder = zstd::stream::read::Decoder::new(file)?;
    // A writer with long-distance matching may use a window past zstd's 128 MiB default limit.
    decoder.window_log_max(31)?;
    let out = crate::config::private_state_create_new(to)?;
    let mut out = std::io::BufWriter::with_capacity(256 * 1024, out);
    let copied = std::io::copy(&mut decoder, &mut out)?;
    out.into_inner().map_err(|e| e.into_error())?.sync_all()?;
    Ok(copied)
}

impl LocalStore {
    /// Decodes every sealed segment of `id`'s log that has no plain segment of its name back
    /// into place ([module docs](self)); how many it put back. Under the cold lock, so no
    /// archive or rehydrate of the chat runs meanwhile; refused once the store is sealed.
    pub(super) fn thaw_sealed(&self, id: &str) -> Result<usize> {
        let _cold = self.cold.lock(id);
        let _sealed = self.unsealed(id)?;
        let events = self.dir(id).join("events");
        crate::config::refuse_lost_home(&events)?;
        let entries = match crate::home_fs::read_dir(&events) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(0),
            Err(e) => return Err(e.into()),
        };
        let names: HashSet<String> =
            entries.iter().map(|e| e.name.to_string_lossy().into_owned()).collect();
        let mut sealed: Vec<(&str, &str)> = entries
            .iter()
            .filter(|e| e.is_file)
            .filter_map(|e| {
                let name = e.name.to_str()?;
                Some((name, plain_name(name)?))
            })
            .filter(|(_, plain)| !names.contains(*plain))
            .collect();
        sealed.sort();
        let started = std::time::Instant::now();
        let mut thawed = Vec::new();
        let mut bytes = 0u64;
        for (name, plain) in sealed {
            let from = events.join(name);
            let stem = plain.strip_suffix(".ndjson").unwrap_or(plain);
            let tmp = events.join(format!("{stem}{THAW_SUFFIX}"));
            let _ = crate::home_fs::remove_file(&tmp);
            match decode_into(&from, &tmp) {
                Ok(n) => {
                    crate::home_fs::rename(&tmp, events.join(plain))?;
                    bytes += n;
                    thawed.push(from);
                }
                Err(e) => {
                    let _ = crate::home_fs::remove_file(&tmp);
                    let kept = events.join(format!("{stem}{UNREADABLE_SUFFIX}"));
                    tracing::warn!(session = %id, "a sealed segment {name} does not decode, kept as {}: {e:#}", kept.display());
                    crate::home_fs::rename(&from, &kept)?;
                }
            }
        }
        self.segment_table.forget(id);
        if thawed.is_empty() {
            return Ok(0);
        }
        sync_directory(&events)?;
        for from in &thawed {
            crate::home_fs::remove_file(from)?;
        }
        sync_directory(&events)?;
        self.segment_table.forget(id);
        tracing::info!(
            session = %id,
            segments = thawed.len(),
            bytes,
            ms = started.elapsed().as_millis() as u64,
            "decoded segments zstd'd in place back into the log"
        );
        Ok(thawed.len())
    }
}

#[cfg(all(test, unix))]
#[path = "sealed_segments_tests.rs"]
mod tests;
