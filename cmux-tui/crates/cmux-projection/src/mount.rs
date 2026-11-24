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
//! - a listing of a folder only in the manifest (`FOPEN_CACHE_DIR`), dropped by the kernel when a
//!   change through the mount touches the folder, and each listed name's `stat` with it
//!   (`FUSE_DO_READDIRPLUS`), so a walk asks this process once per folder and never per file;
//! - `FUSE_AUTO_INVAL_DATA`: pages go when a fresh `stat` shows another size or mtime.
//!
//! No writeback cache: edits must be on the upper folder's disk when the write returns, because
//! Bring Back and the daemon restart read that folder directly, never through the mount.

use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::Path;

use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::consts::{
    FOPEN_CACHE_DIR, FOPEN_KEEP_CACHE, FUSE_ATOMIC_O_TRUNC, FUSE_AUTO_INVAL_DATA,
    FUSE_DO_READDIRPLUS,
};
use fuser::{
    BackgroundSession, FileAttr, FileType, Filesystem, KernelConfig, MountOption, Notifier,
    ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory, ReplyDirectoryPlus, ReplyEmpty, ReplyEntry,
    ReplyOpen, ReplyStatfs, ReplyWrite, Request, TimeOrNow,
};

use crate::overlay::{Attr, Overlay, Set, Type, Version, Who};
use crate::upper::SetTime;

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

/// A listed name: its number, kind, name, and its attributes when the listing had them.
type Listed = (u64, FileType, String, Option<Attr>);

/// Threads that run reads and writes.
const WORKERS: usize = 16;

type Job = Box<dyn FnOnce() + Send>;

/// A mounted projection; dropping it unmounts.
pub struct Mounted {
    session: Option<BackgroundSession>,
    notifier: Option<Notifier>,
}

impl Mounted {
    /// Tells the kernel to drop what it cached of `name` in folder `parent` (a number the overlay
    /// gave), so the next lookup asks the overlay again: after [`Overlay::swap_to_link`].
    pub fn forget_entry(&self, parent: u64, name: &str) -> std::io::Result<()> {
        match &self.notifier {
            Some(notifier) => notifier.inval_entry(parent, OsStr::new(name)),
            None => Ok(()),
        }
    }

    /// Tells the kernel to drop what it cached of each folder or file in `inos` (numbers the
    /// overlay gave): its attributes, its pages, and a folder's listing, so the next `stat`,
    /// read and `ls` ask the overlay again: after [`Overlay::extend`].
    pub fn forget_inodes(&self, inos: &[u64]) {
        if let Some(notifier) = &self.notifier {
            for ino in inos {
                // ENOENT: the kernel holds nothing of it, which is fine.
                let _ = notifier.inval_inode(*ino, 0, 0);
            }
        }
    }

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
    let (fs, notifier) = filesystem(overlay, &options)?;
    let session = fuser::spawn_mount2(fs, at, &mount_options(&options))?;
    // Set before this returns, so before anything the caller starts opens through the mount.
    let _ = notifier.set(session.notifier());
    Ok(Mounted { notifier: Some(session.notifier()), session: Some(session) })
}

/// Mounts `overlay` at `at` and serves it on this thread until it is unmounted from outside
/// (`fusermount3 -u`) or this process gets SIGTERM, SIGINT or SIGHUP, which unmount it
/// ([`unmount_on_signal`]). `mounted` runs once the mount is up, before the first request.
pub fn serve(overlay: Arc<Overlay>, at: &Path, mounted: impl FnOnce()) -> anyhow::Result<()> {
    serve_with(overlay, at, Options::default(), mounted)
}

