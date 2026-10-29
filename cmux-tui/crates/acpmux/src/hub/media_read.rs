//! The media reader (R10 in leo-workspace#874): the images and videos a chat's agent names are
//! read on the machine that runs the chat, never as a same-named file on the app's Mac. This is the
//! reader itself; the `_acpmux/media_open` and `_acpmux/media_range` methods that serve it come in
//! their own change.
//!
//! What a chat may read: a file under its folder (`cwd`, the root a relative path starts from),
//! `/tmp`, its home folder, or its own uploads (`hub/file_uploads.rs`). The open runs against the
//! descriptor, not the path:
//!
//! - each root is resolved once (`realpath`): a root that is itself a link (`/tmp` on macOS, a
//!   folder the person linked) means the person chose its target. That resolved folder is opened
//!   from `/` one component at a time with `O_DIRECTORY | O_NOFOLLOW` and must be the folder that
//!   was resolved (same device and inode), so no link swapped in after the resolve, at the root
//!   or above it, is followed;
//! - every component below it is opened with `openat` and `O_NOFOLLOW`, so no component inside
//!   the root can be a link, and each must be on the root's mount (its device, and on Linux its
//!   mount id, since a bind mount of a folder on the same filesystem keeps the device), so no
//!   mount point or firmlink below the root is crossed;
//! - after the file is open, its folder's `..` chain must reach the opened root in as many steps
//!   as the walk went down, so a folder renamed out of the root during the walk is refused;
//! - the opened descriptor must be a regular file with one link, its own path (`F_GETPATH`,
//!   `/proc/self/fd`) inside the root's, and no part of it below the root a dot name, nor a key
//!   file, nor under `~/Library`;
//! - its type is sniffed from its bytes: png, jpeg, gif or webp up to [`MAX_IMAGE_BYTES`], an
//!   mp4, mov, m4v or webm up to [`MAX_VIDEO_BYTES`]. SVG and PDF are never read.
//!
//! Every range is read from the opened descriptor after and before comparing `(dev, ino, size,
//! mtime, ctime)` with the open's (ctime, since an owner can set mtime back but not ctime), so a file changed since the open is refused, and a file replaced at
//! its path keeps serving the bytes that were opened. A range is at most [`MAX_RANGE`] bytes:
//! 8 MiB of base64, under the RPC cap (`rpc.rs`) and an older peer's 16 MiB frame.

use super::Hub;
use super::media_handles::Handles;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::ffi::OsString;
use std::fs::File;
use std::path::{Component, Path, PathBuf};

/// The `initialize` feature of a daemon that serves the media reader methods.
pub const FEATURE: &str = "mediaRead";

/// The most bytes one range reads.
pub const MAX_RANGE: usize = 6 << 20;
/// The largest image read.
pub const MAX_IMAGE_BYTES: u64 = 10 << 20;
/// The largest video read.
pub const MAX_VIDEO_BYTES: u64 = 200 << 20;

pub(crate) fn refused(reason: &str, message: &str) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

fn unreadable() -> RpcError {
    refused("media.unreadable", "the file cannot be opened without following a link")
}

fn mount() -> RpcError {
    refused("media.mount", "the file is on another mount than the chat's folder")
}

fn outside() -> RpcError {
    refused("media.outside", "the file is outside the chat's folder and its uploads")
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
    ctime: (i64, i64),
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
        hash.update(self.ctime.0.to_le_bytes());
        hash.update(self.ctime.1.to_le_bytes());
        hash.finalize().iter().take(16).map(|b| format!("{b:02x}")).collect()
    }
}

pub struct Opened {
    pub file: File,
    pub identity: Identity,
    pub mime: &'static str,
}

/// Where the race tests act during an open: after the root is resolved, after it is opened, after each folder below
/// it, and after the file's checks (before its first range).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Resolved,
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

/// A root as resolved: its path, and the device and inode the open must find there.
struct Root {
    path: PathBuf,
    id: (u64, u64),
}

fn resolve(root: &Path) -> Option<Root> {
    let path = std::fs::canonicalize(root).ok()?;
    let id = sys::dev_ino(&std::fs::symlink_metadata(&path).ok()?);
    Some(Root { path, id })
}

