//! The mount of an [`Overlay`] (Linux, FUSE through the `fusermount3` binary, so no root and no
//! libfuse). Only the user who mounts it can reach it (no `allow_other`, which needs
//! `user_allow_other` in `/etc/fuse.conf`). The session loop answers metadata itself; reads,
//! writes and everything that may fetch from the Mac run on a small pool of threads, so one slow
//! fetch does not stall `ls` or `stat`.
//!
//! What the kernel keeps (so a warm read or `stat` never reaches this process):
//! - a file's pages across opens (`FOPEN_KEEP_CACHE`) while its [`Version`] is the one it had at
//!   the last open; any other version (an upper file changed on the disk, a lower file copied up)
//!   opens without it, which drops the pages, after its cached attributes are dropped too;
//! - an answer about a path only in the manifest for [`LOWER_TTL`] (the manifest is fixed for the
//!   life of the mount, and every change to the path comes through the mount, which tells the
//!   kernel), an answer about an upper path for [`UPPER_TTL`] (the upper folder
//!   is plain files on the machine's disk);
//! - `FUSE_AUTO_INVAL_DATA`: pages go when a fresh `stat` shows another size or mtime.
//!
//! No writeback cache: edits must be on the upper folder's disk when the write returns, because
//! Bring Back and the daemon restart read that folder directly, never through the mount.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::fs::File;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::consts::FOPEN_KEEP_CACHE;
use fuser::{
    BackgroundSession, FileAttr, FileType, Filesystem, KernelConfig, MountOption, Notifier,
    ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen,
    ReplyStatfs, ReplyWrite, Request, TimeOrNow,
};

use crate::manifest::Kind;
use crate::overlay::{Attr, Overlay, Version};

/// `FUSE_AUTO_INVAL_DATA` (ABI 7.20, which fuser 0.14 names only with its `abi-7-20` feature; the
/// kernel reads the flag at any minor version).
const FUSE_AUTO_INVAL_DATA: u32 = 1 << 12;

/// How long the kernel may keep an answer about a path only in the manifest.
pub const LOWER_TTL: Duration = Duration::from_secs(3600);
/// How long the kernel may keep an answer about an upper path (a missing path is never kept).
pub const UPPER_TTL: Duration = Duration::from_secs(1);

/// Whether `version` is an upper file whose last change is too recent to tell apart from the next.
fn racy(version: &Version) -> bool {
    let Version::Upper { ctime_ns, .. } = *version else { return false };
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|since| i64::try_from(since.as_nanos()).ok())
        .unwrap_or(i64::MAX);
    now.saturating_sub(ctime_ns) < 1_000_000_000
}

fn ttl(attr: &Attr) -> Duration {
    if attr.upper { UPPER_TTL } else { LOWER_TTL }
}

/// Threads that run reads and writes.
const WORKERS: usize = 16;

type Job = Box<dyn FnOnce() + Send>;

/// A mounted projection; dropping it unmounts.
pub struct Mounted {
    session: Option<BackgroundSession>,
}

impl Mounted {
    /// Unmounts and waits for the session to end.
    pub fn unmount(mut self) {
        if let Some(session) = self.session.take() {
            session.join();
        }
    }
}

impl Drop for Mounted {
    fn drop(&mut self) {
        if let Some(session) = self.session.take() {
            session.join();
        }
    }
}

/// Mounts `overlay` at `at` (an existing, empty folder).
pub fn mount(overlay: Arc<Overlay>, at: &Path) -> anyhow::Result<Mounted> {
    let (sender, receiver) = channel::<Job>();
    let receiver = Arc::new(Mutex::new(receiver));
    for index in 0..WORKERS {
        let receiver = receiver.clone();
        std::thread::Builder::new().name(format!("projection-io-{index}")).spawn(move || {
            loop {
                let job = receiver.lock().unwrap_or_else(PoisonError::into_inner).recv();
                match job {
                    Ok(job) => job(),
                    Err(_) => return,
                }
            }
        })?;
    }
    let notifier: Arc<OnceLock<Notifier>> = Arc::new(OnceLock::new());
    let fs = Fs {
        overlay,
        jobs: sender,
        listings: HashMap::new(),
        next_handle: AtomicU64::new(1),
        writers: Arc::new(Mutex::new(HashMap::new())),
        versions: HashMap::new(),
        notifier: notifier.clone(),
    };
    let options = [
        MountOption::FSName("cmux-projection".into()),
        MountOption::Subtype("cmux".into()),
        MountOption::DefaultPermissions,
        MountOption::NoAtime,
        MountOption::RW,
    ];
    let session = fuser::spawn_mount2(fs, at, &options)?;
    // Set before this returns, so before anything the caller starts opens through the mount.
    let _ = notifier.set(session.notifier());
    Ok(Mounted { session: Some(session) })
}

