//! A retention pass's archive folder (`store/compact.rs`, `--archive DIR`): the chat's old
//! segments and `session.json`, kept under `DIR/<chat id>/<pass>/` before the log is rewritten.
//!
//! An archive is a copy kept for a person, not state the daemon reads back, so the folders the
//! person named may be any they chose (huge-blue's `~/archive` is group-writable). What the pass
//! makes is held open instead: every folder from the first one that was there before the pass
//! down to its `events` is opened without following a link, each one it goes into is made
//! relative to its parent's handle and must be this user's and owner-only, and the copies go in
//! by those handles, never over anything there. An account that may write a folder above can
//! rename what the pass made, but not move where its copies go.

#[cfg(unix)]
pub(super) use unix::Archive;

#[cfg(not(unix))]
pub(super) use other::Archive;

#[cfg(unix)]
mod unix {
    use anyhow::{Context, Result, anyhow, bail, ensure};
    use std::ffi::{CString, OsStr};
    use std::fs::File;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    use std::path::{Component, Path};

    /// A pass's archive folder, held open (module docs).
    pub(in crate::store) struct Archive {
        /// From the first folder that was there before the pass down to the pass's own.
        dirs: Vec<File>,
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
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        let fd = unsafe { libc::openat(parent.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error())
                .with_context(|| format!("open archive folder {}", path.display()));
        }
        // SAFETY: `openat` just returned this descriptor, owned by nothing else.
        let dir = File::from(unsafe { OwnedFd::from_raw_fd(fd) });
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

    impl Archive {
        /// Makes `pass` and its `events`, and every missing folder above it, owner-only. A pass
        /// folder that is there already is another pass's: refused.
        pub(in crate::store) fn create(pass: &Path) -> Result<Self> {
            let existed = pass
                .ancestors()
                .skip(1)
                .find(|dir| !dir.as_os_str().is_empty() && dir.is_dir())
                .context("the archive has no folder above it")?;
            let root = std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_DIRECTORY | libc::O_CLOEXEC)
                .open(existed)
                .with_context(|| format!("open archive folder {}", existed.display()))?;
            let parts = pass
                .strip_prefix(existed)?
                .components()
                .map(|part| match part {
                    Component::Normal(part) => Ok(part),
                    _ => bail!("archive path {} is not plain", pass.display()),
                })
                .collect::<Result<Vec<_>>>()?;
            let mut dirs = vec![root];
            let mut path = existed.to_path_buf();
            for (i, part) in parts.iter().enumerate() {
                path.push(part);
                let part = name(part)?;
                let parent = dirs.last().expect("the root");
                match mkdir_at(parent, &part) {
                    Ok(()) => {}
                    // A chat's folder an earlier pass made; never the pass's own.
                    Err(e)
                        if e.kind() == std::io::ErrorKind::AlreadyExists && i + 1 < parts.len() => {
                    }
                    Err(e) => {
                        return Err(e)
                            .with_context(|| format!("make archive folder {}", path.display()));
                    }
                }
                let dir = own_dir_at(parent, &part, &path)?;
                dirs.push(dir);
            }
            let events = name(OsStr::new("events"))?;
            let pass_dir = dirs.last().expect("the pass's folder");
            mkdir_at(pass_dir, &events).with_context(|| {
                format!("make archive folder {}", pass.join("events").display())
            })?;
            let events = own_dir_at(pass_dir, &events, &pass.join("events"))?;
            Ok(Self { dirs, events })
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
            let dir =
                if in_events { &self.events } else { self.dirs.last().expect("the pass's folder") };
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
        pub(in crate::store) fn create(pass: &Path) -> Result<Self> {
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
