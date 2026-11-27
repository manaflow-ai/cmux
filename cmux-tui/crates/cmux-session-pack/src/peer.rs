//! Fleet peers (RFD 0166 F1): a machine that holds chunks serves them to its neighbours, so a
//! second machine in a zone fetches an artifact's chunks from the first one and only what no
//! peer holds from the floor (R2, an HTTPS origin, any slower source the caller names).
//!
//! Leo, 2026-11-25: "if it's cloud-related stuff. do not ever only plan. always be starting and
//! continuing and carrying things through."
//!
//! The wire is one request and one answer on any byte stream (TCP here; Braid's bulk class later):
//!
//! - request: `CSPW1\n`, a count (u32 LE), then that many 32-byte ids;
//! - answer, per id in order: the id, then the chunk file's length (u32 LE) and the file as the
//!   store holds it, or the length [`NOPE`] and nothing when the peer lacks it.
//!
//! A peer can waste bytes but never change them: every file is checked against its id
//! ([`Store::receive`]) before it is stored, and a peer that sends one wrong file, a different id
//! or a cut answer is dropped for the rest of the fetch. Every peer is optional: an unreachable,
//! slow or lying peer costs at most its timeout, and the floor always finishes the fetch.

use crate::Result;
use crate::store::{Id, MAX_STORED_CHUNK_BYTES, Store};
use std::io::{BufReader, BufWriter, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::time::Duration;

const MAGIC: &[u8; 6] = b"CSPW1\n";
/// The length an answer gives a chunk the peer does not hold.
pub const NOPE: u32 = u32::MAX;
/// The most ids one request may name (a request is at most 2 MiB of ids).
pub const MAX_WANT: u32 = 1 << 16;
/// The largest chunk file a peer may send (a chunk holds at most 4 GiB raw; files here are a few
/// MiB, so anything past this is a lie).
pub const MAX_FILE: u32 = MAX_STORED_CHUNK_BYTES as u32;

/// Serves `store`'s chunks to every peer that connects to `listener`, one scoped thread a
/// connection (each joined before this returns), until the listener fails.
pub fn serve(store: Store, listener: TcpListener) -> Result<()> {
    std::thread::scope(|s| {
        for conn in listener.incoming() {
            let Ok(conn) = conn else { continue };
            let store = &store;
            s.spawn(move || {
                // A peer that hangs up or sends garbage only ends its own connection.
                let _ = answer(store, conn);
            });
        }
    });
    Ok(())
}

/// Reads one request from `conn` and answers it.
pub fn answer(store: &Store, conn: TcpStream) -> Result<()> {
    conn.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut input = BufReader::new(conn.try_clone()?);
    let mut magic = [0u8; 6];
    input.read_exact(&mut magic)?;
    if &magic != MAGIC {
        return Err("not a chunk request".into());
    }
    let n = read_u32(&mut input)?;
    if n > MAX_WANT {
        return Err(format!("a request for {n} chunks is over {MAX_WANT}").into());
    }
    let mut ids = Vec::with_capacity(n as usize);
    for _ in 0..n {
        let mut id: Id = [0u8; 32];
        input.read_exact(&mut id)?;
        ids.push(id);
    }
    let mut out = BufWriter::with_capacity(1 << 20, conn);
    for id in &ids {
        out.write_all(id)?;
        match store.stored(id) {
            Ok(file) if file.len() <= MAX_FILE as usize => {
                out.write_all(&(file.len() as u32).to_le_bytes())?;
                out.write_all(&file)?;
            }
            _ => out.write_all(&NOPE.to_le_bytes())?,
        }
    }
    out.flush()?;
    Ok(())
}

/// What a [`fetch`] took from where.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct FetchStats {
    /// Chunks the store already held.
    pub held: u64,
    /// Chunks and bytes from peers (the bytes that never crossed the WAN).
    pub peer_chunks: u64,
    pub peer_bytes: u64,
    /// Chunks and bytes from the floor.
    pub floor_chunks: u64,
    pub floor_bytes: u64,
    /// Peers dropped: unreachable, timed out, cut short or sent a file that is not its id.
    pub dropped: Vec<(SocketAddr, String)>,
}

/// Puts every chunk of `ids` into `store`: those it lacks from `peers` in order, each asked for
/// what is still missing, then what no peer gave from `floor` (which returns a chunk's file).
/// Each peer gets `timeout` to connect and between reads.
pub fn fetch(
    store: &Store,
    ids: &[Id],
    peers: &[SocketAddr],
    timeout: Duration,
    floor: &mut dyn FnMut(&Id) -> Result<Vec<u8>>,
) -> Result<FetchStats> {
    let mut stats = FetchStats::default();
    let mut missing: Vec<Id> = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for id in ids {
        if !seen.insert(*id) {
            continue;
        }
        if store.verified(id)? {
            stats.held += 1;
        } else {
            missing.push(*id);
        }
    }
    for peer in peers {
        if missing.is_empty() {
            break;
        }
        match ask(store, *peer, &missing, timeout, &mut stats) {
            Ok(()) => {}
            Err(e) => stats.dropped.push((*peer, e.to_string())),
        }
        missing.retain(|id| !store.has(id));
    }
    for id in &missing {
        let file = floor(id)?;
        store.receive(id, &file)?;
        stats.floor_chunks += 1;
        stats.floor_bytes += file.len() as u64;
    }
    Ok(stats)
}

fn ask(
    store: &Store,
    peer: SocketAddr,
    want: &[Id],
    timeout: Duration,
    stats: &mut FetchStats,
) -> Result<()> {
    let conn = TcpStream::connect_timeout(&peer, timeout)?;
    conn.set_read_timeout(Some(timeout))?;
    conn.set_write_timeout(Some(timeout))?;
    conn.set_nodelay(true)?;
    let mut out = BufWriter::new(conn.try_clone()?);
    out.write_all(MAGIC)?;
    out.write_all(&(want.len() as u32).to_le_bytes())?;
    for id in want {
        out.write_all(id)?;
    }
    out.flush()?;
    let mut input = BufReader::with_capacity(1 << 20, conn);
    for id in want {
        let mut got: Id = [0u8; 32];
        input.read_exact(&mut got)?;
        if got != *id {
            return Err("answered a different chunk".into());
        }
        let len = read_u32(&mut input)?;
        if len == NOPE {
            continue;
        }
        let file = crate::ship::read_bounded(&mut input, len, MAX_FILE as usize, "peer chunk")?;
        store.receive(id, &file)?;
        stats.peer_chunks += 1;
        stats.peer_bytes += u64::from(len);
    }
    Ok(())
}

fn read_u32(input: &mut dyn Read) -> Result<u32> {
    let mut b = [0u8; 4];
    input.read_exact(&mut b)?;
    Ok(u32::from_le_bytes(b))
}