/// Lazily unmounts whatever is mounted at `at` (a dead mount a daemon restart left), ignoring
/// every error.
pub fn unmount_stale(at: &Path) {
    let _ = std::process::Command::new("fusermount3")
        .arg("-u")
        .arg("-z")
        .arg(at)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status();
}

struct Fs {
    overlay: Arc<Overlay>,
    jobs: Sender<Job>,
    /// Folder listings by handle, taken at `opendir` so paging is stable and cheap.
    listings: HashMap<u64, Vec<(u64, FileType, String)>>,
    /// Handles for files and folders alike.
    next_handle: AtomicU64,
    /// The upper file each open handle writes to, opened at its create or first write (so later
    /// writes open nothing); dropped at its release.
    writers: Arc<Mutex<HashMap<u64, Arc<File>>>>,
    /// Each file's [`Version`] at its last open: the pages the kernel holds are of it.
    versions: HashMap<u64, Version>,
    notifier: Arc<OnceLock<Notifier>>,
}

fn file_type(kind: Kind) -> FileType {
    match kind {
        Kind::File => FileType::RegularFile,
        Kind::Dir => FileType::Directory,
        Kind::Link => FileType::Symlink,
    }
}

fn time(ns: i64) -> SystemTime {
    UNIX_EPOCH + Duration::from_nanos(u64::try_from(ns).unwrap_or(0))
}

fn file_attr(attr: &Attr) -> FileAttr {
    let at = time(attr.mtime_ns);
    FileAttr {
        ino: attr.ino,
        size: attr.size,
        blocks: attr.size.div_ceil(512),
        atime: at,
        mtime: at,
        ctime: at,
        crtime: at,
        kind: file_type(attr.kind),
        perm: u16::try_from(attr.mode & 0o7777).unwrap_or(0o644),
        nlink: attr.nlink,
        uid: attr.uid,
        gid: attr.gid,
        rdev: 0,
        blksize: 4096,
        flags: 0,
    }
}

fn name_of(name: &OsStr) -> Result<&str, i32> {
    name.to_str().ok_or(libc::EINVAL)
}

fn ns_of(value: TimeOrNow) -> i64 {
    let at = match value {
        TimeOrNow::SpecificTime(at) => at,
        TimeOrNow::Now => SystemTime::now(),
    };
    at.duration_since(UNIX_EPOCH)
        .ok()
        .and_then(|since| i64::try_from(since.as_nanos()).ok())
        .unwrap_or(0)
}

impl Fs {
    fn run(&self, job: impl FnOnce(&Overlay) + Send + 'static) {
        let overlay = self.overlay.clone();
        let _ = self.jobs.send(Box::new(move || job(&overlay)));
    }

    /// `FOPEN_KEEP_CACHE` when file `ino` is at the version it had at its last open (the kernel's
    /// pages are of these bytes), else nothing, which drops them. A changed file's cached
    /// attributes go first, so the opener's `fstat` sees its size now. No page is held during an
    /// open, so telling the kernel here, before the answer, cannot wait on this open.
    fn open_flags(&mut self, ino: u64) -> u32 {
        let Ok(Some(now)) = self.overlay.version(ino) else {
            self.versions.remove(&ino);
            return 0;
        };
        match self.versions.insert(ino, now) {
            // An upper file changed under a second ago is never trusted equal (git's "racily
            // clean"): on a disk with coarse timestamps a same-size rewrite in the same tick
            // leaves size, mtime and ctime as they were.
            Some(before) if before == now && !racy(&now) => FOPEN_KEEP_CACHE,
            Some(_) => {
                if let Some(notifier) = self.notifier.get() {
                    // ENOENT: the kernel holds nothing of it, which is fine.
                    let _ = notifier.inval_inode(ino, -1, 0);
                }
                0
            }
            None => 0,
        }
    }
}

impl Filesystem for Fs {
    fn init(&mut self, _req: &Request<'_>, config: &mut KernelConfig) -> Result<(), libc::c_int> {
        // A kernel without it still works: an open of a changed file drops its pages anyway.
        let _ = config.add_capabilities(FUSE_AUTO_INVAL_DATA);
        Ok(())
    }

