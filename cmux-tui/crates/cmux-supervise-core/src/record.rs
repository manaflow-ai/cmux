//! The owner record: who runs a supervised thing, written before it starts (H2).
//!
//! `{pid, startTime, pgid, bootId, epoch, argv}` goes to one JSON file by tmp-then-rename, so a
//! reader sees the old record or the new one, never half of one. Every later "is it the same
//! one" reads this record through [`crate::identity::check`], never a pid alone: a pid reused
//! after a crash or a reboot reads dead. The epoch grows by one per start, so a writer that
//! decided from an older record can tell it was superseded.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::identity::{self, Identity, Liveness};

/// One supervised process's owner record.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerRecord {
    pub pid: u32,
    pub start_time: u64,
    pub pgid: u32,
    pub boot_id: String,
    /// One more than the record it replaced; 1 for the first.
    pub epoch: u64,
    /// The program only, never an argument ([`redact`]): the record is served on health and
    /// status and written to death events, and any argument may be a secret (`--token`).
    pub argv: Vec<String>,
}

impl OwnerRecord {
    /// The record for `who`, one epoch past `previous`. Of `argv` it keeps only the program
    /// ([`redact`]).
    pub fn new(who: Identity, previous: Option<&OwnerRecord>, argv: Vec<String>) -> Self {
        Self {
            pid: who.pid,
            start_time: who.start_time,
            pgid: who.pgid,
            boot_id: who.boot_id,
            epoch: previous.map_or(1, |p| p.epoch.saturating_add(1)),
            argv: redact(&argv),
        }
    }

    /// This process, one epoch past `previous`; `None` where its identity cannot be read.
    pub fn for_current(previous: Option<&OwnerRecord>) -> Option<Self> {
        Some(Self::new(identity::current()?, previous, std::env::args().collect()))
    }

    pub fn identity(&self) -> Identity {
        Identity {
            pid: self.pid,
            start_time: self.start_time,
            pgid: self.pgid,
            boot_id: self.boot_id.clone(),
        }
    }

    /// Whether the process this record names still runs.
    pub fn liveness(&self) -> Liveness {
        identity::check(&self.identity())
    }

    /// Whether this record names the calling process.
    pub fn is_current(&self) -> bool {
        identity::current().is_some_and(|me| me == self.identity())
    }
}

/// A command line with nothing but its program: no argument is kept. Which arguments carry a
/// secret (a flag's value, a positional, a value that looks like a flag) is each program's
/// business and cannot be told from outside, and nothing reads the arguments back, so the
/// record keeps none.
pub fn redact(argv: &[String]) -> Vec<String> {
    argv.first().cloned().into_iter().collect()
}

/// What reading a record file found.
#[derive(Debug)]
pub enum Loaded {
    Record(OwnerRecord),
    /// No file: nothing was ever started here, or it was cleared.
    Missing,
    /// A file that does not parse (an older format, a foreign writer). Never proof of anything.
    Unreadable(String),
}

impl Loaded {
    pub fn record(&self) -> Option<&OwnerRecord> {
        match self {
            Self::Record(r) => Some(r),
            Self::Missing | Self::Unreadable(_) => None,
        }
    }
}

/// Read the record at `path`.
pub fn load(path: &Path) -> Loaded {
    match std::fs::read(path) {
        Ok(bytes) => match serde_json::from_slice(&bytes) {
            Ok(record) => Loaded::Record(record),
            Err(e) => Loaded::Unreadable(e.to_string()),
        },
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Loaded::Missing,
        Err(e) => Loaded::Unreadable(e.to_string()),
    }
}

/// Whether the owner the record at `path` names still runs: [`Liveness::Dead`] when there is no
/// record, [`Liveness::Unknown`] when it cannot be read.
pub fn owner_liveness(path: &Path) -> Liveness {
    match load(path) {
        Loaded::Record(r) => r.liveness(),
        Loaded::Missing => Liveness::Dead,
        Loaded::Unreadable(_) => Liveness::Unknown,
    }
}

/// Write `record` to `path`: beside it, synced, then renamed over it, then the folder synced.
pub fn store(path: &Path, record: &OwnerRecord) -> std::io::Result<()> {
    store_with(path, record, &write_file)
}

/// [`store`] through the caller's own atomic writer.
pub fn store_with(path: &Path, record: &OwnerRecord, write: Writer<'_>) -> std::io::Result<()> {
    let text = serde_json::to_vec(record).map_err(std::io::Error::other)?;
    write(path, &text)
}

