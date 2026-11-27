//! Encrypted, named snapshots of running chats. The caller captures a private, stable directory;
//! this layer publishes it atomically and recovers only inert files, never a live chat or lease.
//! Roots use the existing sync store's retention policy and must be refreshed while in use.

use crate::{Cloud, seal, sha256_hex, store};
use anyhow::{Context, bail};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Component, Path, PathBuf};

const CHUNK: usize = 4 << 20;
const MAX_MANIFEST: usize = 8 << 20;
const MAX_FILES: usize = 16_384;
const MAX_CHUNKS: usize = 65_536;
const MAX_BYTES: u64 = 16 << 30;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Receipt {
    pub pair: String,
    pub manifest: String,
    pub files: usize,
    pub bytes: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    version: u32,
    pair: String,
    session_id: String,
    directories: Vec<String>,
    files: Vec<Entry>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Entry {
    path: String,
    bytes: u64,
    sha256: String,
    chunks: Vec<Chunk>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Chunk {
    hash: String,
    plain_sha256: String,
    bytes: usize,
}

// This is an optimization only: missing/expired roots and unreadable old manifests fall back to
// uploading a complete snapshot. No previous local metadata is needed, including after restart.
fn previous_chunks(pair: &str, cloud: &Cloud) -> anyhow::Result<BTreeMap<(String, usize), String>> {
    let hashes = cloud.store.get_root(pair)?;
    if hashes.is_empty() || hashes.len() > MAX_CHUNKS + 1 {
        bail!("invalid prior replica root");
    }
    let plain = open_blob(&hashes[0], MAX_MANIFEST, cloud)?;
    let manifest: Manifest = serde_json::from_slice(&plain)?;
    if manifest.version != 1 || manifest.pair != pair {
        bail!("invalid prior replica identity");
    }
    let mut reusable = BTreeMap::new();
    let retained: BTreeSet<_> = hashes.iter().collect();
    for entry in manifest.files {
        for chunk in entry.chunks {
            store::validate_hash(&chunk.hash)?;
            store::validate_hash(&chunk.plain_sha256)?;
            if chunk.bytes == 0 || chunk.bytes > CHUNK || !retained.contains(&chunk.hash) {
                bail!("invalid prior replica chunk");
            }
            reusable.insert((chunk.plain_sha256, chunk.bytes), chunk.hash);
        }
    }
    Ok(reusable)
}

/// Stable, opaque name: no session id, path, or machine name is sent to the store.
pub fn pair(session_id: &str, cloud: &Cloud) -> anyhow::Result<String> {
    if session_id.is_empty() || session_id.len() > 4096 {
        bail!("invalid replica session id");
    }
    let mut digest = Sha256::new();
    digest.update(b"cmux running replica v1\0");
    digest.update(cloud.key.id_material());
    digest.update(session_id.as_bytes());
    let name = format!("{}csr.{}", cloud.root_prefix, hex::encode(digest.finalize()));
    store::validate_pair(&name)?;
    Ok(name)
}

/// Uploads every file before changing the named root. A failed upload leaves the last root intact.
/// `dir` must be a stable private capture, not the mutable live session directory.
pub fn publish(dir: &Path, session_id: &str, cloud: &Cloud) -> anyhow::Result<Receipt> {
    if !fs::symlink_metadata(dir)?.file_type().is_dir() {
        bail!("replica source must be a directory");
    }
    let pair = pair(session_id, cloud)?;
    let mut reusable = previous_chunks(&pair, cloud).unwrap_or_default();
    let candidates: Vec<_> =
        reusable.values().cloned().collect::<BTreeSet<_>>().into_iter().collect();
    let missing: BTreeSet<_> = cloud.store.missing(&candidates)?.into_iter().collect();
    reusable.retain(|_, hash| !missing.contains(hash));
    let mut paths = Vec::new();
    let mut directories = Vec::new();
    scan(dir, dir, &mut paths, &mut directories, 0)?;
    let mut manifest = Manifest {
        version: 1,
        pair: pair.clone(),
        session_id: session_id.to_string(),
        directories,
        files: Vec::new(),
    };
    let mut hashes = Vec::new();
    let mut total = 0u64;
    let mut buffer = vec![0; CHUNK];
    for path in paths {
        let full = dir.join(&path);
        if !fs::symlink_metadata(&full)?.file_type().is_file() {
            bail!("replica source changed type");
        }
        let mut file = File::open(&full)?;
        if !file.metadata()?.is_file() {
            bail!("replica source is not a regular file");
        }
        let mut digest = Sha256::new();
        let mut bytes = 0u64;
        let mut chunks = Vec::new();
        loop {
            // Fill a whole chunk even if a read is short, so recovery has one canonical layout.
            let mut used = 0;
            while used < CHUNK {
                let n = file.read(&mut buffer[used..])?;
                if n == 0 {
                    break;
                }
                used += n;
            }
            if used == 0 {
                break;
            }
            total = total.checked_add(used as u64).context("replica size overflow")?;
            if total > MAX_BYTES || hashes.len() >= MAX_CHUNKS {
                bail!("replica snapshot exceeds its bound");
            }
            let plain = &buffer[..used];
            digest.update(plain);
            bytes += used as u64;
            let plain_sha256 = sha256_hex(plain);
            let key = (plain_sha256.clone(), used);
            let previous = reusable.get(&key);
            let hash = match previous {
                Some(hash) => hash.clone(),
                _ => {
                    let sealed = seal::seal(&cloud.key, plain)?;
                    let hash = sha256_hex(&sealed);
                    cloud.store.put(&hash, &sealed)?;
                    reusable.insert(key, hash.clone());
                    hash
                }
            };
            hashes.push(hash.clone());
            chunks.push(Chunk { hash, plain_sha256, bytes: used });
        }
        manifest.files.push(Entry { path, bytes, sha256: hex::encode(digest.finalize()), chunks });
    }
    let plain = serde_json::to_vec(&manifest)?;
    if plain.len() > MAX_MANIFEST {
        bail!("replica manifest exceeds its bound");
    }
    let sealed = seal::seal(&cloud.key, &plain)?;
    let hash = sha256_hex(&sealed);
    cloud.store.put(&hash, &sealed)?;
    // The first hash is the discoverable manifest; all other hashes retain its encrypted chunks.
    hashes.insert(0, hash.clone());
    cloud.store.set_root(&pair, &hashes)?;
    Ok(Receipt { pair, manifest: hash, files: manifest.files.len(), bytes: total })
}

fn scan(
    base: &Path,
    dir: &Path,
    files: &mut Vec<String>,
    directories: &mut Vec<String>,
    depth: usize,
) -> anyhow::Result<()> {
    if depth > 64 {
        bail!("replica directory nesting exceeds its bound");
    }
    let mut entries = Vec::new();
    for entry in fs::read_dir(dir)? {
        if entries.len() >= MAX_FILES {
            bail!("replica directory exceeds its bound");
        }
        entries.push(entry?);
    }
    entries.sort_by_key(|entry| entry.file_name());
    for entry in entries {
        if files.len() + directories.len() >= MAX_FILES {
            bail!("replica file count exceeds its bound");
        }
        let path = entry.path();
        let relative =
            path.strip_prefix(base)?.to_str().context("replica paths must be UTF-8")?.to_string();
        safe_path(&relative)?;
        let kind = entry.file_type()?;
        if kind.is_dir() {
            directories.push(relative);
            scan(base, &path, files, directories, depth + 1)?;
        } else if kind.is_file() {
            files.push(relative);
        } else {
            bail!("replica refuses symlinks and special files");
        }
    }
    Ok(())
}

fn safe_path(path: &str) -> anyhow::Result<PathBuf> {
    if path.is_empty()
        || path.len() > 4096
        || path.contains(['\\', '\0', ':'])
        || path.split('/').any(|part| part.is_empty() || part == "." || part == "..")
        || path.split('/').count() > 65
        || Path::new(path).components().any(|part| !matches!(part, Component::Normal(_)))
    {
        bail!("unsafe replica path");
    }
    Ok(PathBuf::from(path))
}

fn private_dir(path: &Path) -> anyhow::Result<()> {
    let mut builder = fs::DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        builder.mode(0o700);
    }
    builder.create(path)?;
    Ok(())
}

fn open_blob(hash: &str, bound: usize, cloud: &Cloud) -> anyhow::Result<Vec<u8>> {
    store::validate_hash(hash)?;
    let sealed = cloud.store.get(hash)?;
    if sealed.len() > store::MAX_BLOB || sha256_hex(&sealed) != hash {
        bail!("replica blob digest mismatch");
    }
    seal::open(&cloud.key, &sealed, bound)
}

/// Recovers verified files into a NEW private directory. Existing paths are never replaced.
/// The caller must explicitly import this inert capture as a new chat; this grants no ownership.
pub fn recover(pair: &str, dest: &Path, cloud: &Cloud) -> anyhow::Result<Receipt> {
    store::validate_pair(pair)?;
    let hashes = cloud.store.get_root(pair)?;
    if hashes.is_empty() || hashes.len() > MAX_CHUNKS + 1 {
        bail!("invalid replica root size");
    }
    let hash = &hashes[0];
    let plain = open_blob(hash, MAX_MANIFEST, cloud)?;
    let manifest: Manifest = serde_json::from_slice(&plain)?;
    if manifest.version != 1 || manifest.pair != pair {
        bail!("replica manifest identity mismatch");
    }
    // A recovery may use a person credential with a different root prefix. The encrypted manifest
    // binds the original full pair; the suffix must still belong to this key and session.
    let derived = self::pair(&manifest.session_id, cloud)?;
    let suffix = derived.strip_prefix(&cloud.root_prefix).context("invalid replica prefix")?;
    if !pair.ends_with(suffix) {
        bail!("replica manifest session mismatch");
    }
    if manifest.files.len() + manifest.directories.len() > MAX_FILES {
        bail!("replica file count exceeds its bound");
    }
    let mut paths = BTreeSet::new();
    let mut directories = BTreeSet::new();
    for dir in &manifest.directories {
        safe_path(dir)?;
        if !paths.insert(dir.clone()) {
            bail!("duplicate replica path");
        }
        directories.insert(dir.clone());
    }
    let mut expected = vec![hash.clone()];
    let mut total = 0u64;
    for entry in &manifest.files {
        safe_path(&entry.path)?;
        if !paths.insert(entry.path.clone()) {
            bail!("duplicate replica path");
        }
        store::validate_hash(&entry.sha256)?;
        total = total.checked_add(entry.bytes).context("replica size overflow")?;
        if total > MAX_BYTES || entry.chunks.len() as u64 != entry.bytes.div_ceil(CHUNK as u64) {
            bail!("invalid replica file size");
        }
        let mut remaining = entry.bytes;
        for chunk in &entry.chunks {
            store::validate_hash(&chunk.hash)?;
            store::validate_hash(&chunk.plain_sha256)?;
            if chunk.bytes as u64 != remaining.min(CHUNK as u64) {
                bail!("invalid replica chunk length");
            }
            remaining -= chunk.bytes as u64;
        }
        expected.extend(entry.chunks.iter().map(|chunk| chunk.hash.clone()));
        if expected.len() > MAX_CHUNKS + 1 {
            bail!("replica chunk count exceeds its bound");
        }
    }
    for path in &paths {
        for parent in Path::new(path).ancestors().skip(1).filter(|p| !p.as_os_str().is_empty()) {
            if !directories.contains(parent.to_str().context("invalid replica parent")?) {
                bail!("replica parent is not a directory");
            }
        }
    }
    if expected != hashes {
        bail!("replica root does not retain exactly its manifest and chunks");
    }
    // create (not create_dir_all) is the exclusive claim. Even a dangling symlink is refused.
    private_dir(dest)?;
    let result = (|| -> anyhow::Result<()> {
        // Lexical order puts every parent before its children.
        for dir in &directories {
            private_dir(&dest.join(dir))?;
        }
        for entry in &manifest.files {
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut file = options.open(dest.join(&entry.path))?;
            let mut digest = Sha256::new();
            let mut remaining = entry.bytes;
            for chunk in &entry.chunks {
                let bytes = open_blob(&chunk.hash, CHUNK, cloud)?;
                if bytes.len() as u64 != remaining.min(CHUNK as u64)
                    || sha256_hex(&bytes) != chunk.plain_sha256
                {
                    bail!("replica chunk digest or length mismatch");
                }
                remaining -= bytes.len() as u64;
                digest.update(&bytes);
                file.write_all(&bytes)?;
            }
            if remaining != 0 || hex::encode(digest.finalize()) != entry.sha256 {
                bail!("replica file digest mismatch");
            }
            file.sync_all()?;
        }
        for dir in directories.iter().rev() {
            crate::sync_dir(&dest.join(dir))?;
        }
        crate::sync_dir(dest)?;
        crate::sync_dir(
            dest.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or(Path::new(".")),
        )?;
        Ok(())
    })();
    if let Err(error) = result {
        // Only this call's exclusively created destination is removed, never a caller-owned path.
        let _ = fs::remove_dir_all(dest);
        return Err(error);
    }
    Ok(Receipt {
        pair: pair.to_string(),
        manifest: hash.clone(),
        files: manifest.files.len(),
        bytes: total,
    })
}
