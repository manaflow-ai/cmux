use std::{
    cmp::Ordering,
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result};

#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum EntryKind {
    Directory,
    File,
}

#[derive(Debug, Clone, Eq, PartialEq)]
pub struct FileEntry {
    pub name: String,
    pub path: PathBuf,
    pub kind: EntryKind,
}

impl FileEntry {
    pub fn is_dir(&self) -> bool {
        self.kind == EntryKind::Directory
    }
}

pub fn list_directory(directory: &Path, show_hidden: bool) -> Result<Vec<FileEntry>> {
    let read_dir = fs::read_dir(directory)
        .with_context(|| format!("cannot read directory {}", directory.display()))?;
    let mut entries = Vec::new();

    for item in read_dir {
        let item = item.with_context(|| format!("cannot read entry in {}", directory.display()))?;
        let name = item.file_name().to_string_lossy().into_owned();
        if !show_hidden && name.starts_with('.') {
            continue;
        }
        let kind = if item
            .file_type()
            .with_context(|| format!("cannot inspect {}", item.path().display()))?
            .is_dir()
        {
            EntryKind::Directory
        } else {
            EntryKind::File
        };
        entries.push(FileEntry { name, path: item.path(), kind });
    }

    entries.sort_by(compare_entries);
    Ok(entries)
}

fn compare_entries(left: &FileEntry, right: &FileEntry) -> Ordering {
    let kind_order = match (left.kind, right.kind) {
        (EntryKind::Directory, EntryKind::File) => Ordering::Less,
        (EntryKind::File, EntryKind::Directory) => Ordering::Greater,
        _ => Ordering::Equal,
    };
    kind_order.then_with(|| {
        left.name
            .to_lowercase()
            .cmp(&right.name.to_lowercase())
            .then_with(|| left.name.cmp(&right.name))
    })
}

pub fn filtered_indices(entries: &[FileEntry], query: &str) -> Vec<usize> {
    let query = query.to_lowercase();
    entries
        .iter()
        .enumerate()
        .filter_map(|(index, entry)| entry.name.to_lowercase().contains(&query).then_some(index))
        .collect()
}
