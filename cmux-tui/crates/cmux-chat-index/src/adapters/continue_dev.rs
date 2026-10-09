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

pub(super) fn read_store(root: &Path) -> io::Result<Vec<ChatEntry>> { Ok(Vec::new()) }
pub(super) fn classify(parts: &[&str]) -> PathRole { PathRole::Ignore }
