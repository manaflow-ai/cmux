//! File helpers: atomic writes with a mode, directories with a mode, the
//! symlink swap behind every `current` flip, read-only package trees and
//! their removal.

use std::fs::{self, File, OpenOptions, TryLockError};
use std::io::{self, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_server_core::HostPath;

use crate::error::{IoContext, Result};
use crate::sys;

/// An acquired exclusive lock. Explicitly unlock before closing: a concurrent
/// fork can inherit the descriptor until exec, keeping a close-only lock alive.
#[derive(Debug)]
pub(crate) struct FileLock(File);

impl FileLock {
    pub(crate) fn try_acquire(file: File) -> std::result::Result<Self, TryLockError> {
        file.try_lock()?;
        Ok(Self(file))
    }
}

impl Drop for FileLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

/// A core `HostPath` as a local path.
pub fn local(path: &HostPath) -> PathBuf {
    PathBuf::from(path.as_str())
}

/// A unique sibling name for a temporary file next to `path`.
pub fn temp_sibling(path: &Path, tag: &str) -> PathBuf {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let mut nonce = [0u8; 6];
    let _ = getrandom::fill(&mut nonce);
    let nonce: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    path.with_file_name(format!(".{name}.{tag}.{}.{nonce}", std::process::id()))
}

fn open_new(path: &Path, mode: u32) -> io::Result<File> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(mode);
    }
    #[cfg(not(unix))]
    let _ = mode;
    options.open(path)
}

/// Sets the permission bits of `path` (Unix only; a no-op elsewhere).
pub fn set_mode(path: &Path, mode: u32) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(mode))
    }
    #[cfg(not(unix))]
    {
        let _ = (path, mode);
        Ok(())
    }
}

/// The permission bits of `path` (0 where there are none).
pub fn mode_of(meta: &fs::Metadata) -> u32 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        meta.permissions().mode() & 0o7777
    }
    #[cfg(not(unix))]
    {
        let _ = meta;
        0
    }
}

