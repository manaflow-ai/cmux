//! File operations under the home this daemon holds, made through the folder it locked
//! (`config::hold_home`), not its path. A writer checks the home first
//! (`config::refuse_lost_home`); a home replaced after that check passed and before the write
//! (moved away, another folder made at the same path) would get a write made by path. Made here,
//! the write lands in the folder this daemon locked, wherever it is now, so the replacement never
//! gets it.
//!
//! Each operation takes the same path a `std::fs` call would. On Unix, a path under the held home
//! is opened as a name in its parent folder, and that folder is reached from the held home's
//! descriptor one name at a time (`openat`), following a folder symlink as a path would; the
//! operation is then the `*at` call on that name. Any other path (a CLI command holds no home, a
//! file outside the home) goes by path, as `std::fs` does.
//!
//! Off Unix there is no `*at` call: each operation goes by path, but first checks the home again
//! ([`held`]: `config::refuse_lost_home`, which on Windows compares the home's file id, its
//! volume serial and file index, with the held home's). A home replaced before that check is
//! refused; the window left is the one call itself.

use std::fs::File;
use std::io;
use std::path::Path;

/// `std::fs::OpenOptions`, with `mode` and `custom_flags` as on Unix (ignored elsewhere).
#[derive(Clone, Debug)]
pub(crate) struct OpenOptions {
    read: bool,
    write: bool,
    append: bool,
    truncate: bool,
    create: bool,
    create_new: bool,
    mode: u32,
    custom_flags: i32,
}

impl OpenOptions {
    pub(crate) fn new() -> Self {
        Self {
            read: false,
            write: false,
            append: false,
            truncate: false,
            create: false,
            create_new: false,
            mode: 0o666,
            custom_flags: 0,
        }
    }

    pub(crate) fn read(&mut self, read: bool) -> &mut Self {
        self.read = read;
        self
    }

    pub(crate) fn write(&mut self, write: bool) -> &mut Self {
        self.write = write;
        self
    }

    pub(crate) fn append(&mut self, append: bool) -> &mut Self {
        self.append = append;
        self
    }

    pub(crate) fn truncate(&mut self, truncate: bool) -> &mut Self {
        self.truncate = truncate;
        self
    }

    pub(crate) fn create(&mut self, create: bool) -> &mut Self {
        self.create = create;
        self
    }

    pub(crate) fn create_new(&mut self, create_new: bool) -> &mut Self {
        self.create_new = create_new;
        self
    }

    pub(crate) fn mode(&mut self, mode: u32) -> &mut Self {
        self.mode = mode;
        self
    }

    pub(crate) fn custom_flags(&mut self, flags: i32) -> &mut Self {
        self.custom_flags = flags;
        self
    }

    pub(crate) fn open(&self, path: &Path) -> io::Result<File> {
        #[cfg(unix)]
        {
            unix::open(path, self)
        }
        #[cfg(not(unix))]
        {
            held(path)?;
            std::fs::OpenOptions::new()
                .read(self.read)
                .write(self.write)
                .append(self.append)
                .truncate(self.truncate)
                .create(self.create)
                .create_new(self.create_new)
                .open(path)
        }
    }
}

/// `std::fs::DirBuilder::new().recursive(true).mode(mode).create(dir)`.
pub(crate) fn create_dir_all(dir: &Path, mode: u32) -> io::Result<()> {
    #[cfg(unix)]
    {
        unix::create_dir_all(dir, mode)
    }
    #[cfg(not(unix))]
    {
        let _ = mode;
        held(dir)?;
        std::fs::create_dir_all(dir)
    }
}

/// Off Unix: refuses an operation on `path` under a home that is no longer the held one (its
/// file id moved on), right before the operation.
#[cfg(not(unix))]
fn held(path: &Path) -> io::Result<()> {
    crate::config::refuse_lost_home(path).map_err(io::Error::other)
}

