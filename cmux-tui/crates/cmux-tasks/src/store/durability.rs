//! Where a group commit must reach before the owner answers (decision T1,
//! plans/cmux-next/tasks.md section 14 item 2; plans/cmux-next/server.md 7.3).
//!
//! The store always appends and fsyncs locally. Two more pieces sit behind
//! one interface so the storage tier can change without touching the store:
//!
//! - `Replica`: called once per group commit, after the local fsync and
//!   before any reply. On a mounted zero-loss tier whose fsync is the
//!   acknowledgement the replica is `NoopReplica`. On a cmux server, and in
//!   the fallback without a mount, an implementation ships the bytes to R2
//!   under the contract on the trait (create-if-absent keyed by `seq` alone,
//!   epoch in the body). A failure stops the writer.
//! - `EpochFence`: the supervisor's lease epoch (`CMUX_APP_EPOCH`). At open
//!   the store creates `epoch-<n>` with `O_EXCL` beside `LOCK` and refuses to
//!   open when a newer epoch file exists; every group commit checks again
//!   before it writes, so a stale host that resumes after a restore stops
//!   writing instead of forking the log.

use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

/// Ships group commits to the durable tier.
///
/// Contract for implementations (review of slice 2):
/// - The create must be conditional on the sequence alone (create-if-absent
///   of `seq`), with the epoch in the object's body or metadata. A key of
///   `(epoch, seq)` is not a fence: a stale and a new owner would both
///   create "their" `seq`.
/// - The commit must refuse when the tier has seen a higher epoch (an epoch
///   high-water object, or a refused create under a higher epoch prefix).
/// - `high_water` reports the last sequence the tier acknowledged, so the
///   store re-ships a local tail that a crash left unshipped before it
///   serves.
pub trait Replica: Send {
    /// `bytes` are the records `first_seq..=last_seq` as JSON lines, exactly
    /// as appended to the local log. Return only after the tier acknowledged
    /// them.
    fn commit(&mut self, epoch: u64, first_seq: u64, last_seq: u64, bytes: &[u8])
    -> io::Result<()>;

    /// The last sequence the tier holds, or `None` when the local log is the
    /// durable copy (no replica).
    fn high_water(&mut self) -> io::Result<Option<u64>>;

    /// The largest range one `commit` may carry. The store splits a group
    /// commit and the re-ship of an unshipped tail into consecutive ranges
    /// of whole records under this limit, in order. `None` = no limit.
    fn range_limit(&self) -> Option<RangeLimit> {
        None
    }
}

/// The most one replica call may carry.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RangeLimit {
    /// Bytes of log lines per range.
    pub max_bytes: usize,
    /// Sequences per range.
    pub max_seqs: u64,
}

impl RangeLimit {
    /// The TeamVmDO journal (team VM plan, e4c59605b9e): at most 1 MiB of
    /// decoded bytes and 100,000 sequences per `journal.append`.
    pub const TEAM_VM_JOURNAL: Self = Self { max_bytes: 1 << 20, max_seqs: 100_000 };
}

/// Split consecutive log lines (their byte lengths, in order) into ranges
/// under `limit`. Each range holds whole lines and at least one line.
/// `Err(index)` names the first line that alone exceeds `max_bytes`: it can
/// never ship, so the caller refuses it before the local append.
pub fn split_ranges(
    line_lens: &[usize],
    limit: RangeLimit,
) -> Result<Vec<std::ops::Range<usize>>, usize> {
    let max_seqs = usize::try_from(limit.max_seqs.max(1)).unwrap_or(usize::MAX);
    let mut ranges = Vec::new();
    let mut start = 0;
    let mut bytes = 0usize;
    for (i, len) in line_lens.iter().copied().enumerate() {
        if len > limit.max_bytes {
            return Err(i);
        }
        if i > start && (bytes + len > limit.max_bytes || i - start >= max_seqs) {
            ranges.push(start..i);
            start = i;
            bytes = 0;
        }
        bytes += len;
    }
    if start < line_lens.len() {
        ranges.push(start..line_lens.len());
    }
    Ok(ranges)
}

/// The TeamVmDO journal as seen from the owner (team VM plan slices S6 and
/// S7): `journal.append {stream, epoch, seq, bytes}` is create-if-absent
/// keyed by `(stream, seq)` with the epoch in the record, refused after a
/// higher epoch, and durable on return; `journal.high_water {stream}` is the
/// last sequence it holds (0 when empty).
pub trait Journal: Send {
    fn append(
        &mut self,
        stream: &str,
        epoch: u64,
        first_seq: u64,
        last_seq: u64,
        bytes: &[u8],
    ) -> io::Result<()>;

    fn high_water(&mut self, stream: &str) -> io::Result<u64>;
}

/// The replica on the team VM: each range goes to one journal append on the
/// owner's stream, under the journal's limits.
pub struct JournalReplica<J> {
    stream: String,
    journal: J,
}

impl<J: Journal> JournalReplica<J> {
    pub fn new(stream: impl Into<String>, journal: J) -> Self {
        Self { stream: stream.into(), journal }
    }
}

impl<J: Journal> Replica for JournalReplica<J> {
    fn commit(&mut self, epoch: u64, first: u64, last: u64, bytes: &[u8]) -> io::Result<()> {
        self.journal.append(&self.stream, epoch, first, last, bytes)
    }

    fn high_water(&mut self) -> io::Result<Option<u64>> {
        self.journal.high_water(&self.stream).map(Some)
    }

    fn range_limit(&self) -> Option<RangeLimit> {
        Some(RangeLimit::TEAM_VM_JOURNAL)
    }
}