/// Writes `bytes` to `path` atomically: a new temporary file created with
/// `mode` (so a secret is never readable by others, not even briefly),
/// fsync, rename over `path`, fsync of the directory.
pub fn atomic_write(path: &Path, bytes: &[u8], mode: u32) -> Result<()> {
    let tmp = temp_sibling(path, "tmp");
    let result = (|| -> io::Result<()> {
        let mut file = open_new(&tmp, mode)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        set_mode(&tmp, mode)?;
        fs::rename(&tmp, path)?;
        if let Some(dir) = path.parent() {
            sys::fsync_dir(dir)?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result.ctx(path.display())
}

/// Copies `source` to `path` like [`atomic_write`]: a new temporary file
/// (`O_EXCL`, a random name, so a planted file or symlink there is never
/// written through), created with `mode`, fsync, one rename over `path`.
pub fn atomic_copy(source: &Path, path: &Path, mode: u32) -> Result<()> {
    let tmp = temp_sibling(path, "tmp");
    let result = (|| -> io::Result<()> {
        let mut from = File::open(source)?;
        let mut file = open_new(&tmp, mode)?;
        io::copy(&mut from, &mut file)?;
        file.sync_all()?;
        drop(file);
        set_mode(&tmp, mode)?;
        fs::rename(&tmp, path)?;
        if let Some(dir) = path.parent() {
            sys::fsync_dir(dir)?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result.ctx(path.display())
}

/// Like [`atomic_write`], but only when the content differs. Returns
/// whether it wrote. Anything but a plain file at `path` (a symlink, even
/// to the same bytes) is replaced, never kept or written through.
pub fn write_if_changed(path: &Path, bytes: &[u8], mode: u32) -> Result<bool> {
    let plain = fs::symlink_metadata(path).is_ok_and(|m| m.is_file());
    match fs::read(path) {
        Ok(old) if plain && old == bytes => {
            set_mode(path, mode).ctx(path.display())?;
            Ok(false)
        }
        _ => atomic_write(path, bytes, mode).map(|()| true),
    }
}

/// Creates `path` when it is missing: missing parents get `mode` (less the
/// umask), and `path` itself, created by one non-recursive `mkdir`, gets
/// exactly `mode`. An existing directory is left as it is, mode included,
/// also when another process creates it first (decision SV-R4: the server
/// never changes a directory it did not just create; the policy paths in
/// `cmux_server_core::access` are checked, and refused when wider, by
/// [`crate::access`]).
pub fn ensure_dir(path: &Path, mode: u32) -> Result<()> {
    if fs::metadata(path).is_ok_and(|m| m.is_dir()) {
        return Ok(());
    }
    let builder = |recursive: bool| {
        let mut builder = fs::DirBuilder::new();
        builder.recursive(recursive);
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            builder.mode(mode);
        }
        builder
    };
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        builder(true).create(parent).ctx(parent.display())?;
    }
    match builder(false).create(path) {
        Ok(()) => set_mode(path, mode).ctx(path.display()),
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists && path.is_dir() => Ok(()),
        Err(e) => Err(crate::error::Error::io(path.display(), e)),
    }
}

/// Points the symlink `link` at `target` with one `rename(2)`: a reader
/// sees the old or the new target, never a missing link.
pub fn swap_symlink(link: &Path, target: &Path) -> Result<()> {
    swap(link, target, false)
}

/// Pins older than this are removed on the next flip or GC.
pub const PIN_MAX_AGE: Duration = Duration::from_secs(10);
/// At most this many (the newest) pins are kept, so a burst of flips
/// inside [`PIN_MAX_AGE`] cannot grow the directory without bound. A reader
/// needs the pin only for the few flips during its own lookup.
pub const PIN_MAX_COUNT: usize = 64;

/// [`swap_symlink`] for a link that readers resolve while it flips (the
/// store's `current`). On macOS 26.5, `rename(2)` over a symlink makes a
/// concurrent `readlink`, `stat` or `open` of that path fail with EINVAL
/// while the replaced symlink's inode is freed. So the old symlink is first
/// hard-linked to `.<name>.pin.<pid>.<nonce>` (the link itself, not its
/// target), which keeps that inode alive through the rename. Each flip and
/// GC remove pins whose ctime is older than [`PIN_MAX_AGE`] and all but the
/// newest [`PIN_MAX_COUNT`].
pub fn swap_symlink_pinned(link: &Path, target: &Path) -> Result<()> {
    swap(link, target, true)?;
    // The flip is done; a pin that cannot be removed now is removed by the
    // next flip or GC, so it never turns a done flip into a failure.
    let _ = prune_pins(link, PIN_MAX_AGE, PIN_MAX_COUNT);
    Ok(())
}

fn swap(link: &Path, target: &Path, pin: bool) -> Result<()> {
    let tmp = temp_sibling(link, "swap");
    #[cfg(unix)]
    std::os::unix::fs::symlink(target, &tmp).ctx(tmp.display())?;
    #[cfg(not(unix))]
    return Err(crate::error::Error::internal(format!(
        "{}: symlink flips need a Unix platform; {} -> {} (pin {pin})",
        tmp.display(),
        link.display(),
        target.display()
    )));
    #[cfg(unix)]
    {
        if pin && fs::symlink_metadata(link).is_ok_and(|m| m.file_type().is_symlink()) {
            // Best effort: a file system without hard links still flips.
            let _ = hard_link_no_follow(link, &temp_sibling(link, "pin"));
        }
        if let Err(e) = fs::rename(&tmp, link) {
            let _ = fs::remove_file(&tmp);
            return Err(crate::error::Error::io(link.display(), e));
        }
        if let Some(dir) = link.parent() {
            sys::fsync_dir(dir).ctx(dir.display())?;
        }
        Ok(())
    }
}

/// `linkat(2)` without `AT_SYMLINK_FOLLOW`: a new name for the symlink
/// itself.
#[cfg(unix)]
fn hard_link_no_follow(existing: &Path, new: &Path) -> io::Result<()> {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    let c = |p: &Path| {
        CString::new(p.as_os_str().as_bytes()).map_err(|e| io::Error::other(e.to_string()))
    };
    let (from, to) = (c(existing)?, c(new)?);
    // SAFETY: both pointers come from live CStrings.
    let rc = unsafe { libc::linkat(libc::AT_FDCWD, from.as_ptr(), libc::AT_FDCWD, to.as_ptr(), 0) };
    if rc == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

/// Removes the pins of `link` whose ctime is at least `max_age` old, and
/// all but the newest `max_count` (`Duration::ZERO` or 0: all of them).
pub fn prune_pins(link: &Path, max_age: Duration, max_count: usize) -> Result<()> {
    let (Some(dir), Some(name)) = (link.parent(), link.file_name()) else { return Ok(()) };
    let prefix = format!(".{}.pin.", name.to_string_lossy());
    let Ok(entries) = fs::read_dir(dir) else { return Ok(()) };
    let now = SystemTime::now();
    let mut pins: Vec<(SystemTime, PathBuf)> = entries
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with(&prefix))
        .filter_map(|e| fs::symlink_metadata(e.path()).ok().map(|m| (ctime(&m), e.path())))
        .collect();
    // Newest first.
    pins.sort_by_key(|pin| std::cmp::Reverse(pin.0));
    for (i, (at, path)) in pins.iter().enumerate() {
        let old = now.duration_since(*at).unwrap_or(Duration::ZERO) >= max_age;
        if old || i >= max_count {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => {}
                Err(e) => return Err(crate::error::Error::io(path.display(), e)),
            }
        }
    }
    Ok(())
}

fn ctime(meta: &fs::Metadata) -> SystemTime {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let secs = u64::try_from(meta.ctime()).unwrap_or(0);
        let nanos = u32::try_from(meta.ctime_nsec()).unwrap_or(0);
        UNIX_EPOCH + Duration::new(secs, nanos)
    }
    #[cfg(not(unix))]
    {
        meta.modified().unwrap_or(UNIX_EPOCH)
    }
}

/// Removes write permission from every file and directory under `root`
/// (keeping execute bits), so a package is immutable after unpack.
pub fn make_read_only(root: &Path) -> Result<()> {
    for entry in fs::read_dir(root).ctx(root.display())? {
        let entry = entry.ctx(root.display())?;
        let path = entry.path();
        let meta = fs::symlink_metadata(&path).ctx(path.display())?;
        if meta.is_dir() {
            make_read_only(&path)?;
        } else if meta.is_file() {
            set_mode(&path, mode_of(&meta) & 0o555).ctx(path.display())?;
        }
    }
    set_mode(root, 0o555).ctx(root.display())
}

/// Removes `path` (file, symlink or tree). Read-only directories are made
/// writable first; symlinks are removed, never followed. Missing is fine.
pub fn remove_tree(path: &Path) -> Result<()> {
    let meta = match fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(crate::error::Error::io(path.display(), e)),
    };
    if !meta.is_dir() {
        return fs::remove_file(path).ctx(path.display());
    }
    set_mode(path, 0o700).ctx(path.display())?;
    for entry in fs::read_dir(path).ctx(path.display())? {
        remove_tree(&entry.ctx(path.display())?.path())?;
    }
    fs::remove_dir(path).ctx(path.display())
}

/// Removes the file at `path` only when, as it goes, it is still one
/// `ours` accepts. Returns false when there is none.
///
/// Every step goes through descriptors, never a path read twice (Codex
/// R-002): cmux opens the file's folder (this account's, writable by no one
/// else by mode or ACL), makes a new folder in it that only this account
/// can enter, and moves the file there (rename moves the entry itself and
/// never follows a symlink). There no other account can swap the entry,
/// so the file checked is the file removed. It must be a plain file of
/// this account's that no other account can write (mode or ACL) and that
/// has no other name, and its bytes must be ones `ours` accepts. Anything
/// else goes back to its name, never over a new entry there, and the call
/// fails. A descriptor another account opened for writing before all this
/// (when it still could) is not revoked by it: it can change the bytes of
/// the file being removed, never make cmux remove another file.
#[cfg(unix)]
pub fn remove_if_unchanged(path: &Path, ours: impl Fn(&[u8]) -> bool) -> Result<bool> {
    use std::io::Read as _;
    use std::os::fd::AsRawFd as _;
    use std::os::unix::ffi::OsStrExt as _;
    use std::os::unix::fs::MetadataExt as _;

    use crate::error::Error;

    let (Some(dir), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(Error::rejected(format!("{} names no file", path.display())));
    };
    let dir = if dir.as_os_str().is_empty() { Path::new(".") } else { dir };
    let io_err = |e: io::Error| Error::io(path.display(), e);
    let cname = cstring(name.as_bytes()).map_err(io_err)?;
    let cdir = cstring(dir.as_os_str().as_bytes()).map_err(io_err)?;
    let folder = match open_dir(libc::AT_FDCWD, &cdir) {
        Ok(folder) => folder,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(Error::io(dir.display(), e)),
    };
    let meta = folder.metadata().ctx(dir.display())?;
    let others_write = |file: &File, mode: u32| {
        mode & 0o022 != 0 || crate::acl::fd_write_grants(file).unwrap_or(true)
    };
    if meta.uid() != sys::euid() || others_write(&folder, meta.mode()) {
        return Err(Error::rejected(format!(
            "{} (the folder of {}) is not yours alone (owner uid {}, mode {:o}, or an ACL entry that allows writing), so cmux removes nothing there",
            dir.display(),
            path.display(),
            meta.uid(),
            meta.mode() & 0o7777
        )));
    }
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let hold_name = format!(".cmux-removing.{}.{nanos}", std::process::id());
    let hold = Hold::make(&folder, dir, &hold_name)?;
    let hfd = hold.dir.as_raw_fd();
    let fd = folder.as_raw_fd();
    // SAFETY: both descriptors are open folders and cname a valid C string.
    if unsafe { libc::renameat(fd, cname.as_ptr(), hfd, cname.as_ptr()) } != 0 {
        let e = io::Error::last_os_error();
        hold.drop_empty()?;
        return match e.kind() {
            io::ErrorKind::NotFound => Ok(false),
            _ => Err(io_err(e)),
        };
    }
    let held = hold.path.join(name);
    // Why the held entry is not one to remove; None: remove it.
    let refused: Option<&str> = match open_file(hfd, &cname) {
        Err(_) => Some("is no longer a plain file"),
        Ok(mut file) => match file.metadata() {
            Err(_) => Some("cannot be read"),
            Ok(m) if !m.is_file() || m.uid() != sys::euid() => {
                Some("is no longer a plain file of this account's")
            }
            Ok(m) if others_write(&file, m.mode()) => {
                Some("can be written by other accounts (mode or ACL)")
            }
            Ok(m) if m.nlink() != 1 => Some("has another name (a hard link) cmux never checked"),
            Ok(_) => {
                let mut bytes = Vec::new();
                match file.read_to_end(&mut bytes) {
                    Ok(_) if ours(&bytes) => None,
                    Ok(_) => Some("changed and is no longer the file cmux wrote"),
                    Err(_) => Some("cannot be read"),
                }
            }
        },
    };
    let why = match refused {
        None => {
            // SAFETY: hfd is open and cname a valid C string.
            if unsafe { libc::unlinkat(hfd, cname.as_ptr(), 0) } == 0 {
                hold.drop_empty()?;
                return Ok(true);
            }
            let e = io::Error::last_os_error();
            format!("could not be removed ({e})")
        }
        Some(why) => why.to_owned(),
    };
    // Back to its name, never over an entry that took the name meanwhile.
    match rename_noreplace(hfd, &cname, fd) {
        Ok(()) => {
            hold.drop_empty()?;
            Err(Error::rejected(format!(
                "{} {why}, so cmux left it in place; nothing else was removed",
                path.display()
            )))
        }
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Err(Error::rejected(format!(
            "{} {why}; a new entry took its name meanwhile, so cmux kept the old one at {}",
            path.display(),
            held.display()
        ))),
        Err(e) => Err(Error::rejected(format!(
            "{} {why}, and cmux could not put it back ({e}): it is at {}",
            path.display(),
            held.display()
        ))),
    }
}

/// The private folder [`remove_if_unchanged`] holds a file in: made with
/// mode 0700 in the unit folder, checked on its descriptor, and removed
/// when it is empty again, also when a step fails (its drop).
#[cfg(unix)]
struct Hold {
    dir: File,
    parent: std::os::fd::RawFd,
    name: std::ffi::CString,
    path: PathBuf,
    done: bool,
}

#[cfg(unix)]
impl Hold {
    fn make(parent: &File, parent_path: &Path, name: &str) -> Result<Hold> {
        use std::os::fd::AsRawFd as _;
        use std::os::unix::fs::MetadataExt as _;

        use crate::error::Error;

        let path = parent_path.join(name);
        let cname = cstring(name.as_bytes()).map_err(|e| Error::io(path.display(), e))?;
        let pfd = parent.as_raw_fd();
        // SAFETY: pfd is open and cname a valid C string.
        if unsafe { libc::mkdirat(pfd, cname.as_ptr(), 0o700) } != 0 {
            return Err(Error::io(path.display(), io::Error::last_os_error()));
        }
        let rmdir = || {
            // SAFETY: pfd is open and cname a valid C string.
            unsafe { libc::unlinkat(pfd, cname.as_ptr(), libc::AT_REMOVEDIR) };
        };
        let dir = match open_dir(pfd, &cname) {
            Ok(dir) => dir,
            Err(e) => {
                rmdir();
                return Err(Error::io(path.display(), e));
            }
        };
        let private = dir.metadata().is_ok_and(|m| m.uid() == sys::euid() && m.mode() & 0o077 == 0)
            && !crate::acl::fd_write_grants(&dir).unwrap_or(true);
        if !private {
            rmdir();
            return Err(Error::rejected(format!(
                "{} is not a folder only this account can enter (mode, owner or an inherited ACL entry), so cmux removes nothing",
                path.display()
            )));
        }
        Ok(Hold { dir, parent: pfd, name: cname, path, done: false })
    }

    /// Removes the folder, which must be empty now.
    fn drop_empty(mut self) -> Result<()> {
        self.done = true;
        // SAFETY: the parent descriptor outlives self; name is a C string.
        if unsafe { libc::unlinkat(self.parent, self.name.as_ptr(), libc::AT_REMOVEDIR) } != 0 {
            return Err(crate::error::Error::io(self.path.display(), io::Error::last_os_error()));
        }
        Ok(())
    }
}

#[cfg(unix)]
impl Drop for Hold {
    fn drop(&mut self) {
        if !self.done {
            // Only an empty folder goes: one that still holds a file stays,
            // and the error that brought us here names it.
            // SAFETY: the parent descriptor outlives self; name is a C string.
            unsafe { libc::unlinkat(self.parent, self.name.as_ptr(), libc::AT_REMOVEDIR) };
        }
    }
}

/// Moves the entry `name` from the folder `from` to the folder `to`, under
/// the same name, failing with `AlreadyExists` rather than replacing an
/// entry there.
#[cfg(unix)]
fn rename_noreplace(
    from: std::os::fd::RawFd,
    name: &std::ffi::CStr,
    to: std::os::fd::RawFd,
) -> io::Result<()> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        // SAFETY: both descriptors are open folders and name a C string.
        let rc = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                from,
                name.as_ptr(),
                to,
                name.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        if rc == 0 {
            return Ok(());
        }
        let e = io::Error::last_os_error();
        // An old kernel or a file system without it: link, then unlink.
        if !matches!(e.raw_os_error(), Some(libc::ENOSYS | libc::EINVAL | libc::EOPNOTSUPP)) {
            return Err(e);
        }
    }
    #[cfg(target_os = "macos")]
    {
        // SAFETY: both descriptors are open folders and name a C string.
        let rc = unsafe {
            libc::renameatx_np(from, name.as_ptr(), to, name.as_ptr(), libc::RENAME_EXCL)
        };
        if rc == 0 {
            return Ok(());
        }
        let e = io::Error::last_os_error();
        if !matches!(e.raw_os_error(), Some(libc::ENOTSUP | libc::EINVAL)) {
            return Err(e);
        }
    }
    // A hard link fails when the name is taken (and for a folder).
    // SAFETY: both descriptors are open folders and name a C string.
    if unsafe { libc::linkat(from, name.as_ptr(), to, name.as_ptr(), 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: as above.
    if unsafe { libc::unlinkat(from, name.as_ptr(), 0) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(unix)]
fn cstring(bytes: &[u8]) -> io::Result<std::ffi::CString> {
    std::ffi::CString::new(bytes).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))
}

