//! File helpers: atomic writes with a mode, directories with a mode, the
//! symlink swap behind every `current` flip, read-only package trees and
//! their removal.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_server_core::HostPath;

use crate::error::{IoContext, Result};
use crate::sys;

/// A core `HostPath` as a local path.
pub fn local(path: &HostPath) -> PathBuf {
    PathBuf::from(path.as_str())
}

/// A unique sibling name for a temporary file next to `path`.
pub fn temp_sibling(path: &Path, tag: &str) -> PathBuf {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut nonce = [0u8; 6];
    let _ = getrandom::fill(&mut nonce);
    let nonce: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    path.with_file_name(format!(".{name}.{tag}.{}.{nonce}", std::process::id()))
}

fn open_new(path: &Path, mode: u32) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(mode);
    }
    #[cfg(not(unix))]
    let _ = mode;
    options.open(path)
}

/// Sets the permission bits of `path` (Unix only; a no-op elsewhere).
pub fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode))
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
        Ok(())
    }
}

/// The permission bits of `path` (0 where there are none).
pub fn mode_of(meta: &fs::Metadata) -> u32 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o7777
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        0
    }
}

/// Writes `bytes` to `path` atomically: a new temporary file created with
/// `mode` (so a secret is never readable by others, not even briefly),
/// fsync, rename over `path`, fsync of the directory.
pub fn atomic_write(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let tmp = temp_sibling(path, "tmp");
    let result = (|| -> io::Result<()> {
        let mut file = open_new(&tmp, mode)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        set_mode(&tmp, mode)?;
        fs::rename(&tmp, path)?;
        if let Some(dir) = path.parent() {
            sys::fsync_dir(dir)?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result.ctx(path.display())
}

/// Like [`atomic_write`], but only when the content differs. Returns
/// whether it wrote.
pub fn write_if_changed(path: &Path, bytes: &[u8], mode: u32) -> Result<bool> {
    match fs::read(path) {
        Ok(old) if old == bytes => {
            set_mode(path, mode).ctx(path.display())?;
            Ok(false)
        }
        _ => atomic_write(path, bytes, mode).map(|()| true),
    }
}

/// Creates `path` when it is missing: missing parents get `mode` (less the
/// umask), and `path` itself, created by one non-recursive `mkdir`, gets
/// exactly `mode`. An existing directory is left as it is, mode included,
/// also when another process creates it first (decision SV-R4: the server
/// never changes a directory it did not just create; the policy paths in
/// `cmux_server_core::access` are checked, and refused when wider, by
/// [`crate::access`]).
pub fn ensure_dir(path: &Path, mode: u32) -> Result<()> {
    if fs::metadata(path).is_ok_and(|m| m.is_dir()) {
        return Ok(());
    }
    let builder = |recursive: bool| {
        let mut builder = fs::DirBuilder::new();
        builder.recursive(recursive);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(mode);
        }
        builder
    };
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        builder(true).create(parent).ctx(parent.display())?;
    }
    match builder(false).create(path) {
        Ok(()) => set_mode(path, mode).ctx(path.display()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists && path.is_dir() => Ok(()),
        Err(e) => Err(crate::error::Error::io(path.display(), e)),
    }
}

/// Points the symlink `link` at `target` with one `rename(2)`: a reader
/// sees the old or the new target, never a missing link.
pub fn swap_symlink(link: &Path, target: &Path) -> Result<()> {
    swap(link, target, false)
}

/// Pins older than this are removed on the next flip or GC.
pub const PIN_MAX_AGE: Duration = Duration::from_secs(10);

/// [`swap_symlink`] for a link that readers resolve while it flips (the
/// store's `current`). On macOS 26.5, `rename(2)` over a symlink makes a
/// concurrent `readlink`, `stat` or `open` of that path fail with EINVAL
/// while the replaced symlink's inode is freed. So the old symlink is first
/// hard-linked to `.<name>.pin.<pid>.<nonce>` (the link itself, not its
/// target), which keeps that inode alive through the rename. Pins whose
/// ctime is older than [`PIN_MAX_AGE`] are removed on each flip and by GC.
pub fn swap_symlink_pinned(link: &Path, target: &Path) -> Result<()> {
    swap(link, target, true)?;
    prune_pins(link, PIN_MAX_AGE)
}

fn swap(link: &Path, target: &Path, pin: bool) -> Result<()> {
    let tmp = temp_sibling(link, "swap");
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, &tmp).ctx(tmp.display())?;
    #[cfg(not(unix))]
    return Err(crate::error::Error::internal(format!(
        "{}: symlink flips need a Unix platform; {} -> {} (pin {pin})",
        tmp.display(),
        link.display(),
        target.display()
    )));
    #[cfg(unix)]
    {
        if pin && fs::symlink_metadata(link).is_ok_and(|m| m.file_type().is_symlink()) {
            // Best effort: a file system without hard links still flips.
            let _ = hard_link_no_follow(link, &temp_sibling(link, "pin"));
        }
        if let Err(e) = fs::rename(&tmp, link) {
            let _ = fs::remove_file(&tmp);
            return Err(crate::error::Error::io(link.display(), e));
        }
        if let Some(dir) = link.parent() {
            sys::fsync_dir(dir).ctx(dir.display())?;
        }
        Ok(())
    }
}

/// `linkat(2)` without `AT_SYMLINK_FOLLOW`: a new name for the symlink
/// itself.
#[cfg(unix)]
fn hard_link_no_follow(existing: &Path, new: &Path) -> io::Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = |p: &Path| {
        CString::new(p.as_os_str().as_bytes()).map_err(|e| io::Error::other(e.to_string()))
    };
    let (from, to) = (c(existing)?, c(new)?);
    // SAFETY: both pointers come from live CStrings.
    let rc = unsafe { libc::linkat(libc::AT_FDCWD, from.as_ptr(), libc::AT_FDCWD, to.as_ptr(), 0) };
    if rc == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

/// Removes the pins of `link` whose ctime is at least `max_age` old
/// (`Duration::ZERO`: all of them).
pub fn prune_pins(link: &Path, max_age: Duration) -> Result<()> {
    let (Some(dir), Some(name)) = (link.parent(), link.file_name()) else { return Ok(()) };
    let prefix = format!(".{}.pin.", name.to_string_lossy());
    let Ok(entries) = fs::read_dir(dir) else { return Ok(()) };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        if !entry.file_name().to_string_lossy().starts_with(&prefix) {
            continue;
        }
        let path = entry.path();
        let Ok(meta) = fs::symlink_metadata(&path) else { continue };
        if now.duration_since(ctime(&meta)).unwrap_or(Duration::ZERO) >= max_age {
            match fs::remove_file(&path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(crate::error::Error::io(path.display(), e)),
            }
        }
    }
    Ok(())
}

