//! The mount of an [`Overlay`] (Linux, FUSE through the `fusermount3` binary, so no root and no
//! libfuse). Only the user who mounts it can reach it (no `allow_other`, which needs
//! `user_allow_other` in `/etc/fuse.conf`). The session loop answers metadata itself; reads,
//! writes and everything that may fetch from the Mac run on a small pool of threads, so one slow
//! fetch does not stall `ls` or `stat`.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::Path;

use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, SystemTime};

use fuser::{
    BackgroundSession, FileAttr, FileType, Filesystem, MountOption, ReplyAttr, ReplyCreate,
    ReplyData, ReplyDirectory, ReplyEmpty, ReplyEntry, ReplyOpen, ReplyStatfs, ReplyWrite, Request,
    TimeOrNow,
};

use crate::overlay::{Attr, Overlay, Set, Type, Who};
use crate::upper::SetTime;

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

/// How to mount.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// Only the read-only view: every write answers `EROFS` from the kernel. The lower a kernel
    /// overlay can stack an upper on, and what the conformance suites check alone.
    pub read_only: bool,
    /// Let users other than the mounting one in (`allow_other`: root, or `user_allow_other` in
    /// `/etc/fuse.conf`). The product never sets it; the conformance suites, which switch users,
    /// do.
    pub allow_other: bool,
    /// The source the mount table shows (default `cmux-projection`): a suite that finds its mount
    /// by its device name sets one.
    pub fsname: Option<String>,
    /// Access times follow the machine's disk (its `relatime`) instead of staying put (`noatime`,
    /// the default). A read-only mount always keeps them.
    pub disk_atime: bool,
}

/// Mounts `overlay` at `at` (an existing, empty folder).
pub fn mount(overlay: Arc<Overlay>, at: &Path) -> anyhow::Result<Mounted> {
    mount_with(overlay, at, Options::default())
}

/// Mounts `overlay` at `at` (an existing, empty folder) as `options` say.
pub fn mount_with(overlay: Arc<Overlay>, at: &Path, options: Options) -> anyhow::Result<Mounted> {
    let session =
        fuser::spawn_mount2(filesystem(overlay, &options)?, at, &mount_options(&options))?;
    Ok(Mounted { session: Some(session) })
}

/// Mounts `overlay` at `at` and serves it on this thread until it is unmounted from outside
/// (`fusermount3 -u`). `mounted` runs once the mount is up, before the first request.
pub fn serve(overlay: Arc<Overlay>, at: &Path, mounted: impl FnOnce()) -> anyhow::Result<()> {
    let options = Options::default();
    let mut session =
        fuser::Session::new(filesystem(overlay, &options)?, at, &mount_options(&options))?;
    mounted();
    session.run()?;
    Ok(())
}

fn mount_options(options: &Options) -> Vec<MountOption> {
    let mut mount_options = vec![
        MountOption::FSName(options.fsname.clone().unwrap_or_else(|| "cmux-projection".into())),
        MountOption::Subtype("cmux".into()),
        MountOption::DefaultPermissions,
        if options.disk_atime { MountOption::Atime } else { MountOption::NoAtime },
        if options.read_only { MountOption::RO } else { MountOption::RW },
    ];
    if options.allow_other {
        mount_options.push(MountOption::AllowOther);
    }
    mount_options
}

fn filesystem(overlay: Arc<Overlay>, options: &Options) -> anyhow::Result<Fs> {
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
    overlay.keep_atime(options.read_only || !options.disk_atime);
    Ok(Fs { overlay, jobs: sender, listings: HashMap::new() })
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
    /// Folder listings by handle, taken at `opendir` and again at each read from the start, so
    /// paging is stable and cheap.
    listings: HashMap<u64, Vec<(u64, FileType, String)>>,
}

fn file_type(kind: Type) -> FileType {
    match kind {
        Type::File => FileType::RegularFile,
        Type::Dir => FileType::Directory,
        Type::Link => FileType::Symlink,
        Type::Fifo => FileType::NamedPipe,
        Type::Socket => FileType::Socket,
        Type::Char => FileType::CharDevice,
        Type::Block => FileType::BlockDevice,
    }
}

fn file_attr(attr: &Attr) -> FileAttr {
    let mtime = Overlay::time_of(attr.mtime_ns);
    FileAttr {
        ino: attr.ino,
        size: attr.size,
        blocks: attr.blocks,
        atime: Overlay::time_of(attr.atime_ns),
        mtime,
        ctime: Overlay::time_of(attr.ctime_ns),
        crtime: mtime,
        kind: file_type(attr.kind),
        perm: u16::try_from(attr.mode & 0o7777).unwrap_or(0o644),
        nlink: attr.nlink,
        uid: attr.uid,
        gid: attr.gid,
        rdev: u32::try_from(attr.rdev).unwrap_or(0),
        blksize: 4096,
        flags: 0,
    }
}

