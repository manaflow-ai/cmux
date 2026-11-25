//! Reads and writes against a sleeping machine: a replica of its working tree with the journal
//! laid over it.
//!
//! A replica is a copy of the machine's files taken while nothing on the machine was running
//! (at pause). It answers for the machine only while that is still true: once anything ran there
//! (an exec, a resume), [`ReplicaSource::is_fresh`] is false and every read and write that the
//! journal cannot answer goes to the machine. A path the replica leaves out (too large, ignored,
//! not text) is [`ReplicaRead::MachineOnly`]: the machine must be asked.

use super::{Op, PathError, Version, WriteJournal, rel_path};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

/// What a replica has for one path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplicaRead {
    Present(Vec<u8>),
    Absent,
    /// The replica does not hold this path; only the machine can answer.
    MachineOnly,
}

/// A snapshot of one machine's folder.
pub trait ReplicaSource: Send + Sync {
    /// Bumped on every reseed, so a cached answer names the snapshot it came from.
    fn generation(&self) -> u64;
    /// False once anything may have run on the machine since the snapshot.
    fn is_fresh(&self) -> bool;
    /// `path` is already a journal path ([`rel_path`]).
    fn read(&self, path: &str) -> io::Result<ReplicaRead>;
}

/// A replica kept as a plain folder: the self-hosted default and the test double. Files over
/// `max_file_bytes` are [`ReplicaRead::MachineOnly`]; symlinks are never followed out of it.
pub struct DirReplica {
    root: PathBuf,
    max_file_bytes: u64,
    generation: AtomicU64,
    fresh: AtomicBool,
}

impl DirReplica {
    /// 1 MiB: larger files are read from the machine.
    pub const DEFAULT_MAX_FILE_BYTES: u64 = 1 << 20;

    pub fn new(root: impl Into<PathBuf>, max_file_bytes: u64) -> Self {
        Self {
            root: root.into(),
            max_file_bytes,
            generation: AtomicU64::new(1),
            fresh: AtomicBool::new(true),
        }
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Anything ran on the machine: stop answering for it until the next reseed.
    pub fn invalidate(&self) {
        self.fresh.store(false, Ordering::SeqCst);
    }

    /// The folder was refreshed from the machine while nothing ran there.
    pub fn reseeded(&self) -> u64 {
        self.fresh.store(true, Ordering::SeqCst);
        self.generation.fetch_add(1, Ordering::SeqCst).saturating_add(1)
    }
}

impl ReplicaSource for DirReplica {
    fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }

    fn is_fresh(&self) -> bool {
        self.fresh.load(Ordering::SeqCst)
    }

    /// No link is followed anywhere on the path, the folder itself included: a link may point
    /// outside the snapshot.
    #[cfg(unix)]
    fn read(&self, path: &str) -> io::Result<ReplicaRead> {
        use super::nofollow::{Dir, is_not_plain};
        use std::io::Read;
        let mut parts: Vec<&str> = path.split('/').collect();
        let Some(name) = parts.pop() else { return Ok(ReplicaRead::Absent) };
        let mut dir = Dir::open_root(&self.root)?;
        for part in parts {
            dir = match dir.child(part, false) {
                Ok(Some(d)) => d,
                Ok(None) => return Ok(ReplicaRead::Absent),
                Err(e) if is_not_plain(&e) => return Ok(ReplicaRead::MachineOnly),
                Err(e) => return Err(e),
            };
        }
        let file = match dir.open_file(name) {
            Ok(Some(f)) => f,
            Ok(None) => return Ok(ReplicaRead::Absent),
            Err(e) if is_not_plain(&e) => return Ok(ReplicaRead::MachineOnly),
            Err(e) => return Err(e),
        };
        let meta = file.metadata()?;
        if !meta.is_file() || meta.len() > self.max_file_bytes {
            return Ok(ReplicaRead::MachineOnly);
        }
        let mut bytes = Vec::new();
        file.take(self.max_file_bytes.saturating_add(1)).read_to_end(&mut bytes)?;
        if bytes.len() as u64 > self.max_file_bytes {
            return Ok(ReplicaRead::MachineOnly);
        }
        Ok(ReplicaRead::Present(bytes))
    }

