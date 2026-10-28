//! Where `cmux link sync pull` changes this Mac's folder: through folder
//! handles opened one name at a time with `O_NOFOLLOW` (`openat`,
//! `renameat`, `unlinkat`, `mkdirat`), so a symlink swapped in after the
//! plan never redirects a write, and as one transaction: every replaced or
//! deleted file is first moved aside, and any failure puts back what the
//! pull changed before it.

use std::ffi::CString;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd};
use std::path::Path;

use anyhow::{Context as _, bail};
use sha2::{Digest as _, Sha256};

/// An open folder.
pub(super) struct Dir(OwnedFd);

/// What [`Dir::entry`] found at a name.
pub(super) enum Entry {
    Missing,
    File {
        mode: u32,
    },
    Dir,
    /// A symlink or special file.
    Other,
}

fn c_name(name: &str) -> io::Result<CString> {
    CString::new(name).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

/// A `mode_t` (u16 on macOS, u32 on Linux) as u32.
fn widen<T: TryInto<u32>>(value: T) -> u32 {
    value.try_into().unwrap_or_default()
}

/// A `dev_t` or `ino_t` (their widths and signs vary) as u64.
fn widen_u64<T: TryInto<u64>>(value: T) -> u64 {
    value.try_into().unwrap_or_default()
}

fn check(result: libc::c_int) -> io::Result<libc::c_int> {
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(result) }
}

