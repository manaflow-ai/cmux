//! Replace several private files as one change: every new file is staged
//! first, and the live files change only once all of them are staged. A
//! failure before that leaves every live file as it was; a failure while
//! they are put in place puts back the ones already replaced.
//!
//! Each folder below `home` is opened relative to the one above it with
//! `O_NOFOLLOW` (made 0700 when missing), must be a folder this user owns,
//! and the last is set to 0700. Each new file is a fresh 0600 file in its
//! folder, written and synced, then renamed over its target by the folder's
//! descriptor, so a reader sees the old file or the new one and no path is
//! resolved twice. Before the first rename each live file is hard-linked
//! aside in its own folder, which is what a rollback renames back.
//!
//! A write may name the live bytes it was computed from ([`Expect`]): when
//! the live file differs once everything is staged, nothing is replaced and
//! the error is [`super::files::is_changed`]. The caller serializes its own requests; this
//! only catches an edit from outside them.

use std::ffi::{CString, OsStr};
use std::io::{self, Read as _, Write as _};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};

use super::files::{Changed, Expect, Planned};

#[cfg(test)]
thread_local! {
    /// Tests only: fail the step with this index (each staged write and
    /// each rename is one step, in order).
    pub(super) static FAIL_AT: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
    /// Tests only: run after every file is staged and before the live files
    /// are compared, as an outside edit would.
    pub(super) static BEFORE_COMMIT: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
}

/// One file staged next to its target.
struct Staged {
    directory: OwnedFd,
    file_name: CString,
    temporary: CString,
    /// The live file's hard link, when there was a live file.
    backup: Option<CString>,
    /// The new file is in place.
    placed: bool,
}

