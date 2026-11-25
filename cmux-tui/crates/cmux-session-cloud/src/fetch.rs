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
