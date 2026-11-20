//! The mount of an [`Overlay`] (Linux, FUSE through the `fusermount3` binary, so no root and no
//! libfuse). Only the user who mounts it can reach it (no `allow_other`, which needs
//! `user_allow_other` in `/etc/fuse.conf`). The session loop answers metadata itself; reads,
//! writes and everything that may fetch from the Mac run on a small pool of threads, so one slow
//! fetch does not stall `ls` or `stat`.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{
    BackgroundSession, FileAttr, FileType, Filesystem, MountOption, Notifier, ReplyAttr,
    ReplyCreate, ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen, ReplyStatfs,
    ReplyWrite, Request, TimeOrNow,
};

use crate::manifest::Kind;
use crate::overlay::{Attr, Overlay};

/// How long the kernel may keep an answer.
const TTL: Duration = Duration::from_secs(1);
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
    let (filesystem, notifier) = filesystem(overlay)?;
    let session = fuser::spawn_mount2(filesystem, at, &options())?;
    // Set before this returns, so before anything the caller starts can read through the mount.
    let _ = notifier.set(session.notifier());
    Ok(Mounted { session: Some(session) })
}

/// Mounts `overlay` at `at` and serves it on this thread until it is unmounted from outside
/// (`fusermount3 -u`). `mounted` runs once the mount is up, before the first request.
pub fn serve(overlay: Arc<Overlay>, at: &Path, mounted: impl FnOnce()) -> anyhow::Result<()> {
    let (filesystem, notifier) = filesystem(overlay)?;
    let mut session = fuser::Session::new(filesystem, at, &options())?;
    let _ = notifier.set(session.notifier());
    mounted();
    session.run()?;
    Ok(())
}

fn options() -> [MountOption; 5] {
    [
        MountOption::FSName("cmux-projection".into()),
        MountOption::Subtype("cmux".into()),
        MountOption::DefaultPermissions,
        MountOption::NoAtime,
        MountOption::RW,
    ]
}

/// The kernel's notifier, set once the session exists (after the [`Fs`] that uses it is made).
type SharedNotifier = Arc<OnceLock<Notifier>>;

fn filesystem(overlay: Arc<Overlay>) -> anyhow::Result<(Fs, SharedNotifier)> {
    let notifier: SharedNotifier = Arc::new(OnceLock::new());
    // A file the Mac re-listed (RFD 0007, hard case 7): its cached attributes and pages go, on a
    // thread of their own, after the read that found the change was answered (the kernel waits
    // for a page a read still holds; a worker that waited there could hold up that read).
    let (invalidate, invalidations) = channel::<u64>();
    {
        let notifier = notifier.clone();
        std::thread::Builder::new().name("projection-invalidate".into()).spawn(move || {
            while let Ok(ino) = invalidations.recv() {
                if let Some(notifier) = notifier.get() {
                    // ENOENT: the kernel holds nothing of it, which is fine.
                    let _ = notifier.inval_inode(ino, 0, 0);
                }
            }
        })?;
    }
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
    let fs = Fs {
        overlay,
        jobs: sender,
        invalidate,
        notifier: notifier.clone(),
        listings: HashMap::new(),
        next_handle: AtomicU64::new(1),
    };
    Ok((fs, notifier))
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
    /// Inodes whose cached attributes and pages the kernel is told to drop.
    invalidate: Sender<u64>,
    notifier: SharedNotifier,
    /// Folder listings by handle, taken at `opendir` so paging is stable and cheap.
    listings: HashMap<u64, Vec<(u64, FileType, String)>>,
    next_handle: AtomicU64,
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
    /// Runs `job` (which replies) on a worker, then queues what it re-listed for the kernel.
    fn run(&self, job: impl FnOnce(&Overlay) + Send + 'static) {
        let overlay = self.overlay.clone();
        let invalidate = self.invalidate.clone();
        let _ = self.jobs.send(Box::new(move || {
            job(&overlay);
            for ino in overlay.take_restated() {
                let _ = invalidate.send(ino);
            }
        }));
    }
}

impl Filesystem for Fs {
    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        match name_of(name).and_then(|name| self.overlay.lookup(parent, name)) {
            Ok(attr) => reply.entry(&TTL, &file_attr(&attr), 0),
            Err(errno) => reply.error(errno),
        }
    }

    fn getattr(&mut self, _req: &Request<'_>, ino: u64, reply: ReplyAttr) {
        match self.overlay.getattr(ino) {
            Ok(attr) => reply.attr(&TTL, &file_attr(&attr)),
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
        _fh: Option<u64>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        let mtime = mtime.map(ns_of);
        self.run(move |overlay| match overlay.setattr(ino, size, mode, mtime) {
            Ok(attr) => reply.attr(&TTL, &file_attr(&attr)),
            Err(errno) => reply.error(errno),
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
            Ok(attr) => reply.entry(&TTL, &file_attr(&attr), 0),
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
            Ok(attr) => reply.entry(&TTL, &file_attr(&attr), 0),
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

    fn open(&mut self, _req: &Request<'_>, ino: u64, flags: i32, reply: ReplyOpen) {
        if flags & libc::O_ACCMODE == libc::O_WRONLY || self.overlay.open_fault(ino).is_none() {
            reply.opened(0, 0);
            return;
        }
        // Opening a lower file not on the machine yet is a fault (hard case 7): a file the Mac
        // changed is re-listed now, and the kernel forgets its old attributes before the opener's
        // `fstat` (git sizes its index that way, then maps it). No page is held during an open, so
        // the attributes go here, before the answer; the open drops the pages itself (no
        // FOPEN_KEEP_CACHE).
        let notifier = self.notifier.clone();
        self.run(move |overlay| {
            if overlay.open_lower(ino)
                && let Some(notifier) = notifier.get()
            {
                let _ = notifier.inval_inode(ino, -1, 0);
            }
            reply.opened(0, 0);
        });
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
        _fh: u64,
        offset: i64,
        data: &[u8],
        _write_flags: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyWrite,
    ) {
        let offset = u64::try_from(offset).unwrap_or(0);
        let data = data.to_vec();
        self.run(move |overlay| match overlay.write(ino, offset, &data) {
            Ok(written) => reply.written(written),
            Err(errno) => reply.error(errno),
        });
    }

    fn flush(&mut self, _req: &Request<'_>, _ino: u64, _fh: u64, _owner: u64, reply: ReplyEmpty) {
        reply.ok();
    }

    fn release(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        _fh: u64,
        _flags: i32,
        _lock_owner: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
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
        match name_of(name).and_then(|name| self.overlay.create(parent, name, mode & !umask)) {
            Ok(attr) => reply.created(&TTL, &file_attr(&attr), 0, 0, 0),
            Err(errno) => reply.error(errno),
        }
    }
}

#[cfg(test)]
#[path = "mount_tests.rs"]
mod tests;
