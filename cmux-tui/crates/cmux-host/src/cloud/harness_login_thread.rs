//! The thread that keeps a person's harness logins in sync for their Cloud
//! machine (`harness_login.rs`), beside the Cloud worker so a slow request
//! never stalls its poll loop. The worker hands it a client at each bind and
//! waits up to [`BOOT_WAIT`] for its first pass (one list and the writes it
//! allows) before the machine's first status report, so the first chat
//! finds the login. From then on it looks at the login files every
//! [`SCAN_EVERY`] (metadata only; a file is read when it changed) and lists
//! the saved logins every [`PULL_EVERY`] with jitter, backing off on errors.
//! A deployment that keeps no logins (404) is asked again every
//! [`OFF_EVERY`].
//!
//! On Linux the login files are read and written as the work user
//! (`setfsuid`), so a link the work user planted cannot make root read or
//! write another file, and a written login is that user's. The state file
//! is root's (0600). No login, and no fingerprint, is ever logged.

use std::collections::BTreeMap;
use std::ffi::{CStr, CString, OsStr};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use serde_json::Value;

use super::client::{CloudClient, Http};
use super::harness_login::{
    CONTENT_MAX_BYTES, HARNESSES, Harness, Listed, Local, MACHINE_PATH, Put, Report, SyncState,
    parse_list, parse_put, personal_machine, put_path,
};
use super::sender::Backoff;

/// How long the worker holds its first status report for the boot pass.
pub const BOOT_WAIT: Duration = Duration::from_secs(10);
pub const SCAN_EVERY: Duration = Duration::from_secs(10);
pub const PULL_EVERY: Duration = Duration::from_secs(5 * 60);
pub const OFF_EVERY: Duration = Duration::from_secs(60 * 60);
/// A drop waits this long for the request in flight.
pub const STOP_WAIT: Duration = Duration::from_secs(25);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Method {
    Get,
    Put,
}

/// One JSON request to the platform origin with the machine's bearer.
pub trait Platform {
    fn send(
        &self,
        method: Method,
        url: &str,
        body: Option<&Value>,
        bearer: &str,
    ) -> Result<(u16, Value), String>;
}

/// The saved-login routes, as the thread uses them (tests fake it).
pub trait Api {
    fn list(&mut self) -> Listed;
    fn put(&mut self, report: &Report) -> Put;
}

/// Where the thread looks.
#[derive(Clone, Debug)]
pub struct Setup {
    /// The work user's home; the harness files are under it.
    pub home: PathBuf,
    pub state_file: PathBuf,
    /// `/etc/cmux/vm-kind`.
    pub vm_kind_file: PathBuf,
    /// A team enroll or binding on disk (`team_ssh::enroll`).
    pub team_files: Vec<PathBuf>,
    /// The `(uid, gid)` the login files are read and written as (Linux).
    pub fs_identity: Option<(u32, u32)>,
}

impl Setup {
    /// A personal machine, decided again at every pass (fail closed).
    pub fn personal(&self) -> bool {
        let kind = fs::read(&self.vm_kind_file)
            .ok()
            .filter(|b| b.len() <= 64)
            .and_then(|b| String::from_utf8(b).ok());
        let team = self.team_files.iter().any(
            |f| !matches!(fs::symlink_metadata(f), Err(e) if e.kind() == io::ErrorKind::NotFound),
        );
        personal_machine(kind.as_deref(), team)
    }
}

/// What one pass came to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Pass {
    Done,
    Off,
    Retry(String),
}

/// The metadata a scan compares, so an unchanged file is not read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileKey {
    len: u64,
    ino: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
}

/// The sync, over an [`Api`] and the files (sans thread).
pub struct Syncer {
    setup: Setup,
    state: SyncState,
    seen: BTreeMap<&'static str, Option<FileKey>>,
    /// A 409 said the saved login is gone: list soon to learn its revision,
    /// so a sign-out here moves the base past it.
    pub pull_soon: bool,
    log: fn(&str),
}