/// [`serve`] as `options` say (a read-only lower: `read_only`).
pub fn serve_with(
    overlay: Arc<Overlay>,
    at: &Path,
    options: Options,
    mounted: impl FnOnce(),
) -> anyhow::Result<()> {
    let (fs, notifier) = filesystem(overlay, &options)?;
    let mut session = fuser::Session::new(fs, at, &mount_options(&options))?;
    unmount_on_signal(at)?;
    // Set before the first request is read, so before any open.
    let _ = notifier.set(session.notifier());
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

/// The file system, and where its session's notifier goes once the session exists.
fn filesystem(
    overlay: Arc<Overlay>,
    options: &Options,
) -> anyhow::Result<(Fs, Arc<OnceLock<Notifier>>)> {
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
    let notifier: Arc<OnceLock<Notifier>> = Arc::new(OnceLock::new());
    let fs = Fs {
        overlay,
        jobs: sender,
        listings: HashMap::new(),
        versions: Arc::new(Mutex::new(HashMap::new())),
        notifier: notifier.clone(),
        read_only: options.read_only,
    };
    Ok((fs, notifier))
}

/// The write end of the pipe [`on_stop_signal`] wakes the unmounting thread through (-1: none).
static STOP_PIPE: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_stop_signal(_: libc::c_int) {
    let fd = STOP_PIPE.load(Ordering::Relaxed);
    if fd >= 0 {
        let byte = 1_u8;
        // SAFETY: write(2) is async-signal-safe; the byte outlives the call.
        let _ = unsafe { libc::write(fd, (&raw const byte).cast(), 1) };
    }
}

/// On SIGTERM, SIGINT or SIGHUP, unmounts `at`, so the session loop of [`serve`] sees the device
/// go and returns, and the process exits with no mount left behind. A service manager's stop (or
/// Ctrl-C) used to kill the server with its mount still in the table: every call at `at` then
/// failed with ENOTCONN ("Transport endpoint is not connected") until someone ran
/// `fusermount3 -u`. The handler only writes a byte to a pipe; a thread does the unmount: a plain
/// one first, a lazy one when something still has the mount open (its edits are on the upper
/// folder's disk already, nothing is lost). Handlers reset at exec, so no child inherits them.
fn unmount_on_signal(at: &Path) -> anyhow::Result<()> {
    let mut fds = [0; 2];
    // SAFETY: pipe2 writes two descriptors into `fds`.
    anyhow::ensure!(
        unsafe { libc::pipe2(fds.as_mut_ptr(), libc::O_CLOEXEC) } == 0,
        "pipe2: {}",
        std::io::Error::last_os_error()
    );
    let [read, write] = fds;
    STOP_PIPE.store(write, Ordering::Relaxed);
    let at = at.to_path_buf();
    std::thread::Builder::new().name("projection-stop".into()).spawn(move || {
        let mut byte = 0_u8;
        loop {
            // SAFETY: reads one byte into `byte` from the pipe this function made.
            let got = unsafe { libc::read(read, (&raw mut byte).cast(), 1) };
            if got == 1 {
                break;
            }
            if got < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
            {
                continue;
            }
            return;
        }
        let plain = std::process::Command::new("fusermount3")
            .arg("-u")
            .arg(&at)
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        if !plain.is_ok_and(|status| status.success()) {
            unmount_stale(&at);
        }
    })?;
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
        // SAFETY: a zeroed sigaction with a handler that only calls write(2).
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = on_stop_signal as extern "C" fn(libc::c_int) as usize;
            action.sa_flags = libc::SA_RESTART;
            libc::sigemptyset(&raw mut action.sa_mask);
            anyhow::ensure!(
                libc::sigaction(signal, &raw const action, std::ptr::null_mut()) == 0,
                "sigaction: {}",
                std::io::Error::last_os_error()
            );
        }
    }
    Ok(())
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
    listings: HashMap<u64, Arc<[Listed]>>,
    /// Each file's [`Version`] at its last open: the pages the kernel holds are of it.
    versions: Arc<Mutex<HashMap<u64, Version>>>,
    notifier: Arc<OnceLock<Notifier>>,
    /// A read-only mount: nothing in it ever changes, so the kernel keeps folder listings.
    read_only: bool,
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
    fn listing(&self, ino: u64) -> Result<Vec<Listed>, i32> {
        let entries = self.overlay.readdir_plus(ino)?;
        let mut listing = Vec::with_capacity(entries.len() + 2);
        listing.push((ino, FileType::Directory, ".".to_owned(), None));
        listing.push((ino, FileType::Directory, "..".to_owned(), None));
        listing.extend(
            entries.into_iter().map(|(ino, kind, name, attr)| (ino, file_type(kind), name, attr)),
        );
        Ok(listing)
    }

    /// The listing a read of handle `fh` at `offset` answers from. A read from the start (the
    /// first, or one after rewinddir) lists the folder as it is now: POSIX has rewinddir see
    /// names made or deleted since the folder was opened.
    fn listing_at(&mut self, ino: u64, fh: u64, offset: i64) -> Result<Arc<[Listed]>, i32> {
        if offset == 0 && self.listings.contains_key(&fh) {
            let listing = self.listing(ino)?;
            self.listings.insert(fh, listing.into());
        }
        self.listings.get(&fh).cloned().ok_or(libc::EBADF)
    }

    fn run(&self, job: impl FnOnce(&Overlay) + Send + 'static) {
        let overlay = self.overlay.clone();
        let _ = self.jobs.send(Box::new(move || job(&overlay)));
    }
}