/// Replace each planned file, all or none (see the module doc).
pub fn replace_all(home: &Path, writes: &[Planned<'_>]) -> io::Result<()> {
    replace_all_with(home, writes, true)
}

/// [`replace_all`] for the daemon's own state: no test fault applies.
pub fn replace_state(home: &Path, relative: &Path, bytes: &[u8]) -> io::Result<()> {
    replace_all_with(home, &[Planned { relative, bytes, expect: Expect::Anything }], false)
}

fn replace_all_with(home: &Path, writes: &[Planned<'_>], faults: bool) -> io::Result<()> {
    let mut step = faults.then_some(0_usize);
    let mut staged = Vec::with_capacity(writes.len());
    for write in writes {
        match fault(&mut step).and_then(|()| stage(home, write.relative, write.bytes)) {
            Ok(file) => staged.push(file),
            Err(error) => {
                discard(&staged);
                return Err(error);
            }
        }
    }
    #[cfg(test)]
    if faults {
        BEFORE_COMMIT.with(|hook| hook.borrow_mut().as_mut().map(|hook| hook()));
    }
    let unchanged = staged.iter().zip(writes).try_for_each(|(file, write)| match write.expect {
        Expect::Anything => Ok(()),
        Expect::Exactly(expected) => {
            if live_bytes(file)?.as_deref().map(Vec::as_slice) == expected {
                Ok(())
            } else {
                Err(io::Error::other(Changed))
            }
        }
    });
    if let Err(error) = unchanged {
        discard(&staged);
        return Err(error);
    }
    if let Err(error) = staged.iter_mut().try_for_each(keep_backup) {
        discard(&staged);
        return Err(error);
    }
    let mut failed = None;
    for file in &mut staged {
        if let Err(error) = fault(&mut step).and_then(|()| place(file)) {
            failed = Some(error);
            break;
        }
        file.placed = true;
    }
    if let Some(error) = failed {
        roll_back(&staged);
        discard(&staged);
        return Err(error);
    }
    if let Some(error) = staged.iter().find_map(|file| sync_dir(&file.directory).err()) {
        roll_back(&staged);
        discard(&staged);
        return Err(error);
    }
    discard(&staged);
    for file in &staged {
        // The renames are durable already; this only makes the removed
        // backups durable, so a failure is not the caller's.
        let _ = sync_dir(&file.directory);
    }
    Ok(())
}

fn fault(step: &mut Option<usize>) -> io::Result<()> {
    let Some(index) = step.as_mut().map(|step| {
        *step += 1;
        *step - 1
    }) else {
        return Ok(());
    };
    #[cfg(test)]
    if FAIL_AT.with(std::cell::Cell::get) == Some(index) {
        return Err(io::Error::other("injected failure"));
    }
    #[cfg(not(test))]
    let _ = index;
    Ok(())
}

fn c_name(name: &OsStr) -> io::Result<CString> {
    CString::new(name.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

fn check(result: libc::c_int) -> io::Result<libc::c_int> {
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(result) }
}

fn open_dir_at(parent: libc::c_int, name: &CString) -> io::Result<OwnedFd> {
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `name` is NUL-terminated; a non-negative result is an owned fd.
    let fd = check(unsafe { libc::openat(parent, name.as_ptr(), flags) })?;
    // SAFETY: `fd` was just opened and is owned by nobody else.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

fn owned_by_us(fd: &OwnedFd) -> io::Result<()> {
    let mut status = std::mem::MaybeUninit::<libc::stat>::uninit();
    // SAFETY: `status` is a valid out pointer for fstat.
    check(unsafe { libc::fstat(fd.as_raw_fd(), status.as_mut_ptr()) })?;
    // SAFETY: fstat succeeded, so `status` is initialized.
    let status = unsafe { status.assume_init() };
    // SAFETY: geteuid has no preconditions and cannot fail.
    if status.st_uid != unsafe { libc::geteuid() } {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "folder is not ours"));
    }
    Ok(())
}

fn sync_dir(directory: &OwnedFd) -> io::Result<()> {
    // SAFETY: `directory` is an open folder.
    check(unsafe { libc::fsync(directory.as_raw_fd()) }).map(|_| ())
}

/// A name for a sibling of `file_name`: `.NAME.<random>.<kind>`.
fn sibling(file_name: &CString, kind: &str) -> io::Result<CString> {
    let suffix =
        super::seal::fresh_nonce().map_err(|_| io::Error::other("no system random source"))?;
    let mut name = b".".to_vec();
    name.extend_from_slice(file_name.as_bytes());
    name.extend_from_slice(format!(".{suffix}.{kind}").as_bytes());
    CString::new(name).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

/// Open (making) the folders down to `relative`'s, then write and sync its
/// bytes to a fresh 0600 file there.
fn stage(home: &Path, relative: &Path, bytes: &[u8]) -> io::Result<Staged> {
    let mut names = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(name) => names.push(c_name(name)?),
            _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a plain path")),
        }
    }
    let file_name =
        names.pop().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?;
    let home = c_name(home.as_os_str())?;
    let mut directory = open_dir_at(libc::AT_FDCWD, &home)?;
    owned_by_us(&directory)?;
    for name in &names {
        // SAFETY: `name` is NUL-terminated and `directory` is an open folder.
        let made = unsafe { libc::mkdirat(directory.as_raw_fd(), name.as_ptr(), 0o700) };
        if made < 0 {
            let error = io::Error::last_os_error();
            if error.kind() != io::ErrorKind::AlreadyExists {
                return Err(error);
            }
        }
        directory = open_dir_at(directory.as_raw_fd(), name)?;
        owned_by_us(&directory)?;
    }
    // SAFETY: `directory` is an open folder this user owns.
    check(unsafe { libc::fchmod(directory.as_raw_fd(), 0o700) })?;

    let temporary = sibling(&file_name, "tmp")?;
    let flags = libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `temporary` is NUL-terminated; mode is passed as the variadic third argument.
    let fd = check(unsafe {
        libc::openat(directory.as_raw_fd(), temporary.as_ptr(), flags, 0o600 as libc::c_uint)
    })?;
    // SAFETY: `fd` was just opened and is owned by nobody else.
    let mut file = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let staged = Staged { directory, file_name, temporary, backup: None, placed: false };
    if let Err(error) = file.write_all(bytes).and_then(|()| file.sync_all()) {
        discard(std::slice::from_ref(&staged));
        return Err(error);
    }
    Ok(staged)
}

/// The live file's bytes, or `None` when there is none. A symlink in its
/// place counts as changed.
fn live_bytes(file: &Staged) -> io::Result<Option<zeroize::Zeroizing<Vec<u8>>>> {
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `file_name` is NUL-terminated and relative to the open folder.
    let fd = unsafe { libc::openat(file.directory.as_raw_fd(), file.file_name.as_ptr(), flags) };
    if fd < 0 {
        let error = io::Error::last_os_error();
        return match error.kind() {
            io::ErrorKind::NotFound => Ok(None),
            _ if error.raw_os_error() == Some(libc::ELOOP) => Err(io::Error::other(Changed)),
            _ => Err(error),
        };
    }
    // SAFETY: `fd` was just opened and is owned by nobody else.
    let mut live = std::fs::File::from(unsafe { OwnedFd::from_raw_fd(fd) });
    let mut bytes = zeroize::Zeroizing::new(Vec::new());
    live.read_to_end(&mut bytes)?;
    Ok(Some(bytes))
}

/// Hard-link the live file (if any) aside, so a rollback can put it back.
fn keep_backup(file: &mut Staged) -> io::Result<()> {
    let backup = sibling(&file.file_name, "bak")?;
    let directory = file.directory.as_raw_fd();
    // SAFETY: both names are NUL-terminated and relative to the same open
    // folder; flag 0 links a symlink itself, never its target.
    let linked =
        unsafe { libc::linkat(directory, file.file_name.as_ptr(), directory, backup.as_ptr(), 0) };
    if linked == 0 {
        file.backup = Some(backup);
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.kind() == io::ErrorKind::NotFound { Ok(()) } else { Err(error) }
}

fn place(file: &Staged) -> io::Result<()> {
    let directory = file.directory.as_raw_fd();
    // SAFETY: both names are NUL-terminated and relative to the same open folder.
    check(unsafe {
        libc::renameat(directory, file.temporary.as_ptr(), directory, file.file_name.as_ptr())
    })
    .map(|_| ())
}

/// Put back every file already replaced: the backup over it, or remove it
/// when there was no live file. Best effort, newest first.
fn roll_back(staged: &[Staged]) {
    for file in staged.iter().rev().filter(|file| file.placed) {
        let directory = file.directory.as_raw_fd();
        match &file.backup {
            // SAFETY: both names are NUL-terminated and relative to the same open folder.
            Some(backup) => unsafe {
                libc::renameat(directory, backup.as_ptr(), directory, file.file_name.as_ptr());
            },
            // SAFETY: `file_name` is NUL-terminated and relative to the open folder.
            None => unsafe {
                libc::unlinkat(directory, file.file_name.as_ptr(), 0);
            },
        }
        let _ = sync_dir(&file.directory);
    }
}

/// Remove every temporary and backup left (a name already renamed away is
/// simply gone).
fn discard(staged: &[Staged]) {
    for file in staged {
        let directory = file.directory.as_raw_fd();
        for name in std::iter::once(&file.temporary).chain(file.backup.as_ref()) {
            // SAFETY: `name` is NUL-terminated and relative to the open folder.
            unsafe { libc::unlinkat(directory, name.as_ptr(), 0) };
        }
    }
}
