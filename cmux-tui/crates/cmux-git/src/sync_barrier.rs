//! A persistent barrier shared by Cloud repository seeding and agent writes.
//!
//! The sidecar lives beside the checkout, so clone can still require an empty
//! destination. Never unlink it: replacing its inode would split the lock. A
//! failed or interrupted sync leaves a non-ready byte, including after restart.
//! This is coordination between cooperating processes, not a security sandbox.
//!
//!
//! Beside the marker, `<marker>.head` says the head is in place: a producer holds
//! it exclusively from before it takes the marker until [`Sync::head_ready`], so
//! a reader that finds the marker locked and the head lock free sees
//! [`Probe::HeadReady`]. A lock, not a byte: a producer that died after its head
//! leaves nothing a later sync's reader could take for its own head. A producer
//! that marks heads also holds `<marker>.owner` for its whole sync; a producer from
//! an older build holds only the marker, so with the owner lock free a reader never
//! takes a free head lock (left by an earlier sync) for that producer's. Only a
//! harness start whose every tool call is gated on [`wait_ready`] may go ahead at
//! the head: its first prompt then waits on the repository's root and instruction
//! files, not on the whole checkout, while its tools still wait for all of it.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_file_lock::{FileLock, Kind, LockError};
use sha2::{Digest, Sha256};

/// A producer must hold this before its first change, and mark ready only after
/// every checkout, submodule and LFS operation has completed successfully.
pub struct Sync {
    marker: FileLock,
    /// The head lock, held until [`Sync::head_ready`].
    head: Option<FileLock>,
    /// The owner lock: this sync marks heads. Released first on drop (below).
    owner: Option<FileLock>,
}

/// Shared locks stay held through the caller's write, preventing a new seed
/// from starting between the readiness check and the actual filesystem write.
pub struct Ready(Vec<FileLock>);

pub enum Probe {
    Ready(Ready),
    /// Still syncing, and its producer said the head is in place ([`Sync::head_ready`]).
    HeadReady,
    Syncing,
    Incomplete,
}

/// Wait until repository synchronization is complete, or until `timeout`.
///
/// Hook callers use this as a synchronous pre-tool gate. The returned read
/// lease is intentionally released before the caller executes the tool; a
/// caller that must serialize the write itself should retain [`Ready`] from
/// [`probe`] through its mutation instead.
pub fn wait_ready(path: &Path, timeout: Duration) -> io::Result<()> {
    let deadline = Instant::now() + timeout;
    loop {
        match probe(path)? {
            Probe::Ready(ready) => {
                drop(ready);
                return Ok(());
            }
            Probe::Incomplete => {
                return Err(io::Error::other("repository synchronization failed; retry the sync"));
            }
            Probe::HeadReady | Probe::Syncing => {
                if Instant::now() >= deadline {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "repository synchronization did not finish",
                    ));
                }
                std::thread::sleep(Duration::from_millis(10));
            }
        }
    }
}

fn head_marker(folder: &Path) -> io::Result<PathBuf> {
    sidecar(folder, ".head")
}

fn owner_marker(folder: &Path) -> io::Result<PathBuf> {
    sidecar(folder, ".owner")
}

fn sidecar(folder: &Path, suffix: &str) -> io::Result<PathBuf> {
    let mut path = marker(folder)?.into_os_string();
    path.push(suffix);
    Ok(PathBuf::from(path))
}

fn marker(folder: &Path) -> io::Result<PathBuf> {
    let parent = folder.parent().ok_or_else(|| io::Error::other("sync root has no parent"))?;
    let name = folder.file_name().ok_or_else(|| io::Error::other("sync root has no name"))?;
    use std::os::unix::ffi::OsStrExt;
    let hash = format!("{:x}", Sha256::digest(name.as_bytes()));
    Ok(parent.join(format!(".cmux-sync-{hash}")))
}

fn open(path: &Path, create: bool) -> io::Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(create)
        .create(create)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC)
        .open(path)?;
    let meta = file.metadata()?;
    // SAFETY: geteuid has no preconditions.
    if !meta.is_file() || meta.nlink() != 1 || meta.uid() != unsafe { libc::geteuid() } {
        return Err(io::Error::other("invalid repository sync marker"));
    }
    Ok(file)
}

