//! The have/want exchange, sans-io. Every message is `[u8 version = 1][u8 type][32-byte root]` and a body:
//!
//! | type | name | body |
//! |---|---|---|
//! | 1 | offer | the manifest ([`Manifest::encode`]) |
//! | 2 | want | a bitmap, one bit per manifest entry (bit `i % 8` of byte `i / 8`): set means "send it" |
//! | 3 | chunks | records `[32-byte id][u32 BE length][sealed chunk]`, the same records as the relay chunk cache's batch read |
//!
//! The sender offers; the receiver answers with what it lacks (after looking in its own store and, if it
//! likes, the relay's cache for the pair); the sender sends only those. A bundle the receiver already
//! holds costs the offer and an empty want: one round trip and no chunk bytes. A chunk from anywhere
//! (the peer, a relay, a disk) is opened and checked against its id before it is stored, so a copy
//! nobody can vouch for is still safe to take.
//!
//! An old peer answers an offer with nothing it can parse ([`Error::Version`], an unknown message): the
//! caller sends the bytes the old way.

use crate::store::Store;
use crate::{ChunkId, Error, Kind, Manifest, PairKey, Result, seal};

/// The exchange's version byte.
pub const VERSION: u8 = 1;
const OFFER: u8 = 1;
const WANT: u8 = 2;
const CHUNKS: u8 = 3;
const HEAD: usize = 2 + 32;
/// A chunks message's default size cap (one link frame is 256 KiB; several frames per message are fine).
pub const BATCH_BYTES: usize = 1 << 20;

fn head(kind: u8, root: &ChunkId, body_len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEAD + body_len);
    out.push(VERSION);
    out.push(kind);
    out.extend_from_slice(root);
    out
}

fn parse(msg: &[u8], want_kind: u8) -> Result<(ChunkId, &[u8])> {
    let (&version, _) = msg.split_first().ok_or(Error::Malformed("bundle message"))?;
    if version != VERSION {
        return Err(Error::Version(version));
    }
    let bad = || Error::Malformed("bundle message");
    let (head, rest) = msg.split_at_checked(HEAD).ok_or_else(bad)?;
    let (&[_, kind], root) = head.split_first_chunk::<2>().ok_or_else(bad)?;
    if kind != want_kind {
        return Err(bad());
    }
    let root: ChunkId = root.try_into().map_err(|_| bad())?;
    Ok((root, rest))
}

/// Encodes chunk records `[id][u32 BE len][sealed]` (the relay cache's batch body).
pub fn encode_records<'a>(
    records: impl IntoIterator<Item = (&'a ChunkId, &'a [u8])>,
    out: &mut Vec<u8>,
) {
    for (id, sealed) in records {
        out.extend_from_slice(id);
        out.extend_from_slice(&(sealed.len() as u32).to_be_bytes());
        out.extend_from_slice(sealed);
    }
}

/// The records in `body`, which must tile it.
pub fn decode_records(mut body: &[u8]) -> Result<Vec<(ChunkId, &[u8])>> {
    let mut out = Vec::new();
    while !body.is_empty() {
        let bad = || Error::Malformed("chunk record");
        let (id, rest) = body.split_first_chunk::<32>().ok_or_else(bad)?;
        let (len, rest) = rest.split_first_chunk::<4>().ok_or_else(bad)?;
        let len = u32::from_be_bytes(*len) as usize;
        if len > seal::MAX_SEALED {
            return Err(bad());
        }
        let (sealed, rest) = rest.split_at_checked(len).ok_or_else(bad)?;
        out.push((*id, sealed));
        body = rest;
    }
    Ok(out)
}

/// The sending side of one bundle.
#[derive(Debug)]
pub struct Sender {
    manifest: Manifest,
    root: ChunkId,
}

impl Sender {
    /// Chunks and seals `data` into `store` and gets ready to offer it.
    pub fn new(key: &PairKey, kind: Kind, data: &[u8], store: &mut dyn Store) -> Result<Self> {
        let manifest = Manifest::build(key, kind, data, store)?;
        let root = manifest.root(key);
        Ok(Self { manifest, root })
    }

    /// The bundle's root id.
    pub fn root(&self) -> &ChunkId {
        &self.root
    }

