//! The Chief home clone: folders with their modes, regular files as APFS
//! clones (a byte copy where cloning fails), symbolic links as links;
//! sockets, FIFOs and devices skipped. A SQLite database is copied with
//! `VACUUM INTO` from a read-only connection (one consistent, self-contained
//! file while NIGHTLY's brain or owner writes it, WAL content included); its
//! `-wal`/`-shm`/`-journal` files are not copied. A database that cannot be
//! read that way is cloned raw with its journal files and named in `raw`.

use std::path::{Path, PathBuf};

/// What [`clone_tree`] leaves out, by the path relative to the top.
pub(super) type Skip<'a> = &'a dyn Fn(&[String]) -> bool;

pub(super) struct Cloned {
    /// Databases cloned raw (not readable through SQLite).
    pub raw: Vec<PathBuf>,
    /// Entries left out by the skip rule.
    pub skipped: Vec<String>,
}

/// Copies `source` to the new folder `target` (which must not exist).
pub(super) fn clone_tree(source: &Path, target: &Path, skip: Skip<'_>) -> std::io::Result<Cloned> {
    let mut out = Cloned { raw: Vec::new(), skipped: Vec::new() };
    clone_dir(source, target, &mut Vec::new(), skip, &mut out)?;
    Ok(out)
}

fn clone_dir(
    source: &Path,
    target: &Path,
    rel: &mut Vec<String>,
    skip: Skip<'_>,
    out: &mut Cloned,
) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let mode = cmux_blocking::fs::metadata(source)?.permissions().mode() & 0o7777;
    crate::blocking::fs::create_dir(target)?;
    crate::blocking::fs::set_permissions(target, std::fs::Permissions::from_mode(0o700))?;
    let mut names: Vec<String> = cmux_blocking::fs::read_dir(source)?
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let databases: Vec<String> =
        names.iter().filter(|n| is_sqlite(&source.join(n))).cloned().collect();
    for name in &names {
        if is_sidecar(name, &databases) {
            continue;
        }
        rel.push(name.clone());
        let result = clone_entry(source, target, name, rel, skip, &databases, &names, out);
        rel.pop();
        result?;
    }
    crate::blocking::fs::set_permissions(target, std::fs::Permissions::from_mode(mode))
}

#[allow(clippy::too_many_arguments)]
fn clone_entry(
    source: &Path,
    target: &Path,
    name: &str,
    rel: &mut Vec<String>,
    skip: Skip<'_>,
    databases: &[String],
    names: &[String],
    out: &mut Cloned,
) -> std::io::Result<()> {
    let (from, to) = (source.join(name), target.join(name));
    if skip(rel) {
        out.skipped.push(rel.join("/"));
        return Ok(());
    }
    let Ok(meta) = cmux_blocking::fs::symlink_metadata(&from) else { return Ok(()) };
    let kind = meta.file_type();
    if kind.is_dir() {
        clone_dir(&from, &to, rel, skip, out)
    } else if kind.is_symlink() {
        std::os::unix::fs::symlink(crate::blocking::fs::read_link(&from)?, &to)
    } else if kind.is_file() && databases.iter().any(|d| d == name) {
        if backup_database(&from, &to).is_err() {
            let _ = cmux_blocking::fs::remove_file(&to);
            for suffix in ["", "-wal", "-shm", "-journal"] {
                let file = format!("{name}{suffix}");
                if names.contains(&file) {
                    clone_file(&source.join(&file), &target.join(&file))?;
                }
            }
            out.raw.push(from);
        }
        Ok(())
    } else if kind.is_file() {
        clone_file(&from, &to)
    } else {
        // Sockets, FIFOs, devices: a live process's, never state.
        Ok(())
    }
}

/// A regular file that starts with the SQLite header.
pub(super) fn is_sqlite(path: &Path) -> bool {
    use std::io::Read;
    let Ok(meta) = cmux_blocking::fs::symlink_metadata(path) else { return false };
    if !meta.file_type().is_file() {
        return false;
    }
    let mut header = [0u8; 16];
    cmux_blocking::fs::open(path).and_then(|mut f| f.read_exact(&mut header)).is_ok()
        && &header == b"SQLite format 3\0"
}

fn is_sidecar(name: &str, databases: &[String]) -> bool {
    ["-wal", "-shm", "-journal"].iter().any(|suffix| {
        name.strip_suffix(suffix).is_some_and(|base| databases.iter().any(|d| d == base))
    })
}

/// An APFS clone of one file on macOS, else (or where it fails) a copy.
pub(super) fn clone_file(from: &Path, to: &Path) -> std::io::Result<()> {
    #[cfg(target_os = "macos")]
    {
        use std::ffi::CString;
        use std::os::unix::ffi::OsStrExt;
        const CLONE_NOFOLLOW: u32 = 0x0001;
        if let (Ok(src), Ok(dst)) =
            (CString::new(from.as_os_str().as_bytes()), CString::new(to.as_os_str().as_bytes()))
        {
            // SAFETY: two NUL-terminated paths that live through the call.
            if unsafe { libc::clonefile(src.as_ptr(), dst.as_ptr(), CLONE_NOFOLLOW) } == 0 {
                return Ok(());
            }
        }
    }
    cmux_blocking::fs::copy(from, to).map(|_| ())
}

/// `VACUUM INTO` the new file `to` from a read-only connection to `from`.
fn backup_database(from: &Path, to: &Path) -> rusqlite::Result<()> {
    use rusqlite::{Connection, OpenFlags};
    let connection = Connection::open_with_flags(
        from,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )?;
    connection.busy_timeout(std::time::Duration::from_secs(10))?;
    connection.execute("VACUUM INTO ?1", [to.to_string_lossy().as_ref()])?;
    Ok(())
}

/// Replaces `from` (a path) with `to` in the UTF-8 text file `path`, only
/// where a whole path component ends (`…/default` and `…/default/x`, never
/// `…/default2`). Returns whether the file changed.
pub(super) fn rewrite_root(path: &Path, from: &str, to: &str) -> std::io::Result<bool> {
    let Ok(text) = cmux_blocking::fs::read_to_string(path) else { return Ok(false) };
    let mut out = String::with_capacity(text.len());
    let mut rest = text.as_str();
    let mut changed = false;
    while let Some(at) = rest.find(from) {
        let after = &rest[at + from.len()..];
        let ends = after
            .chars()
            .next()
            .is_none_or(|c| !(c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-')));
        out.push_str(&rest[..at]);
        out.push_str(if ends { to } else { from });
        changed |= ends;
        rest = after;
    }
    out.push_str(rest);
    if changed {
        let tmp = path.with_extension(format!("adopt-{}", super::random_hex(4)));
        cmux_blocking::fs::write(&tmp, out)?;
        if let Ok(meta) = cmux_blocking::fs::metadata(path) {
            crate::blocking::fs::set_permissions(&tmp, meta.permissions())?;
        }
        cmux_blocking::fs::rename(&tmp, path)?;
    }
    Ok(changed)
}