/// `FOPEN_KEEP_CACHE` when file `ino` is at the version it had at its last open (the kernel's
/// pages are of these bytes), else nothing, which drops them. A changed file's cached attributes
/// go first, so the opener's `fstat` sees its size now. No page is held during an open, so telling
/// the kernel here, before the answer, cannot wait on this open.
fn open_flags(
    overlay: &Overlay,
    versions: &Mutex<HashMap<u64, Version>>,
    notifier: &OnceLock<Notifier>,
    ino: u64,
) -> u32 {
    let mut versions = versions.lock().unwrap_or_else(PoisonError::into_inner);
    let Ok(Some(now)) = overlay.version(ino) else {
        versions.remove(&ino);
        return 0;
    };
    // An upper file changed under a second ago is never recorded (git's "racily clean"): on a
    // disk with coarse timestamps a same-size rewrite in the same tick leaves size, mtime and
    // ctime as they were, so only a version seen a second or more after its change can later
    // earn the kept cache.
    let before = if racy(&now) { versions.remove(&ino) } else { versions.insert(ino, now) };
    drop(versions);
    let inval = || {
        if let Some(notifier) = notifier.get() {
            // ENOENT: the kernel holds nothing of it, which is fine.
            let _ = notifier.inval_inode(ino, -1, 0);
        }
    };
    match before {
        Some(before) if before == now && !racy(&now) => FOPEN_KEEP_CACHE,
        Some(_) => {
            inval();
            0
        }
        // A first open of an upper version (a copy-up since the lookup): drop the lower attrs
        // the kernel keeps for an hour.
        None if matches!(now, Version::Upper { .. }) => {
            inval();
            0
        }
        None => 0,
    }
}

/// `FOPEN_CACHE_DIR | FOPEN_KEEP_CACHE` for a folder only in the manifest, else nothing. The
/// manifest is fixed for the life of the mount, so such a folder's names change only by a create,
/// unlink, rename or rmdir through the mount, each of which drops the kernel's cached listing
/// itself; the next walk (`git status`, `find`, `rg`) is then answered by the kernel, with no
/// `READDIR`. An upper folder is plain files on the machine's disk and is listed afresh.
fn dir_flags(overlay: &Overlay, ino: u64) -> u32 {
    if overlay.lower_only(ino) { FOPEN_CACHE_DIR | FOPEN_KEEP_CACHE } else { 0 }
}

