//! The GC root of a folder pair in the content-addressed store
//! ([`super::store`]). The store's collector deletes a person's blobs no
//! live root names once they are a day old, as soon as that person has one
//! root. So after every push with a store configured, this Mac registers
//! the pair's root (`POST /v1/sync/roots {pair, tree}`): `tree` is a blob,
//! uploaded like any other, of the line [`TREE_HEADER`] and then one
//! lowercase SHA-256 per line, every blob the pair's record ([`Manifest`])
//! and kept history ([`super::history`]) name. A file cut into pieces
//! ([`super::store::chunks`]) is named by its pieces, as this Mac recorded
//! them when it uploaded them (`<state>/link-sync/<key>.chunks.json`, kept
//! next to the base record and trimmed to what the tree still names); a
//! file whose pieces this Mac never recorded is named by its own hash.
//!
//! The pair is [`super::base::key`], the SHA-256 of the local folder and the
//! machine folder: a hash, never a path. A root not registered again for 90
//! days expires; every push registers it again. A failure never fails the
//! push: it is named once on stderr and the next push tries again.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};

use anyhow::Context as _;

use super::history::{Held, Snapshot};
use super::{Manifest, base, store};

/// A tree blob's first line.
pub(super) const TREE_HEADER: &str = "cmux-sync-tree 1";

/// The pieces of each file cut into pieces, by the file's SHA-256.
pub(super) type Chunks = BTreeMap<String, Vec<String>>;

/// The folder pair's id in the store.
pub(super) fn pair(local: &Path, remote_root: &str) -> String {
    base::key(local, remote_root)
}

/// Whether `sha` is a lowercase SHA-256, the only kind a tree names.
fn is_sha(sha: &str) -> bool {
    sha.len() == 64 && sha.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// Every file hash `manifest` and `history` name.
pub(super) fn files_named(manifest: &Manifest, history: &[Snapshot]) -> BTreeSet<String> {
    let held =
        history.iter().flat_map(|snapshot| snapshot.paths.values()).filter_map(|held| match held {
            Held::File { sha256, .. } => Some(sha256),
            Held::Link { .. } => None,
        });
    manifest
        .files
        .values()
        .map(|pushed| &pushed.sha256)
        .chain(held)
        .filter(|sha| is_sha(sha))
        .cloned()
        .collect()
}

/// The blobs `files` need: each file's pieces when `chunks` has them, else
/// the file's own hash.
pub(super) fn blobs_needed(files: &BTreeSet<String>, chunks: &Chunks) -> BTreeSet<String> {
    let mut blobs = BTreeSet::new();
    for file in files {
        match chunks.get(file) {
            Some(pieces) => blobs.extend(pieces.iter().filter(|sha| is_sha(sha)).cloned()),
            None => {
                blobs.insert(file.clone());
            }
        }
    }
    blobs
}

/// A tree blob's bytes: [`TREE_HEADER`], then each of `blobs` on its own
/// line, sorted, each line ending in a newline.
pub(super) fn tree(blobs: &BTreeSet<String>) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(TREE_HEADER.len() + 1 + blobs.len() * 65);
    bytes.extend_from_slice(TREE_HEADER.as_bytes());
    bytes.push(b'\n');
    for sha in blobs {
        bytes.extend_from_slice(sha.as_bytes());
        bytes.push(b'\n');
    }
    bytes
}

/// The pieces kept for `files`: what this Mac recorded before (`kept`) and
/// what this push cut (`sent`), of the files the tree still names.
pub(super) fn chunks_kept(kept: Chunks, sent: &Chunks, files: &BTreeSet<String>) -> Chunks {
    let mut chunks: Chunks = kept.into_iter().filter(|(file, _)| files.contains(file)).collect();
    for (file, pieces) in sent {
        if files.contains(file) {
            chunks.insert(file.clone(), pieces.clone());
        }
    }
    chunks
}

fn chunks_path(local: &Path, remote_root: &str) -> anyhow::Result<PathBuf> {
    Ok(base::packs_dir(local, remote_root)?.with_extension("chunks.json"))
}

fn read_chunks(path: &Path) -> Chunks {
    std::fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default()
}

fn save_chunks(path: &Path, chunks: &Chunks) -> anyhow::Result<()> {
    let dir = path.parent().context("no state folder")?;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let part = path.with_extension(format!("{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)
        .with_context(|| format!("cannot write {}", part.display()))?;
    file.write_all(&serde_json::to_vec(chunks)?)?;
    std::fs::rename(&part, path).with_context(|| format!("cannot write {}", path.display()))
}

/// Registers the root of `local` synced to `remote_root` after a push that
/// left `next` and cut `sent` into pieces. Nothing without a store, nor for
/// a pair no push has sent through it (`used`, this push, or the pieces
/// record an earlier one left): its blobs are not in the store, and a
/// machine that cannot fetch from it costs the store nothing. A failure is
/// named once on stderr and never fails the push.
pub(super) fn register_after_push(
    local: &Path,
    remote_root: &str,
    next: &Manifest,
    sent: &Chunks,
    used: bool,
) {
    if !store::is_configured() {
        return;
    }
    if !used && !chunks_path(local, remote_root).is_ok_and(|path| path.exists()) {
        return;
    }
    if let Err(error) = register(local, remote_root, next, sent) {
        eprintln!(
            "{}",
            serde_json::json!({"store_root": {"registered": false, "error": format!("{error:#}")}})
        );
    }
}

fn register(local: &Path, remote_root: &str, next: &Manifest, sent: &Chunks) -> anyhow::Result<()> {
    let history = super::history::list(local, remote_root).unwrap_or_default();
    let files = files_named(next, &history);
    let path = chunks_path(local, remote_root)?;
    let chunks = chunks_kept(read_chunks(&path), sent, &files);
    // Kept before the root is asked for: pieces this push cut are named by
    // the next push's tree even if this root fails.
    save_chunks(&path, &chunks).context("cannot keep the pieces of the pushed files")?;
    let tree = tree(&blobs_needed(&files, &chunks));
    store::register_root(&pair(local, remote_root), &tree)
        .context("cannot register the folder's root in the store")
}

#[cfg(test)]
#[path = "roots_tests.rs"]
mod tests;