/// The folder `name` in the folder `at` (`AT_FDCWD`: the working folder),
/// opened as a folder. A final symlink is followed only from `AT_FDCWD`
/// (a unit folder may be a symlink); in a held folder it is refused.
#[cfg(unix)]
fn open_dir(at: libc::c_int, name: &std::ffi::CStr) -> io::Result<File> {
    use std::os::fd::FromRawFd as _;
    let mut flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC;
    if at != libc::AT_FDCWD {
        flags |= libc::O_NOFOLLOW;
    }
    // SAFETY: name is a valid C string; the result is checked.
    let fd = unsafe { libc::openat(at, name.as_ptr(), flags) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd was just opened and is owned here.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// The entry `name` in the folder `at`, opened to read without following
/// a symlink or blocking on a FIFO.
#[cfg(unix)]
fn open_file(at: libc::c_int, name: &std::ffi::CStr) -> io::Result<File> {
    use std::os::fd::FromRawFd as _;
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;
    // SAFETY: name is a valid C string; the result is checked.
    let fd = unsafe { libc::openat(at, name.as_ptr(), flags) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fd was just opened and is owned here.
    Ok(unsafe { File::from_raw_fd(fd) })
}

/// [`remove_if_unchanged`] where there are no descriptor calls: the
/// file is renamed to a private name in its folder, read, then removed.
#[cfg(not(unix))]
pub fn remove_if_unchanged(path: &Path, ours: impl Fn(&[u8]) -> bool) -> Result<bool> {
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.subsec_nanos());
    let claimed =
        path.with_file_name(format!(".{name}.cmux-removing.{}.{nanos}", std::process::id()));
    match fs::rename(path, &claimed) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(false),
        Err(e) => return Err(crate::error::Error::io(path.display(), e)),
    }
    if read_plain_file(&claimed).is_some_and(|bytes| ours(&bytes)) {
        fs::remove_file(&claimed).ctx(claimed.display())?;
        return Ok(true);
    }
    let back = fs::hard_link(&claimed, path).is_ok() && fs::remove_file(&claimed).is_ok();
    Err(crate::error::Error::rejected(if back {
        format!(
            "{} changed while cmux uninstalled it and is no longer the file cmux wrote, so cmux left it in place; nothing else was removed",
            path.display()
        )
    } else {
        format!(
            "{} changed while cmux uninstalled it and is no longer the file cmux wrote; a new file took its name, so cmux kept the changed one at {}",
            path.display(),
            claimed.display()
        )
    }))
}

/// The bytes of the plain file at `path` that this account owns, read
/// through one descriptor opened without following a symlink (or blocking
/// on a FIFO); None for anything else.
#[cfg(not(unix))]
fn read_plain_file(path: &Path) -> Option<Vec<u8>> {
    use std::io::Read as _;
    let mut file = OpenOptions::new().read(true).open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || sys::owner_uid(&meta) != sys::euid() {
        return None;
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

/// True when `path` exists (without following a final symlink).
pub fn exists_no_follow(path: &Path) -> bool {
    fs::symlink_metadata(path).is_ok()
}