/// The resolved root `path` is under and its components below it (each a plain name): a
/// relative path is under the first root (the chat's folder), an absolute one under the root it
/// starts with, as spelled or resolved, the deepest first. Only the roots are resolved: nothing
/// outside them is looked up, so a path in a protected folder raises no privacy prompt.
fn locate(roots: &[PathBuf], path: &str) -> Result<(Root, Vec<OsString>), RpcError> {
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
        let root = roots.first().and_then(|root| resolve(root)).ok_or_else(unreadable)?;
        return Ok((root, parts(p)?));
    }
    let mut spellings: Vec<(PathBuf, Root)> = roots
        .iter()
        .filter_map(|spelled| Some((spelled, resolve(spelled)?)))
        .flat_map(|(spelled, root)| {
            let real = Root { path: root.path.clone(), id: root.id };
            [(spelled.clone(), root), (real.path.clone(), real)]
        })
        .collect();
    spellings.sort_by_key(|(spelled, _)| std::cmp::Reverse(spelled.components().count()));
    let (spelled, root) =
        spellings.into_iter().find(|(spelled, _)| p.starts_with(spelled)).ok_or_else(outside)?;
    let rest = p.strip_prefix(&spelled).map_err(|_| bad())?;
    Ok((root, parts(rest)?))
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
    at(Step::Resolved);
    let mut dir = sys::open_root(&root.path).ok_or_else(unreadable)?;
    let opened_root = sys::dev_ino(&dir.metadata().map_err(|_| unreadable())?);
    if opened_root != root.id {
        return Err(unreadable());
    }
    let root_path = sys::fd_path(&dir).ok_or_else(unreadable)?;
    let device = sys::mount(&dir).ok_or_else(unreadable)?;
    at(Step::Root);
    let (name, folders) = parts.split_last().ok_or_else(unreadable)?;
    for (index, folder) in folders.iter().enumerate() {
        dir = sys::open_below(&dir, folder, true).ok_or_else(unreadable)?;
        if sys::mount(&dir).ok_or_else(unreadable)? != device {
            return Err(mount());
        }
        at(Step::Dir(index));
    }
    let file = sys::open_below(&dir, name, false).ok_or_else(unreadable)?;
    let mut up = dir;
    for _ in folders {
        up = sys::open_below(&up, std::ffi::OsStr::new(".."), true).ok_or_else(unreadable)?;
    }
    if sys::dev_ino(&up.metadata().map_err(|_| unreadable())?) != root.id {
        return Err(outside());
    }
    if sys::mount(&file).ok_or_else(unreadable)? != device {
        return Err(mount());
    }
    let meta = file.metadata().map_err(|_| unreadable())?;
    if !meta.is_file() {
        return Err(refused("media.notFile", "the path is not a regular file"));
    }
    if sys::links(&meta) != 1 {
        return Err(refused("media.linked", "the file has another name (a hard link)"));
    }
    let identity = sys::identity(&meta);
    let own = sys::fd_path(&file).ok_or_else(unreadable)?;
    let inside = own.strip_prefix(&root_path).map_err(|_| outside())?;
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