/// `kind` on `file` now: the lock, or the file back when another holder has it. Every lock here
/// is a [`FileLock`], which unlocks before it closes: a child that another thread of this process
/// forked meanwhile (a git run) keeps no lock through its copy of the descriptor.
fn try_take(file: File, kind: Kind) -> io::Result<Result<FileLock, File>> {
    match FileLock::try_take(file, kind) {
        Ok(lock) => Ok(Ok(lock)),
        Err(LockError::Busy(file)) => Ok(Err(file)),
        Err(LockError::Io(error)) => Err(error),
    }
}

/// Serializes one folder's first marker with readers that saw no marker yet.
/// Leases are keyed by canonical folder, so independent repositories do not
/// wait for each other's writes or startup. They live outside the repository
/// and share a location even when daemon processes have different TMPDIRs.
/// Never unlink these inodes, for the same reason as the repository markers.
fn creation_lock(folder: &Path) -> io::Result<File> {
    use std::os::unix::ffi::OsStrExt;
    // SAFETY: geteuid has no preconditions.
    let uid = unsafe { libc::geteuid() };
    let hash = format!("{:x}", Sha256::digest(folder.as_os_str().as_bytes()));
    open(&PathBuf::from(format!("/tmp/cmux-repo-sync-{uid}-{hash}.lock")), true)
}

fn wait_take(file: File, kind: Kind) -> io::Result<FileLock> {
    FileLock::take_within(file, kind, Duration::from_secs(30), Duration::from_millis(10)).map_err(
        |error| match error {
            LockError::Busy(_) => io::Error::new(io::ErrorKind::TimedOut, "repository is in use"),
            LockError::Io(error) => error,
        },
    )
}

impl Sync {
    /// `folder` must have its parent canonicalized by the producer's sandbox.
    pub fn begin(folder: &Path) -> io::Result<Self> {
        let Ok(mut marker) = try_take(open(&marker(folder)?, true)?, Kind::Exclusive)? else {
            return Err(io::Error::new(io::ErrorKind::WouldBlock, "repository is in use"));
        };
        // Then the head lock, then the owner lock: a reader takes the head as in place only
        // while the owner lock is held and the head lock free, so until both are taken this
        // sync reads as short of its head. Only the marker's holder takes them, and a reader
        // holds either only for one probe, so these waits are short.
        let head = wait_take(open(&head_marker(folder)?, true)?, Kind::Exclusive)?;
        let owner = wait_take(open(&owner_marker(folder)?, true)?, Kind::Exclusive)?;
        // Take the repository lock first: a reader of an existing marker
        // refuses this sync immediately. A reader that preceded the first
        // marker instead holds the creation lease until its write completes.
        let _creating = wait_take(creation_lock(folder)?, Kind::Exclusive)?;
        let file = marker.file_mut();
        file.write_all(b"0")?;
        file.set_len(1)?;
        file.sync_data()?;
        Ok(Self { marker, head: Some(head), owner: Some(owner) })
    }

    /// The head is in place and the rest of the checkout still arrives: a reader
    /// that may start before the whole checkout sees [`Probe::HeadReady`]. The
    /// marker stays locked, so every [`wait_ready`] still waits, and a producer that
    /// dies after this leaves the barrier incomplete, as before it. Mark it only
    /// when the head holds no harness setting that runs a command as the harness
    /// starts (a `.claude/settings*.json` with hooks): that start would run it on a
    /// partial checkout.
    pub fn head_ready(&mut self) {
        // The drop unlocks it.
        self.head = None;
    }

    /// A failed durability step leaves the barrier incomplete.
    pub fn complete(mut self) -> io::Result<()> {
        let file = self.marker.file_mut();
        file.seek(SeekFrom::Start(0))?;
        file.write_all(b"1")?;
        if let Err(error) = file.sync_data() {
            let _ = file.seek(SeekFrom::Start(0));
            let _ = file.write_all(b"0");
            let _ = file.sync_data();
            return Err(error);
        }
        Ok(())
    }
}