impl Syncer {
    pub fn new(setup: Setup, log: fn(&str)) -> Syncer {
        let text = fs::read_to_string(&setup.state_file).ok();
        Syncer {
            state: SyncState::parse(text.as_deref()),
            setup,
            seen: BTreeMap::new(),
            pull_soon: false,
            log,
        }
    }

    pub fn state(&self) -> &SyncState {
        &self.state
    }

    pub fn setup(&self) -> &Setup {
        &self.setup
    }

    fn as_user<T>(&self, f: impl FnOnce() -> T) -> T {
        set_fs_identity(self.setup.fs_identity, self.log);
        let out = f();
        if self.setup.fs_identity.is_some() {
            set_fs_identity(Some(own_identity()), self.log);
        }
        out
    }

    fn local(&self, harness: &Harness) -> (Local, Option<FileKey>) {
        self.as_user(|| read_login(harness, &self.setup.home))
    }

    fn save_state(&self) {
        let text = self.state.to_text();
        if let Err(e) = write_atomic(&self.setup.state_file, text.as_bytes(), 0o600) {
            (self.log)(&format!("harness login: state write failed: {e}"));
        }
    }

    /// Lists the saved logins and writes each one the rules allow (boot and
    /// every pull).
    pub fn pull(&mut self, api: &mut dyn Api) -> Pass {
        let saved = match api.list() {
            Listed::Saved(saved) => saved,
            Listed::Off => return Pass::Off,
            Listed::Retry(why) => return Pass::Retry(why),
            Listed::Refused(code) => return Pass::Retry(format!("list refused: {code}")),
        };
        let mut changed = false;
        for entry in &saved {
            let Some(harness) = super::harness_login::harness(&entry.harness) else { continue };
            let (local, read_key) = self.local(harness);
            let (write, moved) = self.state.saved(&local, entry);
            changed |= moved;
            let Some(content) = write else { continue };
            // A saved login is held to the same checks as one read here: never a CodeRouter, an
            // API-key-only or a malformed file, whatever the platform answered.
            if let Err(why) = harness.check(&content) {
                (self.log)(&format!("harness login: {} saved login refused: {why:?}", harness.id));
                continue;
            }
            // Written only while the file is still the one just read: a sign-in or token refresh in
            // between wins, and the next scan sends it.
            match self.as_user(|| write_login(&self.setup.home, harness, &content, read_key)) {
                Ok(()) => {
                    self.state.written(entry);
                    self.seen.remove(harness.id);
                    changed = true;
                    (self.log)(&format!(
                        "harness login: {} revision {} written",
                        harness.id, entry.revision
                    ));
                }
                Err(e) => (self.log)(&format!("harness login: {} write failed: {e}", harness.id)),
            }
        }
        if changed {
            self.save_state();
        }
        Pass::Done
    }

    /// Looks at each login file; a changed one is read, and a login that
    /// differs from the last synced one is sent once.
    pub fn scan(&mut self, api: &mut dyn Api) -> Pass {
        let mut outcome = Pass::Done;
        for harness in HARNESSES {
            let key = self.as_user(|| file_key(&self.setup.home, harness));
            if key.is_ok() && self.seen.get(harness.id) == key.as_ref().ok() {
                continue;
            }
            let (local, read_key) = self.local(harness);
            let (report, moved) = self.state.observe(harness.id, &local);
            if moved {
                (self.log)(&format!("harness login: {} signed out here", harness.id));
                self.save_state();
            }
            let Some(report) = report else {
                if local != Local::Unreadable {
                    self.seen.insert(harness.id, read_key);
                }
                continue;
            };
            let put = api.put(&report);
            self.state.answered(&report, &put);
            match &put {
                Put::Saved { revision, .. } => {
                    (self.log)(&format!("harness login: {} sent, revision {revision}", harness.id));
                }
                Put::Revoked => {
                    self.pull_soon = true;
                    (self.log)(&format!(
                        "harness login: {} was deleted by its owner; not sent until a fresh sign-in",
                        harness.id
                    ));
                }
                Put::Refused(code) => {
                    (self.log)(&format!("harness login: {} refused: {code}", harness.id));
                }
                Put::Off => outcome = Pass::Off,
                Put::Retry(why) => outcome = Pass::Retry(why.clone()),
            }
            if matches!(put, Put::Saved { .. } | Put::Revoked | Put::Refused(_)) {
                self.seen.insert(harness.id, read_key);
                self.save_state();
            }
            if outcome != Pass::Done {
                break;
            }
        }
        outcome
    }
}