/// Opens the regular file `parts` names below `root`, the way [`open_in`] opens media: the root
/// resolved once and opened from `/` without following a link, each component below it opened
/// with `O_NOFOLLOW` on the root's mount, the file's folder's `..` chain back to the root, and
/// the file a regular file with one link. For a reader of files the daemon's own agents write
/// under a root it chose (`subagent_transcript.rs`), so no type sniff and no private-place check.
/// Blocking: run it off the runtime.
pub(crate) fn open_regular_below(root: &Path, parts: &[OsString]) -> Result<File, RpcError> {
    let root = resolve(root).ok_or_else(unreadable)?;
    let mut dir = sys::open_root(&root.path).ok_or_else(unreadable)?;
    if sys::dev_ino(&dir.metadata().map_err(|_| unreadable())?) != root.id {
        return Err(unreadable());
    }
    let device = sys::mount(&dir).ok_or_else(unreadable)?;
    let (name, folders) = parts.split_last().ok_or_else(unreadable)?;
    for folder in folders {
        dir = sys::open_below(&dir, folder, true).ok_or_else(unreadable)?;
        if sys::mount(&dir).ok_or_else(unreadable)? != device {
            return Err(mount());
        }
    }
    let file = sys::open_below(&dir, name, false).ok_or_else(unreadable)?;
    let mut up = dir;
    for _ in folders {
        up = sys::open_below(&up, std::ffi::OsStr::new(".."), true).ok_or_else(unreadable)?;
    }
    if sys::dev_ino(&up.metadata().map_err(|_| unreadable())?) != root.id {
        return Err(outside());
    }
    if sys::mount(&file).ok_or_else(unreadable)? != device {
        return Err(mount());
    }
    let meta = file.metadata().map_err(|_| unreadable())?;
    if !meta.is_file() {
        return Err(refused("media.notFile", "the path is not a regular file"));
    }
    if sys::links(&meta) != 1 {
        return Err(refused("media.linked", "the file has another name (a hard link)"));
    }
    Ok(file)
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

async fn blocking<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, RpcError> + Send + 'static,
) -> Result<T, RpcError> {
    tokio::task::spawn_blocking(work).await.map_err(|e| RpcError::internal(e.to_string()))?
}

/// `_acpmux/media_open` or `_acpmux/media_range` for one of this daemon's chats.
pub async fn handle(
    hub: &Hub,
    handles: &Handles,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    // A range for a chat that is gone closes its handle, which nothing can read again: a
    // forwarding daemon closes a departed client's handles so (`server/media_forward.rs`). Only
    // the handle's own chat counts: a purged chat closes its own handles, and a chat that no
    // longer resolves only a handle whose chat no longer exists at all.
    let range_handle = (m == method::MUX_MEDIA_RANGE)
        .then(|| params.get("handle").and_then(Value::as_str))
        .flatten();
    let session = hub.resolve(crate::server::session_key(params)?).inspect_err(|_| {
        if let Some(handle) = range_handle {
            handles.forget_orphan(handle);
        }
    })?;
    if session.purged.load(std::sync::atomic::Ordering::SeqCst) {
        if let Some(handle) = range_handle {
            handles.close(&session, handle);
        }
        return Err(RpcError::invalid_params("no such chat"));
    }
    if m == method::MUX_MEDIA_OPEN {
        let home = dirs::home_dir();
        let raw_path = params.get("path").and_then(Value::as_str).unwrap_or_default();
        let path = expand_reply_path(raw_path, &session.meta().cwd, home.as_deref());
        let mut roots = vec![session.meta().cwd.clone(), PathBuf::from("/tmp")];
        if let Some(home) = &home {
            roots.push(home.clone());
        }
        roots.extend(super::file_uploads::session_dir(&session.id));
        let opened = blocking(move || open_in(&roots, &path, home.as_deref(), &mut |_| {})).await?;
        let (size, mime, identity) = (opened.identity.size, opened.mime, opened.identity.token());
        let handle = handles.insert(&session, opened)?;
        return Ok(json!({"handle": handle, "size": size, "mimeType": mime, "identity": identity}));
    }
    let handle = params.get("handle").and_then(Value::as_str).unwrap_or_default();
    let (file, identity) = handles.get(&session, handle)?;
    let number = |key: &str| {
        params.get(key).and_then(Value::as_u64).ok_or_else(|| {
            refused("media.range", &format!("{key} must be a whole number of bytes"))
        })
    };
    let read = match (number("offset"), number("length")) {
        (Ok(offset), Ok(length)) => blocking(move || read_range(&file, &identity, offset, length))
            .await
            .map(|bytes| (offset, bytes)),
        (Err(e), _) | (_, Err(e)) => Err(e),
    };
    // A refused range closes the handle: a reader that asks wrong opens the file again.
    let (offset, bytes) = read.inspect_err(|_| handles.close(&session, handle))?;
    let end = offset.saturating_add(u64::try_from(bytes.len()).unwrap_or(u64::MAX));
    if end >= identity.size {
        handles.close(&session, handle);
    }
    use base64::Engine;
    Ok(json!({
        "offset": offset,
        "size": identity.size,
        "identity": identity.token(),
        "data": base64::engine::general_purpose::STANDARD.encode(bytes),
    }))
}