impl Dir {
    /// Opens the folder at `path` (its last name not followed if a symlink).
    pub(super) fn open(path: &Path) -> anyhow::Result<Self> {
        let path = CString::new(path.as_os_str().as_encoded_bytes())?;
        // SAFETY: a valid C string; the result is checked.
        let fd = check(unsafe {
            libc::open(
                path.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        })?;
        // SAFETY: a new descriptor this handle owns.
        Ok(Self(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    /// The folder `name` in this one; None when it is missing. A symlink or
    /// anything else there is an error.
    pub(super) fn child(&self, name: &str) -> io::Result<Option<Self>> {
        let c = c_name(name)?;
        // SAFETY: a valid descriptor and C string; the result is checked.
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                c.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        match check(fd) {
            // SAFETY: a new descriptor this handle owns.
            Ok(fd) => Ok(Some(Self(unsafe { OwnedFd::from_raw_fd(fd) }))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    /// What is at `name`, without following a symlink.
    pub(super) fn entry(&self, name: &str) -> io::Result<Entry> {
        let c = c_name(name)?;
        // SAFETY: zeroed stat is a valid out value.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: a valid descriptor, C string and out pointer.
        let result = unsafe {
            libc::fstatat(self.0.as_raw_fd(), c.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW)
        };
        match check(result) {
            Ok(_) => Ok(match stat.st_mode & libc::S_IFMT {
                libc::S_IFREG => {
                    // mode_t is u16 on macOS and u32 on Linux.
                    Entry::File { mode: widen(stat.st_mode & 0o7777) }
                }
                libc::S_IFDIR => Entry::Dir,
                _ => Entry::Other,
            }),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Entry::Missing),
            Err(error) => Err(error),
        }
    }

    /// Opens the regular file `name` for reading, never through a symlink
    /// or blocking on a FIFO.
    pub(super) fn open_file(&self, name: &str) -> io::Result<File> {
        let c = c_name(name)?;
        // SAFETY: a valid descriptor and C string; the result is checked.
        let fd = check(unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                c.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        })?;
        // SAFETY: a new descriptor the file owns.
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    /// Makes the file `name` (it must not exist) with `mode`, for writing.
    fn create_file(&self, name: &str, mode: u32) -> io::Result<File> {
        let c = c_name(name)?;
        // SAFETY: a valid descriptor and C string; the result is checked.
        let fd = check(unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                c.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                mode,
            )
        })?;
        // SAFETY: a new descriptor the file owns.
        Ok(unsafe { File::from_raw_fd(fd) })
    }

    /// The (device, inode) of the entry `name`, not following a symlink;
    /// None when it is missing.
    fn inode(&self, name: &str) -> io::Result<Option<(u64, u64)>> {
        let c = c_name(name)?;
        // SAFETY: zeroed stat is a valid out value.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: a valid descriptor, C string and out pointer.
        let result = unsafe {
            libc::fstatat(self.0.as_raw_fd(), c.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW)
        };
        match check(result) {
            // dev_t and ino_t differ in width and sign across platforms.
            Ok(_) => Ok(Some((widen_u64(stat.st_dev), widen_u64(stat.st_ino)))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn mkdir(&self, name: &str) -> io::Result<()> {
        let c = c_name(name)?;
        // SAFETY: a valid descriptor and C string.
        check(unsafe { libc::mkdirat(self.0.as_raw_fd(), c.as_ptr(), 0o755) }).map(drop)
    }

    /// Renames `name` here to `to_name` in `to`.
    fn rename(&self, name: &str, to: &Dir, to_name: &str) -> io::Result<()> {
        let (from, dest) = (c_name(name)?, c_name(to_name)?);
        // SAFETY: valid descriptors and C strings.
        check(unsafe {
            libc::renameat(self.0.as_raw_fd(), from.as_ptr(), to.0.as_raw_fd(), dest.as_ptr())
        })
        .map(drop)
    }

    fn unlink(&self, name: &str, folder: bool) -> io::Result<()> {
        let c = c_name(name)?;
        let flags = if folder { libc::AT_REMOVEDIR } else { 0 };
        // SAFETY: a valid descriptor and C string.
        check(unsafe { libc::unlinkat(self.0.as_raw_fd(), c.as_ptr(), flags) }).map(drop)
    }
}

/// Opens the folder holding `relative` under `root`: None when a folder on
/// the way is missing; an error when one is not a folder (a symlink).
pub(super) fn parent_of(root: &Dir, relative: &str) -> io::Result<Option<(Dir, String)>> {
    let mut parts: Vec<&str> = relative.split('/').collect();
    let name = parts.pop().unwrap_or_default().to_string();
    let mut at: Option<Dir> = None;
    for part in parts {
        let next = at.as_ref().unwrap_or(root).child(part)?;
        let Some(next) = next else { return Ok(None) };
        at = Some(next);
    }
    let dir = match at {
        Some(dir) => dir,
        None => root.dup()?,
    };
    Ok(Some((dir, name)))
}

impl Dir {
    fn dup(&self) -> io::Result<Self> {
        Ok(Self(self.0.try_clone()?))
    }
}

/// What a file here must still be for the pull to replace or delete it:
/// its SHA-256 and synced permissions, as the plan saw them.
pub(super) struct Expected {
    pub sha256: String,
    pub permissions: u32,
}

/// A file here changed after the plan saw it: nothing of it was replaced
/// or deleted.
#[derive(Debug)]
pub(super) struct Changed(pub String);

impl std::fmt::Display for Changed {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{} changed here during the pull", self.0)
    }
}

impl std::error::Error for Changed {}

/// One change already made, and how to undo it. Folders are kept by path
/// and opened again (one name at a time, never through a symlink) when
/// needed: a pull holds no handle per file or folder it changes.
enum Undo {
    /// A folder this pull made.
    MadeDir { folder: String },
    /// A file this pull placed at `relative`, and where what it replaced went.
    /// `placed` is its file's (device, inode): roll back removes only that.
    Placed { relative: String, aside: Option<Aside>, placed: Option<(u64, u64)> },
    /// A file this pull deleted, moved aside.
    Removed { relative: String, aside: Aside },
}

/// Where a file moved aside sits: the staging folder, or (on another file
/// system) a hidden name next to it.
struct Aside {
    in_staging: bool,
    name: String,
}

/// The changes of one pull to the folder under `root`.
pub(super) struct Transaction {
    root: Dir,
    staging: Dir,
    undo: Vec<Undo>,
    deleted: Vec<String>,
    asides: u64,
}

impl Transaction {
    pub(super) fn new(root: &Path, staging: &Path) -> anyhow::Result<Self> {
        Ok(Self {
            root: Dir::open(root)?,
            staging: Dir::open(staging)?,
            undo: Vec::new(),
            deleted: Vec::new(),
            asides: 0,
        })
    }

    /// Moves the staged file `staged` (a name in the staging folder, its
    /// permissions already set) to `relative`, making missing folders. The
    /// file there must still be `expected` (None: no file); it is moved
    /// aside and checked, and a file that changed after the plan stays
    /// ([`Changed`]). The staged file never replaces one made meanwhile.
    pub(super) fn write(
        &mut self,
        relative: &str,
        staged: &str,
        expected: Option<&Expected>,
    ) -> anyhow::Result<()> {
        let (dir, name) = self.folder_for(relative)?;
        let aside = match dir.entry(&name)? {
            Entry::Missing if expected.is_some() => return Err(Changed(relative.into()).into()),
            Entry::Missing => None,
            Entry::File { .. } => Some(self.take(&dir, &name, relative, expected)?),
            Entry::Dir | Entry::Other => bail!("{relative} here is not a regular file"),
        };
        if let Err(error) = self.place(staged, &dir, &name, relative) {
            if let Some(aside) = aside
                && self.put_back(&dir, &name, &aside).is_err()
            {
                self.undo.push(Undo::Removed { relative: relative.into(), aside });
            }
            return Err(error);
        }
        let placed = dir.inode(&name).ok().flatten();
        self.undo.push(Undo::Placed { relative: relative.into(), aside, placed });
        Ok(())
    }

    /// Deletes the file at `relative` (moved aside until the pull ends),
    /// once it is checked to be still `expected`; nothing when it is
    /// already gone.
    pub(super) fn delete(&mut self, relative: &str, expected: &Expected) -> anyhow::Result<()> {
        let Some((dir, name)) = parent_of(&self.root, relative)? else { return Ok(()) };
        if !matches!(dir.entry(&name)?, Entry::File { .. }) {
            return Ok(());
        }
        let aside = self.take(&dir, &name, relative, Some(expected))?;
        self.undo.push(Undo::Removed { relative: relative.into(), aside });
        self.deleted.push(relative.to_string());
        Ok(())
    }

    /// Puts back everything this pull changed, newest first. The error
    /// names what could not be put back (it stays in the staging folder or
    /// next to its file).
    pub(super) fn roll_back(mut self) -> Result<(), Vec<String>> {
        let mut left = Vec::new();
        while let Some(undo) = self.undo.pop() {
            let undone = match &undo {
                Undo::Placed { relative, aside, placed } => {
                    self.at(relative).and_then(|(dir, name)| {
                        // A file saved over it since stays, and so does the aside.
                        if placed.is_none() || dir.inode(&name)? != *placed {
                            return Err(io::Error::from(io::ErrorKind::AlreadyExists));
                        }
                        dir.unlink(&name, false)?;
                        aside.as_ref().map_or(Ok(()), |aside| self.put_back(&dir, &name, aside))
                    })
                }
                Undo::Removed { relative, aside } => {
                    self.at(relative).and_then(|(dir, name)| self.put_back(&dir, &name, aside))
                }
                Undo::MadeDir { folder } => {
                    self.at(folder).and_then(|(parent, name)| parent.unlink(&name, true))
                }
            };
            if undone.is_err() {
                left.push(match undo {
                    Undo::Placed { relative, .. }
                    | Undo::Removed { relative, .. }
                    | Undo::MadeDir { folder: relative } => relative,
                });
            }
        }
        if left.is_empty() { Ok(()) } else { Err(left) }
    }

    /// Keeps the changes: files moved aside next to their folder go, and
    /// folders the deletes left empty go too (never the top folder).
    pub(super) fn finish(mut self) {
        for undo in std::mem::take(&mut self.undo) {
            if let Undo::Placed { relative, aside: Some(aside), .. }
            | Undo::Removed { relative, aside } = undo
                && !aside.in_staging
                && let Ok((dir, _)) = self.at(&relative)
            {
                let _ = dir.unlink(&aside.name, false);
            }
        }
        for relative in &self.deleted {
            let parts: Vec<&str> = relative.split('/').collect();
            for end in (1..parts.len()).rev() {
                let folder = parts[..end].join("/");
                let Ok(Some((parent, name))) = parent_of(&self.root, &folder) else { break };
                if parent.unlink(&name, true).is_err() {
                    break;
                }
            }
        }
    }

    /// The folder holding `relative`, opened again, and its last name.
    fn at(&self, relative: &str) -> io::Result<(Dir, String)> {
        parent_of(&self.root, relative)?.ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))
    }

    /// The folder for `relative`, opened, with folders made on the way.
    fn folder_for(&mut self, relative: &str) -> anyhow::Result<(Dir, String)> {
        let mut parts: Vec<&str> = relative.split('/').collect();
        let name = parts.pop().unwrap_or_default().to_string();
        let mut at: Option<Dir> = None;
        for (index, part) in parts.iter().enumerate() {
            let parent = at.as_ref().unwrap_or(&self.root);
            let next = match parent.child(part) {
                Ok(Some(next)) => next,
                Ok(None) => {
                    parent
                        .mkdir(part)
                        .with_context(|| format!("cannot make a folder for {relative}"))?;
                    self.undo.push(Undo::MadeDir { folder: parts[..=index].join("/") });
                    let parent = at.as_ref().unwrap_or(&self.root);
                    parent.child(part)?.with_context(|| format!("{part} went away"))?
                }
                Err(error) => {
                    return Err(error).with_context(|| format!("{relative} is not under a folder"));
                }
            };
            at = Some(next);
        }
        let dir = match at {
            Some(dir) => dir,
            None => self.root.dup()?,
        };
        Ok((dir, name))
    }

    /// Moves the file `name` in `dir` aside and checks it is `expected`
    /// (None: there should be no file). One that is not goes back, and the
    /// answer is [`Changed`].
    fn take(
        &mut self,
        dir: &Dir,
        name: &str,
        relative: &str,
        expected: Option<&Expected>,
    ) -> anyhow::Result<Aside> {
        let aside =
            self.move_aside(dir, name).with_context(|| format!("cannot move {relative}"))?;
        let same = match expected {
            Some(expected) => self.aside_is(dir, &aside, expected),
            None => Ok(false),
        };
        if same.as_ref().is_ok_and(|same| *same) {
            return Ok(aside);
        }
        if self.put_back(dir, name, &aside).is_err() {
            // Something new took its place: what moved aside stays aside.
            self.undo.push(Undo::Removed { relative: relative.into(), aside });
        }
        same?;
        Err(Changed(relative.into()).into())
    }

    /// Whether the file moved aside is `expected`: its bytes and synced
    /// permissions.
    fn aside_is(&self, dir: &Dir, aside: &Aside, expected: &Expected) -> anyhow::Result<bool> {
        let from = if aside.in_staging { &self.staging } else { dir };
        let mut file = from.open_file(&aside.name)?;
        let mode = std::os::unix::fs::PermissionsExt::mode(&file.metadata()?.permissions());
        if super::local::permissions_of(mode) != expected.permissions {
            return Ok(false);
        }
        let mut hasher = Sha256::new();
        io::copy(&mut file, &mut hasher)?;
        let sha256: String = hasher.finalize().iter().map(|byte| format!("{byte:02x}")).collect();
        Ok(sha256 == expected.sha256)
    }

    fn move_aside(&mut self, dir: &Dir, name: &str) -> anyhow::Result<Aside> {
        self.asides += 1;
        let staged = format!("aside-{}", self.asides);
        match dir.rename(name, &self.staging, &staged) {
            Ok(()) => Ok(Aside { in_staging: true, name: staged }),
            Err(error) if error.raw_os_error() == Some(libc::EXDEV) => {
                let near =
                    format!(".{name}.cmux-sync-aside-{}-{}", std::process::id(), self.asides);
                dir.rename(name, dir, &near)?;
                Ok(Aside { in_staging: false, name: near })
            }
            Err(error) => Err(error.into()),
        }
    }

    /// Puts a file moved aside back at `name`, never over a file there.
    fn put_back(&self, dir: &Dir, name: &str, aside: &Aside) -> io::Result<()> {
        let from = if aside.in_staging { &self.staging } else { dir };
        link_new(from, &aside.name, dir, name)
    }

    /// Moves the staged file to `name` in `dir`, never over a file there.
    fn place(&self, staged: &str, dir: &Dir, name: &str, relative: &str) -> anyhow::Result<()> {
        let placed = match link_new(&self.staging, staged, dir, name) {
            // Another file system (a mount inside the folder): copy next to it.
            Err(error) if error.raw_os_error() == Some(libc::EXDEV) => {
                self.copy_across(staged, dir, name)
            }
            placed => placed,
        };
        match placed {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                Err(Changed(relative.into()).into())
            }
            Err(error) => {
                Err(anyhow::Error::from(error).context(format!("cannot write {relative}")))
            }
        }
    }

    fn copy_across(&self, staged: &str, dir: &Dir, name: &str) -> io::Result<()> {
        let part = format!(".{name}.cmux-sync-part");
        let _ = dir.unlink(&part, false);
        let mut from = self.staging.open_file(staged)?;
        let mode = from.metadata()?.permissions();
        let mut out = dir.create_file(&part, 0o600)?;
        let copied = io::copy(&mut from, &mut out)
            .and_then(|_| out.set_permissions(mode))
            .and_then(|()| crate::blocking::fs::sync_all(&out))
            .and_then(|()| link_new(dir, &part, dir, name));
        if copied.is_err() {
            let _ = dir.unlink(&part, false);
        }
        copied
    }
}

/// Moves `from_name` in `from` to `to_name` in `to` only if nothing is
/// there (a hard link, then the old name goes): `AlreadyExists` otherwise.
/// A file system without hard links falls back to a checked rename.
fn link_new(from: &Dir, from_name: &str, to: &Dir, to_name: &str) -> io::Result<()> {
    let (source, dest) = (c_name(from_name)?, c_name(to_name)?);
    // SAFETY: valid descriptors and C strings.
    let linked = check(unsafe {
        libc::linkat(from.0.as_raw_fd(), source.as_ptr(), to.0.as_raw_fd(), dest.as_ptr(), 0)
    });
    match linked {
        Ok(_) => {
            let _ = from.unlink(from_name, false);
            Ok(())
        }
        // ENOTSUP and EOPNOTSUPP are one value on Linux, two on macOS.
        Err(error)
            if error.raw_os_error().is_some_and(|code| {
                [libc::EPERM, libc::ENOTSUP, libc::EOPNOTSUPP, libc::EMLINK, libc::ENOSYS]
                    .contains(&code)
            }) =>
        {
            if !matches!(to.entry(to_name)?, Entry::Missing) {
                return Err(io::Error::from(io::ErrorKind::AlreadyExists));
            }
            from.rename(from_name, to, to_name)
        }
        Err(error) => Err(error),
    }
}

#[cfg(test)]
mod tests {
    use sha2::{Digest as _, Sha256};

    use super::*;

    fn sha256(bytes: &[u8]) -> String {
        Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
    }

    /// A file edited here after the plan read it (between the last check
    /// and its move) is never replaced or deleted: the edit stays.
    #[test]
    fn a_file_edited_after_the_plan_is_never_replaced_or_deleted() {
        let top = tempfile::tempdir().unwrap();
        let (root, staging) = (top.path().join("root"), top.path().join("staging"));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&staging).unwrap();
        std::fs::write(root.join("a.txt"), "edited\n").unwrap();
        std::fs::write(root.join("b.txt"), "edited\n").unwrap();
        std::fs::write(staging.join("file-1"), "machine\n").unwrap();
        let planned = Expected { sha256: sha256(b"planned\n"), permissions: 0o644 };

        let mut transaction = Transaction::new(&root, &staging).unwrap();
        let error = transaction.write("a.txt", "file-1", Some(&planned)).unwrap_err();
        assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
        let error = transaction.delete("b.txt", &planned).unwrap_err();
        assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
        // A file made after the plan saw none is not replaced either.
        std::fs::write(root.join("c.txt"), "made here\n").unwrap();
        let error = transaction.write("c.txt", "file-1", None).unwrap_err();
        assert!(error.downcast_ref::<Changed>().is_some(), "{error:#}");
        let _ = transaction.roll_back();

        assert_eq!(std::fs::read_to_string(root.join("a.txt")).unwrap(), "edited\n");
        assert_eq!(std::fs::read_to_string(root.join("b.txt")).unwrap(), "edited\n");
        assert_eq!(std::fs::read_to_string(root.join("c.txt")).unwrap(), "made here\n");
    }
}
