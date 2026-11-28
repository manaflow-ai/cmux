//! What each side keeps outside the synced folder: the synced revision (cmux-sync's
//! content-addressed [`Revision`], head written after the revision so a crash keeps the old one)
//! and the bytes of synced text files, the base a three-way merge needs.

use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use cmux_sync::two_way::{self, Store, Tree};

/// Text files up to this size keep their synced bytes as a merge base.
pub const BASE_MAX: usize = 1024 * 1024;

pub struct State {
    dir: PathBuf,
}

const PAIR: &str = "live";

impl State {
    pub fn open(dir: impl Into<PathBuf>) -> io::Result<Self> {
        let dir = dir.into();
        fs::create_dir_all(dir.join("revisions"))?;
        fs::create_dir_all(dir.join("bases"))?;
        Ok(Self { dir })
    }

    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The synced tree and its id; empty with no id before the first round. A head that names a
    /// missing or corrupt revision is an error, never an empty tree (which would read every file
    /// as created on both sides).
    pub fn load(&self) -> anyhow::Result<(Option<String>, Tree)> {
        let tree = two_way::load(self, PAIR).map_err(|e| anyhow::anyhow!("{e}"))?;
        Ok((self.head(PAIR), tree))
    }

    pub fn commit(&mut self, tree: &Tree) -> String {
        let id = two_way::commit(self, PAIR, tree);
        // Older revisions are not read again: keep the head only.
        if let Ok(read) = fs::read_dir(self.dir.join("revisions")) {
            for e in read.flatten() {
                if e.file_name().to_str() != Some(id.as_str()) {
                    let _ = fs::remove_file(e.path());
                }
            }
        }
        id
    }

    pub fn put_base(&self, hash: &str, bytes: &[u8]) {
        if bytes.len() <= BASE_MAX && is_text(bytes) {
            let _ = write_atomic(&self.dir.join("bases").join(hash), bytes);
        }
    }

    pub fn base(&self, hash: &str) -> Option<Vec<u8>> {
        fs::read(self.dir.join("bases").join(hash)).ok()
    }

    /// Drops bases no synced path names.
    pub fn prune_bases(&self, tree: &Tree) {
        let keep: BTreeSet<&str> = tree.values().map(String::as_str).collect();
        if let Ok(read) = fs::read_dir(self.dir.join("bases")) {
            for e in read.flatten() {
                if e.file_name().to_str().is_none_or(|n| !keep.contains(n)) {
                    let _ = fs::remove_file(e.path());
                }
            }
        }
    }
}

impl Store for State {
    fn put(&mut self, id: &str, bytes: Vec<u8>) {
        let _ = write_atomic(&self.dir.join("revisions").join(id), &bytes);
    }
    fn get(&self, id: &str) -> Option<Vec<u8>> {
        fs::read(self.dir.join("revisions").join(id)).ok()
    }
    fn head(&self, _pair: &str) -> Option<String> {
        fs::read_to_string(self.dir.join("head"))
            .ok()
            .map(|s| s.trim().to_owned())
            .filter(|s| !s.is_empty())
    }
    fn set_head(&mut self, _pair: &str, id: &str) {
        let _ = write_atomic(&self.dir.join("head"), id.as_bytes());
    }
}

fn write_atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, bytes)?;
    fs::rename(&tmp, path)
}

/// Text: UTF-8 with no NUL byte.
pub fn is_text(bytes: &[u8]) -> bool {
    !bytes.contains(&0) && std::str::from_utf8(bytes).is_ok()
}
