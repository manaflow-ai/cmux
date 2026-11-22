//! Atomic writes and tree removal.
//!
//! A write creates `.<name>.cmux-<random>.tmp` with `O_EXCL | O_NOFOLLOW`
//! in the target's own directory descriptor, writes and fsyncs it, checks
//! the mode against the target once more, renames it over the target, and
//! fsyncs the directory. Until the rename the target is untouched; on any
//! error, and when a [`PendingWrite`] is dropped before
//! [`PendingWrite::commit`] (a cancelled stream), the temporary file is
//! unlinked, so no partial file ever appears at the target.

use std::fs::File;
use std::io::Write as _;
use std::os::fd::{AsFd, BorrowedFd, OwnedFd};

use super::entry::{Entry, EntryKind, Meta, temporary_name};
use super::error::FsError;
use super::resolve::Roots;
use super::sys;

/// How a write treats an existing file.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WriteMode {
    /// `fs.exists` when the target exists.
    Create,
    /// Replace whatever file is there.
    Overwrite,
    /// Replace only when the file still has this revision.
    Replace { expected: String },
}

impl WriteMode {
    /// `mode` and `expected` as the wire sends them.
    pub fn parse(mode: &str, expected: Option<String>) -> Result<Self, FsError> {
        match (mode, expected) {
            ("create", None) => Ok(Self::Create),
            ("overwrite", None) => Ok(Self::Overwrite),
            ("replace", Some(expected)) => Ok(Self::Replace { expected }),
            ("replace", None) => Err(FsError::ParamsInvalid("replace needs expected".into())),
            ("create" | "overwrite", Some(_)) => {
                Err(FsError::ParamsInvalid("expected is only valid with replace".into()))
            }
            _ => Err(FsError::ParamsInvalid("mode is create, overwrite or replace".into())),
        }
    }

    /// Whether the target's current state allows this write.
    fn admits(&self, current: Option<&Meta>) -> Result<(), FsError> {
        if let Some(meta) = current
            && meta.kind != EntryKind::File
        {
            return Err(FsError::Exists);
        }
        match (self, current) {
            (Self::Create, Some(_)) => Err(FsError::Exists),
            (Self::Replace { expected }, current) => {
                let found = current.map(Meta::revision);
                if found.as_deref() == Some(expected.as_str()) {
                    Ok(())
                } else {
                    Err(FsError::RevisionMismatch { current: found })
                }
            }
            _ => Ok(()),
        }
    }
}

fn current(dir: BorrowedFd<'_>, name: &str) -> Result<Option<Meta>, FsError> {
    match sys::lstat_at(dir, name) {
        Ok(stat) => Ok(Some(Meta::of(&stat))),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error.into()),
    }
}

/// A write whose bytes go to a temporary file until [`Self::commit`].
pub struct PendingWrite {
    dir: OwnedFd,
    name: String,
    temporary: String,
    file: File,
    mode: WriteMode,
    committed: bool,
}

impl PendingWrite {
    /// Resolves `path` (a symlink as the last component is followed inside
    /// the roots), checks `mode` and, when `size` is known, the free space,
    /// and creates the temporary file.
    pub fn begin(
        roots: &Roots,
        path: &str,
        mode: WriteMode,
        size: Option<u64>,
    ) -> Result<Self, FsError> {
        let resolved = roots.resolve(path, true)?;
        let Some(name) = resolved.name.clone() else {
            return Err(if resolved.is_root {
                FsError::PermissionDenied
            } else {
                FsError::NotAFile
            });
        };
        let existing = current(resolved.dir(), &name)?;
        mode.admits(existing.as_ref())?;
        if let Some(size) = size
            && sys::available_bytes(resolved.dir())? < size
        {
            return Err(FsError::NoSpace);
        }
        let permissions = existing.map_or(0o644, |meta| meta.mode & 0o777);
        let temporary = temporary_name(&name);
        let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL;
        let fd = sys::open_at(resolved.dir(), &temporary, flags, permissions)?;
        let pending = Self {
            dir: resolved.dir,
            name,
            temporary,
            file: File::from(fd),
            mode,
            committed: false,
        };
        if existing.is_some() {
            // Keep the replaced file's exact bits (the umask cut them).
            sys::fchmod(pending.file.as_fd(), permissions)?;
        }
        Ok(pending)
    }

    /// Appends `bytes` to the temporary file.
    pub fn write(&mut self, bytes: &[u8]) -> Result<(), FsError> {
        Ok(self.file.write_all(bytes)?)
    }

    /// Fsyncs, checks the mode once more, renames over the target and
    /// fsyncs the directory. Returns the new entry.
    pub fn commit(mut self) -> Result<Entry, FsError> {
        self.file.sync_all()?;
        let dir = self.dir.as_fd();
        self.mode.admits(current(dir, &self.name)?.as_ref())?;
        match self.mode {
            WriteMode::Create => sys::rename_no_replace(dir, &self.temporary, &self.name)?,
            // Replace: a write that lands between the check above and this
            // rename is overwritten (the same window as the SFTP owner).
            WriteMode::Overwrite | WriteMode::Replace { .. } => {
                sys::rename_at(dir, &self.temporary, &self.name)?;
            }
        }
        self.committed = true;
        sys::fsync(dir)?;
        Entry::at(dir, &self.name)
    }
}

impl Drop for PendingWrite {
    fn drop(&mut self) {
        if !self.committed {
            let _ = sys::unlink_at(self.dir.as_fd(), &self.temporary, false);
        }
    }
}

/// Deepest folder nesting [`remove_tree`] descends.
const MAX_DEPTH: usize = 256;

/// Removes `name` in `dir` and everything below it. Symlinks are removed,
/// never followed; every folder is entered with `O_NOFOLLOW`; a folder on
/// another file system (a mount point) is refused, never descended.
pub fn remove_tree(dir: BorrowedFd<'_>, name: &str) -> Result<(), FsError> {
    let device = sys::lstat_at(dir, name)?.st_dev;
    remove_below(dir, name, 0, device)
}

fn remove_below(
    dir: BorrowedFd<'_>,
    name: &str,
    depth: usize,
    device: libc::dev_t,
) -> Result<(), FsError> {
    let stat = sys::lstat_at(dir, name)?;
    let meta = Meta::of(&stat);
    if meta.kind != EntryKind::Dir {
        return Ok(sys::unlink_at(dir, name, false)?);
    }
    if stat.st_dev != device {
        return Err(FsError::PermissionDenied);
    }
    if depth >= MAX_DEPTH {
        return Err(FsError::NotEmpty);
    }
    let child = sys::open_dir_at(dir, name)?;
    let names = sys::read_dir_names(child.as_fd()).map_err(|error| match error {
        sys::ReadDirError::Io(error) => FsError::from(error),
        sys::ReadDirError::TooMany => FsError::TooLarge { total: None },
    })?;
    for entry in names {
        let entry = String::from_utf8(entry).map_err(|_| FsError::NotEmpty)?;
        match remove_below(child.as_fd(), &entry, depth + 1, device) {
            Err(FsError::NotFound) | Ok(()) => {}
            Err(error) => return Err(error),
        }
    }
    Ok(sys::unlink_at(dir, name, true)?)
}