/// [`create_dir_all`] with 0700, and an existing folder of this user narrowed to 0700 (one an
/// older build made under a wider umask); a symlink or another user's folder is left as it is.
pub(crate) fn private_dir(dir: &Path) -> io::Result<()> {
    create_dir_all(dir, 0o700)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        let opened = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
            .open(dir);
        let Ok(opened) = opened else { return Ok(()) };
        let meta = opened.metadata()?;
        // SAFETY: getuid has no preconditions.
        let mine = meta.uid() == unsafe { libc::getuid() };
        if mine && meta.mode() & 0o077 != 0 {
            opened.set_permissions(std::fs::Permissions::from_mode(0o700))?;
        }
    }
    Ok(())
}

/// `std::fs::set_permissions(path, Permissions::from_mode(mode))`.
#[cfg(unix)]
pub(crate) fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    unix::set_mode(path, mode)
}

/// `std::fs::rename(from, to)`.
pub(crate) fn rename(from: &Path, to: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        unix::rename(from, to)
    }
    #[cfg(not(unix))]
    {
        held(from)?;
        held(to)?;
        std::fs::rename(from, to)
    }
}

/// `std::fs::remove_file(path)`.
pub(crate) fn remove_file(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        unix::remove(path, 0)
    }
    #[cfg(not(unix))]
    {
        held(path)?;
        std::fs::remove_file(path)
    }
}

/// `std::fs::remove_dir_all(path)`: a symlink at `path` is removed, never followed.
pub(crate) fn remove_dir_all(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        unix::remove_dir_all(path)
    }
    #[cfg(not(unix))]
    {
        held(path)?;
        std::fs::remove_dir_all(path)
    }
}

/// `std::fs::write(path, bytes)`, then synced: a copy written aside before a rename puts it in
/// place.
pub(crate) fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;
    let mut file = OpenOptions::new().write(true).create(true).truncate(true).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Syncs the folder `dir` itself (a rename in it is durable once it is synced).
pub(crate) fn sync_dir(dir: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        OpenOptions::new().read(true).custom_flags(libc::O_DIRECTORY).open(dir)?.sync_all()
    }
    #[cfg(not(unix))]
    {
        let _ = dir;
        Ok(())
    }
}

/// Called once a file's temporary copy is written and synced, before it is renamed over the
/// file: a test may end the process there (`config::seams::on_before_rename`).
pub(crate) fn before_rename(path: &Path) {
    #[cfg(test)]
    crate::config::seams::before_rename(path);
    let _ = path;
}

/// Writes `bytes` as `path` (0600) whole: a new temporary copy beside it (`path` with the
/// extension `tmp-<pid>`), synced, then renamed over it, then the folder synced; the folder and
/// any missing parent are made owner-only first ([`private_dir`]). The chat index's own files
/// (`cmux_chat_index::write_json_private` writes the same, by path).
pub(crate) fn write_json_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;
    let dir = path.parent().ok_or_else(|| io::Error::other("no parent folder"))?;
    private_dir(dir)?;
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    // A file a crashed process left under a reused pid keeps its mode: start anew.
    let _ = remove_file(&tmp);
    let written = (|| {
        let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        before_rename(path);
        rename(&tmp, path)
    })();
    if written.is_err() {
        let _ = remove_file(&tmp);
        return written;
    }
    let _ = sync_dir(dir);
    Ok(())
}

/// The chat index's own files (its cache, its recorded roots, the chat text): [`write_json_private`]
/// on every platform, a synced temporary copy renamed over the file (off Unix by path, the home
/// checked again before each step).
pub(crate) fn write_index_file(path: &Path, bytes: &[u8]) -> io::Result<()> {
    write_json_private(path, bytes)
}

#[cfg(unix)]
mod unix {
    use std::ffi::{CStr, CString, OsStr};
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    use std::path::{Component, Path};

    /// A name in an open folder (`dir`), or a path (`dir` `None`: `AT_FDCWD`).
    pub(super) struct At {
        dir: Option<OwnedFd>,
        name: CString,
    }

    impl At {
        fn dirfd(&self) -> libc::c_int {
            self.dir.as_ref().map_or(libc::AT_FDCWD, |dir| dir.as_raw_fd())
        }
    }

