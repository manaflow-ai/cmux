//! A sealed log segment's records of the kinds a chat's log load reads, kept beside the log.
//!
//! A restored chat's first open waits for its log load (`hub/log_load.rs`), and the load scans the
//! whole log for its queue, turn, branch and agent pair records (`restore_queue`,
//! `mark_unknown_outcome`): a 102 MB Codex log read 307 MB before its open page (`cold_open_perf`,
//! 2026-10-30). Those records are few. Once a segment is sealed (a newer one is written) it never
//! changes but by a retention rewrite (`store/compact.rs`), so its records of [`INDEXED_KINDS`] are
//! copied, as written, to `<session>/events-index/NNNNNN.ndjson` the first time a scan reads the
//! whole segment ([`LocalStore::scan_kinds`]), and a later scan for those kinds reads the copy.
//!
//! The copy's first line names the segment it was read from: its length and modification time. A
//! copy that does not match its segment (rewritten, replaced, or another log's after a move) is
//! read past and made again. A copy is written whole under a temporary name and renamed into
//! place, so a crash leaves the old copy or none. The newest segment, which appends go to, has no
//! copy. Nothing is written on the append path, and a chat's folder is deleted with its copies.

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

/// What a copy was read from.
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Header {
    schema: String,
    /// The segment's length and modification time (ns since the epoch).
    len: u64,
    modified_ns: u64,
}

impl Header {
    fn of(segment: &std::fs::Metadata) -> Self {
        let modified_ns = segment
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map_or(0, |d| d.as_nanos() as u64);
        Self { schema: SCHEMA.into(), len: segment.len(), modified_ns }
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

    /// The copied lines of sealed segment `index` at `path`, when the copy still matches it.
    pub(super) fn read_kind_index(&self, id: &str, index: u32, path: &Path) -> Option<Vec<u8>> {
        let segment = std::fs::symlink_metadata(path).ok()?;
        let copy = self.kind_index_path(id, index);
        let mut bytes = Vec::new();
        crate::config::private_state_file(&copy).ok()?.read_to_end(&mut bytes).ok()?;
        let end = bytes.iter().position(|b| *b == b'\n')?;
        let header: Header = serde_json::from_slice(&bytes[..end]).ok()?;
        (header == Header::of(&segment)).then(|| bytes.split_off(end + 1))
    }

    /// Saves `lines`, the indexed lines of sealed segment `index` as read from a file with
    /// `segment`'s metadata.
    pub(super) fn write_kind_index(
        &self,
        id: &str,
        index: u32,
        segment: &std::fs::Metadata,
        lines: &[u8],
    ) -> Result<()> {
        let dir = self.dir(id).join(DIR);
        crate::config::private_state_dir(&dir)?;
        let mut out = serde_json::to_vec(&Header::of(segment))?;
        out.push(b'\n');
        out.extend_from_slice(lines);
        write_atomic(&self.kind_index_path(id, index), &out)
    }
}

#[cfg(test)]
#[path = "kind_index_tests.rs"]
mod tests;
