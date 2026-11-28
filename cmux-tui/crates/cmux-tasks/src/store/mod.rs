//! The Tasks store: an append-only op log on the zero-loss tier is the
//! source of truth; the state is the fold of the log through the pure
//! reducer (plans/cmux-next/tasks.md section 4, decision T1).
//!
//! ```text
//! <dir>/LOCK                 single-writer lock (flock)
//! <dir>/meta.json            {format, team, key_prefix}
//! <dir>/log/<seq20>.jsonl    one committed record per line, rotated at 4 MiB
//! <dir>/snapshots/<seq20>.json  full state, written tmp + fsync + rename
//! ```
//!
//! Commit protocol: `stage` reduces an op against the in-memory state and
//! buffers its record; `flush` appends the buffered records and `fsync`s
//! once (group commit). Callers answer and publish only after `flush`. If a
//! flush fails, the in-memory state is ahead of the disk: the process must
//! exit and recover from disk (crash-only), never continue.

mod segment;
mod snapshot;

use std::fs::{self, File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

use cmux_tasks_core::event::EventKind;
use cmux_tasks_core::{Commit, Ctx, Envelope, Reject, State, reduce};
use serde::{Deserialize, Serialize};

pub use segment::Record;

pub const FORMAT: u32 = 1;
/// Version of `State::new` (the genesis every replay starts from). A new
/// default workflow gets a new version; old stores keep replaying from the
/// genesis they were created with.
pub const GENESIS: u32 = 1;

/// Segment and snapshot sizes (tests use small ones).
#[derive(Clone, Copy, Debug)]
pub struct Limits {
    pub segment_bytes: u64,
    pub snapshot_every: u64,
}

impl Default for Limits {
    fn default() -> Self {
        Self { segment_bytes: 4 * 1024 * 1024, snapshot_every: 1_000 }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Meta {
    pub format: u32,
    pub team: String,
    pub key_prefix: String,
    /// Stores written before the field existed used genesis 1.
    #[serde(default = "genesis_one")]
    pub genesis: u32,
}

fn genesis_one() -> u32 {
    1
}

fn genesis_state(meta: &Meta) -> Result<State, OpenError> {
    match meta.genesis {
        1 => Ok(State::new(&meta.team, &meta.key_prefix)),
        other => Err(OpenError::Corrupt(format!(
            "unknown genesis version {other}; this build knows 1..={GENESIS}"
        ))),
    }
}

#[derive(Debug)]
pub enum OpenError {
    /// Another process holds the writer lock (use its socket).
    Locked,
    Io(io::Error),
    Corrupt(String),
}

impl std::fmt::Display for OpenError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Locked => write!(f, "another Tasks owner holds the store lock"),
            Self::Io(e) => write!(f, "store i/o: {e}"),
            Self::Corrupt(m) => write!(f, "store corrupt: {m}"),
        }
    }
}

impl From<io::Error> for OpenError {
    fn from(e: io::Error) -> Self {
        Self::Io(e)
    }
}

/// Events produced while recovering, so the event ring can serve catch-up.
pub type Recovered = Vec<(Record, Vec<EventKind>)>;

pub struct Store {
    dir: PathBuf,
    _lock: File,
    state: State,
    writer: segment::Writer,
    pending: Vec<Record>,
    last_snapshot: u64,
    limits: Limits,
}

impl Store {
    /// Open (or create) the store at `dir`, take the writer lock and recover.
    pub fn open(dir: &Path, team: &str, key_prefix: &str) -> Result<(Self, Recovered), OpenError> {
        Self::open_with(dir, team, key_prefix, Limits::default())
    }

