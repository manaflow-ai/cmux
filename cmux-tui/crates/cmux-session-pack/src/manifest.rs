//! A pack's manifest: the one file of a session that changes.

use crate::Result;
use crate::store::{Id, Store, unhex, write_atomic};
use serde::{Deserialize, Serialize};

/// The manifest's schema.
pub const SCHEMA: &str = "cmux.session-pack.v1";

/// Which lines this build marks as turn starts: 1 is acpmux's records of a kind in
/// [`Params::marks`] and a Claude Code transcript's prompts. A manifest written before
/// transcripts had turns has no `turnRule`, which reads as 0 (acpmux's records only).
pub const TURN_RULE: u32 = 1;

/// How a log was cut and compressed. Two packs of the same log with the same `Params` hold the
/// same chunks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Params {
    /// A segment is sealed once it holds this many bytes of lines.
    pub segment_bytes: u64,
    /// A JSON string of at least this many bytes is stored once, as a blob.
    pub blob_min: u32,
    /// The zstd level.
    pub level: i32,
    /// The `kind`s of the acpmux records that start a turn; the manifest lists their lines.
    pub marks: Vec<String>,
}

impl Default for Params {
    /// The values the RFD's measurements chose: 4 MiB segments (16 MiB gains 1% and makes every
    /// read four times the work), blobs from 384 bytes (128 gains under 1% and triples the
    /// table), level 19 (22 gains nothing).
    fn default() -> Self {
        Self {
            segment_bytes: 4 << 20,
            blob_min: 384,
            level: 19,
            marks: vec!["turn_started".into()],
        }
    }
}

/// One segment of the log.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Segment {
    /// Its first line's number.
    pub line: u64,
    /// How many lines it holds.
    pub lines: u64,
    /// Those lines' bytes in the log.
    pub raw: u64,
    /// BLAKE3 of those bytes.
    pub raw_hash: String,
    /// The least and greatest `seq` of its acpmux records, when it holds any.
    pub seq: Option<(u64, u64)>,
    /// The number of the first blob it was the first to hold.
    pub blob: u64,
    /// How many blobs it was the first to hold.
    pub blobs: u64,
    /// Its events chunk.
    pub events: String,
    /// Its blobs chunk and blob table chunk, when `blobs` is not 0.
    pub blob_chunks: Option<(String, String)>,
    /// Whether it is full, and so never changes.
    pub sealed: bool,
    /// The size of its chunk files.
    pub stored: u64,
    /// The numbers of its lines that start a turn: an acpmux record of a kind in
    /// [`Params::marks`], or a Claude Code transcript's prompt.
    pub marks: Vec<u64>,
}

impl Segment {
    /// Its chunks' ids.
    pub fn chunk_ids(&self) -> Result<Vec<Id>> {
        let mut ids = vec![unhex(&self.events)?];
        if let Some((b, t)) = &self.blob_chunks {
            ids.push(unhex(b)?);
            ids.push(unhex(t)?);
        }
        Ok(ids)
    }
}

/// A session's pack.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    /// [`SCHEMA`].
    pub schema: String,
    /// The session's name in the store.
    pub name: String,
    /// How many lines the log holds.
    pub lines: u64,
    /// The log's size.
    pub raw_bytes: u64,
    /// Whether the log ends with a newline. When it does not, its last line is an append still
    /// under way, and the segment that holds it is not sealed.
    pub final_newline: bool,
    /// How it was packed.
    pub params: Params,
    /// The [`TURN_RULE`] its segments' marks were found by (0 when the manifest predates it).
    #[serde(default)]
    pub turn_rule: u32,
    /// Its segments, in order.
    pub segments: Vec<Segment>,
}

impl Manifest {
    /// `name`'s manifest in `store`, or `None` when the store holds no such session.
    pub fn load(store: &Store, name: &str) -> Result<Option<Self>> {
        check_name(name)?;
        let path = store.manifest_path(name);
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("{}: {e}", path.display()).into()),
        };
        Ok(Some(Self::parse(&bytes).map_err(|e| format!("{}: {e}", path.display()))?))
    }

    /// A manifest from its JSON.
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let m: Self = serde_json::from_slice(bytes)?;
        if m.schema != SCHEMA {
            return Err(format!("schema {:?}, and this build reads {SCHEMA:?}", m.schema).into());
        }
        check_name(&m.name)?;
        Ok(m)
    }

    /// Its JSON.
    pub fn to_json(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    /// Puts it in place in `store`.
    pub fn save(&self, store: &Store) -> Result<()> {
        check_name(&self.name)?;
        write_atomic(&store.manifest_path(&self.name), &self.to_json()?)
    }

    /// Every chunk it names, in order, each once.
    pub fn chunk_ids(&self) -> Result<Vec<Id>> {
        let mut seen = std::collections::HashSet::new();
        let mut ids = Vec::new();
        for s in &self.segments {
            for id in s.chunk_ids()? {
                if seen.insert(id) {
                    ids.push(id);
                }
            }
        }
        Ok(ids)
    }

    /// The size of its chunk files.
    pub fn stored_bytes(&self) -> u64 {
        self.segments.iter().map(|s| s.stored).sum()
    }

    /// Every line that starts a turn, in order.
    pub fn marks(&self) -> impl DoubleEndedIterator<Item = u64> + '_ {
        self.segments.iter().flat_map(|s| s.marks.iter().copied())
    }

    /// The line at which the last `turns` turns start (0 when the log holds fewer).
    pub fn tail_turns(&self, turns: usize) -> u64 {
        if turns == 0 {
            return self.lines;
        }
        self.marks().rev().nth(turns - 1).unwrap_or(0)
    }
}

/// A session's name is a file name: no separators, no leading dot.
pub fn check_name(name: &str) -> Result<()> {
    let ok = !name.is_empty()
        && !name.starts_with('.')
        && name.len() <= 200
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'));
    if ok {
        Ok(())
    } else {
        Err(format!("session name {name:?}: letters, digits, - _ . only").into())
    }
}

/// The name of a range of a session's lines, `<session>@<first>-<last>` (both included): what a
/// compaction summary keeps in place of the text it summarized.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RangeId {
    /// The session.
    pub name: String,
    /// The first line.
    pub first: u64,
    /// The last line.
    pub last: u64,
}

impl RangeId {
    /// The range a name names.
    pub fn parse(s: &str) -> Result<Self> {
        let bad = || format!("range {s:?} is not <session>@<first line>-<last line>");
        let (name, lines) = s.rsplit_once('@').ok_or_else(bad)?;
        let (first, last) = lines.split_once('-').ok_or_else(bad)?;
        let (first, last) = (first.parse().map_err(|_| bad())?, last.parse().map_err(|_| bad())?);
        check_name(name)?;
        if first > last {
            return Err(bad().into());
        }
        Ok(Self { name: name.to_owned(), first, last })
    }
}

impl std::fmt::Display for RangeId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}@{}-{}", self.name, self.first, self.last)
    }
}
