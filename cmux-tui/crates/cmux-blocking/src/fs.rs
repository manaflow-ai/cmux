//! `std::fs` through [`scoped_blocking_call`]. Each call may block on disk.

use std::fs::{File, Metadata, ReadDir};
use std::io;
use std::path::{Path, PathBuf};

use crate::{BlockingKind, scoped_blocking_call};

#[track_caller]
pub fn read(path: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    scoped_blocking_call("fs::read", BlockingKind::Fs, || std::fs::read(path))
}

#[track_caller]
pub fn read_to_string(path: impl AsRef<Path>) -> io::Result<String> {
    scoped_blocking_call("fs::read_to_string", BlockingKind::Fs, || std::fs::read_to_string(path))
}

#[track_caller]
pub fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> io::Result<()> {
    scoped_blocking_call("fs::write", BlockingKind::Fs, || std::fs::write(path, contents))
}

#[track_caller]
pub fn metadata(path: impl AsRef<Path>) -> io::Result<Metadata> {
    scoped_blocking_call("fs::metadata", BlockingKind::Fs, || std::fs::metadata(path))
}

#[track_caller]
pub fn symlink_metadata(path: impl AsRef<Path>) -> io::Result<Metadata> {
    scoped_blocking_call("fs::symlink_metadata", BlockingKind::Fs, || {
        std::fs::symlink_metadata(path)
    })
}

#[track_caller]
pub fn exists(path: impl AsRef<Path>) -> io::Result<bool> {
    scoped_blocking_call("fs::exists", BlockingKind::Fs, || std::fs::exists(path))
}

#[track_caller]
pub fn canonicalize(path: impl AsRef<Path>) -> io::Result<PathBuf> {
    scoped_blocking_call("fs::canonicalize", BlockingKind::Fs, || std::fs::canonicalize(path))
}

/// Opens the directory; iterating the returned `ReadDir` also reads disk, so
/// iterate it where blocking is allowed.
#[track_caller]
pub fn read_dir(path: impl AsRef<Path>) -> io::Result<ReadDir> {
    scoped_blocking_call("fs::read_dir", BlockingKind::Fs, || std::fs::read_dir(path))
}

#[track_caller]
pub fn create_dir_all(path: impl AsRef<Path>) -> io::Result<()> {
    scoped_blocking_call("fs::create_dir_all", BlockingKind::Fs, || std::fs::create_dir_all(path))
}

#[track_caller]
pub fn remove_file(path: impl AsRef<Path>) -> io::Result<()> {
    scoped_blocking_call("fs::remove_file", BlockingKind::Fs, || std::fs::remove_file(path))
}

#[track_caller]
pub fn remove_dir_all(path: impl AsRef<Path>) -> io::Result<()> {
    scoped_blocking_call("fs::remove_dir_all", BlockingKind::Fs, || std::fs::remove_dir_all(path))
}

#[track_caller]
pub fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    scoped_blocking_call("fs::rename", BlockingKind::Fs, || std::fs::rename(from, to))
}

#[track_caller]
pub fn copy(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<u64> {
    scoped_blocking_call("fs::copy", BlockingKind::Fs, || std::fs::copy(from, to))
}

/// `File::open`. Reads and writes on the returned file block too.
#[track_caller]
pub fn open(path: impl AsRef<Path>) -> io::Result<File> {
    scoped_blocking_call("fs::open", BlockingKind::Fs, || File::open(path))
}

/// `File::create`. Reads and writes on the returned file block too.
#[track_caller]
pub fn create(path: impl AsRef<Path>) -> io::Result<File> {
    scoped_blocking_call("fs::create", BlockingKind::Fs, || File::create(path))
}
