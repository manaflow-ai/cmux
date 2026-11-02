//! A retention pass's archive folder (`store/compact.rs`, `--archive DIR`): the chat's old
//! segments and `session.json`, kept under `DIR/<chat id>/<pass>/` before the log is rewritten.
//!
//! An archive is a copy kept for a person, not state the daemon reads back, so the folders the
//! person named may be any they chose (huge-blue's `~/archive` is group-writable). The path is
//! walked from `/` by handle, following only links no other account could have put there
//! (`resolve`); the chat's and the pass's folders are made relative to their parent's handle and
//! must be this user's and owner-only; and the copies go in by those handles, never over anything
//! there. An account that may write a folder above can rename what the pass made, but not move
//! where its copies go.

#[cfg(unix)]
pub(super) use unix::Archive;

#[cfg(not(unix))]
pub(super) use other::Archive;

#[cfg(unix)]
mod unix {
    use anyhow::{Context, Result, anyhow, ensure};
    use std::ffi::{CString, OsStr};
    use std::fs::File;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::{Component, Path, PathBuf};

    /// A pass's archive folder, held open (module docs).
    pub(in crate::store) struct Archive {
        /// The folders to sync above the pass's: every one the pass made above the named one
        /// with the folder that names it, then the named one and the chat's.
        dirs: Vec<File>,
        pass: File,
        events: File,
    }

    fn name(part: &OsStr) -> Result<CString> {
        CString::new(part.as_bytes()).map_err(|_| anyhow!("a NUL in an archive path"))
    }

