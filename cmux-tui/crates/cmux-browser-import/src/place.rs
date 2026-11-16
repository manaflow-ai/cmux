//! Where a reader finds a file or folder: on disk, or in the [`Files`] the app sent (the bytes of
//! a folder macOS protects, which never touch the disk; [`crate::upload`]). The readers of a
//! profile take a [`Place`], so one reader serves both.

use crate::model::ReadError;
use crate::sqlite::Snapshot;
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

/// Files held in memory, by relative name (`Sessions/Session_1`, `History.db-wal`): the parts
/// are joined with `/` and none is empty, `.` or `..`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Files(BTreeMap<String, Vec<u8>>);

impl Files {
    pub fn new() -> Self {
        Self::default()
    }

    /// `name` as a key: relative, its parts plain names (`.` parts are dropped); None for an
    /// absolute name, a `..` part or no name at all.
    pub fn key(name: &str) -> Option<String> {
        let mut parts = Vec::new();
        for part in Path::new(name).components() {
            match part {
                Component::Normal(part) => parts.push(part.to_str()?),
                Component::CurDir => {}
                Component::ParentDir | Component::RootDir | Component::Prefix(_) => return None,
            }
        }
        Some(parts.join("/"))
    }

    /// Appends `bytes` to the file `key` (made when new).
    pub fn append(&mut self, key: String, bytes: &[u8]) {
        self.0.entry(key).or_default().extend_from_slice(bytes);
    }

    /// The bytes of `key`.
    pub fn get(&self, key: &str) -> Option<&[u8]> {
        self.0.get(key).map(Vec::as_slice)
    }

    /// Every file's size, added up.
    pub fn bytes(&self) -> usize {
        self.0.values().map(Vec::len).fold(0, usize::saturating_add)
    }

    /// The names directly in the folder `key` ("" is the top), each once.
    fn names(&self, key: &str) -> Vec<String> {
        let mut names: Vec<String> = self
            .0
            .keys()
            .filter_map(|name| if key.is_empty() { Some(name.as_str()) } else { inside(name, key) })
            .filter_map(|rest| rest.split('/').next())
            .map(str::to_owned)
            .collect();
        names.sort();
        names.dedup();
        names
    }

    /// `key` is a file, or a folder some file is in.
    fn has(&self, key: &str) -> bool {
        key.is_empty()
            || self.0.contains_key(key)
            || self.0.keys().any(|n| inside(n, key).is_some())
    }
}

/// The rest of `name` after the folder `key` and a `/`.
fn inside<'a>(name: &'a str, key: &str) -> Option<&'a str> {
    name.strip_prefix(key)?.strip_prefix('/')
}

/// A file or folder on disk, or in [`Files`].
#[derive(Clone, Debug)]
pub enum Place<'a> {
    Disk(PathBuf),
    /// `key` in `files` ("" is the top folder).
    Memory {
        files: &'a Files,
        key: String,
    },
}

impl<'a> Place<'a> {
    /// The top folder of `files`.
    pub fn memory(files: &'a Files) -> Self {
        Place::Memory { files, key: String::new() }
    }

    /// `name` (one or more parts) under this folder.
    #[must_use]
    pub fn join(&self, name: &str) -> Place<'a> {
        match self {
            Place::Disk(path) => Place::Disk(path.join(name)),
            Place::Memory { files, key } => {
                let key = if key.is_empty() { name.to_owned() } else { format!("{key}/{name}") };
                Place::Memory { files, key }
            }
        }
    }

    /// Where it is, as a reply names it: the disk path, or the name in the files.
    pub fn path(&self) -> PathBuf {
        match self {
            Place::Disk(path) => path.clone(),
            Place::Memory { key, .. } => PathBuf::from(key),
        }
    }

    pub fn exists(&self) -> bool {
        match self {
            Place::Disk(path) => path.exists(),
            Place::Memory { files, key } => files.has(key),
        }
    }

    /// The file's bytes.
    pub fn read(&self) -> Result<Vec<u8>, ReadError> {
        match self {
            Place::Disk(path) => std::fs::read(path).map_err(|e| ReadError::Read(e.to_string())),
            Place::Memory { files, key } => files
                .get(key)
                .map(<[u8]>::to_vec)
                .ok_or_else(|| ReadError::Read(format!("{key}: not among the files sent"))),
        }
    }

    /// The names in the folder (`contentsOfDirectory`), none when it cannot be listed.
    pub fn names(&self) -> Vec<String> {
        match self {
            Place::Disk(path) => std::fs::read_dir(path)
                .map(|entries| {
                    entries
                        .filter_map(Result::ok)
                        .filter_map(|entry| entry.file_name().into_string().ok())
                        .collect()
                })
                .unwrap_or_default(),
            Place::Memory { files, key } => files.names(key),
        }
    }

    /// The database here, with its `-wal`: a private copy of a disk file, or opened from memory.
    pub fn database(&self) -> Result<Snapshot, ReadError> {
        match self {
            Place::Disk(path) => Snapshot::copying(path),
            Place::Memory { files, key } => {
                let main = files
                    .get(key)
                    .ok_or_else(|| ReadError::Read(format!("{key}: not among the files sent")))?;
                Snapshot::from_memory(main, files.get(&format!("{key}-wal")))
            }
        }
    }
}

impl From<&Path> for Place<'static> {
    fn from(path: &Path) -> Self {
        Place::Disk(path.to_path_buf())
    }
}

impl From<&PathBuf> for Place<'static> {
    fn from(path: &PathBuf) -> Self {
        Place::Disk(path.clone())
    }
}

impl From<PathBuf> for Place<'static> {
    fn from(path: PathBuf) -> Self {
        Place::Disk(path)
    }
}

impl<'a> From<&Place<'a>> for Place<'a> {
    fn from(place: &Place<'a>) -> Self {
        place.clone()
    }
}
