//! The media reader (R10 in leo-workspace#874): the images and videos a chat's agent names are
//! read on the machine that runs the chat, never as a same-named file on the app's Mac. This is the
//! reader itself; the `_acpmux/media_open` and `_acpmux/media_range` methods that serve it come in
//! their own change.
//!
//! What a chat may read: a file under its folder (`cwd`, the root a relative path starts from) or
//! its own uploads (`hub/file_uploads.rs`). The hub keeps no `additionalDirectories`, so they are
//! no root. The open runs against the descriptor, not the path:
//!
//! - the root is opened (its own spelling may go through a link), then every component below it
//!   with `openat` and `O_NOFOLLOW`, so no component inside the root can be a link;
//! - the opened descriptor must be a regular file with one link, its own path (`F_GETPATH`,
//!   `/proc/self/fd`) inside the root's, and no part of it below the root a dot name, nor a key
//!   file, nor under `~/Library`;
//! - its type is sniffed from its bytes: png, jpeg, gif or webp up to [`MAX_IMAGE_BYTES`], an
//!   mp4, mov, m4v or webm up to [`MAX_VIDEO_BYTES`]. SVG and PDF are never read.
//!
//! The descriptor stays in a connection's handle table ([`Handles`]: at most [`MAX_HANDLES`],
//! each gone after [`IDLE`] unused). Every range is read from it after and before comparing
//! `(dev, ino, size, mtime)` with the open's, so a file changed since the open is refused, and a
//! file replaced at its path keeps serving the bytes that were opened. A range is at most
//! [`MAX_RANGE`] bytes: 8 MiB of base64, under the RPC cap (`rpc.rs`) and an older peer's 16 MiB
//! frame.

use crate::rpc::RpcError;
use serde_json::json;
use std::collections::HashMap;
use std::ffi::OsString;
use std::fs::File;
use std::path::{Component, Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

/// The most bytes one range reads.
pub const MAX_RANGE: usize = 6 << 20;
/// The largest image read.
pub const MAX_IMAGE_BYTES: u64 = 10 << 20;
/// The largest video read.
pub const MAX_VIDEO_BYTES: u64 = 200 << 20;
/// The most files one connection holds open.
pub const MAX_HANDLES: usize = 8;
/// A handle unused this long is closed.
pub const IDLE: Duration = Duration::from_secs(120);

fn refused(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

fn unreadable() -> RpcError {
    refused("media.unreadable", "the file cannot be opened without following a link")
}

fn changed() -> RpcError {
    refused("media.changed", "the file changed since it was opened; open it again")
}

/// The file as opened: what every range compares before and after it reads.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Identity {
    dev: u64,
    ino: u64,
    pub size: u64,
    mtime: (i64, i64),
}

impl Identity {
    fn of(file: &File) -> Result<Self, RpcError> {
        let meta = file.metadata().map_err(|_| unreadable())?;
        Ok(sys::identity(&meta))
    }

    /// The opaque `identity` the replies carry: keyed by this daemon run, so it names no inode.
    pub fn token(&self) -> String {
        use sha2::Digest;
        static KEY: std::sync::OnceLock<[u8; 16]> = std::sync::OnceLock::new();
        let key = KEY.get_or_init(|| {
            let mut key = [0u8; 16];
            let _ = getrandom::fill(&mut key);
            key
        });
        let fields = [self.dev, self.ino, self.size];
        let mut hash = sha2::Sha256::new();
        hash.update(key);
        fields.iter().for_each(|f| hash.update(f.to_le_bytes()));
        hash.update(self.mtime.0.to_le_bytes());
        hash.update(self.mtime.1.to_le_bytes());
        hash.finalize().iter().take(16).map(|b| format!("{b:02x}")).collect()
    }
}

pub struct Opened {
    pub file: File,
    pub identity: Identity,
    pub mime: &'static str,
}

/// Where the race tests act during an open: after the root is opened, after each folder below
/// it, and after the file's checks (before its first range).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Root,
    Dir(usize),
    File,
}

