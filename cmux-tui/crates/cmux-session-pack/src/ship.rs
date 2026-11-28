//! Moving a session between stores: only the chunks the other side lacks.
//!
//! The receiver says what it holds (every id of its store, [`Store::ids`], or just an older
//! manifest's, [`Manifest::chunk_ids`]). The sender writes a bundle: `CSPB1\n`, the manifest's
//! length (u32 LE) and JSON, then each lacking chunk as its id (32 bytes), its file's length
//! (u32 LE) and its file as the store holds it (already compressed). The receiver checks every
//! chunk against its id before storing it and puts the manifest in place last, so a bundle cut
//! short or damaged on the way leaves the session as it was.
//!
//! A session can also begin on the other side from its tail alone ([`bundle_range`]): the
//! manifest, which names every chunk, and only the chunks the last turns read. Whatever reads
//! further back learns which chunks it lacks ([`Pack::lacking`]) and is sent those
//! ([`bundle_chunks`], a bundle with no manifest).

use crate::Result;
use crate::manifest::Manifest;
use crate::read::Pack;
use crate::store::{Id, MAX_STORED_CHUNK_BYTES, Store, hex};
use std::collections::HashSet;
use std::io::{Read, Write};

const MAGIC: &[u8; 6] = b"CSPB1\n";
const MAX_MANIFEST_BYTES: usize = 128 << 20;

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
    let manifest = load(store, name)?;
    let ids = manifest.chunk_ids()?;
    write_bundle(store, Some(&manifest), &manifest, &ids, have, out)
}

/// Writes session `name`'s manifest and only the chunks a read of `range` needs
/// ([`Pack::needed`]) that are not in `have`. The other side can then show and run the session
/// from those lines on; it asks for the rest as something reads it ([`Pack::lacking`],
/// [`bundle_chunks`]).
pub fn bundle_range(
    store: &Store,
    name: &str,
    range: std::ops::Range<u64>,
    have: &HashSet<Id>,
    out: &mut dyn Write,
) -> Result<ShipStats> {
    let manifest = load(store, name)?;
    let ids = Pack::with_manifest(store, manifest.clone()).needed(range)?;
    write_bundle(store, Some(&manifest), &manifest, &ids, have, out)
}

/// Writes the chunks `ids` of session `name` and no manifest: the answer to a store that asked
/// for chunks it lacks. Its manifest stays its own, which may be newer than this store's.
pub fn bundle_chunks(
    store: &Store,
    name: &str,
    ids: &[Id],
    out: &mut dyn Write,
) -> Result<ShipStats> {
    let manifest = load(store, name)?;
    let of_session: HashSet<Id> = manifest.chunk_ids()?.into_iter().collect();
    if let Some(id) = ids.iter().find(|id| !of_session.contains(*id)) {
        return Err(format!("chunk {} is not one of {name:?}", hex(id)).into());
    }
    write_bundle(store, None, &manifest, ids, &HashSet::new(), out)
}

fn load(store: &Store, name: &str) -> Result<Manifest> {
    Manifest::load(store, name)?
        .ok_or_else(|| format!("{} holds no session {name:?}", store.root().display()).into())
}

fn write_bundle(
    store: &Store,
    send_manifest: Option<&Manifest>,
    manifest: &Manifest,
    ids: &[Id],
    have: &HashSet<Id>,
    out: &mut dyn Write,
) -> Result<ShipStats> {
    let json = match send_manifest {
        Some(m) => m.to_json()?,
        None => Vec::new(),
    };
    out.write_all(MAGIC)?;
    out.write_all(&(json.len() as u32).to_le_bytes())?;
    out.write_all(&json)?;
    let mut stats =
        ShipStats { bytes: (MAGIC.len() + 4 + json.len()) as u64, ..Default::default() };
    for id in manifest.chunk_ids()? {
        stats.session_chunks += 1;
        stats.session_bytes += store.stored_len(&id)?;
    }
    let mut sent = HashSet::new();
    for id in ids {
        if have.contains(id) || !sent.insert(*id) {
            continue;
        }
        let file = store.stored(id)?;
        out.write_all(id)?;
        out.write_all(&(file.len() as u32).to_le_bytes())?;
        out.write_all(&file)?;
        stats.chunks += 1;
        stats.bytes += 36 + file.len() as u64;
    }
    Ok(stats)
}

/// What [`unbundle`] does with a manifest whose chunks are not all there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lacking {
    /// Refuse it and leave the session as it was: a whole move.
    Refuse,
    /// Save it: the session began from part of its log and asks for the rest as it is read.
    Allow,
}

/// Reads a bundle into `store`: its chunks, each checked against its id, then its manifest, if
/// it has one (the manifest it saved is returned).
pub fn unbundle(store: &Store, input: &mut dyn Read, lacking: Lacking) -> Result<Option<Manifest>> {
    let mut magic = [0u8; 6];
    input.read_exact(&mut magic)?;
    if &magic != MAGIC {
        return Err("not a session bundle".into());
    }
    let mut len = [0u8; 4];
    input.read_exact(&mut len)?;
    let json = read_bounded(input, u32::from_le_bytes(len), MAX_MANIFEST_BYTES, "manifest")?;
    let manifest = if json.is_empty() { None } else { Some(Manifest::parse(&json)?) };
    loop {
        let mut id: Id = [0u8; 32];
        match input.read(&mut id[..1])? {
            0 => break,
            _ => input.read_exact(&mut id[1..])?,
        }
        input.read_exact(&mut len)?;
        let file =
            read_bounded(input, u32::from_le_bytes(len), MAX_STORED_CHUNK_BYTES, "stored chunk")?;
        store.receive(&id, &file)?;
    }
    let Some(manifest) = manifest else { return Ok(None) };
    if lacking == Lacking::Refuse
        && let Some(id) = want(store, &manifest)?.first()
    {
        return Err(format!("the bundle and this store together lack chunk {}", hex(id)).into());
    }
    manifest.save(store)?;
    Ok(Some(manifest))
}

pub(crate) fn read_bounded(
    input: &mut dyn Read,
    len: u32,
    max: usize,
    what: &str,
) -> Result<Vec<u8>> {
    let len = len as usize;
    if len > max {
        return Err(format!("a {what} of {len} bytes is over the {max} byte limit").into());
    }
    // The stream may end immediately after its header. Grow only for bytes it
    // supplies, never for its claimed length, including claims below the cap.
    let mut bytes = Vec::new();
    let mut buffer = [0u8; 64 << 10];
    while bytes.len() < len {
        let n = len.saturating_sub(bytes.len()).min(buffer.len());
        let chunk = buffer.get_mut(..n).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidInput, "bundle read exceeds buffer")
        })?;
        let n = match input.read(chunk) {
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            result => result?,
        };
        if n == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::UnexpectedEof,
                format!("a {what} says {len} bytes and holds {}", bytes.len()),
            )
            .into());
        }
        let chunk = chunk.get(..n).ok_or_else(|| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "bundle reader exceeded its buffer",
            )
        })?;
        let wanted = bytes.len().saturating_add(n);
        if wanted > bytes.capacity() {
            let capacity = wanted.max(bytes.capacity().saturating_mul(2)).min(len);
            bytes.try_reserve_exact(capacity.saturating_sub(bytes.len()))?;
        }
        bytes.extend_from_slice(chunk);
    }
    Ok(bytes)
}