    /// The manifest.
    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// The offer message.
    pub fn offer(&self) -> Vec<u8> {
        let m = self.manifest.encode();
        let mut out = head(OFFER, &self.root, m.len());
        out.extend_from_slice(&m);
        out
    }

    /// The chunks messages that answer `want`, each at most about `batch_bytes`, empty when the
    /// receiver lacks nothing.
    pub fn on_want(
        &self,
        want: &[u8],
        store: &dyn Store,
        batch_bytes: usize,
    ) -> Result<Vec<Vec<u8>>> {
        let (root, bits) = parse(want, WANT)?;
        if root != self.root || bits.len() != self.manifest.chunks.len().div_ceil(8) {
            return Err(Error::Malformed("want"));
        }
        let mut sent = std::collections::HashSet::new();
        let mut out = Vec::new();
        let mut cur = head(CHUNKS, &self.root, 0);
        for (i, c) in self.manifest.chunks.iter().enumerate() {
            let wanted = bits.get(i / 8).is_some_and(|b| b & (1 << (i % 8)) != 0);
            if !wanted || !sent.insert(c.id) {
                continue;
            }
            let sealed = store.get(&c.id)?.ok_or(Error::Missing(c.id))?;
            if cur.len() > HEAD && cur.len() + 36 + sealed.len() > batch_bytes {
                out.push(std::mem::replace(&mut cur, head(CHUNKS, &self.root, 0)));
            }
            encode_records([(&c.id, sealed.as_slice())], &mut cur);
        }
        if cur.len() > HEAD {
            out.push(cur);
        }
        Ok(out)
    }
}

/// The receiving side of one bundle.
#[derive(Debug)]
pub struct Receiver {
    key: PairKey,
    manifest: Manifest,
    root: ChunkId,
}

impl Receiver {
    /// Takes an offer; the manifest must hash to the offered root under the pair's key, so only the
    /// pair's other end can make one.
    pub fn on_offer(key: &PairKey, offer: &[u8]) -> Result<Self> {
        let (root, body) = parse(offer, OFFER)?;
        let manifest = Manifest::decode(body)?;
        if manifest.root(key) != root {
            return Err(Error::Seal);
        }
        Ok(Self { key: key.clone(), manifest, root })
    }

    /// The manifest.
    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// The chunks `store` still lacks.
    pub fn missing(&self, store: &dyn Store) -> Vec<ChunkId> {
        self.manifest.lacking(store)
    }

    /// The want message for what `store` lacks now.
    pub fn want(&self, store: &dyn Store) -> Vec<u8> {
        let n = self.manifest.chunks.len();
        let mut bits = vec![0u8; n.div_ceil(8)];
        for (i, c) in self.manifest.chunks.iter().enumerate() {
            if let (false, Some(b)) = (store.has(&c.id), bits.get_mut(i / 8)) {
                *b |= 1 << (i % 8);
            }
        }
        let mut out = head(WANT, &self.root, bits.len());
        out.extend_from_slice(&bits);
        out
    }

    /// Checks one sealed chunk from any source and stores it. A chunk the manifest does not name, or
    /// that does not open to its id, is refused and not stored.
    pub fn accept(&self, id: &ChunkId, sealed: &[u8], store: &mut dyn Store) -> Result<()> {
        let Some(c) = self.manifest.chunks.iter().find(|c| c.id == *id) else {
            return Err(Error::Malformed("chunk not in manifest"));
        };
        let content = seal::open(&self.key, id, sealed)?;
        if content.len() != c.len as usize {
            return Err(Error::Seal);
        }
        store.put(id, sealed)
    }

    /// Takes a chunks message; true once the store holds every chunk.
    pub fn on_chunks(&self, msg: &[u8], store: &mut dyn Store) -> Result<bool> {
        let (root, body) = parse(msg, CHUNKS)?;
        if root != self.root {
            return Err(Error::Malformed("chunks root"));
        }
        for (id, sealed) in decode_records(body)? {
            self.accept(&id, sealed, store)?;
        }
        Ok(self.missing(store).is_empty())
    }

    /// The bundle's bytes.
    pub fn assemble(&self, store: &dyn Store) -> Result<Vec<u8>> {
        self.manifest.assemble(&self.key, store)
    }
}

#[cfg(test)]
#[path = "sync_tests.rs"]
mod tests;
