//! A log segment's records of the kinds a chat's log load reads, kept beside the log.
//!
//! A restored chat's first open waits for its log load (`hub/log_load.rs`), and the load scans the
//! whole log for its queue, turn, branch and agent pair records (`restore_queue`,
//! `mark_unknown_outcome`): a 102 MB Codex log read 307 MB before its open page (`cold_open_perf`,
//! 2026-10-30). Those records are few. A segment is only ever appended to, or replaced whole by a
//! rename (a retention rewrite, `store/compact.rs`). So a scan for [`INDEXED_KINDS`]
//! ([`LocalStore::scan_kinds`]) copies a segment's records of those kinds, as written, to
//! `<session>/events-index/NNNNNN.ndjson`, with the file they came from (device and inode) and
//! how many of its bytes they cover; a later scan reads the copy, then the segment past those
//! bytes only.
//!
//! A copy whose file is gone (replaced, or another log's after a move) or shorter than it covers
//! is read past and made again. A copy is written whole under a temporary name and renamed into
//! place, so a crash leaves the old copy or none. A scan writes one when it had none or read at
//! least [`COPY_AFTER`] bytes past it; nothing is written on the append path, and a chat's folder
//! is deleted with its copies.

use super::*;

/// The kinds a chat's log load reads (`hub/queue.rs` `QUEUE_KINDS`, which a test keeps within
/// these, and `hub/log_load.rs` `mark_unknown_outcome`): a scan for these only reads the copies.
pub const INDEXED_KINDS: &[&str] = &[
    "git",
    "queued",
    "transfer_out",
    "transfer_aborted",
    "imported",
    "dequeued",
    "queue_removed",
    "user_message",
    "turn_started",
    "queue_updated",
    "queue_paused",
    "queue_resumed",
    "queue_order",
    "turn_result",
    "prompt_refused",
    "agent_pair_held",
    "agent_pair_released",
    "agent_pair_dropped",
    "agent_pair_paused",
    "agent_pair_resumed",
];

/// The folder of a chat's copies, beside its `events`.
pub const DIR: &str = "events-index";
const SCHEMA: &str = "acpmux.kind-index.v1";

/// A scan that read this many bytes of a segment past its copy saves the copy again.
pub(super) const COPY_AFTER: u64 = 1 << 20;

/// What a copy was read from: the segment file, and the bytes of it the copy covers.
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Header {
    schema: String,
    dev: u64,
    ino: u64,
    len: u64,
}

/// The file `meta` is of.
fn file_id(meta: &std::fs::Metadata) -> (u64, u64) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        (meta.dev(), meta.ino())
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        (0, 0)
    }
}

/// Whether a line belongs in a copy: its kind is indexed, or its head does not say (it is parsed
/// where it is read, as the segment's would be).
pub(super) fn indexed(line: &[u8]) -> bool {
    record_kind(line).is_none_or(|kind| INDEXED_KINDS.iter().any(|k| k.as_bytes() == kind))
}

impl LocalStore {
    fn kind_index_path(&self, id: &str, index: u32) -> PathBuf {
        self.dir(id).join(DIR).join(format!("{index:06}.ndjson"))
    }

    /// The copied lines of segment `index` at `path`, and the bytes of it they cover, when the
    /// copy is of that file.
    pub(super) fn read_kind_index(
        &self,
        id: &str,
        index: u32,
        path: &Path,
    ) -> Option<(Vec<u8>, u64)> {
        let segment = std::fs::symlink_metadata(path).ok()?;
        let mut bytes = Vec::new();
        let copy = self.kind_index_path(id, index);
        crate::config::private_state_file(&copy).ok()?.read_to_end(&mut bytes).ok()?;
        let end = bytes.iter().position(|b| *b == b'\n')?;
        let header: Header = serde_json::from_slice(&bytes[..end]).ok()?;
        let (dev, ino) = file_id(&segment);
        let same = header.schema == SCHEMA && (header.dev, header.ino) == (dev, ino);
        (same && segment.len() >= header.len).then(|| (bytes.split_off(end + 1), header.len))
    }

    /// Saves `lines`, the indexed lines of the first `len` bytes of segment `index`, read from a
    /// file with metadata `segment`.
    pub(super) fn write_kind_index(
        &self,
        id: &str,
        index: u32,
        segment: &std::fs::Metadata,
        len: u64,
        lines: &[u8],
    ) -> Result<()> {
        let dir = self.dir(id).join(DIR);
        crate::config::private_state_dir(&dir)?;
        let (dev, ino) = file_id(segment);
        let mut out = serde_json::to_vec(&Header { schema: SCHEMA.into(), dev, ino, len })?;
        out.push(b'\n');
        out.extend_from_slice(lines);
        write_atomic(&self.kind_index_path(id, index), &out)
    }
}

#[cfg(test)]
#[path = "kind_index_tests.rs"]
mod tests;
