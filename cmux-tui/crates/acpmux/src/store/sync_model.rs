//! Tests: the event logs' crash model follows the syncs that ran (review 2 of #34901).
//!
//! At an OS crash a log segment keeps its length at its last sync that counts. A failed sync loses
//! what was written since the sync before it, and a later sync does not bring that back: the
//! kernel may mark those pages clean without writing them, and the next sync then reports success.
//! A cut at or before the lost bytes ends the loss (the bytes after it are written again). Each
//! segment is known by its real path and inode, so a test's files never meet another test's, and
//! a segment removed and made again starts with nothing kept.

use std::collections::HashMap;
use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

#[derive(Clone, Copy, Default)]
struct Kept {
    ino: u64,
    /// The length the disk holds since the last sync that counts.
    durable: u64,
    /// A failed sync lost the bytes from here on, until a cut at or before it.
    lost_from: Option<u64>,
}

static FILES: LazyLock<Mutex<HashMap<PathBuf, Kept>>> = LazyLock::new(Mutex::default);

/// Each synced folder's entries (name and file id) as of its last sync: what an OS crash keeps
/// of that folder.
static FOLDERS: LazyLock<Mutex<HashMap<PathBuf, Vec<(std::ffi::OsString, u64)>>>> =
    LazyLock::new(Mutex::default);

/// The real path of `file`'s descriptor.
#[cfg(target_os = "linux")]
fn path_of(file: &File) -> Option<PathBuf> {
    use std::os::fd::AsRawFd;
    std::fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd())).ok()
}

/// The real path of `file`'s descriptor.
#[cfg(target_os = "macos")]
fn path_of(file: &File) -> Option<PathBuf> {
    use std::os::fd::AsRawFd;
    use std::os::unix::ffi::OsStrExt;
    let mut buf = vec![0u8; usize::try_from(libc::PATH_MAX).ok()?];
    // SAFETY: F_GETPATH writes at most PATH_MAX bytes, a NUL-terminated path, into `buf`.
    let got = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_GETPATH, buf.as_mut_ptr()) };
    if got == -1 {
        return None;
    }
    let len = buf.iter().position(|byte| *byte == 0)?;
    Some(PathBuf::from(std::ffi::OsStr::from_bytes(buf.get(..len)?)))
}

/// The real path of `file`'s descriptor (not known here: the model keeps nothing).
#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn path_of(_file: &File) -> Option<PathBuf> {
    None
}

fn key(path: &Path) -> Option<PathBuf> {
    std::fs::canonicalize(path).ok()
}

fn update(file: &File, change: impl FnOnce(&mut Kept, u64)) {
    use std::os::unix::fs::MetadataExt;
    let (Some(path), Ok(meta)) = (path_of(file).as_deref().and_then(key), file.metadata()) else {
        return;
    };
    let mut files = FILES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let kept = files.entry(path).or_default();
    if kept.ino != meta.ino() {
        *kept = Kept { ino: meta.ino(), ..Kept::default() };
    }
    change(kept, meta.len());
}

/// A sync of the log segment `file` ran; `ok` is its result.
pub(crate) fn synced(file: &File, ok: bool) {
    update(file, |kept, len| {
        if !ok {
            kept.lost_from.get_or_insert(kept.durable);
        } else if kept.lost_from.is_none() {
            kept.durable = len;
        }
    });
}

/// The log segment `file` was cut to `len` (its sync follows).
pub(crate) fn cut(file: &File, len: u64) {
    update(file, |kept, _| {
        kept.durable = kept.durable.min(len);
        if kept.lost_from.is_some_and(|from| from >= len) {
            kept.lost_from = None;
        }
    });
}

/// An OS crash of the event logs under `sessions` (`<home>/sessions`): each segment goes back to
/// what the disk kept of it, and a segment no sync counted for goes back to empty.
pub(crate) fn os_crash(sessions: &Path) {
    use std::os::unix::fs::MetadataExt;
    let Ok(chats) = std::fs::read_dir(sessions) else { return };
    let mut files = FILES.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    for chat in chats.flatten() {
        let Ok(segments) = std::fs::read_dir(chat.path().join("events")) else { continue };
        for segment in segments.flatten() {
            let path = segment.path();
            let (Some(real), Ok(meta)) = (key(&path), std::fs::metadata(&path)) else { continue };
            if !meta.is_file() || path.extension().is_none_or(|ext| ext != "ndjson") {
                continue;
            }
            let kept = files.get(&real).copied().filter(|kept| kept.ino == meta.ino());
            let len = kept.map_or(0, |kept| {
                kept.lost_from.map_or(kept.durable, |from| from.min(kept.durable))
            });
            let len = len.min(meta.len());
            let file = std::fs::OpenOptions::new()
                .write(true)
                .open(&path)
                .unwrap_or_else(|e| panic!("open {}: {e}", path.display()));
            file.set_len(len).unwrap_or_else(|e| panic!("cut {}: {e}", path.display()));
            files.insert(real, Kept { ino: meta.ino(), durable: len, lost_from: None });
        }
    }
}

/// The folder at `path` was synced: its entries now are what an OS crash keeps of it.
pub(crate) fn folder_synced(path: &Path) {
    use std::os::unix::fs::MetadataExt;
    let (Some(real), Ok(entries)) = (key(path), std::fs::read_dir(path)) else { return };
    let kept = entries
        .flatten()
        .filter_map(|entry| Some((entry.file_name(), entry.metadata().ok()?.ino())))
        .collect();
    FOLDERS.lock().unwrap_or_else(std::sync::PoisonError::into_inner).insert(real, kept);
}

/// Whether the last sync of the folder at `path` kept its entry `name` as it is now.
pub(crate) fn folder_keeps(path: &Path, name: &str) -> bool {
    use std::os::unix::fs::MetadataExt;
    let (Some(real), Ok(meta)) = (key(path), std::fs::symlink_metadata(path.join(name))) else {
        return false;
    };
    let folders = FOLDERS.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    folders.get(&real).is_some_and(|kept| {
        kept.iter().any(|(kept_name, ino)| kept_name.as_os_str() == name && *ino == meta.ino())
    })
}

/// An OS crash of `sessions`' entries: each chat folder its last sync did not keep goes, with
/// what is in it.
pub(crate) fn os_crash_folders(sessions: &Path) {
    let Ok(chats) = std::fs::read_dir(sessions) else { return };
    for chat in chats.flatten() {
        let name = chat.file_name().to_string_lossy().into_owned();
        if !folder_keeps(sessions, &name) {
            std::fs::remove_dir_all(chat.path())
                .unwrap_or_else(|e| panic!("remove {}: {e}", chat.path().display()));
        }
    }
}