fn entry(reply: ReplyEntry, made: Result<Attr, i32>) {
    match made {
        Ok(attr) => reply.entry(&ttl(&attr), &file_attr(&attr), 0),
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
    fn init(&mut self, _req: &Request<'_>, config: &mut KernelConfig) -> Result<(), libc::c_int> {
        // A kernel without it still works: an open of a changed file drops its pages anyway.
        let _ = config.add_capabilities(FUSE_AUTO_INVAL_DATA);
        // open(O_TRUNC) arrives as one open with the flag, not an open and then a truncate: a
        // lower file it empties copies up empty, never fetching the bytes it drops.
        let _ = config.add_capabilities(FUSE_ATOMIC_O_TRUNC);
        // Every listing carries its entries' attributes (not `FUSE_READDIRPLUS_AUTO`, which sends
        // them only for a folder's first chunk or one already looked up in): the manifest answers
        // them with no fetch, and a walk then never asks per file. A kernel without it lists as
        // before and looks each name up.
        let _ = config.add_capabilities(FUSE_DO_READDIRPLUS);
        Ok(())
    }

    fn forget(&mut self, _req: &Request<'_>, ino: u64, _nlookup: u64) {
        // The kernel let the inode go, and its pages with it.
        self.versions.lock().unwrap_or_else(PoisonError::into_inner).remove(&ino);
    }

    fn lookup(&mut self, _req: &Request<'_>, parent: u64, name: &OsStr, reply: ReplyEntry) {
        entry(reply, name_of(name).and_then(|name| self.overlay.lookup(parent, name)));
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
        // A size or mode change may copy a lower file up (a fetch): off the session loop. A change
        // through an open handle (`futimens`, `ftruncate`, `fchmod`: tar sets each file's time that
        // way) goes to the file that handle holds, without a lookup or an open.
        self.run(move |overlay| match overlay.setattr(ino, fh, set) {
            Ok(attr) => reply.attr(&ttl(&attr), &file_attr(&attr)),
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
        let (versions, notifier) = (self.versions.clone(), self.notifier.clone());
        // A write open copies a lower file up (a fetch): off the session loop.
        self.run(move |overlay| match overlay.open_handle(ino, flags) {
            Ok(handle) => reply.opened(handle, open_flags(overlay, &versions, &notifier, ino)),
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
                self.listings.insert(handle, listing.into());
                // Read only, a folder never changes: the kernel answers every later listing of it
                // from its cache (`find` and git's untracked scan then make no round trip here).
                let flags = if self.read_only {
                    FOPEN_CACHE_DIR | FOPEN_KEEP_CACHE
                } else {
                    dir_flags(&self.overlay, ino)
                };
                reply.opened(handle, flags);
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
        let listing = match self.listing_at(ino, fh, offset) {
            Ok(listing) => listing,
            Err(errno) => {
                reply.error(errno);
                return;
            }
        };
        let start = usize::try_from(offset).unwrap_or(0);
        for (at, (ino, kind, name, _)) in listing.iter().enumerate().skip(start) {
            let next = i64::try_from(at + 1).unwrap_or(i64::MAX);
            if reply.add(*ino, next, *kind, name) {
                break;
            }
        }
        reply.ok();
    }

    /// A listing with each entry's attributes (`FUSE_DO_READDIRPLUS`), so the kernel holds every
    /// name and `stat` of the folder from one call: a walk (`find`, `git status`, `rg`) then
    /// `stat`s each file with no `LOOKUP` round trip. The attributes are the ones `lookup` would
    /// answer, kept as long ([`LOWER_TTL`], [`UPPER_TTL`]).
    fn readdirplus(
        &mut self,
        _req: &Request<'_>,
        ino: u64,
        fh: u64,
        offset: i64,
        mut reply: ReplyDirectoryPlus,
    ) {
        let listing = match self.listing_at(ino, fh, offset) {
            Ok(listing) => listing,
            Err(errno) => {
                reply.error(errno);
                return;
            }
        };
        let start = usize::try_from(offset).unwrap_or(0);
        for (at, (child, _, name, listed)) in listing.iter().enumerate().skip(start) {
            let next = i64::try_from(at + 1).unwrap_or(i64::MAX);
            // `.` and `..` are never linked by the kernel (it takes no lookup for them), so their
            // attributes are the folder's own. A name the listing had no attributes for (an upper
            // folder's) is looked up.
            let attr = match listed {
                Some(attr) => Ok(*attr),
                None if at < 2 => self.overlay.getattr(ino),
                None => self.overlay.lookup(ino, name),
            };
            // A name gone since the listing was taken (a race with an unlink): leave it out, as
            // a fresh listing would.
            let Ok(attr) = attr else { continue };
            if reply.add(*child, next, name, &ttl(&attr), &file_attr(&attr), 0) {
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
            Ok((attr, handle)) => {
                // A new file: whatever the kernel held under this number is not of it.
                self.versions.lock().unwrap_or_else(PoisonError::into_inner).remove(&attr.ino);
                reply.created(&ttl(&attr), &file_attr(&attr), 0, handle, 0);
            }
            Err(errno) => reply.error(errno),
        }
    }
}

#[cfg(test)]
#[path = "mount_tests.rs"]
mod tests;
