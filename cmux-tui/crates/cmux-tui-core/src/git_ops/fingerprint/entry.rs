//! One entry of a work tree, reached only through real folders.
//!
//! git lists a path by its name. A folder above the path can be a link that
//! leads out of the work tree: in a work tree that was made so, or put there
//! between git's listing and the read. So no path of the listing is resolved
//! by name: each folder is opened through its parent's descriptor and
//! refuses a link (`O_NOFOLLOW`), and the entry is looked at and read through
//! its folder's descriptor. A path with a link, a file or nothing in a
//! folder's place has no entry, as git says of it that it is deleted.

use std::ffi::{CStr, CString, OsStr, OsString};
use std::fs::File;
use std::mem::MaybeUninit;
use std::os::fd::{AsRawFd as _, FromRawFd as _, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Component, Path};

/// Folders above one entry; a path with more has no entry.
const MAX_DEPTH: usize = 128;
/// Bytes of a link's target text that count.
const MAX_TARGET_BYTES: usize = 4096;
const FOLDER_FLAGS: libc::c_int =
    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
const FILE_FLAGS: libc::c_int =
    libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC;

/// What the system says of an entry or of an open file.
pub(super) type Stat = libc::stat;

/// A work tree, as its open folders.
pub(super) struct Tree {
    root: OwnedFd,
    /// The folders above the last entry, outermost first. The entries of one
    /// folder follow each other in a listing, so they share them.
    above: Vec<(OsString, OwnedFd)>,
}

/// A name in an open folder of the work tree.
pub(super) struct Entry<'a> {
    folder: &'a OwnedFd,
    name: CString,
}

fn c_name(name: &OsStr) -> Option<CString> {
    CString::new(name.as_bytes()).ok()
}

/// `name` in `folder`, opened with `flags`.
fn open_at(folder: RawFd, name: &CStr, flags: libc::c_int) -> Option<OwnedFd> {
    // SAFETY: a live descriptor and a NUL-terminated name; the result is checked.
    let fd = unsafe { libc::openat(folder, name.as_ptr(), flags) };
    if fd < 0 {
        return None;
    }
    // SAFETY: a descriptor the system just returned, owned by no one else.
    Some(unsafe { OwnedFd::from_raw_fd(fd) })
}

impl Tree {
    /// The work tree at `root`, the folder that the caller names.
    pub(super) fn open(root: &Path) -> Option<Self> {
        let root = File::open(root).ok()?;
        root.metadata().ok()?.is_dir().then(|| Self { root: root.into(), above: Vec::new() })
    }

    /// The entry that `relative` names, a path of the listing; `None` when a
    /// folder above it is not a real folder.
    pub(super) fn entry(&mut self, relative: &Path) -> Option<Entry<'_>> {
        let mut parts = Vec::new();
        for component in relative.components() {
            let Component::Normal(part) = component else { return None };
            parts.push(part);
        }
        let name = c_name(parts.pop()?)?;
        if parts.len() > MAX_DEPTH {
            return None;
        }
        let shared = self
            .above
            .iter()
            .zip(&parts)
            .take_while(|((held, _), part)| held.as_os_str() == **part)
            .count();
        self.above.truncate(shared);
        for part in parts.into_iter().skip(shared) {
            let parent = self.above.last().map_or(&self.root, |(_, folder)| folder).as_raw_fd();
            let folder = open_at(parent, &c_name(part)?, FOLDER_FLAGS)?;
            self.above.push((part.to_os_string(), folder));
        }
        let folder = self.above.last().map_or(&self.root, |(_, folder)| folder);
        Some(Entry { folder, name })
    }
}

impl Entry<'_> {
    /// What the system says of the entry itself: a link is not followed.
    pub(super) fn stat(&self) -> Option<Stat> {
        let mut stat = MaybeUninit::<Stat>::uninit();
        // SAFETY: a live descriptor, a NUL-terminated name and room for one `stat`.
        let result = unsafe {
            libc::fstatat(
                self.folder.as_raw_fd(),
                self.name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        if result != 0 {
            return None;
        }
        // SAFETY: the call succeeded, so it filled the `stat`.
        Some(unsafe { stat.assume_init() })
    }

    /// The target text of the entry, a link.
    pub(super) fn link_target(&self) -> Option<Vec<u8>> {
        let mut target = vec![0_u8; MAX_TARGET_BYTES];
        // SAFETY: a live descriptor, a NUL-terminated name and a buffer of the length given.
        let length = unsafe {
            libc::readlinkat(
                self.folder.as_raw_fd(),
                self.name.as_ptr(),
                target.as_mut_ptr().cast::<libc::c_char>(),
                target.len(),
            )
        };
        target.truncate(usize::try_from(length).ok()?);
        Some(target)
    }

    /// The entry, open for a read. It follows no link and waits on no FIFO.
    pub(super) fn open(&self) -> Option<File> {
        open_at(self.folder.as_raw_fd(), &self.name, FILE_FLAGS).map(File::from)
    }
}

/// What the system says of an open file.
pub(super) fn stat_of(file: &File) -> Option<Stat> {
    let mut stat = MaybeUninit::<Stat>::uninit();
    // SAFETY: a live descriptor and room for one `stat`.
    let result = unsafe { libc::fstat(file.as_raw_fd(), stat.as_mut_ptr()) };
    if result != 0 {
        return None;
    }
    // SAFETY: the call succeeded, so it filled the `stat`.
    Some(unsafe { stat.assume_init() })
}
