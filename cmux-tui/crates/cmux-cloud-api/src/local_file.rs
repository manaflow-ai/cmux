//! The path form of a Worker machine's file read and write: `machine.io` with `local_path`, for a
//! file larger than one `cmux.protocol/2` request or answer may carry as base64 (the SDK sends at
//! most 4 MiB; an answer is at most 16 MiB).
//!
//! The caller hands over a file of its own instead of the bytes: a write's source, which the
//! call reads, or a read's destination, which the call creates and fills. Either must sit directly
//! in the transfer folder, `<per-user temp dir>/cmux-cloud-transfer` (the app's
//! `NSTemporaryDirectory()`; macOS `confstr(_CS_DARWIN_USER_TEMP_DIR)`, never `$TMPDIR`), which
//! must be a real directory of this user's with no group or other access. A source must be a
//! regular file of this user's, 0600 or tighter, with one link, opened without following a
//! symlink; a destination must not exist yet and is created 0600 without following one. Anything
//! else is refused before any request, so the call reads or writes no other file of the user's.
//! The caller removes its file afterwards; a read that fails removes the destination it made.

use std::fs::File;
#[cfg(unix)]
use std::fs::OpenOptions;
#[cfg(unix)]
use std::io::Read as _;
use std::io::{Seek as _, Write as _};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;
use serde_json::Value;

use crate::machine_io::{Answer, Spool};

/// The transfer folder's name in the per-user temp dir.
pub const FOLDER: &str = "cmux-cloud-transfer";

/// The largest file the path form moves (a write's bytes are held while they are sent).
pub const LIMIT: u64 = 256 * 1024 * 1024;

/// The transfer folder, or none where the path form is not served (it is macOS's app's).
pub(crate) fn transfer_dir() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        darwin_user_temp().map(|temp| temp.join(FOLDER))
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

/// `confstr(_CS_DARWIN_USER_TEMP_DIR)`: an absolute `/var/folders/…/T/`.
#[cfg(target_os = "macos")]
fn darwin_user_temp() -> Option<PathBuf> {
    let mut buf = [0u8; 1024];
    // SAFETY: confstr writes at most buf.len() bytes, NUL included, into our buffer.
    let n = unsafe {
        libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr().cast(), buf.len())
    };
    let text = std::str::from_utf8(buf.get(..n.checked_sub(1)?)?).ok()?;
    (text.starts_with("/var/folders/") && text.ends_with("/T/") && !text.contains("/../"))
        .then(|| PathBuf::from(text.trim_end_matches('/')))
}

#[cfg(unix)]
fn uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

/// `path`, when it names a file directly in `dir` and `dir` is a private folder of this user's.
#[cfg(unix)]
fn in_folder(dir: &Path, path: &str) -> Result<PathBuf, String> {
    let meta = std::fs::symlink_metadata(dir)
        .map_err(|_| "the transfer folder does not exist".to_owned())?;
    if meta.file_type().is_symlink()
        || !meta.is_dir()
        || meta.uid() != uid()
        || meta.mode() & 0o077 != 0
    {
        return Err("the transfer folder is not a private folder of this user's".into());
    }
    let named = Path::new(path);
    match (named.parent(), named.file_name()) {
        (Some(parent), Some(name)) if parent == dir && !path.contains('\0') => Ok(dir.join(name)),
        _ => Err("local_path is not a file in the transfer folder".into()),
    }
}

/// A write's source: the bytes of `path`, a regular 0600 file of this user's with one link in
/// `dir`, at most [`LIMIT`] bytes.
#[cfg(unix)]
pub(crate) fn read_source(dir: &Path, path: &str) -> Result<Vec<u8>, String> {
    let path = in_folder(dir, path)?;
    // O_NOFOLLOW refuses a symlink; O_NONBLOCK keeps a FIFO from blocking the open (it is
    // refused just after, as any file that is not a regular one).
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(&path)
        .map_err(|e| format!("the local file could not be opened: {}", e.kind()))?;
    let meta = file.metadata().map_err(|e| format!("the local file could not be read: {e}"))?;
    if !meta.is_file() || meta.uid() != uid() || meta.mode() & 0o077 != 0 || meta.nlink() != 1 {
        return Err("the local file is not a private file of this user's".into());
    }
    if meta.len() > LIMIT {
        return Err(format!("the local file is larger than {LIMIT} bytes"));
    }
    let mut data = Vec::with_capacity(usize::try_from(meta.len()).unwrap_or(0));
    file.take(LIMIT + 1)
        .read_to_end(&mut data)
        .map_err(|e| format!("the local file could not be read: {e}"))?;
    if data.len() as u64 > LIMIT {
        return Err(format!("the local file is larger than {LIMIT} bytes"));
    }
    Ok(data)
}

/// A read's destination: `path` in `dir`, new, created 0600.
#[cfg(unix)]
pub(crate) fn create_destination(dir: &Path, path: &str) -> Result<(PathBuf, File), String> {
    let path = in_folder(dir, path)?;
    // create_new is O_CREAT|O_EXCL, which never follows a symlink at the path.
    let file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&path)
        .map_err(|e| format!("the local file could not be created: {}", e.kind()))?;
    Ok((path, file))
}

/// The path form is a Unix one (file modes, owners, links, `O_NOFOLLOW`): refused elsewhere,
/// where [`transfer_dir`] is none anyway.
#[cfg(not(unix))]
pub(crate) fn read_source(_dir: &Path, _path: &str) -> Result<Vec<u8>, String> {
    Err("local_path is not served on this platform".into())
}

/// Refused off Unix, as [`read_source`] is.
#[cfg(not(unix))]
pub(crate) fn create_destination(_dir: &Path, _path: &str) -> Result<(PathBuf, File), String> {
    Err("local_path is not served on this platform".into())
}

/// Moves a 2xx read's bytes into `out`: the direct route's spooled file, or the proxy's
/// `dataBase64`, which leaves the answer's body. Anything else is left as it is.
pub(crate) fn deliver(answer: &mut Answer, out: &mut File) -> Result<(), String> {
    if !(200..300).contains(&answer.status) {
        return Ok(());
    }
    let failed = |e: std::io::Error| format!("the local file could not be written: {e}");
    match answer.file.take() {
        Some(Spool::Bytes(mut spool)) => {
            spool.rewind().map_err(failed)?;
            std::io::copy(&mut spool, out).map_err(failed)?;
        }
        Some(Spool::Json(_)) => return Err("the machine answered a listing, not a file".into()),
        None => {
            let encoded = answer
                .body
                .as_object_mut()
                .and_then(|body| body.remove("dataBase64"))
                .and_then(|data| match data {
                    Value::String(text) => Some(text),
                    _ => None,
                })
                .ok_or_else(|| "the machine's answer has no file".to_owned())?;
            let data = BASE64
                .decode(encoded)
                .map_err(|_| "the machine's file is not base64".to_owned())?;
            out.write_all(&data).map_err(failed)?;
        }
    }
    out.flush().map_err(failed)
}