/// The type of a file that starts with `head`, when it is one the reader serves.
pub fn sniff(head: &[u8]) -> Option<&'static str> {
    let at = |range: std::ops::Range<usize>| head.get(range);
    if head.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Some("image/png");
    }
    if head.starts_with(&[0xff, 0xd8, 0xff]) {
        return Some("image/jpeg");
    }
    if head.starts_with(b"GIF87a") || head.starts_with(b"GIF89a") {
        return Some("image/gif");
    }
    if head.starts_with(b"RIFF") && at(8..12) == Some(b"WEBP") {
        return Some("image/webp");
    }
    if at(4..8) == Some(b"ftyp") {
        return match at(8..12)? {
            b"qt  " => Some("video/quicktime"),
            b"M4V " | b"M4VH" | b"M4VP" => Some("video/x-m4v"),
            b"isom" | b"iso2" | b"iso3" | b"iso4" | b"iso5" | b"iso6" | b"mp41" | b"mp42"
            | b"avc1" | b"dash" | b"MSNV" => Some("video/mp4"),
            _ => None,
        };
    }
    // EBML, with a DocType element (0x4282, 4 bytes long) of `webm`.
    if head.starts_with(&[0x1a, 0x45, 0xdf, 0xa3]) {
        let doctype = [0x42, 0x82, 0x84, b'w', b'e', b'b', b'm'];
        return head.windows(doctype.len()).any(|w| w == doctype).then_some("video/webm");
    }
    None
}

/// The root `path` is under and its components below the root (each a plain name): a relative
/// path is under the first root (the chat's folder); an absolute one under the root one of its
/// ancestors spells, the deepest first. Only the spelling of the root itself is resolved.
fn locate(roots: &[PathBuf], path: &str) -> Result<(PathBuf, Vec<OsString>), RpcError> {
    let bad = || refused("media.path", "path must name a file with no `.` or `..` part");
    if path.is_empty() || path.len() > 4096 || path.contains('\0') {
        return Err(bad());
    }
    let parts = |rest: &Path| -> Result<Vec<OsString>, RpcError> {
        let names = rest.components().map(|c| match c {
            Component::Normal(name) => Some(name.to_owned()),
            _ => None,
        });
        names.collect::<Option<Vec<_>>>().filter(|names| !names.is_empty()).ok_or_else(bad)
    };
    let p = Path::new(path);
    if p.is_relative() {
        let root = roots.first().ok_or_else(bad)?;
        return Ok((root.clone(), parts(p)?));
    }
    if p.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir)) {
        return Err(bad());
    }
    let canonical: Vec<PathBuf> =
        roots.iter().filter_map(|root| std::fs::canonicalize(root).ok()).collect();
    for ancestor in p.ancestors().skip(1) {
        let Ok(spelled) = std::fs::canonicalize(ancestor) else { continue };
        if canonical.contains(&spelled) {
            let rest = p.strip_prefix(ancestor).map_err(|_| bad())?;
            return Ok((spelled, parts(rest)?));
        }
    }
    Err(refused("media.outside", "the file is outside the chat's folder and its uploads"))
}

/// A part of `inside` (the file's path below its root) or `own` (its whole path) that is never
/// read: a dot name below the root, a key file, or anything under `home`'s `Library`.
fn denied(inside: &Path, own: &Path, home: Option<&Path>) -> bool {
    let dotted = inside.components().any(|c| c.as_os_str().to_string_lossy().starts_with('.'));
    let key = own.extension().is_some_and(|e| {
        matches!(e.to_string_lossy().to_ascii_lowercase().as_str(), "pem" | "key" | "p12" | "pfx")
    });
    let library = home.is_some_and(|home| {
        let homes = [Some(home.to_path_buf()), std::fs::canonicalize(home).ok()];
        homes.into_iter().flatten().any(|home| own.starts_with(home.join("Library")))
    });
    dotted || key || library
}

