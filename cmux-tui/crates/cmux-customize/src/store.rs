//! The generation store.
//!
//! ```text
//! <state dir>/
//!   lock                 one writer at a time (the GUI, a CLI and an agent can race)
//!   index.json           every generation's row, and which one is current
//!   gen/<n>.json         generation n's tree: logical path to content hash
//!   objects/ab/cdef…     file contents by sha256, written once
//!   draft.json           the open draft, when one is
//! ```
//!
//! Every replace is temp file, fsync, rename, so a crash leaves the old or
//! the new file. A generation's objects are written before its tree, and its
//! tree before its index row, so an index row always names a whole
//! generation.

use std::collections::BTreeSet;
use std::fs::{self, File};
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::tree::{Part, Tree, sha256};

/// Generations kept; older ones (never the current one) are dropped by
/// [`Store::prune`] with the objects only they used.
pub const KEEP_GENERATIONS: usize = 100;

/// Why a generation exists.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Kind {
    /// The setup as it was before the first customization here.
    Baseline,
    /// A draft someone applied.
    Applied,
    /// Changes made outside a draft (a hand edit, the Settings window),
    /// recorded when the next draft began so a discard cannot lose them.
    ByHand,
    /// A draft someone discarded: kept, so "discard" is never "lost".
    Discarded,
    /// Unapplied changes that were live when someone rolled back.
    Autosaved,
}

impl Kind {
    pub fn word(self) -> &'static str {
        match self {
            Kind::Baseline => "baseline",
            Kind::Applied => "applied",
            Kind::ByHand => "by hand",
            Kind::Discarded => "discarded",
            Kind::Autosaved => "autosaved",
        }
    }
}

/// One row of the history.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Generation {
    pub n: u32,
    pub kind: Kind,
    /// Milliseconds since the epoch.
    pub at_ms: u64,
    /// Who made it: `user`, `cli`, `mcp`.
    pub origin: String,
    /// What was asked for, or what it is.
    pub label: String,
    /// The generation that was current when this one was made.
    pub parent: Option<u32>,
    /// Files that differ from the parent.
    pub changed: u32,
    pub parts: Vec<Part>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Index {
    pub version: u32,
    pub current: Option<u32>,
    pub next: u32,
    pub generations: Vec<Generation>,
}

impl Index {
    pub fn get(&self, n: u32) -> Option<&Generation> {
        self.generations.iter().find(|generation| generation.n == n)
    }

    pub fn current(&self) -> Option<&Generation> {
        self.current.and_then(|n| self.get(n))
    }
}

/// One thing someone asked for in a draft.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ask {
    pub text: String,
    pub at_ms: u64,
    pub origin: String,
}

/// The open draft: what is live and not yet applied or discarded.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Draft {
    /// The generation the draft started from.
    pub base: Option<u32>,
    pub started_ms: u64,
    pub asks: Vec<Ask>,
    /// The agent chat doing the work, so the next ask continues it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    /// The tree when the agent's last turn ended: a file that differs from
    /// it now was edited by hand since, and the agent re-reads it first.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub turn_tree: Option<Tree>,
}

#[derive(Debug)]
pub struct Store {
    dir: PathBuf,
}

/// Held for the length of one mutation.
#[derive(Debug)]
pub struct Lock {
    _file: File,
}

impl Store {
    pub fn at(dir: &Path) -> Store {
        Store { dir: dir.to_path_buf() }
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// Waits for the lock: mutations are short (a few file copies).
    pub fn lock(&self) -> io::Result<Lock> {
        private_dir(&self.dir)?;
        let file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.dir.join("lock"))?;
        fs4::FileExt::lock(&file)?;
        Ok(Lock { _file: file })
    }

    pub fn index(&self) -> io::Result<Index> {
        match fs::read(self.dir.join("index.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(corrupt("index.json")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                Ok(Index { version: 1, current: None, next: 1, generations: Vec::new() })
            }
            Err(error) => Err(error),
        }
    }

    pub fn put_index(&self, index: &Index) -> io::Result<()> {
        self.put_json("index.json", index)
    }

    pub fn tree(&self, n: u32) -> io::Result<Tree> {
        let name = format!("gen/{n}.json");
        let bytes = fs::read(self.dir.join(&name))?;
        serde_json::from_slice(&bytes).map_err(corrupt(&name))
    }

    pub fn put_tree(&self, n: u32, tree: &Tree) -> io::Result<()> {
        private_dir(&self.dir.join("gen"))?;
        self.put_json(&format!("gen/{n}.json"), tree)
    }