    fn mkdir_at(parent: &File, name: &CString) -> std::io::Result<()> {
        // SAFETY: a valid descriptor and a NUL-terminated name.
        if unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) } == 0 {
            Ok(())
        } else {
            Err(std::io::Error::last_os_error())
        }
    }

    /// `name` in `parent`, a folder of this user's that no one else may write, never a link.
    fn own_dir_at(parent: &File, name: &CString, path: &Path) -> Result<File> {
        let dir = open_at(parent, name)
            .with_context(|| format!("open archive folder {}", path.display()))?;
        let meta = dir.metadata()?;
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        ensure!(
            meta.uid() == uid && meta.mode() & 0o022 == 0,
            "{} is not an owner-only folder of this user (mode {:o})",
            path.display(),
            meta.mode() & 0o777
        );
        Ok(dir)
    }

    fn open_at(parent: &File, name: &CString) -> std::io::Result<File> {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
        }
        // SAFETY: `openat` just returned this descriptor, owned by nothing else.
        Ok(File::from(unsafe { OwnedFd::from_raw_fd(fd) }))
    }

    /// `name` in `parent` as `lstat` sees it: None when there is nothing.
    fn lstat_at(parent: &File, name: &CString) -> std::io::Result<Option<libc::stat>> {
        // SAFETY: zeroed is a valid `stat`; a valid descriptor and a NUL-terminated name.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        let rc = unsafe {
            libc::fstatat(parent.as_raw_fd(), name.as_ptr(), &mut st, libc::AT_SYMLINK_NOFOLLOW)
        };
        if rc == 0 {
            return Ok(Some(st));
        }
        let e = std::io::Error::last_os_error();
        if e.kind() == std::io::ErrorKind::NotFound { Ok(None) } else { Err(e) }
    }

    fn read_link_at(parent: &File, name: &CString) -> std::io::Result<std::ffi::OsString> {
        use std::os::unix::ffi::OsStringExt;
        let mut buf = vec![0u8; libc::PATH_MAX as usize];
        // SAFETY: a valid descriptor, a NUL-terminated name and a buffer of that length.
        let n = unsafe {
            libc::readlinkat(parent.as_raw_fd(), name.as_ptr(), buf.as_mut_ptr().cast(), buf.len())
        };
        if n < 0 {
            return Err(std::io::Error::last_os_error());
        }
        buf.truncate(n as usize);
        Ok(std::ffi::OsString::from_vec(buf))
    }

    fn slash() -> Result<File> {
        Ok(std::fs::OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
            .open("/")?)
    }

    /// The folder at `path`, walked from `/` one name at a time by handle, every missing one
    /// made owner-only (and kept in `made`, with its parent, to be synced). A link is followed
    /// only when no other account could have put it there: it is this user's or root's, in a
    /// folder of this user's or root's that no other account may write, or that is sticky
    /// (`/tmp`; macOS's `/var`). Any other link is refused, so a folder above the archive that
    /// another account may write cannot send it elsewhere.
    fn resolve(path: &Path, made: &mut Vec<File>) -> Result<File> {
        ensure!(path.is_absolute(), "archive path {} is not absolute", path.display());
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        let trusted = |owner: u32| owner == uid || owner == 0;
        let mut todo: std::collections::VecDeque<std::ffi::OsString> =
            path.components().map(|c| c.as_os_str().to_owned()).collect();
        let mut cur = slash()?;
        let mut links = 0;
        while let Some(part) = todo.pop_front() {
            if part == "/" {
                cur = slash()?;
                continue;
            }
            if part == "." {
                continue;
            }
            let c = name(&part)?;
            let st = match lstat_at(&cur, &c)? {
                Some(st) => st,
                None => {
                    match mkdir_at(&cur, &c) {
                        Ok(()) => made.push(cur.try_clone()?),
                        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                        Err(e) => {
                            return Err(e).with_context(|| {
                                format!("make archive folder {:?} in {}", part, path.display())
                            });
                        }
                    }
                    todo.push_front(part);
                    continue;
                }
            };
            if st.st_mode & libc::S_IFMT == libc::S_IFLNK {
                let here = cur.metadata()?;
                let shared = here.mode() & 0o022 != 0 && here.mode() & 0o1000 == 0;
                ensure!(
                    trusted(st.st_uid) && trusted(here.uid()) && !shared,
                    "{} goes through a link {:?} another account could have put there",
                    path.display(),
                    part
                );
                links += 1;
                ensure!(links <= 40, "{} has too many links", path.display());
                let target = read_link_at(&cur, &c)?;
                for (i, t) in Path::new(&target).components().enumerate() {
                    todo.insert(i, t.as_os_str().to_owned());
                }
                continue;
            }
            let next = open_at(&cur, &c)
                .with_context(|| format!("open archive folder {:?} in {}", part, path.display()))?;
            if made.last().is_some_and(|parent| same(parent, &cur)) && part != ".." {
                made.push(next.try_clone()?);
            }
            cur = next;
        }
        Ok(cur)
    }

    fn same(a: &File, b: &File) -> bool {
        match (a.metadata(), b.metadata()) {
            (Ok(a), Ok(b)) => a.dev() == b.dev() && a.ino() == b.ino(),
            _ => false,
        }
    }

    impl Archive {
        /// Makes `<root>/<id>/<pass>/events`, owner-only. `root` is the folder the person named
        /// and any missing folders above it are made owner-only (`resolve`); the chat's folder
        /// is made the first time, and the pass's folder is new: one there already is another
        /// pass's, refused.
        pub(in crate::store) fn create(root: &Path, id: &str, pass: &str) -> Result<Self> {
            let mut dirs = Vec::new();
            let mut parent = resolve(root, &mut dirs)?;
            let mut path = PathBuf::new();
            for (part, made_before) in [(id, true), (pass, false)] {
                ensure!(
                    matches!(
                        Path::new(part).components().collect::<Vec<_>>()[..],
                        [Component::Normal(_)]
                    ),
                    "archive folder name {part:?} is not plain"
                );
                path.push(part);
                let part = name(OsStr::new(part))?;
                match mkdir_at(&parent, &part) {
                    Ok(()) => {}
                    // The chat's folder an earlier pass made; never the pass's own.
                    Err(e) if made_before && e.kind() == std::io::ErrorKind::AlreadyExists => {}
                    Err(e) => {
                        return Err(e)
                            .with_context(|| format!("make archive folder {}", path.display()));
                    }
                }
                let dir = own_dir_at(&parent, &part, &path)?;
                dirs.push(std::mem::replace(&mut parent, dir));
            }
            let events = name(OsStr::new("events"))?;
            mkdir_at(&parent, &events).with_context(|| {
                format!("make archive folder {}", path.join("events").display())
            })?;
            let events = own_dir_at(&parent, &events, &path.join("events"))?;
            Ok(Self { dirs, pass: parent, events })
        }

        /// Keeps `from` (a file of the chat's own folder) in the pass's folder, or its `events`:
        /// a hard link where it can, a copy otherwise (`copy`, or the link failed), never over
        /// anything there.
        pub(in crate::store) fn keep(
            &self,
            from: &Path,
            in_events: bool,
            copy: bool,
        ) -> Result<()> {
            let dir = if in_events { &self.events } else { &self.pass };
            let to = name(from.file_name().context("an archived file has no name")?)?;
            if !copy {
                let source = name(from.as_os_str())?;
                // SAFETY: valid descriptors and NUL-terminated names; flags 0 links `from` itself.
                let linked = unsafe {
                    libc::linkat(libc::AT_FDCWD, source.as_ptr(), dir.as_raw_fd(), to.as_ptr(), 0)
                };
                if linked == 0 {
                    return Ok(());
                }
            }
            let flags =
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
            // SAFETY: a valid descriptor and a NUL-terminated name.
            let fd =
                unsafe { libc::openat(dir.as_raw_fd(), to.as_ptr(), flags, 0o600 as libc::c_uint) };
            if fd < 0 {
                return Err(std::io::Error::last_os_error())
                    .with_context(|| format!("archive {}", from.display()));
            }
            // SAFETY: `openat` just returned this descriptor, owned by nothing else.
            let mut out = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
            let mut source = crate::config::private_state_file(from)?;
            std::io::copy(&mut source, &mut out)?;
            out.sync_all()?;
            Ok(())
        }

        /// Syncs `events` and every folder above it the pass holds: the copies and every name
        /// for them are on disk before a segment is replaced.
        pub(in crate::store) fn sync(&self) -> Result<()> {
            self.events.sync_all()?;
            self.pass.sync_all()?;
            for dir in self.dirs.iter().rev() {
                dir.sync_all()?;
            }
            Ok(())
        }
    }
}