/// Ship `records` (consecutive sequences; `lines` are their log lines in
/// order) through `replica`, one call per range under its limit.
pub(super) fn ship(
    replica: &mut dyn Replica,
    epoch: u64,
    seqs: &[u64],
    lines: &[&[u8]],
) -> io::Result<()> {
    if seqs.len() != lines.len() {
        return Err(io::Error::other("replica ship: records and lines differ"));
    }
    if seqs.is_empty() {
        return Ok(());
    }
    let ranges = match replica.range_limit() {
        Some(limit) => {
            let lens: Vec<usize> = lines.iter().map(|l| l.len()).collect();
            split_ranges(&lens, limit).map_err(|i| oversize(seqs[i], lens[i], limit))?
        }
        None => std::iter::once(0..seqs.len()).collect(),
    };
    for range in ranges {
        let bytes: Vec<u8> = lines[range.clone()].concat();
        replica.commit(epoch, seqs[range.start], seqs[range.end - 1], &bytes)?;
    }
    Ok(())
}

pub(super) fn oversize(seq: u64, len: usize, limit: RangeLimit) -> io::Error {
    io::Error::other(format!(
        "record seq {seq} is {len} bytes, over the replica's {} byte range limit",
        limit.max_bytes
    ))
}

/// The local fsync is the acknowledgement (local dev, the team VM mount).
pub struct NoopReplica;

impl Replica for NoopReplica {
    fn commit(&mut self, _epoch: u64, _first: u64, _last: u64, _bytes: &[u8]) -> io::Result<()> {
        Ok(())
    }

    fn high_water(&mut self) -> io::Result<Option<u64>> {
        Ok(None)
    }
}

const EPOCH_PREFIX: &str = "epoch-";

fn epoch_name(epoch: u64) -> String {
    format!("{EPOCH_PREFIX}{epoch:020}")
}

/// Whether `dir` was ever opened under a lease epoch (supervised).
pub fn is_supervised(dir: &Path) -> io::Result<bool> {
    Ok(highest_epoch(dir)?.is_some())
}

/// The highest epoch file in `dir`, if any.
fn highest_epoch(dir: &Path) -> io::Result<Option<u64>> {
    let mut highest = None;
    for entry in fs::read_dir(dir)? {
        let name = entry?.file_name();
        let Some(n) = name.to_str().and_then(|n| n.strip_prefix(EPOCH_PREFIX)) else { continue };
        if let Ok(n) = n.parse::<u64>() {
            highest = highest.max(Some(n));
        }
    }
    Ok(highest)
}

/// The supervisor's lease epoch on this data directory.
#[derive(Debug)]
pub struct EpochFence {
    dir: PathBuf,
    epoch: u64,
}

/// Why the fence refused.
#[derive(Debug, PartialEq, Eq)]
pub enum Fenced {
    /// A newer epoch owns the data directory.
    Newer { ours: u64, newer: u64 },
    /// Another host already started this epoch.
    Taken { epoch: u64, host: String },
}

impl std::fmt::Display for Fenced {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Newer { ours, newer } => {
                write!(f, "owner_moved: epoch {newer} is newer than this owner's epoch {ours}")
            }
            Self::Taken { epoch, host } => {
                write!(f, "owner_moved: epoch {epoch} was started by host {host:?}")
            }
        }
    }
}

impl EpochFence {
    /// Claim `epoch` for `host` in `dir` (the caller holds `LOCK`). The same
    /// host may reopen its own epoch (a supervisor restart re-adopts it).
    pub fn acquire(dir: &Path, epoch: u64, host: &str) -> io::Result<Result<Self, Fenced>> {
        if let Some(newer) = highest_epoch(dir)?
            && newer > epoch
        {
            return Ok(Err(Fenced::Newer { ours: epoch, newer }));
        }
        let path = dir.join(epoch_name(epoch));
        // Create-if-absent together with its content: write a private tmp
        // file, fsync it, then hard-link it into place (link fails when the
        // name exists). A crash never leaves an empty epoch file.
        let tmp = dir.join(format!(".{}.{}.tmp", epoch_name(epoch), std::process::id()));
        {
            let mut file = OpenOptions::new().write(true).create(true).truncate(true).open(&tmp)?;
            file.write_all(host.as_bytes())?;
            file.sync_all()?;
        }
        let linked = fs::hard_link(&tmp, &path);
        fs::remove_file(&tmp)?;
        match linked {
            Ok(()) => super::sync_dir(dir)?,
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                let mut owner = String::new();
                fs::File::open(&path)?.read_to_string(&mut owner)?;
                if owner != host {
                    return Ok(Err(Fenced::Taken { epoch, host: owner }));
                }
            }
            Err(e) => return Err(e),
        }
        Ok(Ok(Self { dir: dir.to_owned(), epoch }))
    }

    pub fn epoch(&self) -> u64 {
        self.epoch
    }

    /// Before each group commit: no newer epoch exists.
    pub fn check(&self) -> io::Result<()> {
        match highest_epoch(&self.dir)? {
            Some(newer) if newer > self.epoch => {
                Err(io::Error::other(Fenced::Newer { ours: self.epoch, newer }.to_string()))
            }
            _ => Ok(()),
        }
    }
}

/// A claim on the supervisor's lease epoch for this data directory.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EpochClaim {
    pub epoch: u64,
    /// The host that runs this owner (written into the epoch file).
    pub host: String,
}

/// The durability settings of one store.
pub struct Durability {
    pub epoch: Option<EpochClaim>,
    pub replica: Box<dyn Replica>,
}

impl Durability {
    /// Local disk only: no epoch, no replica.
    pub fn local() -> Self {
        Self { epoch: None, replica: Box::new(NoopReplica) }
    }
}
