//! A chat's scrollback goes on past its Claude Code transcript into the ones it continued (Leo
//! 2026-11-22: "i want to be able to scroll up to see all of them when you get resumed. cmux next
//! should be able to do that. stich things together.").
//!
//! A Claude chat's agent can come back under a new Claude session id: a resume Claude refused
//! starts a fresh conversation (`lifecycle.rs` `resume_failed`), a fork primes a new one. The
//! daemon keeps every earlier Claude id it recorded for the chat, oldest first
//! (`SessionMeta::previous_agent_session_ids`), and only those: a transcript is never read on
//! the word of another transcript.
//!
//! `_acpmux/native_history` pages one transcript back to its first byte (`native_history.rs`).
//! When it gets there and the chat continued an earlier transcript, the reply ([`Hop`]):
//! - starts with muted dividers (`host_notice`, the pane's notice row): "resumed HH:MMZ" where
//!   the newer transcript began, and "earlier transcript not found" for each earlier id whose
//!   file is gone (that one is skipped, never an error);
//! - gives the older transcript's end as the next cursor, with a chained mark
//!   (`c1:<depth>:<id>:<mark>`) naming which transcript it is and how far back, and says so
//!   (`olderTranscript`): the cursor jumps forward in bytes, as only a new transcript's does.
//!
//! Every transcript `depth` back has its own seq band, all below the seeded transcript's
//! (`native_history::native_seq`) and each below the newer one, so the pane sorts them oldest
//! first: depth d holds `[-2^52 - d·2^47, -2^52 - (d-1)·2^47)`, a 64-byte cursor bucket by
//! 2^18 records, safe in JavaScript down to [`MAX_DEPTH`]. Within a transcript a Claude Code
//! compaction (its `isCompactSummary` line) shows as a "compacted" divider before the turn
//! after it.
//!
//! Memory stays one page's: a hop reads only file metadata and the mark's 4 KiB, never the
//! older transcript; its pages come one request at a time as the pane asks.

use crate::store::SessionMeta;
use serde_json::{Value, json};
use std::path::Path;

/// The prefix of a mark naming an earlier transcript of the chat.
const CHAIN_PREFIX: &str = "c1:";
/// How many transcripts back a chat's scrollback goes; each depth is a seq band.
pub(super) const MAX_DEPTH: u32 = 31;
/// A depth's seq band, under the seeded transcript's 2^52.
const BAND_BITS: u32 = 47;
/// A record's place on its page (as `native_history::KEY_BITS`).
const KEY_BITS: u32 = 18;
/// Cursor bytes per bucket: two page ends are at least one Claude Code line apart, and every
/// line carries ids and a timestamp, well past 64 bytes. 2^29 buckets: 32 GiB per transcript.
const BUCKET_SHIFT: u32 = 6;
/// What a `host_notice` divider says it came from: never the pane's skipped `resume` source.
const SOURCE: &str = "transcript";

/// A chained mark: transcript `id`, `depth` transcripts before the seeded one, and the
/// `native_history` mark of its cursor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Chained {
    pub depth: u32,
    pub id: String,
    pub inner: String,
}

/// The chained mark `mark` names; None for a seeded transcript's own mark.
pub(super) fn parse(mark: &str) -> Option<Chained> {
    let rest = mark.strip_prefix(CHAIN_PREFIX)?;
    let (depth, rest) = rest.split_once(':')?;
    let (id, inner) = rest.split_once(':')?;
    let depth = depth.parse::<u32>().ok().filter(|d| (1..=MAX_DEPTH).contains(d))?;
    super::subagent_transcript::plain_id(id).then(|| Chained {
        depth,
        id: id.to_owned(),
        inner: inner.to_owned(),
    })
}

pub(super) fn chain_mark(depth: u32, id: &str, inner: &str) -> String {
    format!("{CHAIN_PREFIX}{depth}:{id}:{inner}")
}

/// Whether the chat recorded `id` as one of its own earlier Claude ids: the only transcripts a
/// chained cursor may read.
pub(super) fn authorized(meta: &SessionMeta, id: &str) -> bool {
    meta.previous_agent_session_ids.iter().any(|known| known == id)
}

/// The Claude ids before `seed` (the transcript just paged to its start), newest first. A seed
/// that is the current id has every earlier one before it; one the chat recorded earlier, those
/// recorded before it; anything else (a watched file) none.
pub(super) fn older_ids(meta: &SessionMeta, seed: Option<&str>) -> Vec<String> {
    let Some(seed) = seed else { return Vec::new() };
    let previous = &meta.previous_agent_session_ids;
    let upto = if meta.agent_session_id.as_deref() == Some(seed)
        && meta.agent_session_family.as_deref().is_none_or(|f| f == "claude")
    {
        previous.len()
    } else if let Some(at) = previous.iter().position(|id| id == seed) {
        at
    } else {
        return Vec::new();
    };
    previous.iter().take(upto).rev().cloned().collect()
}