    fn forget(&mut self, _req: &Request<'_>, ino: u64, _nlookup: u64) {
        // The kernel let the inode go, and its pages with it.
        self.versions.remove(&ino);
    }

    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        match name_of(name).and_then(|name| self.overlay.lookup(parent, name)) {
            Ok(attr) => reply.entry(&ttl(&attr), &file_attr(&attr), 0),
            Err(errno) => reply.error(errno),
        }
    }

    fn getattr(&mut self, _req: &Request<'_>, ino: u64, reply: ReplyAttr) {
        match self.overlay.getattr(ino) {
            Ok(attr) => reply.attr(&ttl(&attr), &file_attr(&attr)),
            Err(errno) => reply.error(errno),
        }
    }

    fn setattr(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        size: Option<u64>,
        _atime: Option<TimeOrNow>,
        mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<u64>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        let mtime = mtime.map(ns_of);
        // A change through an open handle (`futimens`, `ftruncate`, `fchmod`: tar sets each file's
        // time that way) goes to the file that handle writes, without a lookup or an open.
        let held = fh.and_then(|fh| {
            self.writers.lock().unwrap_or_else(PoisonError::into_inner).get(&fh).cloned()
        });
        self.run(move |overlay| {
            let result = match held {
                Some(file) => overlay.setattr_open(ino, &file, size, mode, mtime),
                None => overlay.setattr(ino, size, mode, mtime),
            };
            match result {
                Ok(attr) => reply.attr(&ttl(&attr), &file_attr(&attr)),
                Err(errno) => reply.error(errno),
            }
        });
    }

    fn readlink(&mut self, _req: &Request<'_>, ino: u64, reply: ReplyData) {
        match self.overlay.readlink(ino) {
            Ok(target) => reply.data(&target),
            Err(errno) => reply.error(errno),
        }
    }

    fn mkdir(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        mode: u32,
        umask: u32,
        reply: ReplyEntry,
    ) {
        match name_of(name).and_then(|name| self.overlay.mkdir(parent, name, mode & !umask)) {
            Ok(attr) => reply.entry(&ttl(&attr), &file_attr(&attr), 0),
            Err(errno) => reply.error(errno),
        }
    }

    fn unlink(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        match name_of(name).and_then(|name| self.overlay.unlink(parent, name)) {
            Ok(()) => reply.ok(),
            Err(errno) => reply.error(errno),
        }
    }

    fn rmdir(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        match name_of(name).and_then(|name| self.overlay.rmdir(parent, name)) {
            Ok(()) => reply.ok(),
            Err(errno) => reply.error(errno),
        }
    }

    fn symlink(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        link_name: &OsStr,
        target: &Path,
        reply: ReplyEntry,
    ) {
        match name_of(link_name).and_then(|name| self.overlay.symlink(parent, name, target)) {
            Ok(attr) => reply.entry(&ttl(&attr), &file_attr(&attr), 0),
            Err(errno) => reply.error(errno),
        }
    }

    fn rename(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        newparent: u64,
        newname: &OsStr,
        flags: u32,
        reply: ReplyEmpty,
    ) {
        if flags != 0 {
            // RENAME_NOREPLACE, RENAME_EXCHANGE: not in this slice.
            reply.error(libc::EINVAL);
            return;
        }
        let (Ok(name), Ok(newname)) = (name_of(name), name_of(newname)) else {
            reply.error(libc::EINVAL);
            return;
        };
        let (name, newname) = (name.to_owned(), newname.to_owned());
        // A rename may copy a lower file up (a fetch): off the session loop.
        self.run(move |overlay| match overlay.rename(parent, &name, newparent, &newname) {
            Ok(()) => reply.ok(),
            Err(errno) => reply.error(errno),
        });
    }

    fn open(&mut self, _req: &Request<'_>, ino: u64, _flags: i32, reply: ReplyOpen) {
        let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
        reply.opened(handle, self.open_flags(ino));
    }

    fn read(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        _fh: u64,
        offset: i64,
        size: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyData,
    ) {
        let offset = u64::try_from(offset).unwrap_or(0);
        self.run(move |overlay| match overlay.read(ino, offset, size) {
            Ok(bytes) => reply.data(&bytes),
            Err(errno) => reply.error(errno),
        });
    }

    fn write(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        offset: i64,
        data: &[u8],
        _write_flags: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyWrite,
    ) {
        let offset = u64::try_from(offset).unwrap_or(0);
        let data = data.to_vec();
        let writers = self.writers.clone();
        // A write may copy a lower file up (a fetch): off the session loop.
        self.run(move |overlay| {
            let held = writers.lock().unwrap_or_else(PoisonError::into_inner).get(&fh).cloned();
            let file = match held {
                Some(file) => file,
                None => match overlay.writer(ino) {
                    Ok(file) => {
                        let file = Arc::new(file);
                        if fh != 0 {
                            writers
                                .lock()
                                .unwrap_or_else(PoisonError::into_inner)
                                .insert(fh, file.clone());
                        }
                        file
                    }
                    Err(errno) => return reply.error(errno),
                },
            };
            match Overlay::write_to(&file, offset, &data) {
                Ok(written) => reply.written(written),
                Err(errno) => reply.error(errno),
            }
        });
    }

    fn flush(&mut self, _req: &Request<'_>, _ino: u64, _fh: u64, _owner: u64, reply: ReplyEmpty) {
        // Nothing is buffered here (every write is on the disk when it is answered) and there are
        // no locks to drop: ENOSYS tells the kernel to stop sending a flush on every close, one
        // round trip less per file a tool writes. The close itself succeeds.
        reply.error(libc::ENOSYS);
    }

    fn release(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        _flags: i32,
        _lock_owner: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        // The kernel releases a handle only after every write through it was answered.
        self.writers.lock().unwrap_or_else(PoisonError::into_inner).remove(&fh);
        reply.ok();
    }

    fn fsync(&mut self, _req: &Request<'_>, ino: u64, _fh: u64, _data: bool, reply: ReplyEmpty) {
        match self.overlay.fsync(ino) {
            Ok(()) => reply.ok(),
            Err(errno) => reply.error(errno),
        }
    }

    fn opendir(&mut self, _req: &Request<'_>, ino: u64, _flags: i32, reply: ReplyOpen) {
        match self.overlay.readdir(ino) {
            Ok(entries) => {
                let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
                let mut listing = vec![
                    (ino, FileType::Directory, ".".to_owned()),
                    (ino, FileType::Directory, "..".to_owned()),
                ];
                listing.extend(
                    entries.into_iter().map(|(ino, kind, name)| (ino, file_type(kind), name)),
                );
                self.listings.insert(handle, listing);
                reply.opened(handle, 0);
            }
            Err(errno) => reply.error(errno),
        }
    }

    fn readdir(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        let Some(listing) = self.listings.get(&fh) else {
            reply.error(libc::EBADF);
            return;
        };
        let start = usize::try_from(offset).unwrap_or(0);
        for (at, (ino, kind, name)) in listing.iter().enumerate().skip(start) {
            let next = i64::try_from(at + 1).unwrap_or(i64::MAX);
            if reply.add(*ino, next, *kind, name) {
                break;
            }
        }
        reply.ok();
    }

    fn releasedir(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        _flags: i32,
        reply: ReplyEmpty,
    ) {
        self.listings.remove(&fh);
        reply.ok();
    }

    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        reply.statfs(1 << 40, 1 << 39, 1 << 39, 1 << 32, 1 << 31, 4096, 255, 4096);
    }

    fn access(&mut self, _req: &Request<'_>, ino: u64, _mask: i32, reply: ReplyEmpty) {
        match self.overlay.getattr(ino) {
            Ok(_) => reply.ok(),
            Err(errno) => reply.error(errno),
        }
    }

    fn create(
        &mut self,
        _req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        mode: u32,
        umask: u32,
        _flags: i32,
        reply: ReplyCreate,
    ) {
        match name_of(name).and_then(|name| self.overlay.create_open(parent, name, mode & !umask)) {
            Ok((attr, file)) => {
                let handle = self.next_handle.fetch_add(1, Ordering::Relaxed);
                // Its writes go straight to the file this create opened.
                self.writers
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .insert(handle, Arc::new(file));
                // A new file: whatever the kernel held under this number is not of it.
                self.versions.remove(&attr.ino);
                reply.created(&ttl(&attr), &file_attr(&attr), 0, handle, 0);
            }
            Err(errno) => reply.error(errno),
        }
    }
}

#[cfg(test)]
#[path = "mount_tests.rs"]
mod tests;
