//! GC roots of the content-addressed store (cmux-platform `POST /v1/sync/roots`).
//!
//! The store deletes a blob no live root names (after a day, and a day's grace after that). So
//! after a push through the store saves its manifest, this Mac registers the folder pair's root: a
//! tree blob naming every blob the folder's current manifest and its kept history snapshots
//! ([`super::history::KEEP`]) need, so a resume, a second machine or a restore finds them still
//! stored. The tree is `cmux-sync-tree 1`, then one lowercase SHA-256 per line, sorted and unique.
//! A file up to [`WHOLE_FILE_MAX`] is the blob of its own SHA-256; a larger one is its chunks, read
//! from a small cache this Mac keeps of each large file the store path chunked
//! (`<state>/link-sync/chunks/<aa>/<file sha256>`, one chunk hash a line), so an unchanged large
//! file still names its chunks; one this Mac never chunked is left out. The tree is uploaded like
//! any blob (missing, then PUT), so an unchanged tree costs one `missing` and the register.
//!
//! The pair is the SHA-256 of the base record's key ([`super::base::key`]), never a path.
//!
//! Best effort: a failure is one stderr line and never fails the push; the whole registration
//! gives up after [`BUDGET`].

use std::collections::BTreeSet;
use std::io::Write as _;
use std::os::unix::fs::{DirBuilderExt as _, OpenOptionsExt as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use serde_json::json;
use sha2::{Digest as _, Sha256};

use super::Manifest;
use super::history::{self, Held};
use super::store::{self, WHOLE_FILE_MAX};

/// The tree blob's first line.
pub(super) const TREE_HEADER: &str = "cmux-sync-tree 1\n";
/// Longest a root registration may add to a push.
const BUDGET: Duration = Duration::from_secs(10);
/// A cached chunk list not used for this long goes (a root not registered again for 90 days
/// expires on the platform too).
const CHUNKS_KEPT: Duration = Duration::from_secs(90 * 24 * 60 * 60);
/// How often the chunk cache is swept, at most.
const SWEEP_EVERY: Duration = Duration::from_secs(24 * 60 * 60);

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// A lowercase hex SHA-256.
fn is_sha256(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn chunks_dir() -> Option<PathBuf> {
    Some(cmux_tui_core::platform::workspace_state_dir()?.join("link-sync").join("chunks"))
}

fn chunks_path(file_sha256: &str) -> Option<PathBuf> {
    if !is_sha256(file_sha256) {
        return None;
    }
    Some(chunks_dir()?.join(file_sha256.get(..2)?).join(file_sha256))
}

/// Keeps the chunk hashes of the large file `file_sha256`. Best effort.
pub(super) fn remember_chunks(file_sha256: &str, chunks: &[String]) {
    if chunks.is_empty() || !chunks.iter().all(|chunk| is_sha256(chunk)) {
        return;
    }
    let Some(path) = chunks_path(file_sha256) else { return };
    let _ = write_chunks(&path, chunks);
}

fn write_chunks(path: &Path, chunks: &[String]) -> std::io::Result<()> {
    let Some(dir) = path.parent() else { return Ok(()) };
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("chunks");
    let part = dir.join(format!(".{name}.{}.part", std::process::id()));
    let _ = std::fs::remove_file(&part);
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&part)?;
    let mut text = String::with_capacity(chunks.len() * 65);
    for chunk in chunks {
        text.push_str(chunk);
        text.push('\n');
    }
    let written = file.write_all(text.as_bytes()).and_then(|()| std::fs::rename(&part, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&part);
    }
    written
}

/// The chunk hashes kept for the large file `file_sha256`, when this Mac chunked it. Each read
/// keeps the entry fresh for the sweep.
pub(super) fn chunks_of(file_sha256: &str) -> Option<Vec<String>> {
    let path = chunks_path(file_sha256)?;
    let text = std::fs::read_to_string(&path).ok()?;
    let chunks: Vec<String> = text.lines().map(str::to_owned).collect();
    if chunks.is_empty() || !chunks.iter().all(|chunk| is_sha256(chunk)) {
        return None;
    }
    let _ = std::fs::File::options()
        .append(true)
        .open(&path)
        .and_then(|file| file.set_modified(SystemTime::now()));
    Some(chunks)
}

/// The tree blob naming the blobs of `files` (each file's SHA-256 and, when known, its size):
/// a large file's chunks (`chunks_of`), a small or unknown-size file's own hash, nothing for an
/// empty file or a large one whose chunks are not known.
pub(super) fn tree(
    files: impl IntoIterator<Item = (String, Option<u64>)>,
    chunks_of: &dyn Fn(&str) -> Option<Vec<String>>,
) -> Vec<u8> {
    let mut hashes = BTreeSet::new();
    for (sha256, size) in files {
        if !is_sha256(&sha256) || size == Some(0) {
            continue;
        }
        // A file known to be small is its own blob, with no look in the cache: a folder of many
        // files costs no read a file.
        if size.is_some_and(|size| size <= WHOLE_FILE_MAX) {
            hashes.insert(sha256);
            continue;
        }
        match chunks_of(&sha256) {
            Some(chunks) => hashes.extend(chunks.into_iter().filter(|chunk| is_sha256(chunk))),
            None if size.is_some() => {}
            None => {
                hashes.insert(sha256);
            }
        }
    }
    let mut tree = String::with_capacity(TREE_HEADER.len() + hashes.len() * 65);
    tree.push_str(TREE_HEADER);
    for hash in hashes {
        tree.push_str(&hash);
        tree.push('\n');
    }
    tree.into_bytes()
}

/// The pair id of `local` synced to `remote_root`: the SHA-256 of the base record's key.
pub(super) fn pair(local: &Path, remote_root: &str) -> String {
    hex(&Sha256::digest(super::base::key(local, remote_root).as_bytes()))
}

/// Every file `local` synced to `remote_root` needs kept: the current manifest's (`next`, sizes
/// from `size_of` by path) and each kept snapshot's (sizes from this Mac's history blobs).
fn needed(
    local: &Path,
    remote_root: &str,
    next: &Manifest,
    size_of: &dyn Fn(&str) -> Option<u64>,
) -> Vec<(String, Option<u64>)> {
    let mut files: Vec<(String, Option<u64>)> = next
        .files
        .iter()
        .map(|(relative, pushed)| (pushed.sha256.clone(), size_of(relative)))
        .collect();
    let current: BTreeSet<&str> =
        next.files.values().map(|pushed| pushed.sha256.as_str()).collect();
    let mut seen = BTreeSet::new();
    for snapshot in history::list(local, remote_root).unwrap_or_default() {
        for held in snapshot.paths.into_values() {
            let Held::File { sha256, .. } = held else { continue };
            if current.contains(sha256.as_str()) || !seen.insert(sha256.clone()) {
                continue;
            }
            let size = history::blob(&sha256)
                .and_then(|path| std::fs::metadata(path).ok())
                .map(|meta| meta.len());
            files.push((sha256, size));
        }
    }
    files
}

/// Registers the GC root of `local` synced to `remote_root` after a store push saved `next`.
/// Never fails the push: a failure is one stderr line.
pub(super) fn register(
    local: &Path,
    remote_root: &str,
    next: &Manifest,
    size_of: &dyn Fn(&str) -> Option<u64>,
) {
    let files = needed(local, remote_root, next, size_of);
    let tree = tree(files, &chunks_of);
    if let Err(error) = store::register_root(&pair(local, remote_root), tree, BUDGET) {
        eprintln!("{}", json!({"store": {"root": false, "error": format!("{error:#}")}}));
    }
    sweep_chunks();
}

/// Drops cached chunk lists unused for [`CHUNKS_KEPT`], at most once a [`SWEEP_EVERY`].
fn sweep_chunks() {
    let Some(dir) = chunks_dir() else { return };
    let marker = dir.join(".swept");
    let now = SystemTime::now();
    let recent = |path: &Path, within: Duration| {
        std::fs::metadata(path)
            .and_then(|meta| meta.modified())
            .is_ok_and(|at| now.duration_since(at).unwrap_or_default() < within)
    };
    if !dir.is_dir() || recent(&marker, SWEEP_EVERY) {
        return;
    }
    let _ = std::fs::write(&marker, b"");
    let Ok(shards) = std::fs::read_dir(&dir) else { return };
    for shard in shards.filter_map(Result::ok) {
        if !shard.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let Ok(entries) = std::fs::read_dir(shard.path()) else { continue };
        for entry in entries.filter_map(Result::ok) {
            let path = entry.path();
            if !recent(&path, CHUNKS_KEPT) {
                let _ = std::fs::remove_file(&path);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;

    use super::{TREE_HEADER, tree};

    fn sha(fill: char) -> String {
        std::iter::repeat_n(fill, 64).collect()
    }

    #[test]
    fn a_tree_is_the_header_then_sorted_unique_hashes_with_large_files_as_their_chunks() {
        let small_b = sha('b');
        let small_a = sha('a');
        let large_known = sha('c');
        let large_unknown = sha('d');
        let history_only = sha('e');
        let chunks: BTreeMap<String, Vec<String>> =
            BTreeMap::from([(large_known.clone(), vec![sha('9'), sha('1'), sha('9')])]);
        let files = vec![
            (small_b.clone(), Some(10)),
            (small_a.clone(), Some(4 * 1024 * 1024)),
            // The same blob twice (two paths, or a snapshot): named once.
            (small_b.clone(), Some(10)),
            (large_known.clone(), Some(64 * 1024 * 1024)),
            // A large file this Mac never chunked: left out.
            (large_unknown, Some(5 * 1024 * 1024)),
            // A snapshot's file of unknown size: its own hash.
            (history_only.clone(), None),
            // Empty files and records with no hash name nothing.
            (sha('f'), Some(0)),
            (String::new(), Some(10)),
            ("NOT-A-HASH".into(), Some(10)),
        ];
        let tree = tree(files, &|sha256| chunks.get(sha256).cloned());
        let text = String::from_utf8(tree).unwrap();
        let expected =
            [sha('1'), sha('9'), small_a, small_b, history_only].map(|hash| format!("{hash}\n"));
        assert_eq!(text, format!("{TREE_HEADER}{}", expected.concat()));
    }

    #[test]
    fn an_empty_folder_is_the_header_alone() {
        assert_eq!(tree(Vec::new(), &|_| None), TREE_HEADER.as_bytes());
    }
}
