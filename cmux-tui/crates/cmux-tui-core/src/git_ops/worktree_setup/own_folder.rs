//! A git folder that cmux keeps files in, as an open folder.
//!
//! A setup keeps its status, its log, its run lock and its stop marker in
//! the git folder of its worktree, and the ports of a repository's worktrees
//! are in the repository's git folder. The path of such a folder is resolved
//! one time. The folder is opened then, each folder of its path through its
//! parent ([`Tree::open`](crate::git_ops::work_tree_entry::Tree::open)), and
//! it stays open. A file of the folder is opened, looked at, removed and
//! renamed by its name in the open folder: the files are of the folder that
//! was opened, also when its path names a different folder later.
//!
//! A system that is not Unix has no call that takes a name in an open
//! folder. There each call is by the real path of the folder, as the open
//! read it: a link in the path that the folder was opened by has no effect
//! after the open.

use std::fs::File;
use std::io::{self, Read as _, Write as _};
use std::path::{Component, Path, PathBuf};

use super::{MAX_OWN_BYTES, TooLarge};

/// The record that git keeps in the git folder of a worktree: the path of
/// the worktree's `.git` file.
const RECORD: &str = "gitdir";

/// How a file that cmux writes or locks is opened.
#[derive(Clone, Copy)]
pub(super) enum Access {
    /// For writes.
    Write,
    /// For a read, and for writes at the end of the file.
    Append,
}

/// One open of a name of the folder.
#[derive(Clone, Copy)]
enum Open {
    /// For a read. Nothing is made.
    Read,
    /// The file is made when there is none.
    OrMake(Access),
    /// The file is made new: a thing that is at the name stops the open.
    New(Access),
}

/// A git folder that cmux keeps files in (a setup's status, log and lock,
/// the repository's ports). The top folder of a new worktree is opened so
/// too, for the read of its `.git` file
/// ([`read_small`](super::read_small)): that file is git's, not cmux's.
pub(super) struct OwnFolder {
    path: PathBuf,
    /// The real path of the folder at its open, or why there is no open
    /// folder: the kind of the error that the open kept.
    real: Result<PathBuf, io::ErrorKind>,
    folder: system::Folder,
}

impl OwnFolder {
    /// The folder at `path`, opened here. With a folder that is not there, or
    /// that cannot be opened, each open of a name fails, and no name is there.
    pub(super) fn open(path: &Path) -> Self {
        let (real, folder) = system::Folder::open(path);
        Self { path: path.to_path_buf(), real, folder }
    }

    /// The path that the folder was opened by.
    pub(super) fn path(&self) -> &Path {
        &self.path
    }

    /// Why there is no open folder: the kind of the error that the open
    /// kept. `None` for an open folder.
    pub(super) fn not_opened(&self) -> Option<io::ErrorKind> {
        self.real.as_ref().err().copied()
    }

    /// Whether this folder is the git folder that the repository whose git
    /// folder is `common_dir` keeps for the worktree `root`. Each look is
    /// at the folder that was opened, not at the folder that its path names
    /// now:
    ///
    /// - the folder is directly in the `worktrees` folder of `common_dir`,
    ///   by the real path of that folder and the real path that the open of
    ///   this folder walked;
    /// - the folder names the worktree back. Its record, read by its name in
    ///   the open folder, is the path of the `.git` entry of `root`; git
    ///   writes that path from the root of the file system, or from this
    ///   folder.
    pub(super) fn is_of(&self, root: &Path, common_dir: &Path) -> bool {
        let real = |path: &Path| std::fs::canonicalize(path).ok();
        let (Some(own), Some(worktrees)) =
            (self.real.as_deref().ok(), real(&common_dir.join("worktrees")))
        else {
            return false;
        };
        if own.parent() != Some(worktrees.as_path()) {
            return false;
        }
        let Ok(Some(record)) = self.read(RECORD) else { return false };
        let Ok(record) = String::from_utf8(record) else { return false };
        let entry = path_from(own, Path::new(record.trim_end_matches(['\n', '\r'])));
        let (folder, root) = (entry.parent().and_then(real), real(root));
        entry.file_name().is_some_and(|name| name == ".git") && folder.is_some() && folder == root
    }

    /// Whether a thing is at `name`. A link is not followed.
    pub(super) fn has(&self, name: &str) -> bool {
        self.folder.has(name)
    }