    fn c(name: &OsStr) -> io::Result<CString> {
        CString::new(name.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
    }

    fn check(result: libc::c_int) -> io::Result<libc::c_int> {
        if result < 0 { Err(io::Error::last_os_error()) } else { Ok(result) }
    }

    fn owned(fd: libc::c_int) -> io::Result<OwnedFd> {
        let fd = check(fd)?;
        // SAFETY: a descriptor the kernel just returned, owned by nothing else.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    /// The folder `name` in `dir`, following a symlink as a path would.
    fn open_dir_at(dir: &OwnedFd, name: &OsStr) -> io::Result<OwnedFd> {
        let name = c(name)?;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        owned(unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        })
    }

    fn mkdir_at(dir: libc::c_int, name: &CStr, mode: u32) -> io::Result<()> {
        // SAFETY: a valid descriptor (or AT_FDCWD) and a NUL-terminated name.
        if unsafe { libc::mkdirat(dir, name.as_ptr(), mode as libc::mode_t) } < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
        Ok(())
    }

    /// The names of `path` below the held home, when it is below it: `None` for any other path.
    fn held_names(path: &Path) -> Option<(OwnedFd, Vec<std::ffi::OsString>)> {
        let (home, relative) = crate::config::held_home_dir(path)?;
        let dir = home.fd().try_clone_to_owned().ok()?;
        let names = relative
            .components()
            .filter_map(|part| match part {
                Component::Normal(name) => Some(name.to_os_string()),
                Component::ParentDir => Some("..".into()),
                _ => None,
            })
            .collect();
        Some((dir, names))
    }

    /// `path` as a name in its parent folder opened from the held home, when it is below it.
    /// `make`: missing parents are made with that mode, as a recursive `mkdir` would.
    pub(super) fn at(path: &Path, make: Option<u32>) -> io::Result<At> {
        if let Some((mut dir, names)) = held_names(path)
            && let Some((name, folders)) = names.split_last()
        {
            for folder in folders {
                if let Some(mode) = make {
                    mkdir_at(dir.as_raw_fd(), &c(folder)?, mode)?;
                }
                dir = open_dir_at(&dir, folder)?;
            }
            return Ok(At { dir: Some(dir), name: c(name)? });
        }
        if let Some(mode) = make
            && let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty())
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new().recursive(true).mode(mode).create(parent)?;
        }
        Ok(At { dir: None, name: c(path.as_os_str())? })
    }

    pub(super) fn open(path: &Path, options: &super::OpenOptions) -> io::Result<File> {
        let access = match (options.read, options.write || options.append) {
            (true, false) => libc::O_RDONLY,
            (false, true) => libc::O_WRONLY,
            (true, true) => libc::O_RDWR,
            (false, false) => return Err(io::Error::from(io::ErrorKind::InvalidInput)),
        };
        let creation = if options.create_new {
            libc::O_CREAT | libc::O_EXCL
        } else {
            (if options.create { libc::O_CREAT } else { 0 })
                | (if options.truncate { libc::O_TRUNC } else { 0 })
        };
        let append = if options.append { libc::O_APPEND } else { 0 };
        let flags = access
            | creation
            | append
            | libc::O_CLOEXEC
            | (options.custom_flags & !libc::O_ACCMODE);
        let at = at(path, None)?;
        // SAFETY: a valid descriptor (or AT_FDCWD) and a NUL-terminated name.
        let fd = owned(unsafe {
            libc::openat(at.dirfd(), at.name.as_ptr(), flags, options.mode as libc::c_uint)
        })?;
        Ok(File::from(fd))
    }

    pub(super) fn create_dir_all(dir: &Path, mode: u32) -> io::Result<()> {
        if crate::config::held_home_dir(dir).is_none() {
            use std::os::unix::fs::DirBuilderExt;
            return std::fs::DirBuilder::new().recursive(true).mode(mode).create(dir);
        }
        let at = at(dir, Some(mode))?;
        mkdir_at(at.dirfd(), &at.name, mode)
    }

    pub(super) fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
        let at = at(path, None)?;
        // SAFETY: a valid descriptor (or AT_FDCWD) and a NUL-terminated name.
        check(unsafe { libc::fchmodat(at.dirfd(), at.name.as_ptr(), mode as libc::mode_t, 0) })
            .map(drop)
    }

    pub(super) fn rename(from: &Path, to: &Path) -> io::Result<()> {
        let (from, to) = (at(from, None)?, at(to, None)?);
        // SAFETY: valid descriptors (or AT_FDCWD) and NUL-terminated names.
        check(unsafe {
            libc::renameat(from.dirfd(), from.name.as_ptr(), to.dirfd(), to.name.as_ptr())
        })
        .map(drop)
    }

    /// `unlinkat` with `flags` (0: a file; `AT_REMOVEDIR`: an empty folder).
    pub(super) fn remove(path: &Path, flags: libc::c_int) -> io::Result<()> {
        let at = at(path, None)?;
        // SAFETY: a valid descriptor (or AT_FDCWD) and a NUL-terminated name.
        check(unsafe { libc::unlinkat(at.dirfd(), at.name.as_ptr(), flags) }).map(drop)
    }

    pub(super) fn remove_dir_all(path: &Path) -> io::Result<()> {
        if crate::config::held_home_dir(path).is_none() {
            return std::fs::remove_dir_all(path);
        }
        let at = at(path, None)?;
        // SAFETY: a valid descriptor and a NUL-terminated name.
        let folder = owned(unsafe {
            libc::openat(
                at.dirfd(),
                at.name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        });
        match folder {
            Ok(folder) => empty(&folder)?,
            // A symlink or a file: removed itself, as `std::fs::remove_dir_all` does a link.
            Err(error) if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) => {
                // SAFETY: as above.
                return check(unsafe { libc::unlinkat(at.dirfd(), at.name.as_ptr(), 0) }).map(drop);
            }
            Err(error) => return Err(error),
        }
        // SAFETY: as above.
        check(unsafe { libc::unlinkat(at.dirfd(), at.name.as_ptr(), libc::AT_REMOVEDIR) }).map(drop)
    }

    /// Removes everything in the open folder `dir`, never through a symlink.
    fn empty(dir: &OwnedFd) -> io::Result<()> {
        for name in list(dir)? {
            let c_name = c(&name)?;
            // SAFETY: a valid descriptor and a NUL-terminated name.
            let sub = owned(unsafe {
                libc::openat(
                    dir.as_raw_fd(),
                    c_name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            });
            let flags = match sub {
                Ok(sub) => {
                    empty(&sub)?;
                    libc::AT_REMOVEDIR
                }
                Err(error) if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) => {
                    0
                }
                Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error),
            };
            // SAFETY: as above.
            match check(unsafe { libc::unlinkat(dir.as_raw_fd(), c_name.as_ptr(), flags) }) {
                Ok(_) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }

    /// The names in `dir`, without `.` and `..`.
    fn list(dir: &OwnedFd) -> io::Result<Vec<std::ffi::OsString>> {
        // fdopendir takes the descriptor it is given; it gets its own copy.
        let copy = dir.as_fd().try_clone_to_owned()?;
        // SAFETY: a valid descriptor whose ownership passes to the stream.
        let stream = unsafe { libc::fdopendir(copy.as_raw_fd()) };
        if stream.is_null() {
            return Err(io::Error::last_os_error());
        }
        std::mem::forget(copy); // closedir closes it
        let mut names = Vec::new();
        loop {
            // SAFETY: a valid stream; the entry is read before the next readdir.
            let entry = unsafe { libc::readdir(stream) };
            if entry.is_null() {
                break;
            }
            // SAFETY: d_name is NUL-terminated.
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
            if name != b"." && name != b".." {
                names.push(OsStr::from_bytes(name).to_os_string());
            }
        }
        // SAFETY: a stream fdopendir returned, closed once.
        unsafe { libc::closedir(stream) };
        Ok(names)
    }
}
