//! The `std::fs` calls the relay makes that `cmux_blocking::fs` has no
//! wrapper for, each inside `cmux_blocking::scoped_blocking_call` as
//! cmux-tui/lab/clippy/clippy.toml names them (Chrome's
//! base/files/file_util_posix.cc opens a ScopedBlockingCall the same way).

#[cfg(unix)]
use std::fs::{DirBuilder, Permissions};
use std::fs::{File, OpenOptions};
use std::io;
use std::path::Path;

use cmux_blocking::{BlockingKind, scoped_blocking_call};

/// `OpenOptions::open`.
#[track_caller]
pub(crate) fn open_with(options: &OpenOptions, path: &Path) -> io::Result<File> {
    scoped_blocking_call("fs::open_with", BlockingKind::Fs, || options.open(path))
}

/// `File::sync_all`: waits until the disk flushes.
#[track_caller]
pub(crate) fn sync_all(file: &File) -> io::Result<()> {
    scoped_blocking_call("fs::sync_all", BlockingKind::Fs, || file.sync_all())
}

/// `std::fs::set_permissions`.
#[cfg(unix)]
#[track_caller]
pub(crate) fn set_permissions(path: &Path, permissions: Permissions) -> io::Result<()> {
    scoped_blocking_call("fs::set_permissions", BlockingKind::Fs, || {
        std::fs::set_permissions(path, permissions)
    })
}

/// `DirBuilder::create`.
#[cfg(unix)]
#[track_caller]
pub(crate) fn create_dir_with(builder: &DirBuilder, path: &Path) -> io::Result<()> {
    scoped_blocking_call("fs::create_dir_with", BlockingKind::Fs, || builder.create(path))
}

/// `std::fs::create_dir`.
#[cfg(not(unix))]
#[track_caller]
pub(crate) fn create_dir(path: &Path) -> io::Result<()> {
    scoped_blocking_call("fs::create_dir", BlockingKind::Fs, || std::fs::create_dir(path))
}

/// `std::fs::remove_dir`.
#[cfg(unix)]
#[track_caller]
pub(crate) fn remove_dir(path: &Path) -> io::Result<()> {
    scoped_blocking_call("fs::remove_dir", BlockingKind::Fs, || std::fs::remove_dir(path))
}

/// `std::fs::hard_link`.
#[cfg(unix)]
#[track_caller]
pub(crate) fn hard_link(original: &Path, link: &Path) -> io::Result<()> {
    scoped_blocking_call("fs::hard_link", BlockingKind::Fs, || std::fs::hard_link(original, link))
}