    /// Opens `name`. The file is cmux's own, or the `.git` file of a new
    /// worktree ([`read_small`](super::read_small)): a link in its place is not
    /// followed, the open waits for nothing (a named pipe has no other end
    /// to wait for), and only a regular file is used (the open file is
    /// looked at, not its name). A thing at the name that is not a regular
    /// file gives `InvalidInput` when its open succeeds, and the error of
    /// its open when it does not.
    fn open_as(&self, name: &str, open: Open) -> io::Result<File> {
        let file = self.folder.open_file(name, open)?;
        if file.metadata()?.is_file() { Ok(file) } else { Err(io::ErrorKind::InvalidInput.into()) }
    }

    /// Opens the file `name` for a read ([`Self::open_as`]).
    pub(super) fn file(&self, name: &str) -> Option<File> {
        self.open_as(name, Open::Read).ok()
    }

    /// The bytes of the file `name`; `None` when there is no such file to
    /// read.
    pub(super) fn read(&self, name: &str) -> Result<Option<Vec<u8>>, TooLarge> {
        let Some(file) = self.file(name) else { return Ok(None) };
        let mut bytes = Vec::new();
        if file.take(MAX_OWN_BYTES.saturating_add(1)).read_to_end(&mut bytes).is_err() {
            return Ok(None);
        }
        let small = u64::try_from(bytes.len()).is_ok_and(|length| length <= MAX_OWN_BYTES);
        if small { Ok(Some(bytes)) } else { Err(TooLarge) }
    }

    /// Makes the file `name` new, open with `access` ([`Self::open_as`]),
    /// with the error of an open that fails. A thing that is at the name
    /// stops the open.
    pub(super) fn make_new(&self, name: &str, access: Access) -> io::Result<File> {
        self.open_as(name, Open::New(access))
    }

    /// Opens with `access` a file that cmux writes or locks (a setup's log,
    /// its run lock, the lock of the repository's ports), and makes it when
    /// there is none ([`Self::open_as`]). A file that has a second name is
    /// not used: a line written to it, or a lock on it, would be in the file
    /// at that name too. A look at the name comes first, so such a file is
    /// not opened. Its name is removed and the file is made new, as the
    /// `.partial` file of a JSON file is ([`Self::write`]): what comes to the
    /// name after the removal stops the open.
    pub(super) fn open_or_make(&self, name: &str, access: Access) -> Option<File> {
        if !self.folder.has_a_second_name(name) {
            let file = self.open_as(name, Open::OrMake(access)).ok()?;
            // A second look, at the open file: a second name, or a different
            // file, can come to the name after the first look.
            if self.has_one_name(&file, name) {
                return Some(file);
            }
        }
        self.folder.remove(name);
        self.make_new(name, access).ok()
    }

    /// Whether the open file `file` is the file at `name` and has no second
    /// name. One look at the name gives the file and the count of its names
    /// together, so no change between two looks is missed. Where the count
    /// of a file's names is not read, each file has one name.
    pub(super) fn has_one_name(&self, file: &File, name: &str) -> bool {
        self.folder.has_one_name(file, name)
    }

    /// Writes `bytes` as the whole of the JSON file `name`: to the file
    /// `name.partial`, which is flushed and then takes its name. The
    /// `.partial` file is made new ([`Self::make_new`]): what is at its
    /// name goes first, and a link that comes there after that stops the
    /// write.
    ///
    /// The flush puts the bytes before the rename in the order of the
    /// writes to the disk: after a stop of the machine, the name has the
    /// whole of the file from before or the whole of the new one, not a
    /// file that is cut short. A flush that fails stops the write: the
    /// name keeps the file from before. The folder is not flushed after
    /// the rename, so a stop of the machine directly after it can leave
    /// the file from before at the name.
    pub(super) fn write(&self, name: &str, bytes: &[u8]) -> io::Result<()> {
        let partial = format!("{name}.partial");
        self.folder.remove(&partial);
        let mut file = self.make_new(&partial, Access::Write)?;
        file.write_all(bytes)?;
        flush(&file)?;
        self.folder.rename(&partial, name)
    }
}

/// Flushes `file`, which [`OwnFolder::write`] wrote, before it takes its
/// name. In a test build, a flush that the test put in the place for its
/// thread runs and no call to the system is made.
fn flush(file: &File) -> io::Result<()> {
    #[cfg(test)]
    {
        if let Some(result) = flushes::in_place(file) {
            return result;
        }
    }
    system::flush(file)
}