fn name_of(name: &OsStr) -> Result<&str, i32> {
    name.to_str().ok_or(libc::EINVAL)
}

fn set_time(value: TimeOrNow) -> SetTime {
    match value {
        TimeOrNow::Now => SetTime::Now,
        TimeOrNow::SpecificTime(at) => {
            SetTime::At(match at.duration_since(SystemTime::UNIX_EPOCH) {
                Ok(since) => i64::try_from(since.as_nanos()).unwrap_or(i64::MAX),
                Err(before) => {
                    i64::try_from(before.duration().as_nanos()).map_or(i64::MIN, |ns| -ns)
                }
            })
        }
    }
}

fn who(req: &Request<'_>) -> Who {
    Who { uid: req.uid(), gid: req.gid() }
}

impl Fs {
    /// Folder `ino`'s listing as `readdir` pages it: `.`, `..`, then its names.
    fn listing(&self, ino: u64) -> Result<Vec<(u64, FileType, String)>, i32> {
        let entries = self.overlay.readdir(ino)?;
        let mut listing = Vec::with_capacity(entries.len() + 2);
        listing.push((ino, FileType::Directory, ".".to_owned()));
        listing.push((ino, FileType::Directory, "..".to_owned()));
        listing.extend(entries.into_iter().map(|(ino, kind, name)| (ino, file_type(kind), name)));
        Ok(listing)
    }

    fn run(&self, job: impl FnOnce(&Overlay) + Send + 'static) {
        let overlay = self.overlay.clone();
        let _ = self.jobs.send(Box::new(move || job(&overlay)));
    }
}

fn entry(reply: ReplyEntry, made: Result<Attr, i32>) {
    match made {
        Ok(attr) => reply.entry(&TTL, &file_attr(&attr), 0),
        Err(errno) => reply.error(errno),
    }
}

fn empty(reply: ReplyEmpty, done: Result<(), i32>) {
    match done {
        Ok(()) => reply.ok(),
        Err(errno) => reply.error(errno),
    }
}

