//! A chat's copy sends git's loose objects as packs, not one file each
//! (`cmux link sync push` of a git working copy).
//!
//! Every loose object [`super::local::collect`] lists (`.git/objects/xx/...`,
//! the repository's own and the ones it borrows) is left out, and packs that
//! hold them go into `.git/objects/pack/` instead. The packs are made by
//! `git pack-objects` from the object names alone, into this Mac's state
//! folder (`<state>/link-sync/<key>.packs/`, next to the sync record
//! [`super::base`] keeps): nothing in the repository changes, no gc or repack
//! runs there. Packs a pack-file of the repository already holds go as they
//! are, whole, as before.
//!
//! The packs made for a folder stay in that folder until no loose object of
//! theirs is left here, and the next push reuses them: only loose objects no
//! kept pack holds go into a new one. So a push of an unchanged repository
//! makes no pack and writes nothing (the kept packs match the manifest), and
//! one after a commit sends one small pack of the new objects. A loose object
//! git cannot pack (a broken file) goes as a loose file, as before.

use std::collections::{BTreeMap, BTreeSet};
use std::os::unix::fs::DirBuilderExt as _;
use std::path::{Path, PathBuf};

use anyhow::Context as _;

use super::local::{LocalFile, Source};

/// An object name: 40 hex digits (SHA-1) or 64 (SHA-256).
type Id = String;

/// Replaces the loose objects of `files` (a git working copy's push list)
/// by packs that hold them, made from the repository whose common git folder
/// is `common`; the packs are kept in `kept` for the next push.
pub(super) fn pack_loose(
    files: &mut BTreeMap<String, LocalFile>,
    common: &Path,
    kept: &Path,
) -> anyhow::Result<()> {
    let loose: BTreeMap<Id, String> =
        files.keys().filter_map(|path| loose_id(path).map(|id| (id, path.clone()))).collect();
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(kept)
        .with_context(|| format!("cannot make {}", kept.display()))?;
    let Some(width) = loose.keys().next().map(|id| id.len() / 2) else {
        prune(kept, &[]);
        return Ok(());
    };
    let mut uncovered: BTreeSet<&Id> = loose.keys().collect();
    let mut used: Vec<String> = Vec::new();
    for (name, ids) in kept_packs(kept, width) {
        let before = uncovered.len();
        for id in &ids {
            uncovered.remove(id);
        }
        if uncovered.len() < before {
            used.push(name);
        }
    }
    let fresh: Vec<&Id> = uncovered.iter().copied().collect();
    if !fresh.is_empty()
        && let Some(name) = make_pack(common, kept, &fresh)
    {
        used.push(name);
        uncovered.clear();
    }
    // What a pack holds goes in it; anything left goes loose.
    for (id, path) in &loose {
        if !uncovered.contains(id) {
            files.remove(path);
        }
    }
    for name in &used {
        for extension in ["pack", "idx"] {
            let file = format!("{name}.{extension}");
            let target = format!(".git/objects/pack/{file}");
            files.entry(target).or_insert_with(|| LocalFile {
                source: Source::File(kept.join(&file)),
                // Only the owner reads a made pack: it may hold objects
                // that were private here (git makes them 0400 under
                // `umask 077`), including ones no longer loose when it is
                // reused.
                permissions: 0o600,
            });
        }
    }
    prune(kept, &used);
    Ok(())
}

/// The object name of a loose object's path in a push list.
fn loose_id(path: &str) -> Option<Id> {
    let (dir, file) = path.strip_prefix(".git/objects/")?.split_once('/')?;
    let hex = |text: &str| text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'));
    (dir.len() == 2 && hex(dir) && matches!(file.len(), 38 | 62) && hex(file))
        .then(|| format!("{dir}{file}"))
}

/// The packs kept in `kept` (`pack-<hash>`, with both files there) and the
/// objects each holds, by its index (names `width` bytes wide).
fn kept_packs(kept: &Path, width: usize) -> Vec<(String, Vec<Id>)> {
    let Ok(entries) = std::fs::read_dir(kept) else { return Vec::new() };
    let mut packs = Vec::new();
    for entry in entries.flatten() {
        let file = entry.file_name();
        let Some(name) = file.to_str().and_then(|file| file.strip_suffix(".idx")) else {
            continue;
        };
        if !name.starts_with("pack-") || !kept.join(format!("{name}.pack")).is_file() {
            continue;
        }
        if let Some(ids) =
            std::fs::read(entry.path()).ok().and_then(|bytes| index_ids(&bytes, width))
        {
            packs.push((name.to_string(), ids));
        }
    }
    packs.sort();
    packs
}