fn ctime(meta: &fs::Metadata) -> SystemTime {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let secs = u64::try_from(meta.ctime()).unwrap_or(0);
        let nanos = u32::try_from(meta.ctime_nsec()).unwrap_or(0);
        UNIX_EPOCH + Duration::new(secs, nanos)
    }
    #[cfg(not(unix))]
    {
        meta.modified().unwrap_or(UNIX_EPOCH)
    }
}

/// Removes write permission from every file and directory under `root`
/// (keeping execute bits), so a package is immutable after unpack.
pub fn make_read_only(root: &Path) -> Result<()> {
    for entry in fs::read_dir(root).ctx(root.display())? {
        let entry = entry.ctx(root.display())?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path).ctx(path.display())?;
        if meta.is_dir() {
            make_read_only(&path)?;
        } else if meta.is_file() {
            set_mode(&path, mode_of(&meta) & 0o555).ctx(path.display())?;
        }
    }
    set_mode(root, 0o555).ctx(root.display())
}

/// Removes `path` (file, symlink or tree). Read-only directories are made
/// writable first; symlinks are removed, never followed. Missing is fine.
pub fn remove_tree(path: &Path) -> Result<()> {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(crate::error::Error::io(path.display(), e)),
    };
    if !meta.is_dir() {
        return fs::remove_file(path).ctx(path.display());
    }
    set_mode(path, 0o700).ctx(path.display())?;
    for entry in fs::read_dir(path).ctx(path.display())? {
        remove_tree(&entry.ctx(path.display())?.path())?;
    }
    fs::remove_dir(path).ctx(path.display())
}

/// True when `path` exists (without following a final symlink).
pub fn exists_no_follow(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}