/// Resolve the harmless spelling conveniences accepted by reply markdown before the descriptor
/// walk. The walk itself still rejects symlinks, mounts and every component outside its roots.
fn expand_reply_path(path: &str, cwd: &Path, home: Option<&Path>) -> String {
    if let Some(home) = home {
        if path == "~" {
            return home.to_string_lossy().into_owned();
        }
        if let Some(rest) = path.strip_prefix("~/") {
            return home.join(rest).to_string_lossy().into_owned();
        }
    }
    if path.starts_with("./") || path.starts_with("../") {
        let mut expanded = cwd.to_path_buf();
        for component in Path::new(path).components() {
            match component {
                Component::CurDir => {}
                Component::ParentDir => {
                    expanded.pop();
                }
                Component::Normal(name) => expanded.push(name),
                Component::RootDir | Component::Prefix(_) => return path.to_owned(),
            }
        }
        return expanded.to_string_lossy().into_owned();
    }
    path.to_owned()
}

/// The refusal of `m` for a peer that does not serve the reader: the app shows the media as a
/// card.
pub fn peer_unsupported(peer: &crate::peer::Peer, m: &str) -> RpcError {
    RpcError::method_not_found(&format!(
        "{m} (peer {} runs acpmux build {}; run `acpmux host update {}`)",
        peer.name,
        peer.remote_build().unwrap_or_else(|| "unknown".into()),
        peer.name
    ))
    .with_data(json!({"reason": "mediaRead.unsupported"}))
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
            ctime: (meta.ctime(), meta.ctime_nsec()),
        }
    }

    pub fn links(meta: &Metadata) -> u64 {
        meta.nlink()
    }

    pub fn dev_ino(meta: &Metadata) -> (u64, u64) {
        (meta.dev(), meta.ino())
    }

    pub fn read_at(file: &File, buf: &mut [u8], offset: u64) -> std::io::Result<usize> {
        file.read_at(buf, offset)
    }

    /// The mount an open descriptor is on: its device, and on Linux its mount id
    /// (`/proc/self/fdinfo`), because a bind mount on the same filesystem keeps the device. macOS
    /// has no bind mounts, and a firmlink crosses volumes, so the device names the mount there.
    pub fn mount(file: &File) -> Option<(u64, u64)> {
        let dev = file.metadata().ok()?.dev();
        Some((dev, mount_id(file)?))
    }

    #[cfg(target_os = "linux")]
    fn mount_id(file: &File) -> Option<u64> {
        let info =
            std::fs::read_to_string(format!("/proc/self/fdinfo/{}", file.as_raw_fd())).ok()?;
        info.lines().find_map(|line| line.strip_prefix("mnt_id:")?.trim().parse().ok())
    }

    #[cfg(not(target_os = "linux"))]
    fn mount_id(_: &File) -> Option<u64> {
        Some(0)
    }

    /// The resolved root folder, opened from `/` a component at a time, so no link put in its
    /// place or above it is followed.
    pub fn open_root(root: &Path) -> Option<File> {
        use std::path::Component;
        let mut options = std::fs::OpenOptions::new();
        options.read(true).custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC);
        let mut dir = options.open("/").ok()?;
        for component in root.components() {
            match component {
                Component::RootDir => {}
                Component::Normal(name) => dir = open_below(&dir, name, true)?,
                _ => return None,
            }
        }
        Some(dir)
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
        super::Identity { dev: 0, ino: 0, size: meta.len(), mtime: (0, 0), ctime: (0, 0) }
    }

    pub fn links(_: &Metadata) -> u64 {
        0
    }

    pub fn dev_ino(_: &Metadata) -> (u64, u64) {
        (0, 0)
    }

    pub fn read_at(_: &File, _: &mut [u8], _: u64) -> std::io::Result<usize> {
        Err(std::io::ErrorKind::Unsupported.into())
    }

    pub fn mount(_: &File) -> Option<(u64, u64)> {
        None
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