/// Write the record for this process at `path`, one epoch past what is there now.
pub fn claim_current(path: &Path) -> std::io::Result<OwnerRecord> {
    claim_current_with(path, &write_file)
}

/// [`claim_current`] through the caller's own atomic writer.
pub fn claim_current_with(path: &Path, write: Writer<'_>) -> std::io::Result<OwnerRecord> {
    let previous = load(path);
    let record = OwnerRecord::for_current(previous.record()).ok_or_else(|| {
        std::io::Error::other("this process's identity cannot be read (no /proc or proc_pidinfo)")
    })?;
    store_with(path, &record, write)?;
    Ok(record)
}

/// An atomic writer of a whole file: the old file or the new one, never half. Every write of
/// this crate goes through one, so an adopter with its own rule for its state folder (acpmux's
/// held home) keeps it.
pub type Writer<'a> = &'a dyn Fn(&Path, &[u8]) -> std::io::Result<()>;

/// The default [`Writer`]: makes the folder, then [`write_atomic`].
pub fn write_file(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        std::fs::create_dir_all(dir)?;
    }
    write_atomic(path, bytes)
}

/// `bytes` into `path` by tmp-then-rename: a crash or a full disk leaves the old file whole.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = tmp_path(path);
    let result = (|| {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&tmp);
        return result;
    }
    #[cfg(unix)]
    if let Some(dir) = path.parent().filter(|d| !d.as_os_str().is_empty()) {
        // The rename is durable once the folder is: best effort, the file is already whole.
        let _ = std::fs::File::open(dir).and_then(|d| d.sync_all());
    }
    Ok(())
}

/// The temporary sibling: this process's pid and a count per write, so two writers, in two
/// processes or two threads of one, never share one.
fn tmp_path(path: &Path) -> PathBuf {
    static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let mut name = path.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(format!(".tmp.{}.{n}", std::process::id()));
    path.with_file_name(name)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "supervise-record-{tag}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_claim_grows_the_epoch_and_names_this_process() {
        let dir = dir("claim");
        let path = dir.join("owner.json");
        assert!(matches!(load(&path), Loaded::Missing));
        assert_eq!(owner_liveness(&path), Liveness::Dead);
        let first = claim_current(&path).unwrap();
        assert_eq!(first.epoch, 1);
        assert!(first.is_current());
        let second = claim_current(&path).unwrap();
        assert_eq!(second.epoch, 2);
        #[cfg(any(target_os = "linux", target_os = "macos"))]
        assert_eq!(owner_liveness(&path), Liveness::Alive);
        assert!(std::fs::read_dir(&dir).unwrap().count() == 1, "no temporary file is left");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_record_keeps_the_program_and_never_an_argument() {
        // A flag value, a value after `=`, a lowercase positional, and a value that looks like
        // a flag: none can be told from a non-secret from outside.
        let argv: Vec<String> = [
            "/opt/cmux/acpmux",
            "daemon",
            "run",
            "--token",
            "s3cret",
            "--listen=0.0.0.0:47811",
            "lowersecret",
            "--password",
            "-dashsecret",
        ]
        .map(String::from)
        .to_vec();
        let who = identity::current().unwrap_or(Identity {
            pid: 1,
            start_time: 0,
            pgid: 1,
            boot_id: String::new(),
        });
        let record = OwnerRecord::new(who, None, argv);
        assert_eq!(record.argv, ["/opt/cmux/acpmux"]);
        let json = serde_json::to_string(&record).unwrap();
        for secret in ["s3cret", "47811", "lowersecret", "dashsecret"] {
            assert!(!json.contains(secret), "{secret} in {json}");
        }
        assert!(redact(&[]).is_empty());
    }

    #[test]
    fn writers_on_two_threads_never_share_a_temporary_file() {
        let dir = dir("threads");
        let path = dir.join("owner.json");
        std::thread::scope(|s| {
            for t in 0..8u8 {
                let path = &path;
                s.spawn(move || {
                    for _ in 0..50 {
                        write_file(path, &[t; 64]).unwrap();
                    }
                });
            }
        });
        assert_eq!(std::fs::read(&path).unwrap().len(), 64);
        assert!(std::fs::read_dir(&dir).unwrap().count() == 1, "no temporary file is left");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_torn_or_foreign_file_is_unknown_never_dead() {
        let dir = dir("torn");
        let path = dir.join("owner.json");
        std::fs::write(&path, b"{\"pid\": 12").unwrap();
        assert!(matches!(load(&path), Loaded::Unreadable(_)));
        assert_eq!(owner_liveness(&path), Liveness::Unknown);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
