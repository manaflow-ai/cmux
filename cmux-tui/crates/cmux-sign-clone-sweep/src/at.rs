//! Removal bound to the folder a pass checked. A clone is checked by path, so a
//! folder put in its place after the check must never be what is removed. The
//! clone folder is opened from its parent with `O_NOFOLLOW` and removed only
//! when its device and inode are the ones the check saw; everything under it is
//! read and unlinked relative to directory descriptors (`openat`, `fstatat`,
//! `unlinkat`), never by path, so a link or a swapped folder inside is never
//! followed out of it. The last step, the clone's own name, is `unlinkat` with
//! `AT_REMOVEDIR`, which only removes an empty folder: a folder swapped in at
//! that very moment keeps its files.

use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// A file's identity: its device and inode.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Ident {
    pub dev: u64,
    pub ino: u64,
}

impl Ident {
    pub fn of(meta: &std::fs::Metadata) -> Self {
        Self { dev: meta.dev(), ino: meta.ino() }
    }
}

fn c_name(name: &OsStr) -> io::Result<CString> {
    CString::new(name.as_bytes()).map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

fn check(result: libc::c_int) -> io::Result<()> {
    if result == 0 { Ok(()) } else { Err(io::Error::last_os_error()) }
}

/// The folder `name` in `parent`, never through a link.
fn open_dir_at(parent: RawFd, name: &CStr) -> io::Result<File> {
    let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    // SAFETY: `name` is NUL-terminated; the descriptor is checked before use.
    let fd = unsafe { libc::openat(parent, name.as_ptr(), flags) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` is a new descriptor nothing else owns.
    Ok(File::from(unsafe { OwnedFd::from_raw_fd(fd) }))
}

/// Whether `name` in `dir` is a real folder (a link is not).
fn is_dir_at(dir: RawFd, name: &CStr) -> io::Result<bool> {
    // SAFETY: stat is plain old data; all zeroes is a valid value.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: `name` is NUL-terminated and `stat` is writable.
    check(unsafe { libc::fstatat(dir, name.as_ptr(), &raw mut stat, libc::AT_SYMLINK_NOFOLLOW) })?;
    Ok(stat.st_mode & libc::S_IFMT == libc::S_IFDIR)
}

/// The names in `dir`, without `.` and `..`.
fn names(dir: &File) -> io::Result<Vec<OsString>> {
    // SAFETY: dup of a descriptor this holds; fdopendir takes the copy.
    let copy = unsafe { libc::dup(dir.as_raw_fd()) };
    if copy < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `copy` is a directory descriptor this owns; on success the stream owns it.
    let stream = unsafe { libc::fdopendir(copy) };
    if stream.is_null() {
        let error = io::Error::last_os_error();
        // SAFETY: fdopendir failed, so `copy` is still this one's to close.
        unsafe { libc::close(copy) };
        return Err(error);
    }
    let mut found = Vec::new();
    loop {
        // SAFETY: `stream` is open; the entry is read before the next readdir.
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            break;
        }
        // SAFETY: readdir's d_name is NUL-terminated.
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name != b"." && name != b".." {
            found.push(OsString::from_vec(name.to_vec()));
        }
    }
    // SAFETY: `stream` is open and closed once.
    unsafe { libc::closedir(stream) };
    Ok(found)
}

/// Unlinks everything in `dir`, depth first, through descriptors only.
fn empty(dir: &File) -> io::Result<()> {
    for name in names(dir)? {
        let name = c_name(&name)?;
        if is_dir_at(dir.as_raw_fd(), &name)? {
            empty(&open_dir_at(dir.as_raw_fd(), &name)?)?;
            // SAFETY: `name` is NUL-terminated.
            check(unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) })?;
        } else {
            // SAFETY: `name` is NUL-terminated.
            check(unsafe { libc::unlinkat(dir.as_raw_fd(), name.as_ptr(), 0) })?;
        }
    }
    Ok(())
}

/// Removes the folder at `path` and everything in it, only when it is still the
/// folder `expect` names; a different folder there is left as it is.
pub fn remove_checked(path: &Path, expect: Ident) -> io::Result<()> {
    let (Some(parent), Some(name)) = (path.parent(), path.file_name()) else {
        return Err(io::Error::from(io::ErrorKind::InvalidInput));
    };
    let parent = File::open(parent)?;
    let name = c_name(name)?;
    let dir = open_dir_at(parent.as_raw_fd(), &name)?;
    if Ident::of(&dir.metadata()?) != expect {
        return Err(io::Error::other("the folder changed after it was checked"));
    }
    empty(&dir)?;
    // SAFETY: `name` is NUL-terminated.
    check(unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), libc::AT_REMOVEDIR) })
}
