//! macOS: the content-addressed copy of the daemon executable (see
//! `host_exe.rs`).

use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, Once, PoisonError};

use sha2::{Digest, Sha256};

/// Overrides the copy root (tests).
const ROOT_ENV: &str = "CMUX_TUI_HOST_EXE_DIR";
/// The copy's file name: the multi-call binary dispatches on it.
const EXE_NAME: &str = "cmux-tui";
const LOCK_NAME: &str = "in-use.lock";
/// The newest copies besides the current one that collection never
/// deletes, used or not.
const KEEP_UNUSED: usize = 2;
/// `clonefile(2)`: clone a symlink itself instead of its target (sys/clonefile.h).
const CLONE_NOFOLLOW: u32 = 0x0001;

/// The identity of a file whose SHA-256 was verified.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileKey {
    dev: u64,
    ino: u64,
    size: u64,
    mtime: (i64, i64),
    ctime: (i64, i64),
    mode: u32,
    uid: u32,
    nlink: u64,
}

#[derive(Debug, Clone)]
struct Installed {
    path: PathBuf,
    sha: String,
    key: FileKey,
}

static INSTALLED: Mutex<Option<Installed>> = Mutex::new(None);
/// An install failed: this daemon uses its own executable from then on
/// instead of hashing and copying again for every host.
static FAILED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
/// Copy directories this process already holds a shared lock on.
static LOCKED: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

pub(super) fn terminal_host_executable() -> io::Result<PathBuf> {
    let source = crate::platform::self_exe_for_spawn()?;
    let Some(root) = root() else { return Ok(source) };
    if FAILED.load(Ordering::Acquire) {
        return Ok(source);
    }
    match verified_copy(&root, &source) {
        Ok(path) => Ok(path),
        Err(error) => {
            FAILED.store(true, Ordering::Release);
            static REPORTED: Once = Once::new();
            REPORTED.call_once(|| {
                eprintln!(
                    "cmux-tui: terminal hosts run from the app bundle; their copy at {} is not \
                     usable: {error}",
                    root.display()
                );
            });
            Ok(source)
        }
    }
}

/// A spawn of `path` failed: stop using the copy for this daemon.
pub(super) fn copy_failed(path: &Path) {
    let mut installed = INSTALLED.lock().unwrap_or_else(PoisonError::into_inner);
    if installed.as_ref().is_some_and(|copy| copy.path == path) {
        *installed = None;
        FAILED.store(true, Ordering::Release);
    }
}

pub(super) fn hold_in_use_lock() {
    let (Some(root), Ok(exe)) = (root(), std::env::current_exe()) else { return };
    let Some(dir) = exe.parent() else { return };
    let runs_a_copy = exe.file_name().is_some_and(|name| name == EXE_NAME)
        && dir.parent().and_then(|parent| fs::canonicalize(parent).ok())
            == fs::canonicalize(&root).ok();
    if runs_a_copy {
        let _ = hold_shared_lock(dir);
    }
}

fn root() -> Option<PathBuf> {
    if let Some(root) = std::env::var_os(ROOT_ENV).filter(|value| !value.is_empty()) {
        return Some(PathBuf::from(root));
    }
    crate::platform::home_dir()
        .map(|home| home.join("Library/Application Support/cmux-tui/host-exe"))
}

/// The verified copy of `source` under `root`, installing it when needed.
fn verified_copy(root: &Path, source: &Path) -> io::Result<PathBuf> {
    let mut installed = INSTALLED.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(current) = installed.as_mut() {
        let key = file_key(&current.path);
        if key.as_ref().ok() == Some(&current.key) {
            return Ok(current.path.clone());
        }
        if key.is_ok() && sha256_file(&current.path)? == current.sha {
            current.key = file_key(&current.path)?;
            return Ok(current.path.clone());
        }
        eprintln!(
            "cmux-tui: the terminal-host copy {} changed after it was verified; not using it",
            current.path.display()
        );
        *installed = None;
    }
    let fresh = install(root, source)?;
    let path = fresh.path.clone();
    *installed = Some(fresh);
    Ok(path)
}

