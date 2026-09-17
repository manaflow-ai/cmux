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

#[cfg(test)]
mod tests {
    use std::fs::{create_dir, write};

    use super::*;

    fn temp_dir(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "cmux-tui-sidebar-files-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn lists_directories_first_and_sorts_each_kind() {
        let temp = temp_dir("sort");
        create_dir(temp.join("z-dir")).unwrap();
        create_dir(temp.join("A-dir")).unwrap();
        write(temp.join("z-file"), "").unwrap();
        write(temp.join("B-file"), "").unwrap();

        let entries = list_directory(&temp, false).unwrap();
        let actual =
            entries.iter().map(|entry| (entry.name.as_str(), entry.kind)).collect::<Vec<_>>();
        assert_eq!(
            actual,
            vec![
                ("A-dir", EntryKind::Directory),
                ("z-dir", EntryKind::Directory),
                ("B-file", EntryKind::File),
                ("z-file", EntryKind::File),
            ]
        );
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn hides_dotfiles_until_enabled() {
        let temp = temp_dir("hidden");
        create_dir(temp.join(".config")).unwrap();
        write(temp.join(".env"), "").unwrap();
        write(temp.join("visible"), "").unwrap();

        let hidden = list_directory(&temp, false).unwrap();
        assert_eq!(hidden.len(), 1);
        assert_eq!(hidden[0].name, "visible");

        let shown = list_directory(&temp, true).unwrap();
        assert_eq!(shown.len(), 3);
        assert_eq!(shown[0].name, ".config");
        assert_eq!(shown[1].name, ".env");
        fs::remove_dir_all(temp).unwrap();
    }

    #[test]
    fn filters_case_insensitively() {
        let entries = vec![
            FileEntry { name: "ReadMe.md".into(), path: "ReadMe.md".into(), kind: EntryKind::File },
            FileEntry { name: "src".into(), path: "src".into(), kind: EntryKind::Directory },
        ];
        assert_eq!(filtered_indices(&entries, "README"), vec![0]);
        assert_eq!(filtered_indices(&entries, "r"), vec![0, 1]);
    }
}