    #[cfg(not(unix))]
    fn read(&self, _: &str) -> io::Result<ReplicaRead> {
        Ok(ReplicaRead::MachineOnly)
    }
}

/// Why a call must go to the machine instead.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NeedsMachine {
    /// Something ran on the machine since the snapshot.
    Stale,
    /// The replica leaves this path out.
    MachineOnly,
    /// The file is not UTF-8 text.
    NotText,
}

/// The answer to a text read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReadOutcome {
    Text(String),
    NotFound,
    NeedsMachine(NeedsMachine),
}

/// The answer to a write or delete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WriteOutcome {
    /// Durable in the journal under this sequence number.
    Journaled(u64),
    /// The journal cannot know the version the agent is writing over.
    NeedsMachine(NeedsMachine),
}

#[derive(Debug, thiserror::Error)]
pub enum JournalError {
    #[error(transparent)]
    Path(#[from] PathError),
    #[error(transparent)]
    Io(#[from] io::Error),
}

/// The version a read of `path` sees now, and its bytes: the journal's newest entry, else the
/// replica. `Err(NeedsMachine)` when neither can say.
fn current(
    journal: &WriteJournal,
    replica: &dyn ReplicaSource,
    path: &str,
) -> io::Result<Result<Option<Vec<u8>>, NeedsMachine>> {
    if let Some(e) = journal.overlay(path) {
        return Ok(Ok(match &e.op {
            Op::Write { content } => Some(content.clone().into_bytes()),
            Op::Delete => None,
        }));
    }
    let generation = replica.generation();
    if !replica.is_fresh() {
        return Ok(Err(NeedsMachine::Stale));
    }
    let read = replica.read(path)?;
    // Invalidated (or reseeded) while reading: the bytes may predate what ran on the machine.
    if !replica.is_fresh() || replica.generation() != generation {
        return Ok(Err(NeedsMachine::Stale));
    }
    Ok(match read {
        ReplicaRead::Present(b) => Ok(Some(b)),
        ReplicaRead::Absent => Ok(None),
        ReplicaRead::MachineOnly => Err(NeedsMachine::MachineOnly),
    })
}

/// Reads `path` as the agent should see it: its own unflushed writes first (read-your-writes),
/// then the replica. Never wakes anything; the caller acts on `NeedsMachine`.
pub fn read_text(
    journal: &WriteJournal,
    replica: &dyn ReplicaSource,
    raw_path: &str,
) -> Result<ReadOutcome, JournalError> {
    let path = rel_path(raw_path)?;
    Ok(match current(journal, replica, &path)? {
        Err(why) => ReadOutcome::NeedsMachine(why),
        Ok(None) => ReadOutcome::NotFound,
        Ok(Some(bytes)) => match String::from_utf8(bytes) {
            Ok(text) => ReadOutcome::Text(text),
            Err(_) => ReadOutcome::NeedsMachine(NeedsMachine::NotText),
        },
    })
}

/// Records a write (`Some(content)`) or a delete (`None`) of `path`, against the version a read
/// sees now. Durable before it returns [`WriteOutcome::Journaled`].
pub fn write_text(
    journal: &mut WriteJournal,
    replica: &dyn ReplicaSource,
    raw_path: &str,
    content: Option<&str>,
    at_ms: u64,
) -> Result<WriteOutcome, JournalError> {
    let path = rel_path(raw_path)?;
    let base = match current(journal, replica, &path)? {
        Err(why) => return Ok(WriteOutcome::NeedsMachine(why)),
        // A read of this file says NotText, so a write over it must not succeed unseen.
        Ok(Some(bytes)) if std::str::from_utf8(&bytes).is_err() => {
            return Ok(WriteOutcome::NeedsMachine(NeedsMachine::NotText));
        }
        Ok(bytes) => Version::of(bytes.as_deref()),
    };
    let op = match content {
        Some(c) => Op::Write { content: c.to_owned() },
        None => Op::Delete,
    };
    Ok(WriteOutcome::Journaled(journal.record(&path, op, base, at_ms)?))
}