/// Opens `path` for a chat whose roots are `roots` (the folder first), with every check on the
/// opened descriptor. `at` runs at each [`Step`]. Blocking: run it off the runtime.
pub fn open_in(
    roots: &[PathBuf],
    path: &str,
    home: Option<&Path>,
    at: &mut dyn FnMut(Step),
) -> Result<Opened, RpcError> {
    let (root, parts) = locate(roots, path)?;
    let mut dir = sys::open_root(&root).ok_or_else(unreadable)?;
    let root_path = sys::fd_path(&dir).ok_or_else(unreadable)?;
    at(Step::Root);
    let (name, folders) = parts.split_last().ok_or_else(unreadable)?;
    for (index, folder) in folders.iter().enumerate() {
        dir = sys::open_below(&dir, folder, true).ok_or_else(unreadable)?;
        at(Step::Dir(index));
    }
    let file = sys::open_below(&dir, name, false).ok_or_else(unreadable)?;
    let meta = file.metadata().map_err(|_| unreadable())?;
    if !meta.is_file() {
        return Err(refused("media.notFile", "the path is not a regular file"));
    }
    if sys::links(&meta) != 1 {
        return Err(refused("media.linked", "the file has another name (a hard link)"));
    }
    let identity = sys::identity(&meta);
    let own = sys::fd_path(&file).ok_or_else(unreadable)?;
    let inside = own.strip_prefix(&root_path).map_err(|_| {
        refused("media.outside", "the file is outside the chat's folder and its uploads")
    })?;
    if denied(inside, &own, home) {
        return Err(refused("media.denied", "the file is in a private place"));
    }
    let mut head = [0u8; 64];
    let read = read_at(&file, &mut head, 0)?;
    let mime = sniff(head.get(..read).unwrap_or_default())
        .ok_or_else(|| refused("media.type", "the file is not a png, jpeg, gif, webp or video"))?;
    let cap = if mime.starts_with("image/") { MAX_IMAGE_BYTES } else { MAX_VIDEO_BYTES };
    if identity.size > cap {
        return Err(refused("media.tooLarge", &format!("a {mime} is at most {} MiB", cap >> 20))
            .with_data(json!({"reason": "media.tooLarge", "maxBytes": cap})));
    }
    at(Step::File);
    Ok(Opened { file, identity, mime })
}

/// Fills `buf` from `offset` until it is full or the file ends; answers how many bytes it read.
fn read_at(file: &File, buf: &mut [u8], offset: u64) -> Result<usize, RpcError> {
    let mut got = 0;
    while let Some(rest) = buf.get_mut(got..).filter(|rest| !rest.is_empty()) {
        let at = offset.saturating_add(u64::try_from(got).unwrap_or(u64::MAX));
        match sys::read_at(file, rest, at) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => return Err(unreadable()),
        }
    }
    Ok(got)
}

/// `length` bytes from `offset` of the opened `file` (fewer only at its end), when it is still
/// the file `opened` names before and after the read.
pub fn read_range(
    file: &File,
    opened: &Identity,
    offset: u64,
    length: u64,
) -> Result<Vec<u8>, RpcError> {
    let range =
        || refused("media.range", &format!("a range is 1 to {MAX_RANGE} bytes inside the file"));
    let length = usize::try_from(length).ok().filter(|n| (1..=MAX_RANGE).contains(n));
    let length = length.ok_or_else(range)?;
    if offset >= opened.size {
        return Err(range());
    }
    let want = usize::try_from(opened.size - offset).map_or(length, |left| left.min(length));
    if Identity::of(file)? != *opened {
        return Err(changed());
    }
    let mut buf = vec![0u8; want];
    let got = read_at(file, &mut buf, offset)?;
    if got != want || Identity::of(file)? != *opened {
        return Err(changed());
    }
    Ok(buf)
}

struct Entry {
    session: String,
    file: Arc<File>,
    identity: Identity,
    used: Instant,
}

/// One connection's open media files (module docs).
#[derive(Default)]
pub struct Handles(Mutex<HashMap<String, Entry>>);

impl Handles {
    fn table(&self, now: Instant) -> MutexGuard<'_, HashMap<String, Entry>> {
        let mut table = self.0.lock().unwrap_or_else(PoisonError::into_inner);
        table.retain(|_, entry| now.saturating_duration_since(entry.used) < IDLE);
        table
    }

    pub fn insert(&self, session: &str, opened: Opened, now: Instant) -> Result<String, RpcError> {
        let mut raw = [0u8; 16];
        getrandom::fill(&mut raw).map_err(|e| RpcError::internal(format!("no handle: {e}")))?;
        let handle: String = raw.iter().map(|b| format!("{b:02x}")).collect();
        let mut table = self.table(now);
        if table.len() >= MAX_HANDLES {
            return Err(refused(
                "media.handles",
                "too many media files are open; read one to its end",
            ));
        }
        let Opened { file, identity, .. } = opened;
        let entry =
            Entry { session: session.to_owned(), file: Arc::new(file), identity, used: now };
        table.insert(handle.clone(), entry);
        Ok(handle)
    }

    pub fn get(
        &self,
        session: &str,
        handle: &str,
        now: Instant,
    ) -> Result<(Arc<File>, Identity), RpcError> {
        let mut table = self.table(now);
        let entry = table.get_mut(handle).filter(|entry| entry.session == session);
        let entry = entry.ok_or_else(|| {
            refused("media.handle", "no such media handle on this connection; open the file again")
        })?;
        entry.used = now;
        Ok((entry.file.clone(), entry.identity))
    }

    pub fn close(&self, handle: &str) {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).remove(handle);
    }

    /// The connection ended.
    pub fn close_all(&self) {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).clear();
    }
}