#[cfg(not(unix))]
mod other {
    use anyhow::Result;
    use std::path::{Path, PathBuf};

    /// A pass's archive folder, by path: Windows keeps its own owner-only rules
    /// (`crate::owner_only`).
    pub(in crate::store) struct Archive {
        pass: PathBuf,
    }

    impl Archive {
        pub(in crate::store) fn create(root: &Path, id: &str, pass: &str) -> Result<Self> {
            let pass = &root.join(id).join(pass);
            anyhow::ensure!(!pass.exists(), "archive folder {} already exists", pass.display());
            std::fs::create_dir_all(pass.parent().unwrap_or(pass))?;
            crate::config::private_state_dir(pass)?;
            crate::config::private_state_dir(&pass.join("events"))?;
            Ok(Self { pass: pass.to_path_buf() })
        }

        pub(in crate::store) fn keep(
            &self,
            from: &Path,
            in_events: bool,
            copy: bool,
        ) -> Result<()> {
            let dir = if in_events { self.pass.join("events") } else { self.pass.clone() };
            let to = dir.join(from.file_name().unwrap_or_default());
            if copy || std::fs::hard_link(from, &to).is_err() {
                std::fs::copy(from, &to)?;
                std::fs::File::open(&to)?.sync_all()?;
            }
            Ok(())
        }

        pub(in crate::store) fn sync(&self) -> Result<()> {
            Ok(())
        }
    }
}