fn install(root: &Path, source: &Path) -> io::Result<Installed> {
    let source = fs::canonicalize(source)?;
    ensure_private_dir(root)?;
    let sha = sha256_file(&source)?;
    let dir = root.join(&sha);
    ensure_private_dir(&dir)?;
    // Held for this daemon's life before the copy is checked, so a
    // concurrent collection never removes it under us.
    hold_shared_lock(&dir)?;
    let path = dir.join(EXE_NAME);
    let usable = fs::symlink_metadata(&path)
        .is_ok_and(|meta| meta.file_type().is_file() && meta.uid() == effective_uid());
    if !usable || sha256_file(&path)? != sha {
        // The rename replaces a wrong file; a missing one may be another
        // daemon's copy landing now, which the rename also tolerates.
        write_copy(&source, &dir, &path, &sha)?;
    }
    let key = file_key(&path)?;
    collect_unused(root, &sha);
    Ok(Installed { path, sha, key })
}

/// Clone (or copy) `source` to a private temporary file in `dir`, check its
/// hash, then rename it to `path`.
fn write_copy(source: &Path, dir: &Path, path: &Path, sha: &str) -> io::Result<()> {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let temporary = dir.join(format!(
        ".{EXE_NAME}.tmp-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let result = (|| {
        if clone_file(source, &temporary).is_err() {
            let mut from = File::open(source)?;
            let mut to = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o700)
                .custom_flags(libc::O_NOFOLLOW)
                .open(&temporary)?;
            io::copy(&mut from, &mut to)?;
        }
        // A clone keeps the bundle's extended attributes. A quarantined copy
        // outside its approved bundle would stop at Gatekeeper on exec.
        drop_quarantine(&temporary);
        fs::set_permissions(&temporary, fs::Permissions::from_mode(0o500))?;
        File::open(&temporary)?.sync_all()?;
        if sha256_file(&temporary)? != sha {
            return Err(io::Error::other("the copied terminal-host executable has another hash"));
        }
        fs::rename(&temporary, path)?;
        // Directory sync is best effort (some network homes reject it).
        let _ = File::open(dir).and_then(|dir| dir.sync_all());
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn drop_quarantine(path: &Path) {
    let (Ok(path), Ok(name)) =
        (CString::new(path.as_os_str().as_bytes()), CString::new("com.apple.quarantine"))
    else {
        return;
    };
    // SAFETY: both arguments are NUL-terminated strings that outlive the call;
    // a missing attribute is not an error worth reporting.
    unsafe { libc::removexattr(path.as_ptr(), name.as_ptr(), libc::XATTR_NOFOLLOW) };
}

fn clone_file(source: &Path, destination: &Path) -> io::Result<()> {
    let source = CString::new(source.as_os_str().as_bytes())?;
    let destination = CString::new(destination.as_os_str().as_bytes())?;
    // SAFETY: both arguments are NUL-terminated paths that outlive the call.
    if unsafe { libc::clonefile(source.as_ptr(), destination.as_ptr(), CLONE_NOFOLLOW) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

/// Create `dir` (mode 0700) when missing; refuse a directory that is a
/// symlink, owned by another user, or open to group or others.
fn ensure_private_dir(dir: &Path) -> io::Result<()> {
    match fs::DirBuilder::new().recursive(true).mode(0o700).create(dir) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(error),
    }
    let meta = fs::symlink_metadata(dir)?;
    if !meta.file_type().is_dir() || meta.uid() != effective_uid() || meta.mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a private directory of this user", dir.display()),
        ));
    }
    Ok(())
}

fn effective_uid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

