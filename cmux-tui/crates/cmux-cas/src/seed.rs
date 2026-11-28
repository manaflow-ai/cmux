//! VM seeding of the public tier (hq `docs/design/cold-storage-and-shared-tier.md`, P2): a
//! machine that holds public `cas/1` content serves it to the machines of its own region, so a
//! second machine fetches a toolchain from the first and only what no peer gives from the
//! floor (the region's mirror shard, R2 by Range, any source the caller names).
//!
//! Leo, 2026-11-25: "think torrent seeding. like, each customer... maybe still pays for each
//! logical" (the doc's quote); RFD 0008's read order: peers, then mirror, then R2, every read
//! verified.
//!
//! The wire is the cmux-session-pack peer protocol (cmux#55781) with two fields more: the
//! asker's region, and what it wants (a manifest or chunks). One request and one answer on any
//! byte stream:
//!
//! - request: `CASP1\n`, the region's length (u8) and bytes, the want (`M` manifests or `C`
//!   chunk files), a count (u32 LE), then that many 32-byte ids;
//! - answer, per id in order: the id, then the length (u32 LE) and the bytes, or the length
//!   [`NOPE`] and nothing when the seeder will not send it.
//!
//! What keeps it safe:
//!
//! - **Public only.** A [`Seeder`] serves a [`Public`] tier and answers only ids that tier's
//!   index names: chunks of a published manifest, manifests of a published entry. A chunk file
//!   that sits in the store directory but no published manifest names is a NOPE, so a tenant's
//!   chunk can never leave by this route; tenant data has no store here at all.
//! - **Region-scoped.** A seeder answers only an asker of its own region (else every id is a
//!   NOPE), and [`fetch`] asks only peers of its own region; cross-region bytes come from the
//!   floor, never from a customer machine.
//! - **Upload capped.** Every byte a seeder sends is taken from one [`UploadCap`] (a token
//!   bucket shared by its connections); a file the bucket cannot pay for now is a NOPE, never a
//!   wait, so seeding never shows in a machine's network bill past its cap.
//! - **Verified.** A peer can waste bytes but never change them: a manifest is checked against
//!   its id (`Id::of`), every chunk file decodes to its id before it is stored
//!   ([`Store::receive`]), and a peer that sends one wrong file, a different id or a cut answer
//!   is dropped for the rest of the fetch. The asker names the entry (from an index it trusts);
//!   a peer only supplies bytes against ids, and the entry is adopted ([`Public::adopt`]) only
//!   once every chunk is held and read back.
//! - **Off by default.** Nothing here listens, connects or uploads unless a caller runs it:
//!   `cas-seed serve` and `cas-seed fetch` are opt-in commands; no default enables them.

use crate::public::{Entry, Public, PublicIndex};
use crate::{Id, Result};
use std::collections::HashSet;
use std::io::{BufReader, BufWriter, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAGIC: &[u8; 6] = b"CASP1\n";
/// The length an answer gives an item the seeder will not send.
pub const NOPE: u32 = u32::MAX;
/// The most ids one request may name.
pub const MAX_WANT: u32 = 1 << 16;
/// The largest item a seeder may send: a chunk file holds at most 256 KiB raw
/// ([`crate::cdc::MAX`]) plus its header; a manifest of a big toolchain is a few MiB.
pub const MAX_ITEM: u32 = 64 << 20;
/// The longest region name.
pub const MAX_REGION: usize = 64;

/// What a request asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Want {
    /// Manifests, by their id.
    Manifest,
    /// Chunk files, by the chunk's id.
    Chunk,
}

impl Want {
    fn byte(self) -> u8 {
        match self {
            Self::Manifest => b'M',
            Self::Chunk => b'C',
        }
    }

    fn of(b: u8) -> Result<Self> {
        match b {
            b'M' => Ok(Self::Manifest),
            b'C' => Ok(Self::Chunk),
            other => Err(format!("unknown want {other}").into()),
        }
    }
}

