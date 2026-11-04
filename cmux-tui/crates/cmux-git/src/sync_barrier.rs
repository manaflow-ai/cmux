//! A persistent barrier shared by Cloud repository seeding and agent writes.
//!
//! The sidecar lives beside the checkout, so clone can still require an empty
//! destination. Never unlink it: replacing its inode would split the lock. A
//! failed or interrupted sync leaves a non-ready byte, including after restart.
//! This is coordination between cooperating processes, not a security sandbox.

use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use sha2::{Digest, Sha256};

/// A producer must hold this before its first change, and mark ready only after
/// every checkout, submodule and LFS operation has completed successfully.
pub struct Sync(File);

/// Shared locks stay held through the caller's write, preventing a new seed
/// from starting between the readiness check and the actual filesystem write.
pub struct Ready(Vec<File>);

pub enum Probe {
    Ready(Ready),
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
            Probe::Syncing => {
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
        // Take the repository lock first: a reader of an existing marker
        // refuses this sync immediately. A reader that preceded the first
        // marker instead holds the creation lease until its write completes.
        let creating = creation_lock(folder)?;
        wait_lock(&creating, libc::LOCK_EX)?;
        file.write_all(b"0")?;
        file.set_len(1)?;
        file.sync_data()?;
        Ok(Self(file))
    }

    /// A failed durability step leaves the barrier incomplete.
    pub fn complete(mut self) -> io::Result<()> {
        self.0.seek(SeekFrom::Start(0))?;
        self.0.write_all(b"1")?;
        if let Err(error) = self.0.sync_data() {
            let _ = self.0.seek(SeekFrom::Start(0));
            let _ = self.0.write_all(b"0");
            let _ = self.0.sync_data();
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
            return Ok(Probe::Syncing);
        }
        let mut ready = [0];
        if file.read(&mut ready)? != 1 || ready[0] != b'1' {
            return Ok(Probe::Incomplete);
        }
        held.push(file);
    }
    Ok(Probe::Ready(Ready(held)))
}

impl Drop for Ready {
    fn drop(&mut self) {
        // Closing releases each flock. This explicit clear documents that the
        // otherwise opaque field is the lifetime of the write's read lease.
        self.0.clear();
    }
}
