//! Reads an overlay upper directory into the change set for the way back to the Mac.
//!
//! Everything the agent wrote over the projection lands in the overlay's upper directory, so the
//! set of edits is exactly what is there. This module only reads that directory (it needs no
//! mount) and reports each path with what it means:
//!
//! - a regular file: written (or copied up with its bytes);
//! - a regular file marked `overlay.metacopy`: only its metadata changed, its bytes are still the
//!   lower layer's (the overlay was mounted with `metacopy=on`);
//! - a symlink: written, with its link text;
//! - a directory: present in the upper layer. A new directory and one that only holds copied-up
//!   children look the same here; the caller compares with the manifest;
//! - a directory marked `overlay.opaque` = `y`: it replaces the lower directory, so the lower
//!   children it hides are deleted;
//! - a character device 0/0: a whiteout, the lower path is deleted;
//! - a path marked `overlay.redirect`: it was moved from another lower path, reported with the
//!   raw redirect so the caller can refuse what it cannot map;
//! - anything else (a device, a socket, a fifo, a name that is not UTF-8): unsupported.
//!
//! The overlay marks are read from both the `trusted.` and the `user.` namespaces (a rootless
//! overlay uses `user.`). Reading `trusted.` needs privilege; without it those marks are not seen.

use std::fs;
use std::io;
use std::os::unix::fs::{FileTypeExt, MetadataExt};
use std::path::Path;

/// What one path in the upper layer means for the Mac.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum ChangeKind {
    /// A regular file with its own bytes.
    File,
    /// A regular file whose metadata changed; its bytes are still the lower layer's.
    MetadataOnly,
    /// A symlink, with its link text.
    Symlink(String),
    /// A directory present in the upper layer.
    Dir,
    /// A directory that hides everything the lower layer has under it.
    OpaqueDir,
    /// The path was moved here from another lower path (the raw redirect value).
    Redirect(String),
    /// A whiteout: the lower path is deleted.
    Delete,
    /// Something the way back cannot carry, and why.
    Unsupported(String),
}

/// One path of the change set, relative to the upper directory, components joined with `/`.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Change {
    pub path: String,
    pub kind: ChangeKind,
}

/// Reads the whole upper directory. The result is sorted by path, so it is deterministic.
pub fn read_upper(upper: &Path) -> io::Result<Vec<Change>> {
    let mut out = Vec::new();
    walk(upper, "", &mut out)?;
    out.sort();
    Ok(out)
}

fn walk(dir: &Path, rel: &str, out: &mut Vec<Change>) -> io::Result<()> {
    let mut names: Vec<_> =
        fs::read_dir(dir)?.map(|e| e.map(|e| e.file_name())).collect::<io::Result<_>>()?;
    names.sort();
    for os_name in names {
        let full = dir.join(&os_name);
        let name = os_name.to_string_lossy();
        let path = if rel.is_empty() { name.into_owned() } else { format!("{rel}/{name}") };
        if os_name.to_str().is_none() {
            out.push(Change {
                path,
                kind: ChangeKind::Unsupported("the name is not UTF-8".into()),
            });
            continue;
        }
        let md = fs::symlink_metadata(&full)?;
        let kind = classify(&full, &md)?;
        let descend = matches!(kind, ChangeKind::Dir | ChangeKind::OpaqueDir)
            || (matches!(kind, ChangeKind::Redirect(_)) && md.is_dir());
        out.push(Change { path: path.clone(), kind });
        if descend {
            walk(&full, &path, out)?;
        }
    }
    Ok(())
}

fn classify(full: &Path, md: &fs::Metadata) -> io::Result<ChangeKind> {
    let ft = md.file_type();
    if ft.is_char_device() && md.rdev() == 0 {
        return Ok(ChangeKind::Delete);
    }
    if let Some(redirect) = overlay_mark(full, "redirect") {
        return Ok(ChangeKind::Redirect(String::from_utf8_lossy(&redirect).into_owned()));
    }
    if ft.is_dir() {
        let opaque = overlay_mark(full, "opaque").is_some_and(|v| v == b"y");
        return Ok(if opaque { ChangeKind::OpaqueDir } else { ChangeKind::Dir });
    }
    if ft.is_symlink() {
        let target = fs::read_link(full)?;
        return Ok(match target.to_str() {
            Some(t) => ChangeKind::Symlink(t.to_owned()),
            None => ChangeKind::Unsupported("the link text is not UTF-8".into()),
        });
    }
    if ft.is_file() {
        return Ok(if overlay_mark(full, "metacopy").is_some() {
            ChangeKind::MetadataOnly
        } else {
            ChangeKind::File
        });
    }
    let what = if ft.is_char_device() || ft.is_block_device() {
        "a device"
    } else if ft.is_socket() {
        "a socket"
    } else {
        "a fifo"
    };
    Ok(ChangeKind::Unsupported(what.into()))
}

/// The value of an overlay mark (`trusted.overlay.NAME` or `user.overlay.NAME`), if set.
fn overlay_mark(path: &Path, name: &str) -> Option<Vec<u8>> {
    ["trusted.overlay.", "user.overlay."]
        .iter()
        .find_map(|ns| xattr::get(path, &format!("{ns}{name}")))
}

#[cfg(target_os = "linux")]
mod xattr {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::path::Path;

    /// Reads one extended attribute of `path` itself (a symlink is not followed).
    pub fn get(path: &Path, name: &str) -> Option<Vec<u8>> {
        let cpath = CString::new(path.as_os_str().as_bytes()).ok()?;
        let cname = CString::new(name).ok()?;
        let mut buf = vec![0u8; 256];
        loop {
            // SAFETY: both strings are NUL-terminated and live across the call; the buffer
            // pointer and length describe `buf`, which the kernel writes at most `len` bytes of.
            let n = unsafe {
                libc::lgetxattr(cpath.as_ptr(), cname.as_ptr(), buf.as_mut_ptr().cast(), buf.len())
            };
            if n >= 0 {
                buf.truncate(n as usize);
                return Some(buf);
            }
            if std::io::Error::last_os_error().raw_os_error() != Some(libc::ERANGE)
                || buf.len() >= 1 << 16
            {
                return None;
            }
            buf.resize(buf.len() * 4, 0);
        }
    }
}

#[cfg(not(target_os = "linux"))]
mod xattr {
    use std::path::Path;

    /// Overlay marks exist only on Linux.
    pub fn get(_path: &Path, _name: &str) -> Option<Vec<u8>> {
        None
    }
}
