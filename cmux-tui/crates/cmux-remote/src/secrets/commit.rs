//! Replace several private files as one change: every new file is staged
//! first, and the live files change only once all of them are staged. A
//! failure before that leaves every live file as it was; a failure while
//! they are put in place puts back the ones already replaced.
//!
//! Each folder below `home` is opened relative to the one above it with
//! `O_NOFOLLOW` (made 0700 when missing, its parent synced), must be a
//! folder this user owns, and the last is set to 0700. Each new file is a
//! fresh 0600 file in its folder, written and synced, then renamed over its
//! target by the folder's descriptor, so a reader sees the old file or the
//! new one and no path is resolved twice. Before the first rename each live
//! file is hard-linked aside in its own folder, which is what a rollback
//! renames back.
//!
//! A write may name the live bytes it was computed from ([`Expect`]). On
//! Linux it is put in place with `RENAME_EXCHANGE` and the file it swapped
//! out is compared: anything else (an outside edit at any moment before the
//! swap) is swapped straight back and the error is
//! [`super::files::is_changed`]. A [`Guard`] names a file that is read,
//! never written, and must still hold its bytes once every file is in place.
//! The caller holds the request lock ([`super::Lock`]); this only catches
//! edits from outside it.

use std::ffi::{CString, OsStr};
use std::io::{self, Read as _, Write as _};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::path::{Component, Path};

use zeroize::Zeroizing;

use super::files::{Changed, Expect, Guard, Planned};

/// Tests only: [`AFTER_PLACE`]'s hook.
#[cfg(test)]
pub(super) type PlaceHook = Box<dyn FnMut(usize)>;

#[cfg(test)]
thread_local! {
    /// Tests only: fail the step with this index (each staged write and
    /// each rename is one step, in order).
    pub(super) static FAIL_AT: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
    /// Tests only: run after every file is staged and backed up, right
    /// before the first rename, as an outside edit would.
    pub(super) static BEFORE_COMMIT: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
    /// Tests only: run with a file's index once it is in place, as an
    /// outside edit would.
    pub(super) static AFTER_PLACE: std::cell::RefCell<Option<PlaceHook>> =
        const { std::cell::RefCell::new(None) };
    /// Tests only: run between a swap and the swap that undoes it, as an
    /// outside save would.
    pub(super) static BETWEEN_SWAPS: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
}

/// How a staged file was put in place, which is how a rollback undoes it.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Placed {
    No,
    /// Renamed over the target; the old file, if any, is at `backup`.
    Renamed,
    /// Swapped with the target; the old file is at `temporary` now.
    Exchanged,
}

/// One file staged next to its target.
struct Staged {
    directory: OwnedFd,
    file_name: CString,
    temporary: CString,
    /// The live file's hard link, when there was a live file.
    backup: Option<CString>,
    placed: Placed,
}

/// Replace each planned file, all or none, while every guard still holds
/// (see the module doc).
pub fn replace_all(home: &Path, writes: &[Planned<'_>], guards: &[Guard<'_>]) -> io::Result<()> {
    replace_all_with(home, writes, guards, true)
}

/// [`replace_all`] for the daemon's own state: no test fault applies.
pub fn replace_state(home: &Path, relative: &Path, bytes: &[u8]) -> io::Result<()> {
    replace_all_with(home, &[Planned { relative, bytes, expect: Expect::Anything }], &[], false)
}