impl Filesystem for Fs {
    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        entry(reply, name_of(name).and_then(|name| self.overlay.lookup(parent, name)));
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
        uid: Option<u32>,
        gid: Option<u32>,
        size: Option<u64>,
        atime: Option<TimeOrNow>,
        mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        fh: Option<u64>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<u32>,
        reply: ReplyAttr,
    ) {
        let set =
            Set { size, mode, uid, gid, atime: atime.map(set_time), mtime: mtime.map(set_time) };
        // A size or mode change may copy a lower file up (a fetch): off the session loop.
        self.run(move |overlay| match overlay.setattr(ino, fh, set) {
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

    fn mknod(
        &mut self,
        req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        mode: u32,
        umask: u32,
        rdev: u32,
        reply: ReplyEntry,
    ) {
        let who = who(req);
        let mode = (mode & libc::S_IFMT) | (mode & 0o7777 & !umask);
        entry(
            reply,
            name_of(name)
                .and_then(|name| self.overlay.mknod(parent, name, mode, u64::from(rdev), who)),
        );
    }

    fn mkdir(
        &mut self,
        req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        mode: u32,
        umask: u32,
        reply: ReplyEntry,
    ) {
        let who = who(req);
        entry(
            reply,
            name_of(name).and_then(|name| self.overlay.mkdir(parent, name, mode & !umask, who)),
        );
    }

    fn unlink(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        empty(reply, name_of(name).and_then(|name| self.overlay.unlink(parent, name)));
    }

    fn rmdir(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEmpty) {
        empty(reply, name_of(name).and_then(|name| self.overlay.rmdir(parent, name)));
    }

    fn symlink(
        &mut self,
        req: &Request<'_>,
        parent: u64,
        link_name: &OsStr,
        target: &Path,
        reply: ReplyEntry,
    ) {
        let who = who(req);
        entry(
            reply,
            name_of(link_name).and_then(|name| self.overlay.symlink(parent, name, target, who)),
        );
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
        let (Ok(name), Ok(newname)) = (name_of(name), name_of(newname)) else {
            reply.error(libc::EINVAL);
            return;
        };
        let (name, newname) = (name.to_owned(), newname.to_owned());
        // A rename may copy a lower file up (a fetch): off the session loop.
        self.run(move |overlay| {
            empty(reply, overlay.rename(parent, &name, newparent, &newname, flags));
        });
    }

    fn link(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        newparent: u64,
        newname: &OsStr,
        reply: ReplyEntry,
    ) {
        let Ok(newname) = name_of(newname).map(str::to_owned) else {
            reply.error(libc::EINVAL);
            return;
        };
        // A link of a lower file copies it up (a fetch): off the session loop.
        self.run(move |overlay| entry(reply, overlay.link(ino, newparent, &newname)));
    }

    fn open(&mut self, _req: &Request<'_>, ino: u64, flags: i32, reply: ReplyOpen) {
        // A write open copies a lower file up (a fetch): off the session loop.
        self.run(move |overlay| match overlay.open_handle(ino, flags) {
            Ok(handle) => reply.opened(handle, 0),
            Err(errno) => reply.error(errno),
        });
    }

    fn read(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        offset: i64,
        size: u32,
        _flags: i32,
        _lock_owner: Option<u64>,
        reply: ReplyData,
    ) {
        let offset = u64::try_from(offset).unwrap_or(0);
        self.run(move |overlay| match overlay.read_handle(fh, ino, offset, size) {
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
        self.run(move |overlay| match overlay.write_handle(fh, ino, offset, &data) {
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
        fh: u64,
        _flags: i32,
        _lock_owner: Option<u64>,
        _flush: bool,
        reply: ReplyEmpty,
    ) {
        self.overlay.release(fh);
        reply.ok();
    }

    fn fsync(&mut self, _req: &Request<'_>, _ino: u64, fh: u64, _data: bool, reply: ReplyEmpty) {
        self.run(move |overlay| empty(reply, overlay.fsync(fh)));
    }

    fn fallocate(
        &mut self,
        _req: &Request<'_>,
        _ino: u64,
        fh: u64,
        offset: i64,
        length: i64,
        mode: i32,
        reply: ReplyEmpty,
    ) {
        self.run(move |overlay| empty(reply, overlay.fallocate(fh, offset, length, mode)));
    }

    fn opendir(&mut self, _req: &Request<'_>, ino: u64, _flags: i32, reply: ReplyOpen) {
        // The overlay's handle keeps the folder's attributes readable (fstat) after it is deleted
        // or renamed over, as an open folder on a disk does.
        let listed = self.listing(ino).and_then(|listing| {
            Ok((self.overlay.open_handle(ino, libc::O_RDONLY | libc::O_DIRECTORY)?, listing))
        });
        match listed {
            Ok((handle, listing)) => {
                self.listings.insert(handle, listing);
                reply.opened(handle, 0);
            }
            Err(errno) => reply.error(errno),
        }
    }

    fn readdir(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        offset: i64,
        mut reply: ReplyDirectory,
    ) {
        // A read from the start (the first, or one after rewinddir) lists the folder as it is now:
        // POSIX has rewinddir see names made or deleted since the folder was opened.
        if offset == 0 && self.listings.contains_key(&fh) {
            match self.listing(ino) {
                Ok(listing) => {
                    self.listings.insert(fh, listing);
                }
                Err(errno) => {
                    reply.error(errno);
                    return;
                }
            }
        }
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
        self.overlay.release(fh);
        reply.ok();
    }

    fn statfs(&mut self, _req: &Request<'_>, _ino: u64, reply: ReplyStatfs) {
        match self.overlay.statfs() {
            Ok(vfs) => reply.statfs(
                vfs.f_blocks,
                vfs.f_bfree,
                vfs.f_bavail,
                vfs.f_files,
                vfs.f_ffree,
                u32::try_from(vfs.f_bsize).unwrap_or(4096),
                255,
                u32::try_from(vfs.f_frsize).unwrap_or(4096),
            ),
            Err(errno) => reply.error(errno),
        }
    }

    fn access(&mut self, _req: &Request<'_>, ino: u64, _mask: i32, reply: ReplyEmpty) {
        match self.overlay.getattr(ino) {
            Ok(_) => reply.ok(),
            Err(errno) => reply.error(errno),
        }
    }

    fn create(
        &mut self,
        req: &Request<'_>,
        parent: u64,
        name: &OsStr,
        mode: u32,
        umask: u32,
        _flags: i32,
        reply: ReplyCreate,
    ) {
        let who = who(req);
        match name_of(name).and_then(|name| self.overlay.create(parent, name, mode & !umask, who)) {
            Ok((attr, handle)) => reply.created(&TTL, &file_attr(&attr), 0, handle, 0),
            Err(errno) => reply.error(errno),
        }
    }
}

#[cfg(test)]
#[path = "mount_tests.rs"]
mod tests;