/// A seeder's upload budget: `rate` bytes a second, at most `burst` saved up. One bucket is
/// shared by every connection a seeder answers.
#[derive(Debug)]
pub struct UploadCap {
    rate: u64,
    burst: u64,
    state: Mutex<(f64, Instant)>,
}

impl UploadCap {
    /// A bucket that starts full.
    pub fn new(rate: u64, burst: u64) -> Self {
        Self { rate, burst, state: Mutex::new((burst as f64, Instant::now())) }
    }

    /// Takes `n` bytes if the bucket holds them now; else takes nothing and says no.
    pub fn take(&self, n: u64) -> bool {
        let Ok(mut s) = self.state.lock() else { return false };
        let now = Instant::now();
        let refill = now.duration_since(s.1).as_secs_f64() * self.rate as f64;
        s.0 = (s.0 + refill).min(self.burst as f64);
        s.1 = now;
        if s.0 >= n as f64 {
            s.0 -= n as f64;
            true
        } else {
            false
        }
    }
}

/// What a seeder sent and refused, for its log and tests.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct SeedStats {
    pub sent_items: u64,
    pub sent_bytes: u64,
    /// Asked for by a machine of another region.
    pub refused_region: u64,
    /// Not public: no published entry names it.
    pub refused_not_public: u64,
    /// Over the upload cap.
    pub refused_cap: u64,
}

/// Serves a public tier to the machines of one region.
pub struct Seeder {
    public: Public,
    region: String,
    cap: UploadCap,
    stats: Mutex<SeedStats>,
}

impl Seeder {
    /// A seeder of `public` for `region`, sending at most what `cap` allows.
    pub fn new(public: Public, region: impl Into<String>, cap: UploadCap) -> Result<Self> {
        let region = region.into();
        check_region(&region)?;
        Ok(Self { public, region, cap, stats: Mutex::new(SeedStats::default()) })
    }

    /// What it sent and refused so far.
    pub fn stats(&self) -> SeedStats {
        self.stats.lock().map(|s| s.clone()).unwrap_or_default()
    }

    /// Answers every machine that connects to `listener`, one scoped thread a connection (each
    /// joined before this returns), until the listener fails. `stop` ends it after the
    /// connection in hand (tests; a service runs until killed).
    pub fn serve(&self, listener: TcpListener, stop: &std::sync::atomic::AtomicBool) {
        std::thread::scope(|s| {
            for conn in listener.incoming() {
                if stop.load(std::sync::atomic::Ordering::SeqCst) {
                    break;
                }
                let Ok(conn) = conn else { continue };
                s.spawn(move || {
                    // A peer that hangs up or sends garbage only ends its own connection.
                    let _ = self.answer(conn);
                });
            }
        });
    }

    /// Reads one request from `conn` and answers it.
    pub fn answer(&self, conn: TcpStream) -> Result<()> {
        conn.set_read_timeout(Some(Duration::from_secs(30)))?;
        let mut input = BufReader::new(conn.try_clone()?);
        let mut magic = [0u8; 6];
        input.read_exact(&mut magic)?;
        if &magic != MAGIC {
            return Err("not a seed request".into());
        }
        let mut len = [0u8; 1];
        input.read_exact(&mut len)?;
        let mut region = vec![0u8; usize::from(len[0])];
        input.read_exact(&mut region)?;
        let mut want = [0u8; 1];
        input.read_exact(&mut want)?;
        let want = Want::of(want[0])?;
        let n = read_u32(&mut input)?;
        if n > MAX_WANT {
            return Err(format!("a request for {n} items is over {MAX_WANT}").into());
        }
        let mut ids = Vec::with_capacity(n as usize);
        for _ in 0..n {
            let mut id = [0u8; 32];
            input.read_exact(&mut id)?;
            ids.push(Id(id));
        }
        let same_region = region == self.region.as_bytes();
        // The index is read per request: what was published or adopted since is served too.
        let (index, manifests) = if same_region { self.published()? } else { Default::default() };
        let mut out = BufWriter::with_capacity(1 << 20, conn);
        for id in &ids {
            out.write_all(&id.0)?;
            let item = if !same_region {
                self.count(|s| s.refused_region += 1);
                None
            } else {
                self.item(want, id, &index, &manifests)
            };
            match item {
                Some(bytes) => {
                    out.write_all(&(bytes.len() as u32).to_le_bytes())?;
                    out.write_all(&bytes)?;
                }
                None => out.write_all(&NOPE.to_le_bytes())?,
            }
        }
        out.flush()?;
        Ok(())
    }

