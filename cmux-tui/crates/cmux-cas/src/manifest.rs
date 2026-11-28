//! A manifest: what one artifact (a web bundle tree, a binary, a seed) holds, file by file and
//! chunk by chunk. Its id is the BLAKE3 of its own JSON bytes, so a pointer naming the id names
//! every byte of the tree.

use crate::{Id, Result, cdc};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::path::Path;

/// The manifest schema this crate writes and reads.
pub const SCHEMA: u64 = 1;

/// One chunk of a file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Chunk {
    /// `BLAKE3(bytes)`.
    pub id: Id,
    /// Its length before compression.
    pub len: u32,
}

/// One file of the tree.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct File {
    /// Its path under the tree's root, `/`-separated, never absolute and never `..`.
    pub path: String,
    /// Whether it is executable (mode 0755, else 0644).
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub exec: bool,
    /// Its length.
    pub size: u64,
    /// `BLAKE3` of the whole file, checked after assembly.
    pub hash: Id,
    /// Its chunks, in order.
    pub chunks: Vec<Chunk>,
}

/// A tree of files.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Manifest {
    /// [`SCHEMA`].
    pub schema: u64,
    /// The files, sorted by path.
    pub files: Vec<File>,
}

impl Manifest {
    /// The manifest of in-memory files (`path -> (bytes, exec)`), and each new chunk's bytes,
    /// handed to `chunk` once per distinct id.
    pub fn build(
        files: &BTreeMap<String, (Vec<u8>, bool)>,
        mut chunk: impl FnMut(Id, &[u8]) -> Result<()>,
    ) -> Result<Self> {
        let mut seen = std::collections::HashSet::new();
        let mut out = Vec::with_capacity(files.len());
        for (path, (bytes, exec)) in files {
            check_path(path)?;
            let mut chunks = Vec::new();
            for (at, len) in cdc::chunks(bytes) {
                let end = at.checked_add(len).ok_or("chunk offset overflow")?;
                let piece = bytes.get(at..end).ok_or("chunk outside file")?;
                let id = Id::of(piece);
                if seen.insert(id) {
                    chunk(id, piece)?;
                }
                chunks.push(Chunk { id, len: u32::try_from(len)? });
            }
            out.push(File {
                path: path.clone(),
                exec: *exec,
                size: bytes.len() as u64,
                hash: Id::of(bytes),
                chunks,
            });
        }
        Ok(Self { schema: SCHEMA, files: out })
    }

    /// The manifest of every regular file under `root` (symlinks and empty directories are not
    /// carried; a web bundle and a binary have neither).
    pub fn of_dir(root: &Path, chunk: impl FnMut(Id, &[u8]) -> Result<()>) -> Result<Self> {
        Self::build(&read_tree(root)?, chunk)
    }

    /// Its JSON bytes, the ones its id hashes.
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    /// The manifest `bytes` hold, refused unless they are what `id` names.
    pub fn from_bytes(bytes: &[u8], id: &Id) -> Result<Self> {
        if Id::of(bytes) != *id {
            return Err(format!("manifest bytes are not {id}").into());
        }
        let m: Self = serde_json::from_slice(bytes)?;
        if m.schema != SCHEMA {
            return Err(format!("unknown manifest schema {}", m.schema).into());
        }
        for f in &m.files {
            check_path(&f.path)?;
            let sum: u64 = f.chunks.iter().map(|c| u64::from(c.len)).sum();
            if sum != f.size {
                return Err(
                    format!("{}: chunks hold {sum} bytes, the file {}", f.path, f.size).into()
                );
            }
        }
        Ok(m)
    }

    /// Its id.
    pub fn id(&self) -> Result<Id> {
        Ok(Id::of(&self.to_bytes()?))
    }

    /// Every distinct chunk, first appearance order, with its length.
    pub fn distinct_chunks(&self) -> Vec<Chunk> {
        let mut seen = std::collections::HashSet::new();
        self.files.iter().flat_map(|f| &f.chunks).filter(|c| seen.insert(c.id)).copied().collect()
    }

    /// The tree's length.
    pub fn size(&self) -> u64 {
        self.files.iter().map(|f| f.size).sum()
    }
}

/// Refuse a path that could leave the tree.
pub(crate) fn check_path(path: &str) -> Result<()> {
    let bad = path.is_empty()
        || path.starts_with('/')
        || path.contains('\\')
        || path.contains('\0')
        || path.split('/').any(|p| p.is_empty() || p == "." || p == "..");
    if bad {
        return Err(format!("path {path:?} is not a relative path inside the tree").into());
    }
    Ok(())
}

/// Every regular file under `root`: `path -> (bytes, exec)`, as [`Manifest::of_dir`] reads it.
pub fn read_tree(root: &Path) -> Result<BTreeMap<String, (Vec<u8>, bool)>> {
    let mut files = BTreeMap::new();
    walk(root, root, &mut files)?;
    Ok(files)
}

fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<String, (Vec<u8>, bool)>) -> Result<()> {
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        let path = entry.path();
        if kind.is_dir() {
            walk(root, &path, out)?;
        } else if kind.is_file() {
            let rel =
                path.strip_prefix(root)?.to_str().ok_or("a path is not UTF-8")?.replace('\\', "/");
            #[cfg(unix)]
            let exec = {
                use std::os::unix::fs::PermissionsExt as _;
                entry.metadata()?.permissions().mode() & 0o111 != 0
            };
            #[cfg(not(unix))]
            let exec = false;
            out.insert(rel, (std::fs::read(&path)?, exec));
        }
    }
    Ok(())
}
