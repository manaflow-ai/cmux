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
//! refused; the window left is the one call itself. A read ([`held_read`]) checks the home again
//! after it too, so an answer read in a replacement home is never returned: a home replaced
//! before or during the read is an error, never "nothing there" (#41721 review F1).

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

    pub(crate) fn open(&self, path: impl AsRef<Path>) -> io::Result<File> {
        let path = path.as_ref();
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
pub(crate) fn create_dir_all(dir: impl AsRef<Path>, mode: u32) -> io::Result<()> {
    let dir = dir.as_ref();
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
/// file id moved on), right before the operation. Built in tests on every platform too: the
/// forced race on [`held_read`] (`lost_home_race_tests.rs`) runs on Linux CI, with the same home
/// check (`config::refuse_lost_home`), which compares the device and inode there.
#[cfg(any(not(unix), test))]
fn held(path: &Path) -> io::Result<()> {
    crate::config::refuse_lost_home(path).map_err(io::Error::other)
}

/// Off Unix: `read` of `path`, made between two checks of the home ([`held`]): the answer is the
/// held home's, or an error when the home was replaced before or during the read. A replacement
/// that lacks a file the held home has then never reads as "not there" (#41721 review F1). The
/// second check runs whatever the read answered: a read that failed in a replacement (a
/// `NotFound`, which `LocalStore::load` reads as "no session") is the lost home's error too
/// (#41915 review F1).
#[cfg(any(not(unix), test))]
pub(crate) fn held_read<T, E: From<io::Error>>(
    path: &Path,
    read: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    held(path)?;
    let answer = read();
    held(path)?;
    answer
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
            .mode(0o700)
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
pub(crate) fn set_mode(path: impl AsRef<Path>, mode: u32) -> io::Result<()> {
    let path = path.as_ref();
    unix::set_mode(path, mode)
}

/// `std::fs::rename(from, to)`.
pub(crate) fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    let (from, to) = (from.as_ref(), to.as_ref());
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
pub(crate) fn remove_file(path: impl AsRef<Path>) -> io::Result<()> {
    let path = path.as_ref();
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

/// Whether anything is at `path` itself (`std::fs::symlink_metadata(path).is_ok()`), read in the
/// held home when `path` is below it: a writer that decides by what is there reads the folder it
/// writes, not a replacement made at the same path. Any error is "not there", a lost home's too:
/// a read that decides what a writer keeps or removes takes [`try_exists_nofollow`].
pub(crate) fn exists_nofollow(path: impl AsRef<Path>) -> bool {
    try_exists_nofollow(path).unwrap_or(false)
}

/// Whether anything is at `path` itself, read in the held home when `path` is below it, on every
/// platform: `Ok(false)` only when nothing is there. Off Unix a home that is no longer the held
/// one ([`held_read`]) is an error, never `Ok(false)`: a replacement home without the file must
/// not hide the held home's (#41721 review F1: a cold rehydrate read "not archived" there).
pub(crate) fn try_exists_nofollow(path: impl AsRef<Path>) -> io::Result<bool> {
    let path = path.as_ref();
    #[cfg(unix)]
    {
        unix::try_exists_nofollow(path)
    }
    #[cfg(not(unix))]
    {
        held_read(path, || found(std::fs::symlink_metadata(path)))
    }
}

/// `std::fs::symlink_metadata(path)`, read in the held home when `path` is below it, on every
/// platform: the final name is never followed. Off Unix the read is made between two checks of
/// the home ([`held_read`]), so a home replaced before or during it is an error.
pub(crate) fn symlink_metadata(path: impl AsRef<Path>) -> io::Result<std::fs::Metadata> {
    let path = path.as_ref();
    #[cfg(unix)]
    {
        unix::symlink_metadata(path)
    }
    #[cfg(not(unix))]
    {
        held_read(path, || std::fs::symlink_metadata(path))
    }
}

/// `true` for a read that found something, `false` for `NotFound`, any other error as it is.
fn found<T>(read: io::Result<T>) -> io::Result<bool> {
    match read {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// A name in a folder [`read_dir`] listed, and whether it is a regular file itself (a symlink
/// is not).
pub(crate) struct DirEntry {
    pub(crate) name: std::ffi::OsString,
    pub(crate) is_file: bool,
    pub(crate) is_dir: bool,
    pub(crate) is_symlink: bool,
}

/// `std::fs::read_dir(path)`, read in the held home when `path` is below it: a writer that
/// removes or renames by what a folder holds reads the folder it changes, not a replacement made
/// at the same path (#41462 review F1).
pub(crate) fn read_dir(path: impl AsRef<Path>) -> io::Result<Vec<DirEntry>> {
    let path = path.as_ref();
    #[cfg(unix)]
    {
        unix::read_dir(path)
    }
    #[cfg(not(unix))]
    {
        held_read(path, || {
            std::fs::read_dir(path)?
                .map(|entry| {
                    let entry = entry?;
                    let kind = entry.file_type()?;
                    Ok(DirEntry {
                        name: entry.file_name(),
                        is_file: kind.is_file(),
                        is_dir: kind.is_dir(),
                        is_symlink: kind.is_symlink(),
                    })
                })
                .collect()
        })
    }
}

/// `config::private_state_file(path)` (an existing regular file of this user, its final
/// symlink never followed, opened to read), opened in the held home when `path` is below it:
/// what a removal decides by is read from the folder it removes from (#41462 review F1).
pub(crate) fn private_state_file(path: impl AsRef<Path>) -> anyhow::Result<File> {
    let path = path.as_ref();
    #[cfg(unix)]
    {
        use anyhow::Context as _;
        let file = OpenOptions::new()
            .read(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(path)
            .with_context(|| format!("open private state file {}", path.display()))?;
        crate::config::validate_private_state_file(&file, path)?;
        Ok(file)
    }
    #[cfg(not(unix))]
    {
        held_read(path, || crate::config::private_state_file(path))
    }
}

/// A private store folder held for one read pass. On Unix children are reached from its
/// descriptor, so replacing an ancestor cannot redirect a later chat read. Elsewhere each
/// operation checks the held home before and after its path read.
pub(crate) struct PrivateDir {
    path: std::path::PathBuf,
    #[cfg(unix)]
    file: File,
}

impl PrivateDir {
    pub(crate) fn open(path: &Path) -> anyhow::Result<Self> {
        crate::config::refuse_lost_home(path)?;
        #[cfg(unix)]
        {
            crate::config::validate_private_state_ancestors(path)?;
            let open = || {
                OpenOptions::new()
                    .read(true)
                    .mode(0o700)
                    .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
                    .open(path)
            };
            let file = Self::checked(open()?, path, open)?;
            Ok(Self { path: path.to_path_buf(), file })
        }
        #[cfg(not(unix))]
        {
            held_read(path, || -> anyhow::Result<Self> {
                std::fs::symlink_metadata(path)?;
                crate::config::private_state_dir(path)?;
                Ok(Self { path: path.to_path_buf() })
            })
        }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn names(&self) -> io::Result<Vec<std::ffi::OsString>> {
        #[cfg(unix)]
        {
            use std::os::fd::AsFd as _;
            unix::list(&self.file.as_fd().try_clone_to_owned()?)
        }
        #[cfg(not(unix))]
        {
            held_read(&self.path, || {
                std::fs::read_dir(&self.path)?
                    .map(|entry| entry.map(|entry| entry.file_name()))
                    .collect()
            })
        }
    }

    pub(crate) fn entry(&self, name: &std::ffi::OsStr) -> io::Result<DirEntry> {
        Self::check_name(name)?;
        #[cfg(unix)]
        {
            use std::os::fd::AsFd as _;
            unix::read_entry_fd(self.file.as_fd(), name, &self.path)
        }
        #[cfg(not(unix))]
        {
            let path = self.path.join(name);
            #[cfg(test)]
            crate::config::startup_seams::entry_stat_error(&path)?;
            let kind = symlink_metadata(path)?.file_type();
            Ok(DirEntry {
                name: name.to_os_string(),
                is_file: kind.is_file(),
                is_dir: kind.is_dir(),
                is_symlink: kind.is_symlink(),
            })
        }
    }

    pub(crate) fn child(&self, name: &std::ffi::OsStr) -> anyhow::Result<Self> {
        Self::check_name(name)?;
        let path = self.path.join(name);
        #[cfg(unix)]
        {
            let open = || self.open_name(name, libc::O_DIRECTORY);
            let file = Self::checked(open()?, &path, open)?;
            Ok(Self { path, file })
        }
        #[cfg(not(unix))]
        {
            Self::open(&path)
        }
    }

    pub(crate) fn private_file(&self, name: &std::ffi::OsStr) -> anyhow::Result<File> {
        Self::check_name(name)?;
        #[cfg(unix)]
        {
            let file = self.open_name(name, libc::O_NONBLOCK)?;
            crate::config::validate_private_state_file(&file, &self.path.join(name))?;
            Ok(file)
        }
        #[cfg(not(unix))]
        {
            private_state_file(self.path.join(name))
        }
    }

    fn check_name(name: &std::ffi::OsStr) -> io::Result<()> {
        // Only one child name is accepted: no caller can escape the held parent with `..`.
        let mut parts = Path::new(name).components();
        if !matches!(parts.next(), Some(std::path::Component::Normal(part)) if part == name)
            || parts.next().is_some()
        {
            return Err(io::Error::from(io::ErrorKind::InvalidInput));
        }
        Ok(())
    }

    #[cfg(unix)]
    fn open_name(&self, name: &std::ffi::OsStr, flags: i32) -> io::Result<File> {
        use std::os::fd::AsFd as _;
        unix::open_private_at(self.file.as_fd(), name, flags).map(File::from)
    }

    #[cfg(unix)]
    fn checked(
        file: File,
        path: &Path,
        reopen: impl FnOnce() -> io::Result<File>,
    ) -> anyhow::Result<File> {
        use std::os::unix::fs::MetadataExt as _;
        crate::config::validate_private_state_dir(&file, path)?;
        let before = file.metadata()?;
        #[cfg(test)]
        crate::config::startup_seams::dir_checked(path);
        let after = reopen()?.metadata()?;
        anyhow::ensure!(
            before.dev() == after.dev() && before.ino() == after.ino(),
            "{} changed while its private permissions were checked",
            path.display()
        );
        Ok(file)
    }
}

/// `std::fs::remove_dir(path)`: an empty folder.
pub(crate) fn remove_dir(path: impl AsRef<Path>) -> io::Result<()> {
    let path = path.as_ref();
    #[cfg(unix)]
    {
        unix::remove(path, libc::AT_REMOVEDIR)
    }
    #[cfg(not(unix))]
    {
        held(path)?;
        std::fs::remove_dir(path)
    }
}

/// `std::fs::hard_link(original, link)`: `link` becomes another name of `original`, both
/// reached from the held home when they are below it (`linkat`, never following a symlink at
/// `original`). The link is the same file as `original` (one inode, one mode), so it never
/// shows its bytes under wider permissions than `original` has.
pub(crate) fn hard_link(original: impl AsRef<Path>, link: impl AsRef<Path>) -> io::Result<()> {
    let (original, link) = (original.as_ref(), link.as_ref());
    #[cfg(unix)]
    {
        unix::hard_link(original, link)
    }
    #[cfg(not(unix))]
    {
        held(original)?;
        held(link)?;
        std::fs::hard_link(original, link)
    }
}

/// `std::fs::remove_dir_all(path)`: a symlink at `path` is removed, never followed, and any other
/// file that is not a folder is refused (`NotADirectory`) and left in place, as `std::fs` does.
pub(crate) fn remove_dir_all(path: impl AsRef<Path>) -> io::Result<()> {
    let path = path.as_ref();
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

/// `std::fs::create_dir_all(dir)`: missing folders made with the default mode (0777, less the
/// umask).
pub(crate) fn create_dirs(dir: impl AsRef<Path>) -> io::Result<()> {
    create_dir_all(dir, 0o777)
}

// The permission rule for every helper here that makes a file or folder (#41462 review F1): it
// never shows its bytes under wider permissions than their source's, or 0600 when they have no
// source. A file is made new (`O_EXCL`) with its mode narrowed to 0600, given its final mode on
// the open descriptor (`fchmod`) before any byte goes in, and a temporary copy is removed on any
// error. A folder is made 0700 at most. A hard link is the same file as its source (one inode,
// one mode), so it is never wider than its source; a symlink's own mode is never read (access
// goes by its target's), so it shows nothing. On Windows each file is made owner-only
// (`owner_only::create_new`: an access list for this user alone) and each folder too
// (`owner_only::create_dir_all`), the counterpart of 0600 and 0700.

/// Mode bits a made file keeps: the permission bits, never set-id or sticky.
#[cfg(unix)]
const PERMISSION_BITS: u32 = 0o777;

/// `std::fs::create_dir(dir)`, made 0700 at most (`mode` as `DirBuilder::mode`, narrowed to the
/// owner's bits): one folder, its parent there already; an existing one is `AlreadyExists`.
pub(crate) fn create_dir(dir: impl AsRef<Path>, mode: u32) -> io::Result<()> {
    let dir = dir.as_ref();
    #[cfg(unix)]
    {
        unix::create_dir(dir, mode & 0o700)
    }
    #[cfg(windows)]
    {
        let _ = mode;
        held(dir)?;
        if dir.symlink_metadata().is_ok() {
            return Err(io::Error::from(io::ErrorKind::AlreadyExists));
        }
        crate::owner_only::create_dir_all(dir)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = mode;
        held(dir)?;
        std::fs::create_dir(dir)
    }
}

/// A new name beside `path` for a temporary copy of it: `.<name>.tmp-<pid>-<n>`.
fn aside(path: &Path) -> io::Result<std::path::PathBuf> {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let name = path.file_name().ok_or_else(|| io::Error::from(io::ErrorKind::InvalidInput))?;
    let mut tmp = std::ffi::OsString::from(".");
    tmp.push(name);
    tmp.push(format!(".tmp-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
    Ok(path.with_file_name(tmp))
}

/// Makes `path`, which must not exist (`O_EXCL`), mode 0600 at most, then gives it `mode`
/// (`fchmod` on the open descriptor) before any byte goes in; on Windows owner-only. Removed
/// again if that fails.
fn create_private(path: &Path, mode: u32) -> io::Result<File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let file = OpenOptions::new().write(true).create_new(true).mode(mode & 0o600).open(path)?;
        if let Err(error) = file.set_permissions(std::fs::Permissions::from_mode(mode)) {
            let _ = remove_file(path);
            return Err(error);
        }
        Ok(file)
    }
    #[cfg(windows)]
    {
        let _ = mode;
        held(path)?;
        crate::owner_only::create_new(path)
    }
    #[cfg(not(any(unix, windows)))]
    {
        let _ = mode;
        OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
    }
}

/// Writes `bytes` to `file` (made at `path`): the first half, then the rest. A test fails the
/// write in between (`config::seams::on_mid_write`), as a full disk would.
fn fill(file: &mut File, path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;
    let (first, rest) = bytes.split_at(bytes.len() / 2);
    file.write_all(first)?;
    #[cfg(test)]
    crate::config::seams::mid_write(path)?;
    let _ = path;
    file.write_all(rest)
}

/// Puts a file in place at `to` whole: made beside it new ([`create_private`], `mode`), filled by
/// `fill`, then renamed over `to`. On any error the temporary copy is removed and `to` is left as
/// it was.
fn replace_with<T>(
    to: &Path,
    mode: u32,
    fill: impl FnOnce(&mut File, &Path) -> io::Result<T>,
) -> io::Result<T> {
    let tmp = aside(to)?;
    let mut file = create_private(&tmp, mode)?;
    let done = fill(&mut file, &tmp).and_then(|value| {
        drop(file);
        rename(&tmp, to).map(|()| value)
    });
    if done.is_err() {
        let _ = remove_file(&tmp);
    }
    done
}

/// The mode a rewritten file keeps: an existing file's, narrowed to the owner's bits; a new
/// file's 0600.
fn rewritten_mode(path: &Path) -> u32 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        path.symlink_metadata()
            .ok()
            .filter(|meta| meta.is_file())
            .map_or(0o600, |meta| meta.permissions().mode() & 0o700)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        0o600
    }
}

/// `std::fs::write(path, contents)`, made whole: a new copy beside it (0600, or an existing
/// file's mode narrowed to the owner's bits) filled, then renamed over it. A failed write leaves
/// `path` as it was and no copy behind.
pub(crate) fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> io::Result<()> {
    let path = path.as_ref();
    replace_with(path, rewritten_mode(path), |file, tmp| fill(file, tmp, contents.as_ref()))
}

/// `std::fs::File::create(path)`: made 0600 (an existing file narrowed to the owner's bits on
/// the open descriptor) before it is cut to nothing and handed back to be written.
pub(crate) fn create_file(path: impl AsRef<Path>) -> io::Result<File> {
    open_private(path.as_ref(), true)
}

/// Opens `path` to write, made 0600 when new; an existing file is narrowed to the owner's bits
/// (`fchmod` on the open descriptor) before anything is written. `truncate`: cut to nothing,
/// after the narrowing. On Windows a new file is made owner-only.
fn open_private(path: &Path, truncate: bool) -> io::Result<File> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let file = OpenOptions::new().write(true).create(true).mode(0o600).open(path)?;
        let mode = file.metadata()?.permissions().mode();
        if mode & 0o077 != 0 {
            file.set_permissions(std::fs::Permissions::from_mode(mode & 0o700))?;
        }
        if truncate {
            file.set_len(0)?;
        }
        Ok(file)
    }
    #[cfg(windows)]
    {
        held(path)?;
        let file = crate::owner_only::open_rw(path)?;
        if truncate {
            file.set_len(0)?;
        }
        Ok(file)
    }
    #[cfg(not(any(unix, windows)))]
    {
        OpenOptions::new().write(true).create(true).truncate(truncate).mode(0o600).open(path)
    }
}

/// `std::fs::copy(from, to)`: `to` replaced whole by a new copy of `from`'s bytes with `from`'s
/// permissions ([`replace_with`]: made 0600 at most, given `from`'s mode before any byte goes
/// in); the bytes copied. A failed copy leaves `to` as it was and no partial copy behind.
pub(crate) fn copy(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<u64> {
    let mut source = OpenOptions::new().read(true).mode(0o600).open(from)?;
    let permissions = source.metadata()?.permissions();
    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt as _;
        permissions.mode() & PERMISSION_BITS
    };
    #[cfg(not(unix))]
    let mode = 0o600;
    replace_with(to.as_ref(), mode, |target, tmp| {
        use std::io::{Read as _, Write as _};
        // The first block, then the rest: a test fails the copy in between.
        let mut block = vec![0; 64 << 10];
        let first = source.read(&mut block)?;
        block.truncate(first);
        target.write_all(&block)?;
        #[cfg(test)]
        crate::config::seams::mid_write(tmp)?;
        let _ = tmp;
        let rest = io::copy(&mut source, target)?;
        #[cfg(not(unix))]
        target.set_permissions(permissions)?;
        Ok((first as u64).saturating_add(rest))
    })
}

/// `std::fs::set_permissions(path, permissions)`.
pub(crate) fn set_permissions(
    path: impl AsRef<Path>,
    permissions: std::fs::Permissions,
) -> io::Result<()> {
    let path = path.as_ref();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        unix::set_mode(path, permissions.mode())
    }
    #[cfg(not(unix))]
    {
        held(path)?;
        std::fs::set_permissions(path, permissions)
    }
}

/// `std::os::unix::fs::symlink(original, link)`: `link` made (`symlinkat`) naming `original` as
/// it is written. A symlink's own mode is never read (opening it reads its target's), so it
/// shows no bytes of its own.
#[cfg(unix)]
pub(crate) fn symlink(original: impl AsRef<Path>, link: impl AsRef<Path>) -> io::Result<()> {
    unix::symlink(original.as_ref(), link.as_ref())
}

/// `std::fs::write(path, bytes)`, then synced: a copy written aside before a rename puts it in
/// place. Made 0600 (an existing file narrowed to the owner's bits) before any byte goes in
/// ([`open_private`]).
pub(crate) fn write_synced(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write as _;
    let mut file = open_private(path, true)?;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Syncs the folder `dir` itself (a rename in it is durable once it is synced).
pub(crate) fn sync_dir(dir: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        OpenOptions::new()
            .read(true)
            .mode(0o600)
            .custom_flags(libc::O_DIRECTORY)
            .open(dir)?
            .sync_all()
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
    use std::os::fd::{AsFd, AsRawFd, BorrowedFd, FromRawFd, OwnedFd};
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

    pub(super) fn open_private_at(
        dir: BorrowedFd<'_>,
        name: &OsStr,
        flags: i32,
    ) -> io::Result<OwnedFd> {
        let name = c(name)?;
        // SAFETY: a valid descriptor and a NUL-terminated child name.
        owned(unsafe {
            libc::openat(
                dir.as_raw_fd(),
                name.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | flags,
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

    pub(super) fn create_dir(dir: &Path, mode: u32) -> io::Result<()> {
        if crate::config::held_home_dir(dir).is_none() {
            use std::os::unix::fs::DirBuilderExt;
            return std::fs::DirBuilder::new().mode(mode).create(dir);
        }
        let at = at(dir, None)?;
        // SAFETY: a valid descriptor (or AT_FDCWD) and a NUL-terminated name.
        check(unsafe { libc::mkdirat(at.dirfd(), at.name.as_ptr(), mode as libc::mode_t) })
            .map(drop)
    }

    pub(super) fn symlink(original: &Path, link: &Path) -> io::Result<()> {
        let target = c(original.as_os_str())?;
        let at = at(link, None)?;
        // SAFETY: a NUL-terminated target, a valid descriptor (or AT_FDCWD) and name.
        check(unsafe { libc::symlinkat(target.as_ptr(), at.dirfd(), at.name.as_ptr()) }).map(drop)
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
            // Not a folder (`ELOOP`: a symlink on Linux; `ENOTDIR`: a symlink on some systems, or
            // a file): a symlink is removed itself, as `std::fs::remove_dir_all` removes a link;
            // anything else is refused and kept, as `std::fs::remove_dir_all` refuses a file.
            Err(error) if matches!(error.raw_os_error(), Some(libc::ELOOP | libc::ENOTDIR)) => {
                if !is_symlink_at(at.dirfd(), &at.name)? {
                    return Err(io::Error::from_raw_os_error(libc::ENOTDIR));
                }
                // SAFETY: as above.
                return check(unsafe { libc::unlinkat(at.dirfd(), at.name.as_ptr(), 0) }).map(drop);
            }
            Err(error) => return Err(error),
        }
        // SAFETY: as above.
        check(unsafe { libc::unlinkat(at.dirfd(), at.name.as_ptr(), libc::AT_REMOVEDIR) }).map(drop)
    }

    /// Whether `name` in `dir` is a symlink itself (`fstatat` with `AT_SYMLINK_NOFOLLOW`).
    fn is_symlink_at(dir: libc::c_int, name: &CStr) -> io::Result<bool> {
        // SAFETY: an all-zero `stat` is a valid value for fstatat to fill.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: a valid descriptor (or AT_FDCWD), a NUL-terminated name and a `stat` to fill.
        check(unsafe { libc::fstatat(dir, name.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW) })?;
        Ok(stat.st_mode & libc::S_IFMT == libc::S_IFLNK)
    }

    pub(super) fn try_exists_nofollow(path: &Path) -> io::Result<bool> {
        let at = match at(path, None) {
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(false),
            at => at?,
        };
        super::found(is_symlink_at(at.dirfd(), &at.name))
    }

    /// Flags that open a name itself (a symlink too, never followed) for its `fstat` only, with
    /// no read access asked: `O_PATH` on Linux, `O_EVTONLY | O_SYMLINK` on Apple's systems.
    /// Elsewhere none, and a name is read by path.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    const STAT_ONLY: Option<libc::c_int> = Some(libc::O_PATH | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    #[cfg(target_vendor = "apple")]
    const STAT_ONLY: Option<libc::c_int> =
        Some(libc::O_EVTONLY | libc::O_SYMLINK | libc::O_NONBLOCK | libc::O_CLOEXEC);
    #[cfg(not(any(target_os = "linux", target_os = "android", target_vendor = "apple")))]
    const STAT_ONLY: Option<libc::c_int> = None;

    /// The name opened in its folder reached from the held home (`STAT_ONLY`), then `fstat`:
    /// the metadata `std::fs::symlink_metadata` gives (on Linux both are `statx`, birth time
    /// included), of the held home's file.
    pub(super) fn symlink_metadata(path: &Path) -> io::Result<std::fs::Metadata> {
        let at = at(path, None)?;
        let (Some(dir), Some(flags)) = (&at.dir, STAT_ONLY) else {
            return std::fs::symlink_metadata(path);
        };
        // SAFETY: a valid descriptor and a NUL-terminated name.
        let fd = owned(unsafe { libc::openat(dir.as_raw_fd(), at.name.as_ptr(), flags) })?;
        File::from(fd).metadata()
    }

    pub(super) fn read_dir(path: &Path) -> io::Result<Vec<super::DirEntry>> {
        if crate::config::held_home_dir(path).is_none() {
            return std::fs::read_dir(path)?
                .map(|entry| {
                    let entry = entry?;
                    let kind = entry.file_type()?;
                    Ok(super::DirEntry {
                        name: entry.file_name(),
                        is_file: kind.is_file(),
                        is_dir: kind.is_dir(),
                        is_symlink: kind.is_symlink(),
                    })
                })
                .collect();
        }
        let at = at(path, None)?;
        // SAFETY: a valid descriptor and a NUL-terminated name. A final symlink is followed, as
        // `std::fs::read_dir` follows it.
        let folder = owned(unsafe {
            libc::openat(
                at.dirfd(),
                at.name.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
            )
        })?;
        read_dir_fd(&folder, path)
    }

    pub(super) fn read_dir_fd(folder: &OwnedFd, path: &Path) -> io::Result<Vec<super::DirEntry>> {
        let mut out = Vec::new();
        for name in list(folder)? {
            match read_entry_fd(folder.as_fd(), &name, path) {
                Ok(entry) => out.push(entry),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        Ok(out)
    }

    pub(super) fn read_entry_fd(
        folder: BorrowedFd<'_>,
        name: &OsStr,
        _path: &Path,
    ) -> io::Result<super::DirEntry> {
        #[cfg(test)]
        crate::config::startup_seams::entry_stat_error(&_path.join(name))?;
        // SAFETY: an all-zero `stat` is a valid value for fstatat to fill.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        let c_name = c(name)?;
        // SAFETY: a valid descriptor, a NUL-terminated name and a `stat` to fill.
        check(unsafe {
            libc::fstatat(folder.as_raw_fd(), c_name.as_ptr(), &mut stat, libc::AT_SYMLINK_NOFOLLOW)
        })?;
        Ok(super::DirEntry {
            name: name.to_os_string(),
            is_file: stat.st_mode & libc::S_IFMT == libc::S_IFREG,
            is_dir: stat.st_mode & libc::S_IFMT == libc::S_IFDIR,
            is_symlink: stat.st_mode & libc::S_IFMT == libc::S_IFLNK,
        })
    }

    pub(super) fn hard_link(original: &Path, link: &Path) -> io::Result<()> {
        let (original, link) = (at(original, None)?, at(link, None)?);
        // SAFETY: valid descriptors (or AT_FDCWD) and NUL-terminated names; flags 0 links a
        // symlink itself, never its target.
        check(unsafe {
            libc::linkat(
                original.dirfd(),
                original.name.as_ptr(),
                link.dirfd(),
                link.name.as_ptr(),
                0,
            )
        })
        .map(drop)
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

    fn directory_errno() -> Option<*mut libc::c_int> {
        // SAFETY: each function returns this thread's errno slot.
        #[cfg(any(target_vendor = "apple", target_os = "freebsd", target_os = "dragonfly"))]
        {
            Some(unsafe { libc::__error() })
        }
        #[cfg(target_os = "linux")]
        {
            Some(unsafe { libc::__errno_location() })
        }
        #[cfg(any(target_os = "android", target_os = "netbsd", target_os = "openbsd"))]
        {
            Some(unsafe { libc::__errno() })
        }
        #[cfg(not(any(
            target_vendor = "apple",
            target_os = "freebsd",
            target_os = "dragonfly",
            target_os = "linux",
            target_os = "android",
            target_os = "netbsd",
            target_os = "openbsd"
        )))]
        {
            None
        }
    }

    /// The names in `dir`, without `.` and `..`.
    pub(super) fn list(dir: &OwnedFd) -> io::Result<Vec<std::ffi::OsString>> {
        // fdopendir takes the descriptor it is given; it gets its own copy.
        let copy = dir.as_fd().try_clone_to_owned()?;
        // SAFETY: a valid descriptor whose ownership passes to the stream.
        let stream = unsafe { libc::fdopendir(copy.as_raw_fd()) };
        if stream.is_null() {
            return Err(io::Error::last_os_error());
        }
        std::mem::forget(copy); // closedir closes it
        let mut names = Vec::new();
        let errno = directory_errno();
        let done = loop {
            if let Some(errno) = errno {
                // SAFETY: this thread's errno slot. Zero distinguishes EOF from a read error.
                unsafe { *errno = 0 };
            }
            // SAFETY: a valid stream; the entry is read before the next readdir.
            let entry = unsafe { libc::readdir(stream) };
            if entry.is_null() {
                let error = errno.and_then(|errno| {
                    // SAFETY: this thread's errno slot, read before another syscall changes it.
                    let code = unsafe { *errno };
                    (code != 0).then(|| io::Error::from_raw_os_error(code))
                });
                #[cfg(test)]
                let error = crate::config::startup_seams::directory_read_error(error);
                break match error {
                    Some(error) => Err(error),
                    None => Ok(names),
                };
            }
            // SAFETY: d_name is NUL-terminated.
            let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
            if name != b"." && name != b".." {
                names.push(OsStr::from_bytes(name).to_os_string());
            }
        };
        // SAFETY: a stream fdopendir returned, closed once.
        unsafe { libc::closedir(stream) };
        done
    }
}