/// The path `path` from the folder `folder`; `path` itself when it starts at
/// the root of the file system. Each `..` takes the last name off: `folder`
/// is a real path, so its last name is no link.
fn path_from(folder: &Path, path: &Path) -> PathBuf {
    let mut whole = folder.to_path_buf();
    for part in path.components() {
        match part {
            Component::ParentDir => {
                whole.pop();
            }
            Component::CurDir => {}
            part => whole.push(part),
        }
    }
    whole
}

#[cfg(unix)]
mod system {
    use std::ffi::{CStr, CString};
    use std::fs::File;
    use std::io;
    use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd, RawFd};
    use std::path::{Path, PathBuf};

    use super::{Access, Open};
    use crate::git_ops::work_tree_entry::{Kind, Stat, Tree, kind_in, open_at, stat_at, stat_of};

    /// The flags of each open of a file: no link is followed, and no open
    /// waits for the other end of a named pipe.
    const FILE_FLAGS: libc::c_int = libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    /// The mode of a file that an open makes, before the mask of the
    /// process: the mode that `std::fs` makes a file with.
    const NEW_FILE_MODE: libc::c_uint = 0o666;

    /// Flushes `file` with the sync that the record files of the terminal
    /// host have before their rename, `barrier_sync`
    /// ([`sync_before_rename`](crate::terminal_host_runtime::sync_before_rename)):
    /// it puts the bytes of the file before the writes that come after it.
    /// On macOS that is `F_BARRIERFSYNC`, which does not empty the cache of
    /// the drive.
    pub(super) fn flush(file: &File) -> io::Result<()> {
        crate::terminal_host_runtime::sync_before_rename(file)
    }

    /// The open folder, or why there is none.
    pub(super) struct Folder(Result<OwnedFd, io::ErrorKind>);

    /// `name` in `folder`, opened with `flags` that make the file when
    /// nothing has the name.
    fn make_at(folder: RawFd, name: &CStr, flags: libc::c_int) -> io::Result<OwnedFd> {
        // SAFETY: a live descriptor and a NUL-terminated name; the result is checked.
        let fd = unsafe { libc::openat(folder, name.as_ptr(), flags, NEW_FILE_MODE) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: a descriptor the system just returned, owned by no one else.
        Ok(unsafe { OwnedFd::from_raw_fd(fd) })
    }

    impl Folder {
        /// The folder at `path`, with its real path. Its links are resolved
        /// one time, and each folder of the path that this gives is then
        /// opened through its parent and refuses a link: the real path is
        /// the path of the folder that is open. With no open folder, the
        /// kind is of the error that stopped this: of the read of the real
        /// path, or of the open of a folder of that path.
        pub(super) fn open(path: &Path) -> (Result<PathBuf, io::ErrorKind>, Self) {
            let real = match std::fs::canonicalize(path) {
                Ok(real) => real,
                Err(error) => return (Err(error.kind()), Self(Err(error.kind()))),
            };
            match Tree::opened(&real) {
                Ok(tree) => (Ok(real), Self(Ok(tree.into_top()))),
                Err(error) => (Err(error.kind()), Self(Err(error.kind()))),
            }
        }

        /// The open folder and `name`, as the system's calls take them.
        fn at(&self, name: &str) -> io::Result<(RawFd, CString)> {
            let folder = self.0.as_ref().map_err(|kind| io::Error::from(*kind))?;
            let name = CString::new(name).map_err(|_| io::ErrorKind::InvalidInput)?;
            Ok((folder.as_raw_fd(), name))
        }

        /// What the system says of `name`, with no link followed.
        fn stat(&self, name: &str) -> Option<Stat> {
            let (folder, name) = self.at(name).ok()?;
            stat_at(folder, &name)
        }

        pub(super) fn open_file(&self, name: &str, open: Open) -> io::Result<File> {
            let (folder, name) = self.at(name)?;
            let with = |access: Access| match access {
                Access::Write => libc::O_WRONLY,
                Access::Append => libc::O_RDWR | libc::O_APPEND,
            };
            let file = match open {
                Open::Read => open_at(folder, &name, libc::O_RDONLY | FILE_FLAGS),
                Open::OrMake(access) => {
                    make_at(folder, &name, with(access) | libc::O_CREAT | FILE_FLAGS)
                }
                Open::New(access) => {
                    let flags = with(access) | libc::O_CREAT | libc::O_EXCL | FILE_FLAGS;
                    make_at(folder, &name, flags)
                }
            };
            file.map(File::from)
        }

        pub(super) fn has(&self, name: &str) -> bool {
            self.stat(name).is_some()
        }

        /// Whether the thing at `name` is a regular file that has a second
        /// name.
        pub(super) fn has_a_second_name(&self, name: &str) -> bool {
            self.stat(name).is_some_and(|named| kind_in(&named) == Kind::File && named.st_nlink > 1)
        }

        pub(super) fn has_one_name(&self, file: &File, name: &str) -> bool {
            let (Some(open), Some(named)) = (stat_of(file), self.stat(name)) else {
                return false;
            };
            named.st_nlink <= 1 && named.st_dev == open.st_dev && named.st_ino == open.st_ino
        }

        /// Removes the name `name`, when a thing that is no folder has it.
        pub(super) fn remove(&self, name: &str) {
            let Ok((folder, name)) = self.at(name) else { return };
            // SAFETY: a live descriptor and a NUL-terminated name.
            unsafe {
                libc::unlinkat(folder, name.as_ptr(), 0);
            }
        }

        /// Gives the thing at `from` the name `to`.
        pub(super) fn rename(&self, from: &str, to: &str) -> io::Result<()> {
            let ((folder, from), (_, to)) = (self.at(from)?, self.at(to)?);
            // SAFETY: a live descriptor and two NUL-terminated names; the result is checked.
            let result = unsafe { libc::renameat(folder, from.as_ptr(), folder, to.as_ptr()) };
            if result == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
        }
    }
}

