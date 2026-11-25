//! Offload one file (a cold chat's archive): [`upload`] with no lock held, then [`commit`] under the
//! caller's lock. A crash at any step loses nothing:
//!
//! - before the stub is written: the file is still there; at worst an unreferenced blob, which the store's
//!   GC collects;
//! - stub written, file not yet removed: both are there; the file wins and the stub is redundant (the next
//!   [`commit`] of the same bytes removes the file without uploading again);
//! - stub only: offloaded.

use crate::Cloud;
use crate::seal;
use crate::store::MAX_BLOB;
use crate::stub::{self, Stub};
use anyhow::{Context, bail};
use std::path::Path;
use std::time::{SystemTime, UNIX_EPOCH};

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Seals `file`, puts it in the store and checks the store has it. Answers the stub to commit. Changes
/// nothing on the disk.
pub fn upload(file: &Path, cloud: &Cloud) -> anyhow::Result<Stub> {
    let plain = std::fs::read(file).with_context(|| format!("cannot read {}", file.display()))?;
    let plain_sha256 = crate::sha256_hex(&plain);
    let sealed = seal::seal(&cloud.key, &plain)?;
    if sealed.len() > MAX_BLOB {
        // A chat past 64 MiB of archive needs parts; until then it stays local.
        bail!("{} seals to {} bytes, over the store's 64 MiB blob", file.display(), sealed.len());
    }
    let blob = crate::sha256_hex(&sealed);
    cloud.store.put(&blob, &sealed)?;
    if !cloud.store.has(&blob)? {
        bail!("the store does not list {blob} after the put");
    }
    Ok(Stub {
        v: 1,
        blob,
        plain_sha256,
        plain_bytes: plain.len() as u64,
        stored_bytes: sealed.len() as u64,
        offloaded_at_ms: now_ms(),
    })
}

/// Writes `record` as `file`'s stub and removes `file`, if `file` still holds the bytes [`upload`] sealed.
/// Answers the bytes freed, or None when `file` changed or went (nothing is removed then).
pub fn commit(file: &Path, record: &Stub) -> anyhow::Result<Option<u64>> {
    let plain = match std::fs::read(file) {
        Ok(plain) => plain,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    if plain.len() as u64 != record.plain_bytes || crate::sha256_hex(&plain) != record.plain_sha256
    {
        return Ok(None);
    }
    crate::write_durable(&stub::stub_path(file), &serde_json::to_vec(record)?)?;
    std::fs::remove_file(file)?;
    crate::sync_dir(file.parent().context("a file has a folder")?)?;
    Ok(Some(plain.len() as u64))
}

/// Upload one immutable session-pack revision from a private staging store. The caller
/// publishes the stub and registers all its blob addresses before releasing its archive.
pub fn upload_pack(
    source: &cmux_session_pack::Store,
    name: &str,
    tail_turns: usize,
    cloud: &Cloud,
) -> anyhow::Result<stub::Packed> {
    use cmux_session_pack::{Pack, hex, ship};
    use std::collections::{BTreeMap, HashSet};

    let pack = Pack::open(source, name).map_err(anyhow::Error::from_boxed)?;
    let manifest = &pack.manifest;
    let first_line = if tail_turns > 0 && manifest.marks().next().is_none() {
        manifest.segments.last().map_or(0, |segment| segment.line)
    } else {
        manifest.tail_turns(tail_turns)
    };
    let range = first_line..manifest.lines;
    let mut bundle = Vec::new();
    ship::bundle_range(source, name, range.clone(), &HashSet::new(), &mut bundle)
        .map_err(anyhow::Error::from_boxed)?;
    let tail = upload_part(&bundle, cloud)?;
    let included: HashSet<_> =
        pack.needed(range).map_err(anyhow::Error::from_boxed)?.into_iter().collect();
    let mut older = BTreeMap::new();
    for id in manifest.chunk_ids().map_err(anyhow::Error::from_boxed)? {
        if !included.contains(&id) {
            let file = source.stored(&id).map_err(anyhow::Error::from_boxed)?;
            older.insert(hex(&id), upload_part(&file, cloud)?);
        }
    }
    Ok(stub::Packed {
        v: 2,
        name: name.to_owned(),
        tail,
        first_line,
        manifest_sha256: crate::sha256_hex(&manifest.to_json().map_err(anyhow::Error::from_boxed)?),
        older,
    })
}

fn upload_part(bytes: &[u8], cloud: &Cloud) -> anyhow::Result<stub::Part> {
    let sealed = seal::seal(&cloud.key, bytes)?;
    anyhow::ensure!(sealed.len() <= MAX_BLOB, "sealed history part exceeds the sync blob limit");
    let blob = crate::sha256_hex(&sealed);
    cloud.store.put(&blob, &sealed)?;
    Ok(stub::Part { blob, plain_bytes: bytes.len() })
}