/// The seq of the `k`th record of the page ending at `before`, `depth` transcripts back
/// (depth 0 is the seeded transcript's own `native_seq`).
pub(super) fn seq(depth: u32, before: u64, k: usize) -> i64 {
    if depth == 0 {
        return super::native_history::native_seq(before, k);
    }
    debug_assert!(depth <= MAX_DEPTH && k < 1 << KEY_BITS);
    let bucket = (before >> BUCKET_SHIFT).min((1 << (BAND_BITS - KEY_BITS)) - 1) as i64;
    let low = -(1i64 << 52) - i64::from(depth) * (1i64 << BAND_BITS);
    low + ((bucket << KEY_BITS) | k as i64)
}

/// The `(dev, ino)` a `v1` mark was taken on.
pub(super) fn identity(mark: &str) -> Option<(u64, u64)> {
    let mut fields = mark.split(':');
    (fields.next()? == "v1").then_some(())?;
    Some((fields.next()?.parse().ok()?, fields.next()?.parse().ok()?))
}

/// The cursor the reply gives when it goes on into an older transcript.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct Next {
    pub id: String,
    pub depth: u32,
    /// The older transcript's length: its newest page ends there.
    pub before: u64,
    pub mark: String,
}

/// What a page that reached its transcript's start adds: the dividers over it and where
/// paging goes on.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(super) struct Hop {
    /// Earlier ids, oldest first, whose transcript is not on disk.
    pub missing: Vec<String>,
    pub next: Option<Next>,
}

impl Hop {
    pub fn is_empty(&self) -> bool {
        self.missing.is_empty() && self.next.is_none()
    }

    /// The divider texts, oldest first: a missing transcript is older than the join it ends at.
    pub fn dividers(&self, joined_at: Option<u64>) -> Vec<String> {
        let mut out: Vec<String> =
            self.missing.iter().map(|_| "earlier transcript not found".to_owned()).collect();
        if !self.is_empty() {
            out.push(match joined_at {
                Some(ms) => format!("resumed {}", clock(ms)),
                None => "resumed".to_owned(),
            });
        }
        out
    }
}

/// Where paging goes on from the transcript `depth` back, given the ids before it (newest first,
/// [`older_ids`]): the first whose file is in `home`; the ones before it that are not are
/// missing. Reads directory entries and one 4 KiB mark, nothing more.
pub(super) fn hop(home: Option<&Path>, older: &[String], depth: u32) -> Hop {
    let mut hop = Hop::default();
    for (n, id) in older.iter().enumerate() {
        let depth = depth + 1 + n as u32;
        if depth > MAX_DEPTH || !super::subagent_transcript::plain_id(id) {
            break;
        }
        let found = home.and_then(|home| crate::adopt::find_claude(home, id));
        let next = found.and_then(|file| {
            let mut input = std::fs::File::open(&file).ok()?;
            let before = input.metadata().ok()?.len();
            let inner = super::native_history::mark(&mut input, before)?;
            Some(Next { id: id.clone(), depth, before, mark: chain_mark(depth, id, &inner) })
        });
        match next {
            Some(next) => {
                hop.next = Some(next);
                break;
            }
            None => hop.missing.insert(0, id.clone()),
        }
    }
    hop
}

/// The id among `ids` (newest first) whose transcript in `home` is the file `mark` was taken on:
/// a seeded cursor whose chat has since resumed under a new id still reads its own transcript.
pub(super) fn seeded_by_mark(
    home: &Path,
    ids: &[String],
    mark: &str,
) -> Option<(String, std::path::PathBuf)> {
    let want = identity(mark)?;
    ids.iter().filter(|id| super::subagent_transcript::plain_id(id)).find_map(|id| {
        let file = crate::adopt::find_claude(home, id)?;
        let meta = std::fs::metadata(&file).ok()?;
        (file_identity(&meta) == want).then(|| (id.clone(), file))
    })
}

fn file_identity(meta: &std::fs::Metadata) -> (u64, u64) {
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

/// A muted divider row (`host_notice`, as the pane draws a notice).
pub(super) fn divider(session_id: &str, seq: i64, at: u64, text: &str) -> Value {
    json!({"sessionId": session_id, "seq": seq, "at": at, "dir": "mux", "kind": "host_notice",
        "msg": {"text": text, "source": SOURCE}})
}

/// `HH:MMZ` of a time in ms since the epoch.
fn clock(ms: u64) -> String {
    let secs = ms / 1000;
    format!("{:02}:{:02}Z", (secs / 3600) % 24, (secs / 60) % 60)
}

#[cfg(test)]
#[path = "native_history_chain_tests.rs"]
mod tests;