fn key_of(meta: &fs::Metadata) -> FileKey {
    FileKey {
        len: meta.len(),
        ino: meta.ino(),
        mtime: (meta.mtime(), meta.mtime_nsec()),
        ctime: (meta.ctime(), meta.ctime_nsec()),
    }
}

fn c_name(name: &OsStr) -> io::Result<CString> {
    CString::new(name.as_bytes()).map_err(|_| io::Error::other("a NUL in a file name"))
}

fn fd_or_error(fd: libc::c_int) -> io::Result<OwnedFd> {
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` is a descriptor the call just opened and nothing else owns.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// The folder `name` in `dir`, never through a link.
fn dir_at(dir: &OwnedFd, name: &CStr) -> io::Result<OwnedFd> {
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `name` is NUL-terminated and `dir` is an open descriptor.
    fd_or_error(unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) })
}

/// The folder at `path` (followed: a root-chosen path such as the home).
fn dir_path(path: &Path) -> io::Result<OwnedFd> {
    let path = c_name(path.as_os_str())?;
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;
    // SAFETY: `path` is NUL-terminated.
    fd_or_error(unsafe { libc::open(path.as_ptr(), flags) })
}

/// The folder that holds `rel` under `home`, each folder below the home
/// opened without following a link, so a `.claude` or `.codex` link cannot
/// point the read or the write at another folder (a team home, say). With
/// `create`, a missing folder is made 0700. `Ok(None)`: one is missing.
fn login_dir(home: &Path, rel: &Path, create: bool) -> io::Result<Option<OwnedFd>> {
    let mut dir = match dir_path(home) {
        Ok(dir) => dir,
        Err(e) if e.kind() == io::ErrorKind::NotFound && create => {
            fs::DirBuilder::new().recursive(true).mode(0o700).create(home)?;
            dir_path(home)?
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let parent = rel.parent().unwrap_or(Path::new(""));
    for part in parent.components() {
        let Component::Normal(part) = part else {
            return Err(io::Error::other("a login path is plain names under the home"));
        };
        let name = c_name(part)?;
        dir = match dir_at(&dir, &name) {
            Ok(next) => next,
            Err(e) if e.kind() == io::ErrorKind::NotFound && create => {
                // SAFETY: `name` is NUL-terminated and `dir` is an open descriptor.
                if unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
                    let e = io::Error::last_os_error();
                    if e.kind() != io::ErrorKind::AlreadyExists {
                        return Err(e);
                    }
                }
                let next = dir_at(&dir, &name)?;
                File::from(next.try_clone()?).set_permissions(fs::Permissions::from_mode(0o700))?;
                next
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(e),
        };
    }
    Ok(Some(dir))
}

fn file_name(rel: &Path) -> io::Result<CString> {
    c_name(rel.file_name().ok_or_else(|| io::Error::other("no file name"))?)
}

/// The file `name` in `dir` opened to read, never through a link and never
/// blocking on a FIFO (`Ok(None)`: not found).
fn open_at(dir: &OwnedFd, name: &CStr) -> io::Result<Option<File>> {
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    // SAFETY: `name` is NUL-terminated and `dir` is an open descriptor.
    match fd_or_error(unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) }) {
        Ok(fd) => Ok(Some(File::from(fd))),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

/// The key of the file `name` in `dir` now (`Ok(None)`: not found).
fn key_at(dir: &OwnedFd, name: &CStr) -> io::Result<Option<FileKey>> {
    match open_at(dir, name)? {
        Some(file) => Ok(Some(key_of(&file.metadata()?))),
        None => Ok(None),
    }
}

/// The key of a harness's login file now (`Ok(None)`: not found).
fn file_key(home: &Path, harness: &Harness) -> io::Result<Option<FileKey>> {
    let rel = Path::new(harness.file);
    match login_dir(home, rel, false)? {
        Some(dir) => key_at(&dir, &file_name(rel)?),
        None => Ok(None),
    }
}

/// A harness's login file under `home`, never through a link (the file or
/// any folder below the home), at most 64 KiB + 1 read.
pub fn read_login(harness: &Harness, home: &Path) -> (Local, Option<FileKey>) {
    let rel = Path::new(harness.file);
    let opened = login_dir(home, rel, false).and_then(|dir| match dir {
        Some(dir) => open_at(&dir, &file_name(rel)?),
        None => Ok(None),
    });
    let mut file = match opened {
        Ok(Some(file)) => file,
        Ok(None) => return (Local::Absent, None),
        Err(_) => return (Local::Unreadable, None),
    };
    let Ok(meta) = file.metadata() else { return (Local::Unreadable, None) };
    if !meta.is_file() {
        return (Local::Unreadable, None);
    }
    let mut bytes = Vec::new();
    if (&mut file).take(CONTENT_MAX_BYTES as u64 + 1).read_to_end(&mut bytes).is_err() {
        return (Local::Unreadable, None);
    }
    (Local::from_bytes(harness, Some(bytes)), Some(key_of(&meta)))
}

/// The file changed after it was read; the saved login is not written over it.
pub const CHANGED_SINCE_READ: &str = "changed since it was read";

/// Writes a harness's login under `home` (folders made 0700 when missing,
/// the file 0600), never through a link, and only while the file is still
/// the one read (`read`, `None` when it was absent).
pub fn write_login(
    home: &Path,
    harness: &Harness,
    content: &[u8],
    read: Option<FileKey>,
) -> io::Result<()> {
    let rel = Path::new(harness.file);
    let dir = login_dir(home, rel, true)?.ok_or_else(|| io::Error::other("no login folder"))?;
    write_at(&dir, &file_name(rel)?, content, 0o600, Some(read))
}

/// A temp file in the same folder (exclusive, never through a link), fsync,
/// rename, fsync of the folder. A missing folder is made 0700.
pub fn write_atomic(path: &Path, content: &[u8], mode: u32) -> io::Result<()> {
    let dir = path.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    if !dir.exists() {
        fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    write_at(&dir_path(dir)?, &file_name(path)?, content, mode, None)
}

/// [`write_atomic`] in an open folder. With `expect`, the rename happens only
/// while `name`'s key is still `expect` (checked right before it).
fn write_at(
    dir: &OwnedFd,
    name: &CStr,
    content: &[u8],
    mode: u32,
    expect: Option<Option<FileKey>>,
) -> io::Result<()> {
    let tmp = c_name(OsStr::new(&format!(
        ".{}.cmux-sync-{}",
        name.to_string_lossy(),
        std::process::id()
    )))?;
    let unlink = || {
        // SAFETY: `tmp` is NUL-terminated and `dir` is an open descriptor.
        unsafe { libc::unlinkat(dir.as_raw_fd(), tmp.as_ptr(), 0) };
    };
    unlink();
    let result = (|| {
        let flags =
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: `tmp` is NUL-terminated and `dir` is an open descriptor.
        let fd = fd_or_error(unsafe {
            libc::openat(dir.as_raw_fd(), tmp.as_ptr(), flags, mode as libc::c_uint)
        })?;
        let mut out = File::from(fd);
        out.write_all(content)?;
        out.set_permissions(fs::Permissions::from_mode(mode))?;
        out.sync_all()?;
        drop(out);
        match expect {
            Some(expect) => replace_if(dir, &tmp, name, expect)?,
            None => rename_at(dir, &tmp, name, 0)?,
        }
        File::from(dir.try_clone()?).sync_all()
    })();
    // On success after a swap `tmp` names the replaced login; on an error it names ours.
    unlink();
    result
}

/// Whether two keys are the same file with the same content: the inode, the
/// size and the modification time. Not the change time, which a rename moves.
fn same_file(a: &FileKey, b: &FileKey) -> bool {
    a.ino == b.ino && a.len == b.len && a.mtime == b.mtime
}

/// `renameat`, or Linux `renameat2` with `flags`.
fn rename_at(dir: &OwnedFd, from: &CStr, to: &CStr, flags: libc::c_uint) -> io::Result<()> {
    let fd = dir.as_raw_fd();
    #[cfg(target_os = "linux")]
    // SAFETY: both names are NUL-terminated and `dir` is an open descriptor.
    let done = unsafe { libc::renameat2(fd, from.as_ptr(), fd, to.as_ptr(), flags) };
    #[cfg(not(target_os = "linux"))]
    let done = {
        let _ = flags;
        // SAFETY: both names are NUL-terminated and `dir` is an open descriptor.
        unsafe { libc::renameat(fd, from.as_ptr(), fd, to.as_ptr()) }
    };
    if done != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Puts `tmp` in place of `name` only while `name` is still the file read
/// (`expect`; `None`: it was absent). On Linux the check is atomic: an
/// absent login is created with `RENAME_NOREPLACE`, and a present one is
/// swapped in with `RENAME_EXCHANGE`, the file it displaced (now at `tmp`)
/// compared with `expect`, and swapped back when it is not the one read.
/// Elsewhere, or on a filesystem without those flags, a check right before
/// the rename.
fn replace_if(dir: &OwnedFd, tmp: &CStr, name: &CStr, expect: Option<FileKey>) -> io::Result<()> {
    let changed = || io::Error::other(CHANGED_SINCE_READ);
    #[cfg(target_os = "linux")]
    {
        let unsupported = |e: &io::Error| e.raw_os_error() == Some(libc::EINVAL);
        match expect {
            None => match rename_at(dir, tmp, name, libc::RENAME_NOREPLACE) {
                Ok(()) => return Ok(()),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => return Err(changed()),
                Err(e) if !unsupported(&e) => return Err(e),
                Err(_) => {}
            },
            Some(want) => match rename_at(dir, tmp, name, libc::RENAME_EXCHANGE) {
                Ok(()) => {
                    let displaced = key_at(dir, tmp);
                    if matches!(&displaced, Ok(Some(got)) if same_file(got, &want)) {
                        return Ok(());
                    }
                    // Not the file read: it goes back, and the newer login stays. Should the swap
                    // back fail, a plain rename still puts it back over ours, never deleting it.
                    if rename_at(dir, tmp, name, libc::RENAME_EXCHANGE).is_err() {
                        rename_at(dir, tmp, name, 0)?;
                    }
                    return Err(changed());
                }
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Err(changed()),
                Err(e) if !unsupported(&e) => return Err(e),
                Err(_) => {}
            },
        }
    }
    let now = key_at(dir, name)?;
    let same = match (&now, &expect) {
        (None, None) => true,
        (Some(a), Some(b)) => same_file(a, b),
        _ => false,
    };
    if !same {
        return Err(changed());
    }
    rename_at(dir, tmp, name, 0)
}

fn own_identity() -> (u32, u32) {
    // SAFETY: plain getters with no arguments.
    unsafe { (libc::geteuid(), libc::getegid()) }
}

/// File access of this thread as `uid`/`gid` (Linux `setfsuid`/`setfsgid`
/// are per thread; network calls are unaffected). Elsewhere a no-op.
fn set_fs_identity(identity: Option<(u32, u32)>, log: fn(&str)) {
    let Some((uid, gid)) = identity else { return };
    #[cfg(target_os = "linux")]
    {
        // SAFETY: plain syscalls on the calling thread; they take integers and touch no memory.
        unsafe {
            libc::setfsgid(gid);
            libc::setfsuid(uid);
        }
        // A second call answers the identity now in force.
        // SAFETY: as above.
        let (now_gid, now_uid) = unsafe { (libc::setfsgid(gid), libc::setfsuid(uid)) };
        if now_uid != uid as i32 || now_gid != gid as i32 {
            log(&format!("harness login: file identity is {now_uid}:{now_gid}, not {uid}:{gid}"));
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (uid, gid, log);
    }
}

/// [`Api`] over the bound machine's client (its bearer) and the platform.
pub struct ClientApi<'a, H: Http, P: Platform> {
    pub client: &'a mut CloudClient<H>,
    pub platform: &'a P,
    pub origin: &'a str,
    pub stop: &'a AtomicBool,
    pub now: fn() -> u64,
}

impl<H: Http, P: Platform> ClientApi<'_, H, P> {
    /// One request; a 401 or 403 drops the cached bearer and retries once.
    fn call(
        &mut self,
        method: Method,
        path: &str,
        body: Option<&Value>,
    ) -> Result<(u16, Value), String> {
        let url = format!("{}{path}", self.origin);
        let mut retried = false;
        loop {
            if self.stop.load(Ordering::SeqCst) {
                return Err("stopping".to_owned());
            }
            let token = self.client.token((self.now)())?;
            let (status, answer) = self.platform.send(method, &url, body, &token)?;
            if (status == 401 || status == 403) && !retried {
                self.client.forget_token();
                retried = true;
                continue;
            }
            return Ok((status, answer));
        }
    }
}

impl<H: Http, P: Platform> Api for ClientApi<'_, H, P> {
    fn list(&mut self) -> Listed {
        match self.call(Method::Get, MACHINE_PATH, None) {
            Ok((status, body)) => parse_list(status, &body),
            Err(why) => Listed::Retry(why),
        }
    }

    fn put(&mut self, report: &Report) -> Put {
        match self.call(Method::Put, &put_path(&report.harness), Some(&report.body())) {
            Ok((status, body)) => parse_put(status, &body),
            Err(why) => Put::Retry(why),
        }
    }
}

enum Msg<H: Http, P: Platform> {
    Bound { client: Box<CloudClient<H>>, platform: P, origin: String, booted: Sender<()> },
}

/// The worker's handle on the thread.
pub struct HarnessLogins<H: Http, P: Platform> {
    tx: Option<Sender<Msg<H, P>>>,
    stop: Arc<AtomicBool>,
    done: Receiver<()>,
    thread: Option<JoinHandle<()>>,
}

impl<H: Http, P: Platform> Drop for HarnessLogins<H, P> {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        self.tx = None;
        if !matches!(self.done.recv_timeout(STOP_WAIT), Err(RecvTimeoutError::Timeout))
            && let Some(thread) = self.thread.take()
        {
            let _ = thread.join();
        }
    }
}

impl<H: Http + Send + 'static, P: Platform + Send + 'static> HarnessLogins<H, P> {
    /// Starts the thread. `now` is wall-clock milliseconds (the bearer's
    /// expiry), `random` in `[0, 1)` (jitter).
    pub fn spawn(
        setup: Setup,
        now: fn() -> u64,
        random: fn() -> f64,
        log: fn(&str),
    ) -> io::Result<HarnessLogins<H, P>> {
        let (tx, rx) = mpsc::channel();
        let (done_tx, done) = mpsc::channel::<()>();
        let stop = Arc::new(AtomicBool::new(false));
        let stopping = Arc::clone(&stop);
        let thread = std::thread::Builder::new().name("cmux-host-harness-login".to_owned()).spawn(
            move || {
                let _done = done_tx;
                run(&rx, &stopping, setup, now, random, log);
            },
        )?;
        Ok(HarnessLogins { tx: Some(tx), stop, done, thread: Some(thread) })
    }

    /// The machine is bound (again) and its environment keeps logins at
    /// `origin`. The answer disconnects when the boot pass is over.
    pub fn bound(&self, client: CloudClient<H>, platform: P, origin: &str) -> Receiver<()> {
        let (booted, done) = mpsc::channel();
        if let Some(tx) = self.tx.as_ref() {
            let msg = Msg::Bound {
                client: Box::new(client),
                platform,
                origin: origin.to_owned(),
                booted,
            };
            let _ = tx.send(msg);
        }
        done
    }
}

struct Live<H: Http, P: Platform> {
    client: Box<CloudClient<H>>,
    platform: P,
    origin: String,
}

fn jittered(every: Duration, random: f64) -> Duration {
    every.mul_f64(0.8 + 0.4 * random.clamp(0.0, 1.0))
}

fn run<H: Http, P: Platform>(
    rx: &Receiver<Msg<H, P>>,
    stop: &AtomicBool,
    setup: Setup,
    now: fn() -> u64,
    random: fn() -> f64,
    log: fn(&str),
) {
    let mut syncer = Syncer::new(setup, log);
    let mut live: Option<Live<H, P>> = None;
    let mut backoff = Backoff::new(5_000, 600_000);
    let mut next_pull = Instant::now();
    let mut next_scan = Instant::now();
    let mut off = false;
    loop {
        let msg = if live.is_none() {
            rx.recv().map_err(|_| RecvTimeoutError::Disconnected)
        } else {
            let at = if off { next_pull } else { next_pull.min(next_scan) };
            rx.recv_timeout(at.saturating_duration_since(Instant::now()))
        };
        let mut booted: Option<Sender<()>> = None;
        match msg {
            Ok(Msg::Bound { client, platform, origin, booted: tx }) => {
                live = Some(Live { client, platform, origin });
                backoff.reset();
                off = false;
                next_pull = Instant::now();
                next_scan = Instant::now();
                booted = Some(tx);
            }
            Err(RecvTimeoutError::Disconnected) => return,
            Err(RecvTimeoutError::Timeout) => {}
        }
        if stop.load(Ordering::SeqCst) {
            return;
        }
        let Some(l) = live.as_mut() else { continue };
        if !syncer.setup().personal() {
            // Checked again later: the kind is recorded after create.
            next_pull = Instant::now() + PULL_EVERY;
            next_scan = next_pull;
            continue;
        }
        let mut api = ClientApi {
            client: &mut *l.client,
            platform: &l.platform,
            origin: &l.origin,
            stop,
            now,
        };
        if Instant::now() >= next_pull {
            let pass = syncer.pull(&mut api);
            next_pull = Instant::now()
                + match pass {
                    Pass::Done => {
                        off = false;
                        backoff.reset();
                        jittered(PULL_EVERY, random())
                    }
                    Pass::Off => {
                        off = true;
                        OFF_EVERY
                    }
                    Pass::Retry(why) => {
                        log(&format!("harness login: list failed: {why}"));
                        Duration::from_millis(backoff.next(0, random()))
                    }
                };
        }
        // The boot pass is over: the first report may go.
        drop(booted);
        if !off && Instant::now() >= next_scan {
            next_scan = Instant::now()
                + match syncer.scan(&mut api) {
                    Pass::Done => SCAN_EVERY,
                    Pass::Off => {
                        off = true;
                        next_pull = Instant::now() + OFF_EVERY;
                        OFF_EVERY
                    }
                    Pass::Retry(why) => {
                        log(&format!("harness login: send failed: {why}"));
                        Duration::from_millis(backoff.next(0, random())).max(SCAN_EVERY)
                    }
                };
            if std::mem::take(&mut syncer.pull_soon) {
                next_pull = Instant::now();
            }
        }
    }
}
