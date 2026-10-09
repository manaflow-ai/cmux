//! Red stub: the adapter lands with its fix commit.
#![allow(unused_variables, dead_code)]

use std::io;
use std::path::{Path, PathBuf};

use super::PathRole;
use crate::entry::{AdapterKind, ChatEntry};
use crate::scan::FileRead;
use crate::stamp::{FileStamp, FileState};

fn none(stamp: FileStamp) -> io::Result<FileRead> {
    Ok(FileRead { entry: None, state: FileState { stamp, offset: stamp.size, ..FileState::default() } })
}

pub(super) fn list_cli(root: &Path) -> io::Result<Vec<PathBuf>> { Ok(Vec::new()) }
pub(super) fn read_cli(path: &Path, stamp: FileStamp, prev: Option<&FileState>) -> io::Result<FileRead> { none(stamp) }
pub(super) fn finish_cli(root: &Path, entries: &mut [ChatEntry]) {}
pub(super) fn classify_cli(parts: &[&str]) -> PathRole { PathRole::Ignore }
pub(super) fn list_code(root: &Path) -> io::Result<Vec<PathBuf>> { Ok(Vec::new()) }
pub(super) fn read_code(path: &Path, stamp: FileStamp) -> io::Result<Option<ChatEntry>> { Ok(None) }
pub(super) fn finish_code(root: &Path, entries: &mut Vec<ChatEntry>) {}
pub(super) fn classify_code(parts: &[&str]) -> PathRole { PathRole::Ignore }