/// Take a shared lock on `dir`'s in-use lock for the rest of this process
/// (once per directory).
fn hold_shared_lock(dir: &Path) -> io::Result<()> {
    let mut locked = LOCKED.lock().unwrap_or_else(PoisonError::into_inner);
    if locked.iter().any(|held| held == dir) {
        return Ok(());
    }
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(dir.join(LOCK_NAME))?;
    // SAFETY: flock on a descriptor this function owns.
    if unsafe { libc::flock(std::os::fd::AsRawFd::as_raw_fd(&file), libc::LOCK_SH) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // The descriptor, and the lock, stay open until the process ends.
    std::mem::forget(file);
    locked.push(dir.to_path_buf());
    Ok(())
}

/// Delete the copies under `root` that no process uses (their in-use lock
/// is free), except `current` and the newest [`KEEP_UNUSED`].
fn collect_unused(root: &Path, current: &str) {
    let Ok(entries) = fs::read_dir(root) else { return };
    let mut unused = entries
        .filter_map(Result::ok)
        .filter(|entry| {
            let name = entry.file_name();
            name.len() == 64
                && name != current
                && name.to_str().is_some_and(|name| name.bytes().all(|b| b.is_ascii_hexdigit()))
        })
        .filter_map(|entry| {
            let meta = fs::symlink_metadata(entry.path()).ok()?;
            meta.file_type().is_dir().then(|| (meta.mtime(), entry.path()))
        })
        .collect::<Vec<_>>();
    unused.sort_by_key(|entry| std::cmp::Reverse(entry.0));
    for (_, dir) in unused.into_iter().skip(KEEP_UNUSED) {
        let Ok(lock) = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(dir.join(LOCK_NAME))
        else {
            continue;
        };
        // SAFETY: flock on a descriptor this function owns.
        let free = unsafe {
            libc::flock(std::os::fd::AsRawFd::as_raw_fd(&lock), libc::LOCK_EX | libc::LOCK_NB)
        } == 0;
        if free {
            let _ = fs::remove_dir_all(&dir);
        }
    }
}

fn file_key(path: &Path) -> io::Result<FileKey> {
    let meta = fs::symlink_metadata(path)?;
    if !meta.file_type().is_file() {
        return Err(io::Error::other("the terminal-host copy is not a regular file"));
    }
    Ok(FileKey {
        dev: meta.dev(),
        ino: meta.ino(),
        size: meta.size(),
        mtime: (meta.mtime(), meta.mtime_nsec()),
        ctime: (meta.ctime(), meta.ctime_nsec()),
        mode: meta.mode(),
        uid: meta.uid(),
        nlink: meta.nlink(),
    })
}

fn sha256_file(path: &Path) -> io::Result<String> {
    let mut file = File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("hx-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir).unwrap();
        dir
    }

    fn source(dir: &Path, bytes: &[u8]) -> PathBuf {
        let path = dir.join("source-exe");
        fs::write(&path, bytes).unwrap();
        path
    }

    #[test]
    fn the_copy_is_private_hashed_and_named_by_its_hash() {
        let dir = temp("install");
        let root = dir.join("root");
        let source = source(&dir, b"first build");
        let installed = install(&root, &source).unwrap();
        assert_eq!(installed.path, root.join(&installed.sha).join(EXE_NAME));
        assert_eq!(fs::read(&installed.path).unwrap(), b"first build");
        let mode = |path: &Path| fs::metadata(path).unwrap().mode() & 0o777;
        assert_eq!(mode(&root), 0o700);
        assert_eq!(mode(&root.join(&installed.sha)), 0o700);
        assert_eq!(mode(&installed.path), 0o500);
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn a_tampered_copy_is_never_reused() {
        let dir = temp("tamper");
        let root = dir.join("root");
        let source = source(&dir, b"good build");
        let installed = install(&root, &source).unwrap();
        fs::set_permissions(&installed.path, fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(&installed.path, b"evil").unwrap();
        // A new install sees the wrong hash and writes the good copy again.
        let again = install(&root, &source).unwrap();
        assert_eq!(fs::read(&again.path).unwrap(), b"good build");
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn a_shared_root_is_refused() {
        let dir = temp("shared");
        let root = dir.join("root");
        fs::DirBuilder::new().mode(0o755).create(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(install(&root, &source(&dir, b"x")).is_err());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn unused_copies_are_collected_but_not_the_newest_two() {
        let dir = temp("collect");
        let root = dir.join("root");
        for (index, name) in ["a", "b", "c", "d"].iter().enumerate() {
            let sha = name.repeat(64);
            let copy = root.join(&sha);
            fs::DirBuilder::new().recursive(true).mode(0o700).create(&copy).unwrap();
            fs::write(copy.join(LOCK_NAME), b"").unwrap();
            let when = std::time::SystemTime::UNIX_EPOCH
                + std::time::Duration::from_secs(1_000 + index as u64);
            File::open(&copy).unwrap().set_modified(when).unwrap();
        }
        // "b" is in use by another process: its lock is held shared.
        hold_shared_lock(&root.join("b".repeat(64))).unwrap();
        collect_unused(&root, &"e".repeat(64));
        let left = |name: &str| root.join(name.repeat(64)).exists();
        assert!(!left("a"), "an old unused copy was kept");
        assert!(left("b"), "a copy in use was deleted");
        assert!(left("c") && left("d"), "the newest two unused copies were deleted");
        let _ = fs::remove_dir_all(dir);
    }
}
