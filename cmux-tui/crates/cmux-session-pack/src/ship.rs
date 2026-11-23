//! Moving a session between stores: only the chunks the other side lacks.
//!
//! The receiver says what it holds (every id of its store, [`Store::ids`], or just an older
//! manifest's, [`Manifest::chunk_ids`]). The sender writes a bundle: `CSPB1\n`, the manifest's
//! length (u32 LE) and JSON, then each lacking chunk as its id (32 bytes), its file's length
//! (u32 LE) and its file as the store holds it (already compressed). The receiver checks every
//! chunk against its id before storing it and puts the manifest in place last, so a bundle cut
//! short or damaged on the way leaves the session as it was.

use crate::Result;
use crate::manifest::Manifest;
use crate::store::{Id, Store, chunk_id, decode_chunk, hex};
use std::collections::HashSet;
use std::io::{Read, Write};

const MAGIC: &[u8; 6] = b"CSPB1\n";

/// What a bundle held.
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct ShipStats {
    /// Chunks in the bundle, and the bundle's size.
    pub chunks: u64,
    pub bytes: u64,
    /// Chunks the session has, and their files' size.
    pub session_chunks: u64,
    pub session_bytes: u64,
}

/// The chunks of `manifest` that `store` lacks.
pub fn want(store: &Store, manifest: &Manifest) -> Result<Vec<Id>> {
    Ok(manifest.chunk_ids()?.into_iter().filter(|id| !store.has(id)).collect())
}

/// Writes session `name`'s manifest and every chunk of it not in `have` to `out`.
pub fn bundle(
    store: &Store,
    name: &str,
    have: &HashSet<Id>,
    out: &mut dyn Write,
) -> Result<ShipStats> {
    let manifest = Manifest::load(store, name)?
        .ok_or_else(|| format!("{} holds no session {name:?}", store.root().display()))?;
    let json = manifest.to_json()?;
    out.write_all(MAGIC)?;
    out.write_all(&(json.len() as u32).to_le_bytes())?;
    out.write_all(&json)?;
    let mut stats =
        ShipStats { bytes: (MAGIC.len() + 4 + json.len()) as u64, ..Default::default() };
    for id in manifest.chunk_ids()? {
        stats.session_chunks += 1;
        if have.contains(&id) {
            stats.session_bytes += store.stored_len(&id)?;
            continue;
        }
        let file = store.stored(&id)?;
        stats.session_bytes += file.len() as u64;
        out.write_all(&id)?;
        out.write_all(&(file.len() as u32).to_le_bytes())?;
        out.write_all(&file)?;
        stats.chunks += 1;
        stats.bytes += 36 + file.len() as u64;
    }
    Ok(stats)
}

/// Reads a bundle into `store`: its chunks, each checked against its id, then its manifest.
pub fn unbundle(store: &Store, input: &mut dyn Read) -> Result<Manifest> {
    let mut magic = [0u8; 6];
    input.read_exact(&mut magic)?;
    if &magic != MAGIC {
        return Err("not a session bundle".into());
    }
    let mut len = [0u8; 4];
    input.read_exact(&mut len)?;
    let mut json = vec![0u8; u32::from_le_bytes(len) as usize];
    input.read_exact(&mut json)?;
    let manifest = Manifest::parse(&json)?;
    loop {
        let mut id: Id = [0u8; 32];
        match input.read(&mut id[..1])? {
            0 => break,
            _ => input.read_exact(&mut id[1..])?,
        }
        input.read_exact(&mut len)?;
        let mut file = vec![0u8; u32::from_le_bytes(len) as usize];
        input.read_exact(&mut file)?;
        let (kind, payload) = decode_chunk(&file)?;
        if chunk_id(kind, &payload) != id {
            return Err(format!("chunk {} does not hash to its id", hex(&id)).into());
        }
        store.put_stored(&id, &file)?;
    }
    if let Some(id) = want(store, &manifest)?.first() {
        return Err(format!("the bundle and this store together lack chunk {}", hex(id)).into());
    }
    manifest.save(store)?;
    Ok(manifest)
}