/// The object names, `width` bytes each, a version 2 pack index lists; None
/// for anything else. They follow the magic, version and 256 fan-out counts
/// (the last is how many), and CRCs and offsets (4 bytes each per object),
/// large offsets (8 bytes each) and two hashes follow them.
fn index_ids(bytes: &[u8], width: usize) -> Option<Vec<Id>> {
    const HEADER: usize = 8 + 256 * 4;
    if bytes.get(..8)? != b"\xfftOc\x00\x00\x00\x02" {
        return None;
    }
    let count = u32::from_be_bytes(bytes.get(HEADER - 4..HEADER)?.try_into().ok()?) as usize;
    let fixed = count.checked_mul(width + 8)?.checked_add(HEADER + 2 * width)?;
    if bytes.len() < fixed || !(bytes.len() - fixed).is_multiple_of(8) {
        return None;
    }
    let names = bytes.get(HEADER..HEADER + count.checked_mul(width)?)?;
    Some(
        names
            .chunks_exact(width)
            .map(|name| name.iter().map(|byte| format!("{byte:02x}")).collect())
            .collect(),
    )
}

/// Packs `ids` with git into `kept`; the new pack's `pack-<hash>` name, or
/// None when git could not (the objects then go loose).
fn make_pack(common: &Path, kept: &Path, ids: &[&Id]) -> Option<String> {
    let scratch = tempfile::Builder::new().prefix(".making").tempdir_in(kept).ok()?;
    let names = scratch.path().join("objects");
    let input: String = ids.iter().map(|id| format!("{id}\n")).collect();
    std::fs::write(&names, input).ok()?;
    let output = cmux_process::Command::new("git")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_ALTERNATE_OBJECT_DIRECTORIES")
        .args(["-c", "core.fsmonitor=false", "-c", "pack.writeReverseIndex=false"])
        .arg("--git-dir")
        .arg(common)
        .args(["pack-objects", "-q", "--delta-base-offset"])
        .arg(scratch.path().join("pack"))
        .stdin(std::fs::File::open(&names).ok()?)
        .stderr(cmux_process::Stdio::null())
        .output()
        .ok()?;
    let hash = String::from_utf8(output.stdout).ok()?;
    let hash = hash.trim();
    if !output.status.success() || hash.is_empty() || !hash.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let name = format!("pack-{hash}");
    for extension in ["pack", "idx"] {
        let file = format!("{name}.{extension}");
        std::fs::rename(scratch.path().join(&file), kept.join(&file)).ok()?;
    }
    Some(name)
}

/// Deletes the packs of `kept` this push did not use (and any leftover of
/// one being made).
fn prune(kept: &Path, used: &[String]) {
    let Ok(entries) = std::fs::read_dir(kept) else { return };
    for entry in entries.flatten() {
        let file = entry.file_name();
        let Some(file) = file.to_str() else { continue };
        let name = file.rsplit_once('.').map_or(file, |(name, _)| name);
        if used.iter().any(|used| used == name) {
            continue;
        }
        let path: PathBuf = entry.path();
        if file.starts_with(".making") {
            let _ = std::fs::remove_dir_all(&path);
        } else if file.starts_with("pack-") {
            let _ = std::fs::remove_file(&path);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{index_ids, loose_id};

    #[test]
    fn only_a_loose_objects_path_names_one() {
        let sha1 = format!(".git/objects/ab/{}", "c".repeat(38));
        let sha256 = format!(".git/objects/ab/{}", "c".repeat(62));
        assert_eq!(loose_id(&sha1), Some(format!("ab{}", "c".repeat(38))));
        assert_eq!(loose_id(&sha256), Some(format!("ab{}", "c".repeat(62))));
        for not in [
            ".git/objects/pack/pack-1.pack".to_string(),
            ".git/objects/info/packs".to_string(),
            format!(".git/objects/AB/{}", "c".repeat(38)),
            format!("src/objects/ab/{}", "c".repeat(38)),
            format!(".git/objects/ab/{}", "c".repeat(37)),
        ] {
            assert_eq!(loose_id(&not), None, "{not}");
        }
    }

    #[test]
    fn a_bad_index_names_nothing() {
        assert_eq!(index_ids(b"", 20), None);
        assert_eq!(index_ids(&[0u8; 2000], 20), None);
        let mut header = b"\xfftOc\x00\x00\x00\x02".to_vec();
        header.extend(std::iter::repeat_n(0u8, 1024));
        // No objects: just the two trailing SHA-1 hashes.
        let mut empty = header.clone();
        empty.extend([0u8; 40]);
        assert_eq!(index_ids(&empty, 20), Some(Vec::new()));
        // Says one object, holds none.
        let mut short = header;
        if let Some(last) = short.get_mut(8 + 1023) {
            *last = 1;
        }
        assert_eq!(index_ids(&short, 20), None);
    }
}
