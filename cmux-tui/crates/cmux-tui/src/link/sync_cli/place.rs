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
use std::rc::Rc;

use anyhow::{Context as _, bail};

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

/// One change already made, and how to undo it.
enum Undo {
    /// A folder this pull made.
    MadeDir { parent: Rc<Dir>, name: String },
    /// A file this pull placed at `name`, and where what it replaced went.
    Placed { dir: Rc<Dir>, name: String, aside: Option<Aside> },
    /// A file this pull deleted, moved aside.
    Removed { dir: Rc<Dir>, name: String, aside: Aside },
}

/// Where a file moved aside sits: the staging folder, or (on another file
/// system) a hidden name next to it.
struct Aside {
    in_staging: bool,
    name: String,
}

/// The changes of one pull to the folder under `root`.
pub(super) struct Transaction {
    root: Rc<Dir>,
    staging: Rc<Dir>,
    undo: Vec<Undo>,
    deleted: Vec<String>,
    asides: u64,
}

impl Transaction {
    pub(super) fn new(root: &Path, staging: &Path) -> anyhow::Result<Self> {
        Ok(Self {
            root: Rc::new(Dir::open(root)?),
            staging: Rc::new(Dir::open(staging)?),
            undo: Vec::new(),
            deleted: Vec::new(),
            asides: 0,
        })
    }

    /// Moves the staged file `staged` (a name in the staging folder, its
    /// permissions already set) to `relative`, making missing folders. A
    /// file there is moved aside; anything else there stops the pull.
    pub(super) fn write(&mut self, relative: &str, staged: &str) -> anyhow::Result<()> {
        let (dir, name) = self.folder_for(relative)?;
        let aside = match dir.entry(&name)? {
            Entry::Missing => None,
            Entry::File { .. } => Some(self.move_aside(&dir, &name)?),
            Entry::Dir | Entry::Other => bail!("{relative} here is not a regular file"),
        };
        let placed = match self.staging.rename(staged, &dir, &name) {
            Ok(()) => Ok(()),
            // Another file system (a mount inside the folder): copy next to it.
            Err(error) if error.raw_os_error() == Some(libc::EXDEV) => {
                self.copy_across(staged, &dir, &name)
            }
            Err(error) => Err(anyhow::Error::from(error)),
        };
        if let Err(error) = placed {
            if let Some(aside) = aside {
                let _ = self.put_back(&dir, &name, &aside);
            }
            return Err(error.context(format!("cannot write {relative}")));
        }
        self.undo.push(Undo::Placed { dir, name, aside });
        Ok(())
    }

    /// Deletes the file at `relative` (moved aside until the pull ends);
    /// nothing when it is already gone.
    pub(super) fn delete(&mut self, relative: &str) -> anyhow::Result<()> {
        let Some((dir, name)) = parent_of(&self.root, relative)? else { return Ok(()) };
        if !matches!(dir.entry(&name)?, Entry::File { .. }) {
            return Ok(());
        }
        let dir = Rc::new(dir);
        let aside =
            self.move_aside(&dir, &name).with_context(|| format!("cannot delete {relative}"))?;
        self.undo.push(Undo::Removed { dir, name, aside });
        self.deleted.push(relative.to_string());
        Ok(())
    }

    /// Puts back everything this pull changed, newest first.
    pub(super) fn roll_back(mut self) {
        while let Some(undo) = self.undo.pop() {
            match undo {
                Undo::Placed { dir, name, aside } => {
                    let _ = dir.unlink(&name, false);
                    if let Some(aside) = aside {
                        let _ = self.put_back(&dir, &name, &aside);
                    }
                }
                Undo::Removed { dir, name, aside } => {
                    let _ = self.put_back(&dir, &name, &aside);
                }
                Undo::MadeDir { parent, name } => {
                    let _ = parent.unlink(&name, true);
                }
            }
        }
    }

    /// Keeps the changes: files moved aside next to their folder go, and
    /// folders the deletes left empty go too (never the top folder).
    pub(super) fn finish(mut self) {
        for undo in self.undo.drain(..) {
            if let Undo::Placed { dir, aside: Some(aside), .. } | Undo::Removed { dir, aside, .. } =
                undo
                && !aside.in_staging
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

    /// The folder for `relative`, opened, with folders made on the way.
    fn folder_for(&mut self, relative: &str) -> anyhow::Result<(Rc<Dir>, String)> {
        let mut parts: Vec<&str> = relative.split('/').collect();
        let name = parts.pop().unwrap_or_default().to_string();
        let mut at = Rc::clone(&self.root);
        for part in parts {
            let next = match at.child(part) {
                Ok(Some(next)) => next,
                Ok(None) => {
                    at.mkdir(part)
                        .with_context(|| format!("cannot make a folder for {relative}"))?;
                    self.undo.push(Undo::MadeDir { parent: Rc::clone(&at), name: part.into() });
                    at.child(part)?.with_context(|| format!("{part} went away"))?
                }
                Err(error) => {
                    return Err(error).with_context(|| format!("{relative} is not under a folder"));
                }
            };
            at = Rc::new(next);
        }
        Ok((at, name))
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

    fn put_back(&self, dir: &Dir, name: &str, aside: &Aside) -> io::Result<()> {
        if aside.in_staging {
            self.staging.rename(&aside.name, dir, name)
        } else {
            dir.rename(&aside.name, dir, name)
        }
    }

    fn copy_across(&self, staged: &str, dir: &Dir, name: &str) -> anyhow::Result<()> {
        let part = format!(".{name}.cmux-sync-part");
        let _ = dir.unlink(&part, false);
        let mut from = self.staging.open_file(staged)?;
        let mode = from.metadata()?.permissions();
        let mut out = dir.create_file(&part, 0o600)?;
        let copied = io::copy(&mut from, &mut out)
            .map_err(anyhow::Error::from)
            .and_then(|_| out.set_permissions(mode).map_err(anyhow::Error::from))
            .and_then(|()| out.sync_all().map_err(anyhow::Error::from))
            .and_then(|()| dir.rename(&part, dir, name).map_err(anyhow::Error::from));
        if copied.is_err() {
            let _ = dir.unlink(&part, false);
        }
        copied
    }
}
