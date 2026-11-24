//! A top-level lower folder replaced by a link to a folder on the machine's disk, in one rename
//! (RFD 0007, seed bundles: a projected `.git` switching to the machine's own fetch,
//! [`crate::git_swap`]).
//!
//! The link goes into the upper layer by `renameat2`: `RENAME_NOREPLACE` when the upper layer has
//! nothing at the name, `RENAME_EXCHANGE` when git already copied the folder up (its writes are
//! in the new folder too, which the caller made from the merged view). Every later lookup of the
//! name answers the link, under a new number, so the kernel never sees one number change kind. A
//! process that already holds the old folder (a `git` mid-command, its cwd) keeps reading the
//! manifest's tree below it, as an open folder renamed away on a disk does: the old number is
//! [`Inner::retired`], never handed out again.

use std::ffi::CString;
use std::os::unix::ffi::OsStrExt as _;

use super::Type;
use super::{EEXIST, EIO, ENOENT, ENOTDIR, Entry, Inner, Kind, Node, Overlay, Path, PoisonError};
use super::{fs, join};

const RENAME_NOREPLACE: u32 = 1;
const RENAME_EXCHANGE: u32 = 2;

/// `renameat2` on Linux: the raw syscall, as `Upper::rename` makes it (musl has no `renameat2`
/// wrapper).
#[cfg(target_os = "linux")]
fn rename2(from: &Path, to: &Path, flags: u32) -> Result<(), i32> {
    let from = CString::new(from.as_os_str().as_bytes()).map_err(|_| EIO)?;
    let to = CString::new(to.as_os_str().as_bytes()).map_err(|_| EIO)?;
    // SAFETY: two valid C strings and `AT_FDCWD` for both (absolute paths).
    let done = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            flags,
        )
    };
    if done < 0 {
        Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(EIO))
    } else {
        Ok(())
    }
}

/// `renamex_np` on macOS, Linux's flags turned into its own (`RENAME_EXCL`, `RENAME_SWAP`), as
/// `Upper::rename` makes it.
#[cfg(not(target_os = "linux"))]
fn rename2(from: &Path, to: &Path, flags: u32) -> Result<(), i32> {
    let from = CString::new(from.as_os_str().as_bytes()).map_err(|_| EIO)?;
    let to = CString::new(to.as_os_str().as_bytes()).map_err(|_| EIO)?;
    let mut own = 0;
    if flags & RENAME_NOREPLACE != 0 {
        own |= libc::RENAME_EXCL;
    }
    if flags & RENAME_EXCHANGE != 0 {
        own |= libc::RENAME_SWAP;
    }
    // SAFETY: two valid C strings (absolute paths).
    if unsafe { libc::renamex_np(from.as_ptr(), to.as_ptr(), own) } < 0 {
        Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(EIO))
    } else {
        Ok(())
    }
}

impl Overlay {
    /// Replaces the lower folder at top-level `name` with a link naming `target`, atomically for
    /// every lookup through the mount. Returns the folder's old number; the caller then tells the
    /// kernel to drop what it cached of `name` ([`crate::mount::Mounted::forget_entry`]).
    pub fn swap_to_link(&self, name: &str, target: &Path) -> Result<u64, i32> {
        if name.is_empty() || name.contains('/') {
            return Err(super::EINVAL);
        }
        let _swap = self.swap.write().unwrap_or_else(PoisonError::into_inner);
        let index = self.lower(name).ok_or(ENOENT)?;
        if self.manifest.entry(index).map(|entry| entry.kind) != Some(Kind::Dir) {
            return Err(ENOTDIR);
        }
        let upper_now = match self.upper.stat(name) {
            Ok(stat) if stat.is_dir() => Some(stat),
            Ok(_) => return Err(EEXIST),
            Err(ENOENT) => None,
            Err(errno) => return Err(errno),
        };
        let old = {
            let inner = self.lock();
            inner.inos.get(name).copied().unwrap_or(u64::from(index) + 1)
        };
        let link = self.scratch_path();
        std::os::unix::fs::symlink(target, &link).map_err(|error| super::io_errno(&error))?;
        let at = self.upper.path().join(name);
        let flags = if upper_now.is_some() { RENAME_EXCHANGE } else { RENAME_NOREPLACE };
        if let Err(errno) = rename2(&link, &at, flags) {
            let _ = fs::remove_file(&link);
            return Err(errno);
        }
        {
            let mut inner = self.lock();
            Self::retire(&mut inner, name, old, index, self.manifest.head_len() as u64);
        }
        // The folder git copied up before the swap (its writes are in `target` too).
        if upper_now.is_some() {
            let _ = fs::remove_dir_all(&link);
        }
        Ok(old)
    }

    fn retire(inner: &mut Inner, name: &str, old: u64, index: u32, manifest_len: u64) {
        inner.inos.remove(name);
        inner.paths.remove(&old);
        inner.by_upper.retain(|_, ino| *ino != old);
        if old <= manifest_len {
            inner.dead.insert(old);
        }
        inner.retired.insert(old, index);
    }

    /// The manifest entry of retired folder `ino`, when it is one.
    pub(super) fn retired_index(&self, ino: u64) -> Option<u32> {
        let inner = self.lock();
        if inner.retired.is_empty() {
            return None;
        }
        inner.retired.get(&ino).copied()
    }

    /// A lookup below a retired folder: the manifest's tree only.
    pub(super) fn lookup_retired(
        &self,
        parent: u64,
        name: &str,
    ) -> Option<Result<super::Attr, i32>> {
        let index = self.retired_index(parent)?;
        let child = join(&self.manifest.path_of(index), name);
        Some(match self.lower(&child) {
            Some(found) => {
                let node = Node::Lower(found);
                Ok(self.attr(&child, &node))
            }
            None => Err(ENOENT),
        })
    }

    pub(super) fn readdir_retired(&self, index: u32) -> Vec<(u64, Type, String)> {
        let path = self.manifest.path_of(index);
        let children: Vec<Entry> =
            self.manifest.children(index).map(|(_, entry)| entry.clone()).collect();
        let mut inner = self.lock();
        children
            .iter()
            .filter(|entry| !Self::hidden(&inner, &join(&path, &entry.name)))
            .cloned()
            .collect::<Vec<_>>()
            .into_iter()
            .map(|entry| {
                let ino = self.name_ino(&mut inner, &join(&path, &entry.name));
                (ino, Type::of_kind(entry.kind), entry.name)
            })
            .collect()
    }
}