fn replace_all_with(
    home: &Path,
    writes: &[Planned<'_>],
    guards: &[Guard<'_>],
    faults: bool,
) -> io::Result<()> {
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
    if let Err(error) = staged.iter_mut().try_for_each(keep_backup) {
        discard(&staged);
        return Err(error);
    }
    #[cfg(test)]
    if faults {
        BEFORE_COMMIT.with(|hook| hook.borrow_mut().as_mut().map(|hook| hook()));
    }
    let mut failed = None;
    #[cfg_attr(not(test), allow(unused_variables))]
    for (index, (file, write)) in staged.iter_mut().zip(writes).enumerate() {
        let (placed, result) = match fault(&mut step) {
            Ok(()) => place(file, write.expect, write.bytes),
            Err(error) => (Placed::No, Err(error)),
        };
        file.placed = placed;
        if let Err(error) = result {
            failed = Some(error);
            break;
        }
        #[cfg(test)]
        if faults {
            AFTER_PLACE.with(|hook| hook.borrow_mut().as_mut().map(|hook| hook(index)));
        }
    }
    let failed = failed
        .or_else(|| guards.iter().find_map(|guard| check_guard(home, guard).err()))
        .or_else(|| staged.iter().find_map(|file| sync_dir(&file.directory).err()));
    if let Some(error) = failed {
        roll_back(&staged, writes);
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
        } else {
            // A new folder's entry is durable only once its parent is synced.
            sync_dir(&directory)?;
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
    let staged = Staged { directory, file_name, temporary, backup: None, placed: Placed::No };
    if let Err(error) = file.write_all(bytes).and_then(|()| file.sync_all()) {
        discard(std::slice::from_ref(&staged));
        return Err(error);
    }
    Ok(staged)
}

/// The bytes of `name` in `directory`, or `None` when there is none. A
/// symlink in its place counts as changed.
fn read_at(directory: &OwnedFd, name: &CString) -> io::Result<Option<Zeroizing<Vec<u8>>>> {
    let flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `name` is NUL-terminated and relative to the open folder.
    let fd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
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
    let mut bytes = Zeroizing::new(Vec::new());
    live.read_to_end(&mut bytes)?;
    Ok(Some(bytes))
}

/// A guard's file must still hold its bytes. It is opened the way
/// [`stage`] opens a target: folder by folder, never through a symlink.
fn check_guard(home: &Path, guard: &Guard<'_>) -> io::Result<()> {
    let mut names = Vec::new();
    for component in guard.relative.components() {
        match component {
            Component::Normal(name) => names.push(c_name(name)?),
            _ => return Err(io::Error::new(io::ErrorKind::InvalidInput, "not a plain path")),
        }
    }
    let file_name =
        names.pop().ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "no file name"))?;
    let mut directory = open_dir_at(libc::AT_FDCWD, &c_name(home.as_os_str())?)?;
    for name in &names {
        directory = match open_dir_at(directory.as_raw_fd(), name) {
            Ok(directory) => directory,
            Err(error) if error.kind() == io::ErrorKind::NotFound && guard.expect.is_none() => {
                return Ok(());
            }
            Err(_) => return Err(io::Error::other(Changed)),
        };
    }
    if read_at(&directory, &file_name)?.as_deref().map(Vec::as_slice) == guard.expect {
        Ok(())
    } else {
        Err(io::Error::other(Changed))
    }
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

/// Put `file` in place: renamed over its target, or, when `expect` names
/// the bytes it must replace, swapped with it and checked (see the module
/// doc). Says how far it got, so a rollback can undo even a failed step.
fn place(file: &Staged, expect: Expect<'_>, ours: &[u8]) -> (Placed, io::Result<()>) {
    let directory = file.directory.as_raw_fd();
    let rename =
        |flags: libc::c_uint| rename_at(directory, &file.temporary, &file.file_name, flags);
    let renamed = |result: io::Result<()>| match result {
        Ok(()) => (Placed::Renamed, Ok(())),
        Err(error) => (Placed::No, Err(error)),
    };
    let Expect::Exactly(expected) = expect else {
        return renamed(rename(0));
    };
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        let changed = |error: io::Error, kind| {
            if error.kind() == kind { io::Error::other(Changed) } else { error }
        };
        let Some(expected) = expected else {
            // Only where there is no file: an outside create wins.
            return renamed(
                rename(libc::RENAME_NOREPLACE)
                    .map_err(|error| changed(error, io::ErrorKind::AlreadyExists)),
            );
        };
        if let Err(error) = rename(libc::RENAME_EXCHANGE) {
            return (Placed::No, Err(changed(error, io::ErrorKind::NotFound)));
        }
        // The file swapped out is exactly what was live at the swap.
        let swapped = read_at(&file.directory, &file.temporary);
        if matches!(&swapped, Ok(Some(bytes)) if bytes.as_slice() == expected) {
            return (Placed::Exchanged, Ok(()));
        }
        let error = swapped.err().unwrap_or_else(|| io::Error::other(Changed));
        between_swaps();
        match rename(libc::RENAME_EXCHANGE) {
            Ok(()) => {
                settle(file, &file.temporary, ours, &[ours]);
                (Placed::No, Err(error))
            }
            // Still swapped: the rollback puts the old file back.
            Err(_) => (Placed::Exchanged, Err(error)),
        }
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        // No atomic swap here: compare, then rename, under the caller's
        // request lock (a writer outside it can still race the rename).
        match read_at(&file.directory, &file.file_name) {
            Ok(live) if live.as_deref().map(Vec::as_slice) == expected => renamed(rename(0)),
            Ok(_) => (Placed::No, Err(io::Error::other(Changed))),
            Err(error) => (Placed::No, Err(error)),
        }
    }
}

/// `renameat`, or `renameat2` with `flags` where there are any.
fn rename_at(
    directory: libc::c_int,
    from: &CString,
    to: &CString,
    flags: libc::c_uint,
) -> io::Result<()> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if flags != 0 {
        // SAFETY: both names are NUL-terminated and relative to the same open folder.
        return check(unsafe {
            libc::renameat2(directory, from.as_ptr(), directory, to.as_ptr(), flags)
        })
        .map(|_| ());
    }
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let _ = flags;
    // SAFETY: both names are NUL-terminated and relative to the same open folder.
    check(unsafe { libc::renameat(directory, from.as_ptr(), directory, to.as_ptr()) }).map(|_| ())
}