/// Resolve even an as-yet missing target through its deepest existing ancestor.
/// This also makes symlink aliases of a repository observe its barrier.
fn resolved(path: &Path) -> io::Result<PathBuf> {
    let mut parent = path;
    let mut missing = Vec::new();
    loop {
        match parent.canonicalize() {
            Ok(mut found) => {
                for name in missing.into_iter().rev() {
                    found.push(name);
                }
                return Ok(found);
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                missing.push(parent.file_name().ok_or(error)?);
                parent = parent.parent().ok_or_else(|| io::Error::other("invalid sync path"))?;
            }
            Err(error) => return Err(error),
        }
    }
}

/// One bounded observation; consumers wait cancellably between observations.
/// The creation lease only covers marker publication. A busy repository lock
/// returns immediately, so a running sync never blocks a reader thread.
/// No marker means an ordinary local repository, which needs no sync wait.
pub fn probe(path: &Path) -> io::Result<Probe> {
    let path = resolved(path)?;
    let mut held = Vec::new();
    let mut head_only = false;
    for folder in path.ancestors().filter(|folder| folder.parent().is_some()) {
        held.push(wait_take(creation_lock(folder)?, Kind::Shared)?);
        let file = match open(&marker(folder)?, false) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        let mut marker = match try_take(file, Kind::Shared)? {
            Ok(marker) => marker,
            // Syncing; past its head when its producer let go of the head lock. An
            // outer folder still syncing short of its head wins below.
            Err(file) => match syncing_state(folder, file)? {
                Syncing::PastHead => {
                    head_only = true;
                    continue;
                }
                Syncing::ShortOfHead => return Ok(Probe::Syncing),
                // The producer ended between the two reads: its byte says how.
                Syncing::Ended(marker) => marker,
            },
        };
        let mut ready = [0];
        if marker.file_mut().read(&mut ready)? != 1 || ready[0] != b'1' {
            return Ok(Probe::Incomplete);
        }
        held.push(marker);
    }
    if head_only {
        return Ok(Probe::HeadReady);
    }
    Ok(Probe::Ready(Ready(held)))
}

enum Syncing {
    PastHead,
    ShortOfHead,
    /// The marker's lock came free: no producer holds it now, and the caller holds it shared.
    Ended(FileLock),
}

/// A folder whose marker was locked: whether its producer is past its head. The head lock is
/// taken shared first and kept for this call, so no new producer can begin meanwhile
/// ([`Sync::begin`] takes it first); then the marker is tried again. Free: its producer ended
/// (a failed one drops every lock), and only the marker's byte may say ready. Still locked:
/// past its head only if the owner lock is held too. Only the marker's holder takes it, after
/// its head lock, which it has let go of, and it lets go of the owner lock before the marker;
/// a producer from before owner locks never takes it.
fn syncing_state(folder: &Path, marker: File) -> io::Result<Syncing> {
    let head = match open(&head_marker(folder)?, false) {
        Ok(head) => head,
        // A producer from before head locks: it never marks a head.
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Syncing::ShortOfHead),
        Err(error) => return Err(error),
    };
    // Held until this call returns.
    let Ok(_head) = try_take(head, Kind::Shared)? else {
        return Ok(Syncing::ShortOfHead);
    };
    if let Ok(marker) = try_take(marker, Kind::Shared)? {
        return Ok(Syncing::Ended(marker));
    }
    let owner = match open(&owner_marker(folder)?, false) {
        Ok(owner) => owner,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Syncing::ShortOfHead),
        Err(error) => return Err(error),
    };
    if try_take(owner, Kind::Shared)?.is_ok() {
        Ok(Syncing::ShortOfHead)
    } else {
        Ok(Syncing::PastHead)
    }
}

impl Drop for Sync {
    fn drop(&mut self) {
        // The owner first: while it is held with the head lock free, a reader takes the
        // head as in place, so it must not outlive the head lock or the marker.
        self.owner = None;
        self.head = None;
    }
}

impl Drop for Ready {
    fn drop(&mut self) {
        // Each lock's drop unlocks it. This explicit clear documents that the
        // otherwise opaque field is the lifetime of the write's read lease.
        self.0.clear();
    }
}

#[cfg(test)]
mod tests;
