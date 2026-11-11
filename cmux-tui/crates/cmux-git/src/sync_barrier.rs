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
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

/// A producer must hold this before its first change, and mark ready only after
/// every checkout, submodule and LFS operation has completed successfully.
pub struct Sync {
    marker: File,
    /// The head lock, held until [`Sync::head_ready`].
    head: Option<File>,
    /// The owner lock: this sync marks heads. Released first on drop (below).
    owner: Option<File>,
}

/// Shared locks stay held through the caller's write, preventing a new seed
/// from starting between the readiness check and the actual filesystem write.
pub struct Ready(Vec<File>);

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

fn lock(file: &File, mode: i32) -> io::Result<bool> {
    // SAFETY: the descriptor remains live for this call and the lock's lifetime.
    if unsafe { libc::flock(file.as_raw_fd(), mode | libc::LOCK_NB) } == 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::WouldBlock { Ok(false) } else { Err(error) }
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

fn wait_lock(file: &File, mode: i32) -> io::Result<()> {
    let deadline = Instant::now() + Duration::from_secs(30);
    while !lock(file, mode)? {
        if Instant::now() >= deadline {
            return Err(io::Error::new(io::ErrorKind::TimedOut, "repository is in use"));
        }
        std::thread::sleep(Duration::from_millis(10));
    }
    Ok(())
}

impl Sync {
    /// `folder` must have its parent canonicalized by the producer's sandbox.
    pub fn begin(folder: &Path) -> io::Result<Self> {
        let mut file = open(&marker(folder)?, true)?;
        if !lock(&file, libc::LOCK_EX)? {
            return Err(io::Error::new(io::ErrorKind::WouldBlock, "repository is in use"));
        }
        // Then the head lock, then the owner lock: a reader takes the head as in place only
        // while the owner lock is held and the head lock free, so until both are taken this
        // sync reads as short of its head. Only the marker's holder takes them, and a reader
        // holds either only for one probe, so these waits are short.
        let head = open(&head_marker(folder)?, true)?;
        wait_lock(&head, libc::LOCK_EX)?;
        let owner = open(&owner_marker(folder)?, true)?;
        wait_lock(&owner, libc::LOCK_EX)?;
        // Take the repository lock first: a reader of an existing marker
        // refuses this sync immediately. A reader that preceded the first
        // marker instead holds the creation lease until its write completes.
        let creating = creation_lock(folder)?;
        wait_lock(&creating, libc::LOCK_EX)?;
        file.write_all(b"0")?;
        file.set_len(1)?;
        file.sync_data()?;
        Ok(Self { marker: file, head: Some(head), owner: Some(owner) })
    }

    /// The head is in place and the rest of the checkout still arrives: a reader
    /// that may start before the whole checkout sees [`Probe::HeadReady`]. The
    /// marker stays locked, so every [`wait_ready`] still waits, and a producer that
    /// dies after this leaves the barrier incomplete, as before it. Mark it only
    /// when the head holds no harness setting that runs a command as the harness
    /// starts (a `.claude/settings*.json` with hooks): that start would run it on a
    /// partial checkout.
    pub fn head_ready(&mut self) {
        // Closing the descriptor releases its flock.
        self.head = None;
    }

    /// A failed durability step leaves the barrier incomplete.
    pub fn complete(mut self) -> io::Result<()> {
        let file = &mut self.marker;
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
        let creating = creation_lock(folder)?;
        wait_lock(&creating, libc::LOCK_SH)?;
        held.push(creating);
        let mut file = match open(&marker(folder)?, false) {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        };
        if !lock(&file, libc::LOCK_SH)? {
            // Syncing; past its head when its producer let go of the head lock. An
            // outer folder still syncing short of its head wins below.
            match syncing_state(folder, &file)? {
                Syncing::PastHead => {
                    head_only = true;
                    continue;
                }
                Syncing::ShortOfHead => return Ok(Probe::Syncing),
                // The producer ended between the two reads: its byte says how.
                Syncing::Ended => {}
            }
        }
        let mut ready = [0];
        if file.read(&mut ready)? != 1 || ready[0] != b'1' {
            return Ok(Probe::Incomplete);
        }
        held.push(file);
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
    Ended,
}

/// A folder whose marker was locked: whether its producer is past its head. The head lock is
/// taken shared first and kept for this call, so no new producer can begin meanwhile
/// ([`Sync::begin`] takes it first); then the marker is tried again. Free: its producer ended
/// (a failed one drops every lock), and only the marker's byte may say ready. Still locked:
/// past its head only if the owner lock is held too. Only the marker's holder takes it, after
/// its head lock, which it has let go of, and it lets go of the owner lock before the marker;
/// a producer from before owner locks never takes it.
fn syncing_state(folder: &Path, marker: &File) -> io::Result<Syncing> {
    let head = match open(&head_marker(folder)?, false) {
        Ok(head) => head,
        // A producer from before head locks: it never marks a head.
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Syncing::ShortOfHead),
        Err(error) => return Err(error),
    };
    // Released when `head` closes at the end of this call.
    if !lock(&head, libc::LOCK_SH)? {
        return Ok(Syncing::ShortOfHead);
    }
    if lock(marker, libc::LOCK_SH)? {
        return Ok(Syncing::Ended);
    }
    let owner = match open(&owner_marker(folder)?, false) {
        Ok(owner) => owner,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Syncing::ShortOfHead),
        Err(error) => return Err(error),
    };
    if lock(&owner, libc::LOCK_SH)? { Ok(Syncing::ShortOfHead) } else { Ok(Syncing::PastHead) }
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
        // Closing releases each flock. This explicit clear documents that the
        // otherwise opaque field is the lifetime of the write's read lease.
        self.0.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The window review F1 (cmux#38084, 8843ee22f76) found: the reader saw the marker locked,
    /// then the producer failed and dropped both locks. The head lock is free now, but the
    /// producer never marked its head, so the folder is not past its head.
    #[test]
    fn a_producer_that_failed_between_the_reads_is_never_past_its_head() {
        let dir = std::env::temp_dir().join(format!("cmux-sync-unit-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let repo = dir.canonicalize().unwrap().join("repo");
        let sync = Sync::begin(&repo).unwrap();
        let marker = open(&marker(&repo).unwrap(), false).unwrap();
        assert!(!lock(&marker, libc::LOCK_SH).unwrap(), "the reader sees the marker locked");
        drop(sync);
        assert!(matches!(syncing_state(&repo, &marker).unwrap(), Syncing::Ended));
        assert!(matches!(probe(&repo).unwrap(), Probe::Incomplete));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Review F1 (cmux#38084, 9efddcbb52a): a producer from before head locks holds only the
    /// marker. The head sidecar an earlier sync left is free, and that must not read as this
    /// producer's head.
    #[test]
    fn an_older_producer_beside_a_left_head_sidecar_is_short_of_its_head() {
        let dir = std::env::temp_dir().join(format!("cmux-sync-legacy-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let repo = dir.canonicalize().unwrap().join("repo");
        let mut sync = Sync::begin(&repo).unwrap();
        sync.head_ready();
        sync.complete().unwrap();
        assert!(head_marker(&repo).unwrap().exists() && owner_marker(&repo).unwrap().exists());
        let legacy = open(&marker(&repo).unwrap(), true).unwrap();
        assert!(lock(&legacy, libc::LOCK_EX).unwrap());
        assert!(matches!(probe(&repo).unwrap(), Probe::Syncing));
        drop(legacy);
        assert!(matches!(probe(&repo).unwrap(), Probe::Ready(_)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