/// Put back every file already replaced, newest first: the old file over
/// it, or none when there was none. Best effort, and only while the live
/// file is still ours: an outside save after it went in place is kept.
fn roll_back(staged: &[Staged], writes: &[Planned<'_>]) {
    for (file, write) in staged.iter().zip(writes).rev() {
        let old = match file.placed {
            Placed::No => continue,
            Placed::Renamed => file.backup.as_ref(),
            Placed::Exchanged => Some(&file.temporary),
        };
        let expected = match write.expect {
            Expect::Exactly(expected) => expected,
            Expect::Anything => None,
        };
        undo(file, old, write.bytes, expected);
        let _ = sync_dir(&file.directory);
    }
}

/// Undo one placed file: swap `old` back in (or move ours aside when there
/// was none) and check that what came out is our bytes; anything else is an
/// outside save, which goes back in place ([`settle`]).
#[cfg(any(target_os = "linux", target_os = "android"))]
fn undo(file: &Staged, old: Option<&CString>, ours: &[u8], expected: Option<&[u8]>) {
    let directory = file.directory.as_raw_fd();
    match old {
        Some(old) => {
            if rename_at(directory, old, &file.file_name, libc::RENAME_EXCHANGE).is_ok() {
                between_swaps();
                // The old file is ours to remove only when it is the one the
                // change read.
                let removable: Vec<&[u8]> = std::iter::once(ours).chain(expected).collect();
                settle(file, old, ours, &removable);
            }
        }
        None => {
            let Ok(aside) = sibling(&file.file_name, "undo") else {
                return;
            };
            if rename_at(directory, &file.file_name, &aside, libc::RENAME_NOREPLACE).is_err() {
                return;
            }
            if is_ours(file, &aside, &[ours]) {
                // SAFETY: `aside` is NUL-terminated and relative to the open folder.
                unsafe { libc::unlinkat(directory, aside.as_ptr(), 0) };
            } else if rename_at(directory, &aside, &file.file_name, libc::RENAME_NOREPLACE).is_err()
            {
                keep(file, &aside);
            }
        }
    }
}

/// `holder` has just been swapped with the live file and should hold our
/// bytes. When it doesn't, an outside save landed in between: it is swapped
/// back in, and whatever then comes out that isn't one of `removable` is
/// kept beside the file under a fresh name. An outside save is never
/// removed; when saves race each other here, the newest may be the kept
/// copy.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn settle(file: &Staged, holder: &CString, ours: &[u8], removable: &[&[u8]]) {
    if is_ours(file, holder, &[ours]) {
        return;
    }
    let directory = file.directory.as_raw_fd();
    if rename_at(directory, holder, &file.file_name, libc::RENAME_EXCHANGE).is_err()
        || !is_ours(file, holder, removable)
    {
        keep(file, holder);
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
/// Whether `name` holds one of `bytes`.
fn is_ours(file: &Staged, name: &CString, bytes: &[&[u8]]) -> bool {
    matches!(read_at(&file.directory, name), Ok(Some(held)) if bytes.contains(&held.as_slice()))
}

/// Move `holder` out of the cleanup's way: `.NAME.<random>.kept`.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn keep(file: &Staged, holder: &CString) {
    if let Ok(kept) = sibling(&file.file_name, "kept") {
        let _ = rename_at(file.directory.as_raw_fd(), holder, &kept, libc::RENAME_NOREPLACE);
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn between_swaps() {
    #[cfg(test)]
    BETWEEN_SWAPS.with(|hook| hook.borrow_mut().as_mut().map(|hook| hook()));
}

/// [`undo`] with no atomic swap: compare, then rename.
#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn undo(file: &Staged, old: Option<&CString>, ours: &[u8], _: Option<&[u8]>) {
    let directory = file.directory.as_raw_fd();
    if !matches!(read_at(&file.directory, &file.file_name), Ok(Some(bytes)) if bytes.as_slice() == ours)
    {
        return;
    }
    match old {
        Some(old) => {
            let _ = rename_at(directory, old, &file.file_name, 0);
        }
        // SAFETY: `file_name` is NUL-terminated and relative to the open folder.
        None => unsafe {
            libc::unlinkat(directory, file.file_name.as_ptr(), 0);
        },
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