    fn published(&self) -> Result<(PublicIndex, HashSet<Id>)> {
        let manifests = self.public.entries()?.into_iter().map(|e| e.manifest).collect();
        Ok((self.public.index()?, manifests))
    }

    fn item(
        &self,
        want: Want,
        id: &Id,
        index: &PublicIndex,
        manifests: &HashSet<Id>,
    ) -> Option<Vec<u8>> {
        let public = match want {
            Want::Manifest => manifests.contains(id),
            Want::Chunk => index.has(id),
        };
        if !public {
            self.count(|s| s.refused_not_public += 1);
            return None;
        }
        let bytes = match want {
            Want::Manifest => self.public.manifest_bytes(id).ok()?,
            Want::Chunk => self.public.store().file(id).ok()?,
        };
        if bytes.len() > MAX_ITEM as usize {
            return None;
        }
        if !self.cap.take(bytes.len() as u64) {
            self.count(|s| s.refused_cap += 1);
            return None;
        }
        self.count(|s| {
            s.sent_items += 1;
            s.sent_bytes += bytes.len() as u64;
        });
        Some(bytes)
    }

    fn count(&self, f: impl FnOnce(&mut SeedStats)) {
        if let Ok(mut s) = self.stats.lock() {
            f(&mut s);
        }
    }
}

fn check_region(region: &str) -> Result<()> {
    if region.is_empty() || region.len() > MAX_REGION {
        return Err(format!("a region is 1 to {MAX_REGION} bytes").into());
    }
    Ok(())
}

/// A machine that may seed: its address and the region it says it is in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    pub addr: SocketAddr,
    pub region: String,
}

impl std::str::FromStr for Peer {
    type Err = String;
    /// `REGION@HOST:PORT`.
    fn from_str(s: &str) -> std::result::Result<Self, String> {
        let (region, addr) = s.split_once('@').ok_or("a peer is REGION@HOST:PORT")?;
        let addr = addr.parse().map_err(|e| format!("{addr}: {e}"))?;
        Ok(Self { addr, region: region.to_string() })
    }
}

/// What a [`fetch`] took from where.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct FetchStats {
    /// Chunks the tier already held.
    pub held: u64,
    /// Items (the manifest and chunks) and bytes from peers of the region.
    pub peer_items: u64,
    pub peer_bytes: u64,
    /// Items and bytes from the floor.
    pub floor_items: u64,
    pub floor_bytes: u64,
    /// Peers of another region, never asked.
    pub skipped_region: u64,
    /// Peers dropped: unreachable, timed out, cut short or sent bytes that are not their id.
    pub dropped: Vec<(SocketAddr, String)>,
}

