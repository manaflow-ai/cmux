//! File helpers: atomic writes with a mode, directories with a mode, the
//! symlink swap behind every `current` flip, read-only package trees and
//! their removal.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::{Path, PathBuf};

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

/// Creates `path` when it is missing: every missing component gets `mode`
/// (less the umask) and `path` itself gets exactly `mode`. An existing
/// directory is left as it is, mode included (decision SV-R4: the server
/// never changes a directory it did not just create; the policy paths in
/// `cmux_server_core::access` are checked, and refused when wider, by
/// [`crate::access`]).
pub fn ensure_dir(path: &Path, mode: u32) -> Result<()> {
    if fs::metadata(path).is_ok_and(|m| m.is_dir()) {
        return Ok(());
    }
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(mode);
    }
    builder.create(path).ctx(path.display())?;
    set_mode(path, mode).ctx(path.display())
}

/// Points the symlink `link` at `target` with one `rename(2)`: a reader
/// sees the old or the new target, never a missing link.
pub fn swap_symlink(link: &Path, target: &Path) -> Result<()> {
    let tmp = temp_sibling(link, "swap");
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, &tmp).ctx(tmp.display())?;
    #[cfg(not(unix))]
    return Err(crate::error::Error::internal(format!(
        "{}: symlink flips need a Unix platform",
        tmp.display()
    )));
    #[cfg(unix)]
    {
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