#[cfg(not(unix))]
mod system {
    use std::fs::{self, File, OpenOptions};
    use std::io;
    use std::path::{Path, PathBuf};

    use super::{Access, Open};

    /// Flushes `file` with the full sync of the system.
    pub(super) fn flush(file: &File) -> io::Result<()> {
        file.sync_all()
    }

    /// The folder, as its real path; as the path that it was opened by when
    /// that has no real path.
    pub(super) struct Folder(PathBuf);

    impl Folder {
        /// The folder at `path`, with its real path at this time. Each
        /// later call is by the real path, which the check of the folder
        /// is of ([`OwnFolder::is_of`](super::OwnFolder::is_of)). With no
        /// real path, each later call is by `path`.
        pub(super) fn open(path: &Path) -> (Result<PathBuf, io::ErrorKind>, Self) {
            match fs::canonicalize(path) {
                Ok(real) => (Ok(real.clone()), Self(real)),
                Err(error) => (Err(error.kind()), Self(path.to_path_buf())),
            }
        }

        pub(super) fn open_file(&self, name: &str, open: Open) -> io::Result<File> {
            let path = self.0.join(name);
            // No open here refuses a link: the look at the name is all there is.
            if fs::symlink_metadata(&path).is_ok_and(|metadata| !metadata.is_file()) {
                return Err(io::ErrorKind::InvalidInput.into());
            }
            let mut options = OpenOptions::new();
            match open {
                Open::Read => options.read(true),
                Open::OrMake(Access::Write) | Open::New(Access::Write) => options.write(true),
                Open::OrMake(Access::Append) | Open::New(Access::Append) => {
                    options.read(true).append(true)
                }
            };
            options.create(matches!(open, Open::OrMake(_)));
            options.create_new(matches!(open, Open::New(_)));
            options.open(path)
        }

        pub(super) fn has(&self, name: &str) -> bool {
            fs::symlink_metadata(self.0.join(name)).is_ok()
        }

        /// The count of a file's names is not read here.
        pub(super) fn has_a_second_name(&self, _name: &str) -> bool {
            false
        }

        /// The count of a file's names is not read here.
        pub(super) fn has_one_name(&self, _file: &File, _name: &str) -> bool {
            true
        }

        pub(super) fn remove(&self, name: &str) {
            let _ = fs::remove_file(self.0.join(name));
        }

        pub(super) fn rename(&self, from: &str, to: &str) -> io::Result<()> {
            fs::rename(self.0.join(from), self.0.join(to))
        }
    }
}

/// A flush that a test puts in the place of the flush of a file that
/// [`OwnFolder::write`] writes, for the writes of the test's own thread.
#[cfg(test)]
#[path = "own_folder_flushes_tests.rs"]
pub(super) mod flushes;