/// Puts `entry` into `public`: its manifest and every chunk it lacks, from the `peers` of
/// `region` in order (each asked for what is still missing), then what no peer gave from
/// `floor` (which returns a manifest's bytes or a chunk's file). The entry is adopted only once
/// all of it is held and read back, so the tier then seeds it too. `entry` must come from an
/// index the caller trusts (a published index, a signed pointer): peers only supply bytes.
pub fn fetch(
    public: &Public,
    entry: &Entry,
    region: &str,
    peers: &[Peer],
    timeout: Duration,
    floor: &mut dyn FnMut(Want, &Id) -> Result<Vec<u8>>,
) -> Result<FetchStats> {
    check_region(region)?;
    let mut stats = FetchStats::default();
    let local: Vec<&Peer> = peers
        .iter()
        .filter(|p| {
            let same = p.region == region;
            if !same {
                stats.skipped_region += 1;
            }
            same
        })
        .collect();
    let mut dropped: HashSet<SocketAddr> = HashSet::new();

    // The manifest first: its id is the entry's, so a peer cannot pass off another.
    let id = entry.manifest;
    let mut manifest = public.manifest_bytes(&id).ok();
    for p in &local {
        if manifest.is_some() {
            break;
        }
        match ask(p, region, Want::Manifest, &[id], timeout, &mut |_, b| {
            if Id::of(b) != id {
                return Err("sent a manifest that is not its id".into());
            }
            manifest = Some(b.to_vec());
            Ok(())
        }) {
            Ok(n) => {
                stats.peer_items += n.0;
                stats.peer_bytes += n.1;
            }
            Err(e) => {
                dropped.insert(p.addr);
                stats.dropped.push((p.addr, e.to_string()));
            }
        }
    }
    let manifest = match manifest {
        Some(m) => m,
        None => {
            let b = floor(Want::Manifest, &id)?;
            stats.floor_items += 1;
            stats.floor_bytes += b.len() as u64;
            b
        }
    };
    let parsed = crate::Manifest::from_bytes(&manifest, &id)?;

    let mut missing = Vec::new();
    for c in parsed.distinct_chunks() {
        if public.store().has(&c.id) {
            stats.held += 1;
        } else {
            missing.push(c.id);
        }
    }
    for p in &local {
        if missing.is_empty() {
            break;
        }
        if dropped.contains(&p.addr) {
            continue;
        }
        let store = public.store();
        match ask(p, region, Want::Chunk, &missing, timeout, &mut |cid, file| {
            store.receive(cid, file)
        }) {
            Ok(n) => {
                stats.peer_items += n.0;
                stats.peer_bytes += n.1;
            }
            Err(e) => {
                dropped.insert(p.addr);
                stats.dropped.push((p.addr, e.to_string()));
            }
        }
        missing.retain(|c| !store.has(c));
    }
    for c in &missing {
        let file = floor(Want::Chunk, c)?;
        public.store().receive(c, &file)?;
        stats.floor_items += 1;
        stats.floor_bytes += file.len() as u64;
    }
    public.adopt(entry, &manifest)?;
    Ok(stats)
}

/// Asks `peer` for `want` of `ids`; hands each item it sends to `got` (which checks it).
/// Returns the items and bytes it sent.
fn ask(
    peer: &Peer,
    region: &str,
    want: Want,
    ids: &[Id],
    timeout: Duration,
    got: &mut dyn FnMut(&Id, &[u8]) -> Result<()>,
) -> Result<(u64, u64)> {
    let conn = TcpStream::connect_timeout(&peer.addr, timeout)?;
    conn.set_read_timeout(Some(timeout))?;
    conn.set_write_timeout(Some(timeout))?;
    conn.set_nodelay(true)?;
    let mut out = BufWriter::new(conn.try_clone()?);
    out.write_all(MAGIC)?;
    out.write_all(&[u8::try_from(region.len())?])?;
    out.write_all(region.as_bytes())?;
    out.write_all(&[want.byte()])?;
    out.write_all(&u32::try_from(ids.len())?.to_le_bytes())?;
    for id in ids {
        out.write_all(&id.0)?;
    }
    out.flush()?;
    let mut input = BufReader::with_capacity(1 << 20, conn);
    let (mut items, mut bytes) = (0u64, 0u64);
    for id in ids {
        let mut echo = [0u8; 32];
        input.read_exact(&mut echo)?;
        if echo != id.0 {
            return Err("answered a different id".into());
        }
        let len = read_u32(&mut input)?;
        if len == NOPE {
            continue;
        }
        if len > MAX_ITEM {
            return Err(format!("an item of {len} bytes").into());
        }
        let mut buf = vec![0u8; len as usize];
        input.read_exact(&mut buf)?;
        got(id, &buf)?;
        items += 1;
        bytes += u64::from(len);
    }
    Ok((items, bytes))
}

fn read_u32(input: &mut dyn Read) -> Result<u32> {
    let mut b = [0u8; 4];
    input.read_exact(&mut b)?;
    Ok(u32::from_le_bytes(b))
}
