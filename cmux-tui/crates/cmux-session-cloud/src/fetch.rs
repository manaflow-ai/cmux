//! Fetch on open: a stub's file comes back, checked twice (the blob's address, then the plaintext's hash)
//! before it is written. The stub stays until the caller has used the file (acpmux removes both once
//! the chat is thawed), so a crash mid-way leaves a stub and maybe the file, never neither.

use crate::Cloud;
use crate::seal;
use crate::stub;
use anyhow::{Context, bail};
use std::path::Path;

/// Writes the file `stub_path` names, durably. Answers its size. A file already there is kept as it is.
pub fn fetch_file(stub_path: &Path, cloud: &Cloud) -> anyhow::Result<u64> {
    let file = stub::segment_path(stub_path).context("not a stub")?;
    let record = stub::read(stub_path)?;
    if file.exists() {
        return Ok(std::fs::metadata(&file)?.len());
    }
    let sealed = cloud.store.get(&record.blob)?;
    if crate::sha256_hex(&sealed) != record.blob {
        bail!("blob {} came back with other bytes", record.blob);
    }
    let plain = seal::open(&cloud.key, &sealed, record.plain_bytes as usize)?;
    if crate::sha256_hex(&plain) != record.plain_sha256 {
        bail!("{} decrypted to other bytes than were offloaded", file.display());
    }
    crate::write_durable(&file, &plain)?;
    Ok(plain.len() as u64)
}

fn part(part: &stub::Part, cloud: &Cloud) -> anyhow::Result<Vec<u8>> {
    cmux_session_pack::unhex(&part.blob).map_err(anyhow::Error::from_boxed)?;
    let sealed = cloud.store.get(&part.blob)?;
    anyhow::ensure!(crate::sha256_hex(&sealed) == part.blob, "incorrect sealed history part");
    let bytes = seal::open(&cloud.key, &sealed, part.plain_bytes)?;
    anyhow::ensure!(bytes.len() == part.plain_bytes, "short history part");
    Ok(bytes)
}

/// One store GET on a cold open. The returned pack can read first_line..manifest.lines
/// immediately, including strings interned by older segments.
pub fn open_pack(
    record: &stub::Packed,
    cache: &cmux_session_pack::Store,
    cloud: &Cloud,
) -> anyhow::Result<cmux_session_pack::Pack> {
    use cmux_session_pack::{Manifest, Pack, ship};
    // The saved manifest is a completion marker for a verified tail. A different
    // revision or damaged cache must be repaired before exposing its last screen.
    if let Ok(Some(manifest)) = Manifest::load(cache, &record.name)
        && crate::sha256_hex(&manifest.to_json().map_err(anyhow::Error::from_boxed)?)
            == record.manifest_sha256
    {
        let ids = manifest.chunk_ids().map_err(anyhow::Error::from_boxed)?;
        let mut complete = true;
        for id in ids {
            if !record.older.contains_key(&cmux_session_pack::hex(&id))
                && !cache.verified(&id).map_err(anyhow::Error::from_boxed)?
            {
                complete = false;
                break;
            }
        }
        if complete {
            return Ok(Pack::with_manifest(cache, manifest));
        }
    }
    let bytes = part(&record.tail, cloud)?;
    let manifest = ship::unbundle(cache, &mut bytes.as_slice(), ship::Lacking::Allow)
        .map_err(anyhow::Error::from_boxed)?
        .context("tail has no manifest")?;
    anyhow::ensure!(
        crate::sha256_hex(&manifest.to_json().map_err(anyhow::Error::from_boxed)?)
            == record.manifest_sha256,
        "a tail for a different revision"
    );
    Ok(Pack::with_manifest(cache, manifest))
}

/// Each accepted chunk is reusable on disk even if the next GET fails or the process exits.
/// IDs in the first response can be repaired together by reopening the tail.
pub fn backfill(
    record: &stub::Packed,
    cache: &cmux_session_pack::Store,
    ids: &[cmux_session_pack::Id],
    cloud: &Cloud,
) -> anyhow::Result<()> {
    for id in ids {
        if cache.verified(id).map_err(anyhow::Error::from_boxed)? {
            continue;
        }
        if let Some(address) = record.older.get(&cmux_session_pack::hex(id)) {
            let file = part(address, cloud)?;
            cache.receive(id, &file).map_err(anyhow::Error::from_boxed)?;
        } else {
            open_pack(record, cache, cloud)?;
            anyhow::ensure!(
                cache.verified(id).map_err(anyhow::Error::from_boxed)?,
                "chunk outside the packed history"
            );
        }
    }
    Ok(())
}