    pub fn open_with(
        dir: &Path,
        team: &str,
        key_prefix: &str,
        limits: Limits,
    ) -> Result<(Self, Recovered), OpenError> {
        fs::create_dir_all(dir.join("log"))?;
        fs::create_dir_all(dir.join("snapshots"))?;
        restrict_dir(dir)?;
        let lock =
            OpenOptions::new().create(true).truncate(false).write(true).open(dir.join("LOCK"))?;
        match fs4::FileExt::try_lock(&lock) {
            Ok(()) => {}
            Err(fs4::TryLockError::WouldBlock) => return Err(OpenError::Locked),
            Err(fs4::TryLockError::Error(e)) => return Err(OpenError::Io(e)),
        }
        let meta = load_or_create_meta(dir, team, key_prefix)?;
        let (mut state, last_snapshot) = match snapshot::load_latest(&dir.join("snapshots"))? {
            Some(state) => {
                let seq = state.seq;
                (state, seq)
            }
            None => (genesis_state(&meta)?, 0),
        };
        let mut recovered = Vec::new();
        for record in segment::read_all(&dir.join("log"))? {
            if record.seq <= state.seq {
                continue;
            }
            if record.seq != state.seq + 1 {
                return Err(OpenError::Corrupt(format!(
                    "gap: expected seq {}, found {}",
                    state.seq + 1,
                    record.seq
                )));
            }
            let commit =
                reduce(&mut state, &record.envelope, Ctx { now: record.at }).map_err(|r| {
                    OpenError::Corrupt(format!(
                        "seq {} no longer commits: {}",
                        record.seq, r.message
                    ))
                })?;
            if commit.result != record.result || commit.replay {
                return Err(OpenError::Corrupt(format!(
                    "seq {} replays to a different result",
                    record.seq
                )));
            }
            recovered.push((record, commit.events));
        }
        let writer = segment::Writer::open(&dir.join("log"), state.seq + 1, limits.segment_bytes)?;
        let store = Self {
            dir: dir.to_owned(),
            _lock: lock,
            state,
            writer,
            pending: Vec::new(),
            last_snapshot,
            limits,
        };
        Ok((store, recovered))
    }

    pub fn state(&self) -> &State {
        &self.state
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Reduce one envelope into the in-memory state and buffer its record.
    /// Not durable until `flush` returns.
    pub fn stage(&mut self, envelope: &Envelope, now: i64) -> Result<Commit, Reject> {
        let commit = reduce(&mut self.state, envelope, Ctx { now })?;
        if !commit.replay {
            self.pending.push(Record {
                v: FORMAT,
                seq: commit.seq,
                at: now,
                envelope: envelope.clone(),
                result: commit.result.clone(),
            });
        }
        Ok(commit)
    }

    /// Append and fsync every staged record; snapshot when due.
    pub fn flush(&mut self) -> io::Result<()> {
        if self.pending.is_empty() {
            return Ok(());
        }
        let records = std::mem::take(&mut self.pending);
        self.writer.append(&records)?;
        if self.state.seq - self.last_snapshot >= self.limits.snapshot_every {
            snapshot::write(&self.dir.join("snapshots"), &self.state)?;
            self.last_snapshot = self.state.seq;
        }
        Ok(())
    }

    /// Records staged but not yet durable.
    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }
}

fn load_or_create_meta(dir: &Path, team: &str, key_prefix: &str) -> Result<Meta, OpenError> {
    let path = dir.join("meta.json");
    match fs::read(&path) {
        Ok(bytes) => {
            let meta: Meta = serde_json::from_slice(&bytes)
                .map_err(|e| OpenError::Corrupt(format!("meta.json: {e}")))?;
            if meta.format != FORMAT {
                return Err(OpenError::Corrupt(format!(
                    "unsupported store format {}",
                    meta.format
                )));
            }
            Ok(meta)
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            let meta = Meta {
                format: FORMAT,
                team: team.to_owned(),
                key_prefix: key_prefix.to_owned(),
                genesis: GENESIS,
            };
            let bytes = serde_json::to_vec_pretty(&meta).map_err(io::Error::other)?;
            snapshot::write_atomic(&path, &bytes)?;
            Ok(meta)
        }
        Err(e) => Err(e.into()),
    }
}

#[cfg(unix)]
fn restrict_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))
}

#[cfg(not(unix))]
fn restrict_dir(_dir: &Path) -> io::Result<()> {
    Ok(())
}

/// fsync a directory so a create or rename inside it is durable.
pub(crate) fn sync_dir(dir: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        File::open(dir)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        Ok(())
    }
}