#[cfg(unix)]
mod sys {
    use std::ffi::{CString, OsStr};
    use std::fs::{File, Metadata};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
    use std::path::{Path, PathBuf};

    pub fn identity(meta: &Metadata) -> super::Identity {
        super::Identity {
            dev: meta.dev(),
            ino: meta.ino(),
            size: meta.size(),
            mtime: (meta.mtime(), meta.mtime_nsec()),
        }
    }

    pub fn links(meta: &Metadata) -> u64 {
        meta.nlink()
    }

    pub fn read_at(file: &File, buf: &mut [u8], offset: u64) -> std::io::Result<usize> {
        file.read_at(buf, offset)
    }

    /// The root folder, through whatever links spell it.
    pub fn open_root(root: &Path) -> Option<File> {
        let mut options = std::fs::OpenOptions::new();
        options.read(true).custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC);
        options.open(root).ok().filter(|dir| dir.metadata().is_ok_and(|m| m.is_dir()))
    }

    /// `name` in the open folder `dir`, never through a link: a folder when `folder`, else the
    /// file itself (non-blocking, so a FIFO cannot hold the open).
    pub fn open_below(dir: &File, name: &OsStr, folder: bool) -> Option<File> {
        let name = CString::new(name.as_bytes()).ok()?;
        let kind = if folder { libc::O_DIRECTORY } else { libc::O_NONBLOCK };
        let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | kind;
        // SAFETY: `dir` is an open descriptor borrowed for the call and `name` is a
        // NUL-terminated string that outlives it.
        let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return None;
        }
        // SAFETY: `fd` was just returned by `openat`, and nothing else owns it.
        Some(File::from(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    /// The path the open descriptor names now.
    #[cfg(target_os = "macos")]
    pub fn fd_path(file: &File) -> Option<PathBuf> {
        use std::os::unix::ffi::OsStringExt;
        let mut buf = vec![0u8; usize::try_from(libc::PATH_MAX).ok()?];
        // SAFETY: F_GETPATH writes at most PATH_MAX bytes into `buf`, which holds PATH_MAX
        // bytes, for a descriptor this function borrows.
        let r = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buf.as_mut_ptr()) };
        if r == -1 {
            return None;
        }
        buf.truncate(buf.iter().position(|&b| b == 0)?);
        Some(PathBuf::from(std::ffi::OsString::from_vec(buf)))
    }

    #[cfg(target_os = "linux")]
    pub fn fd_path(file: &File) -> Option<PathBuf> {
        std::fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd())).ok()
    }

    /// No way to name an open descriptor's path: nothing is read.
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    pub fn fd_path(_: &File) -> Option<PathBuf> {
        None
    }
}

/// Nothing is read off Unix: every open is refused as unreadable.
#[cfg(not(unix))]
mod sys {
    use std::ffi::OsStr;
    use std::fs::{File, Metadata};
    use std::path::{Path, PathBuf};

    pub fn identity(meta: &Metadata) -> super::Identity {
        super::Identity { dev: 0, ino: 0, size: meta.len(), mtime: (0, 0) }
    }

    pub fn links(_: &Metadata) -> u64 {
        0
    }

    pub fn read_at(_: &File, _: &mut [u8], _: u64) -> std::io::Result<usize> {
        Err(std::io::ErrorKind::Unsupported.into())
    }

    pub fn open_root(_: &Path) -> Option<File> {
        None
    }

    pub fn open_below(_: &File, _: &OsStr, _: bool) -> Option<File> {
        None
    }

    pub fn fd_path(_: &File) -> Option<PathBuf> {
        None
    }
}

#[cfg(all(test, unix))]
#[path = "media_read_tests.rs"]
mod tests;