    pub fn draft(&self) -> io::Result<Option<Draft>> {
        match fs::read(self.dir.join("draft.json")) {
            Ok(bytes) => serde_json::from_slice(&bytes).map(Some).map_err(corrupt("draft.json")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    pub fn put_draft(&self, draft: Option<&Draft>) -> io::Result<()> {
        match draft {
            Some(draft) => self.put_json("draft.json", draft),
            None => match fs::remove_file(self.dir.join("draft.json")) {
                Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
                _ => Ok(()),
            },
        }
    }

    /// Where an object is; `None` for a name that is not a sha256 (a
    /// damaged or tampered tree never becomes a path).
    fn object_path(&self, sha: &str) -> Option<PathBuf> {
        if sha.len() != 64 || !sha.bytes().all(|byte| byte.is_ascii_hexdigit()) {
            return None;
        }
        let (head, tail) = sha.split_at_checked(2)?;
        Some(self.dir.join("objects").join(head).join(tail))
    }

    pub fn has_object(&self, sha: &str) -> bool {
        self.object_path(sha).is_some_and(|path| path.is_file())
    }

    /// Stores `bytes` under their hash; a second write of the same content
    /// is a no-op.
    pub fn put_object(&self, bytes: &[u8]) -> io::Result<String> {
        let sha = sha256(bytes);
        let path = self.object_path(&sha).ok_or_else(|| io::Error::other("sha256 is not hex"))?;
        if !path.is_file() {
            if let Some(parent) = path.parent() {
                private_dir(parent)?;
            }
            cmux_config::fsio::write_atomic(&path, bytes)?;
            private_file(&path)?;
        }
        Ok(sha)
    }

    /// An object's bytes, checked against its name: a damaged store fails
    /// here, before anything live is touched.
    pub fn object(&self, sha: &str) -> io::Result<Vec<u8>> {
        let path = self.object_path(sha).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, format!("{sha}: not an object name"))
        })?;
        let bytes = fs::read(path)?;
        if sha256(&bytes) != sha {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("object {sha} does not match its hash"),
            ));
        }
        Ok(bytes)
    }

    /// Drops generations past [`KEEP_GENERATIONS`] (oldest first, never the
    /// current one or its ancestors' newest link) and the objects no kept
    /// generation or draft names. Returns how many generations went.
    pub fn prune(&self, index: &mut Index) -> io::Result<usize> {
        let mut dropped = Vec::new();
        while index.generations.len() > KEEP_GENERATIONS {
            let Some(at) =
                index.generations.iter().position(|generation| Some(generation.n) != index.current)
            else {
                break;
            };
            dropped.push(index.generations.remove(at).n);
        }
        if dropped.is_empty() {
            return Ok(0);
        }
        self.put_index(index)?;
        let mut live = BTreeSet::new();
        for generation in &index.generations {
            live.extend(self.tree(generation.n)?.into_values().map(|entry| entry.sha));
        }
        if let Some(tree) = self.draft()?.and_then(|draft| draft.turn_tree) {
            live.extend(tree.into_values().map(|entry| entry.sha));
        }
        for n in &dropped {
            let _ = fs::remove_file(self.dir.join(format!("gen/{n}.json")));
        }
        for shard in read_names(&self.dir.join("objects"))? {
            for tail in read_names(&self.dir.join("objects").join(&shard))? {
                if !live.contains(&format!("{shard}{tail}")) {
                    let _ = fs::remove_file(self.dir.join("objects").join(&shard).join(&tail));
                }
            }
        }
        Ok(dropped.len())
    }

    fn put_json(&self, name: &str, value: &impl Serialize) -> io::Result<()> {
        private_dir(&self.dir)?;
        let mut bytes = serde_json::to_vec_pretty(value).map_err(io::Error::other)?;
        bytes.push(b'\n');
        let path = self.dir.join(name);
        cmux_config::fsio::write_atomic(&path, &bytes)?;
        private_file(&path)
    }
}

fn corrupt(name: &str) -> impl Fn(serde_json::Error) -> io::Error + '_ {
    move |error| io::Error::new(io::ErrorKind::InvalidData, format!("{name}: {error}"))
}

fn read_names(dir: &Path) -> io::Result<Vec<String>> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    let mut names = Vec::new();
    for entry in entries {
        if let Some(name) = entry?.file_name().to_str() {
            names.push(name.to_owned());
        }
    }
    Ok(names)
}

/// The settings file can hold credentials, so its copies are the owner's
/// only: folders 0700, files 0600.
fn private_dir(dir: &Path) -> io::Result<()> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(dir)
}

fn private_file(path: &Path) -> io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    let _ = path;
    Ok(())
}
