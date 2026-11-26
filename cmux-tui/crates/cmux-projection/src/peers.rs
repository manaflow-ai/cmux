//! Fleet blob seeding (hq `docs/rfd/0008-fleet-blob-seeding.md`): where a projected checkout gets
//! the blobs its host's mirror lacks before it asks GitHub, and how a host seeds what it holds.
//!
//! On unless `CMUX_PROJECTION_PEERS=0`. A missing blob is asked of, in order:
//!
//! 1. the tailnet peers that hold it (`CMUX_PROJECTION_PEER_INDEX`: a file, or an `http(s)` URL
//!    such as the controller's `GET /v1/seeds?repo=R&zone=Z&format=text`, of one seed base URL per
//!    line, nearest first; a URL's answer is kept for a minute, so back-to-back checkouts ask once);
//!    the nearest two at most, each asked for the whole missing set in one `POST <base>/objects`
//!    whose first byte must come within 250 ms ([`batch_request`]); a seed that does not take
//!    batches is asked per blob;
//! 2. the controller SSD (`CMUX_PROJECTION_CACHE_URL`, read token in
//!    `CMUX_PROJECTION_CACHE_TOKEN_FILE`);
//! 3. R2 (`CMUX_PROJECTION_R2_URL`);
//!
//! each per blob as `GET <base>/objects/<id>`, then 4. git: whatever none of them has goes to the
//! existing one-request `git fetch` ([`crate::git::fetch_missing`]). A source that is not
//! configured is skipped, one that fails three times in a row is dropped for the rest of the
//! mount, and nothing in the chain can fail the mount: with no source left every blob goes to git
//! as before. Every answer is hashed and must match the id it was asked for (SHA-1 with collision
//! detection, the algorithm git ships, so a crafted collision is refused too), so any source is
//! untrusted transport: a wrong answer is dropped, a peer that sent one is not asked again for
//! this batch, and the next source is asked. A verified blob is written into the host's mirror as
//! a loose object, so the host now seeds it too.
//!
//! [`serve`] is the seeding side: `GET /objects/<id>` and `POST /objects` (a list of ids, answered
//! as a stream of `<id> <len>\n<bytes>` for the ids it holds) from the one object store it is
//! started on (a host seeds only the repos it is started for: that is the per-repo allowlist),
//! read only, bound to the address it is given, with an upload rate limit, a cap on requests
//! served at once, a load cutoff, and a yield to the host's own builds (a held build lock, or a
//! GitHub Actions job running on the host), so seeding never starves the host's own work or a
//! nightly. A seed that is over any of them answers 503 at once and the client moves on.
//! [`heartbeat`] tells the controller's seed index what the seed holds, every minute.

use std::collections::HashMap;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::{TcpListener, TcpStream, ToSocketAddrs as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use sha1collisiondetection::Sha1CD;
use sha2::Digest as _;

/// The flag that turns the chain off (`0`).
pub const FLAG: &str = "CMUX_PROJECTION_PEERS";

/// The git object id of a blob with these bytes: sha1 for a 40-hex id, sha256 for a 64-hex id.
/// Bytes that carry a SHA-1 collision attack hash to no id (an empty string), so they never match.
#[must_use]
pub fn blob_id(bytes: &[u8], hex_len: usize) -> String {
    let header = format!("blob {}\0", bytes.len());
    if hex_len == 64 {
        let mut hash = sha2::Sha256::new();
        sha2::Digest::update(&mut hash, header.as_bytes());
        sha2::Digest::update(&mut hash, bytes);
        hex(&sha2::Digest::finalize(hash))
    } else {
        let mut hash = Sha1CD::default();
        hash.update(header.as_bytes());
        hash.update(bytes);
        hash.finalize_cd().map(|digest| hex(&digest)).unwrap_or_default()
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Whether `bytes` are the blob named `oid`.
#[must_use]
pub fn verify(oid: &str, bytes: &[u8]) -> bool {
    valid_id(oid) && blob_id(bytes, oid.len()) == oid
}

fn valid_id(oid: &str) -> bool {
    (oid.len() == 40 || oid.len() == 64)
        && oid.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// What one source answered for one id.
#[derive(Debug, PartialEq, Eq)]
pub enum Answer {
    Found(Vec<u8>),
    /// The source does not hold it (404).
    Absent,
    /// Up but at its limit (503, 429): ask the next source; it is not counted as a failure, since
    /// a seed answers busy by design when more checkouts ask it than it serves at once.
    Busy,
    /// Unreachable, timed out or another status: ask the next source.
    Failed,
}

/// What one source answered for a batch.
#[derive(Debug, PartialEq, Eq)]
pub enum BatchAnswer {
    /// It streamed what it holds of the ids (each record handed to `each`); what it did not
    /// send, it does not hold.
    Streamed,
    /// It does not take batches (an older seed, or not an `http://` base): ask it per blob.
    Unsupported,
    /// Up but at its limit: ask the next source.
    Busy,
    /// Unreachable, no first byte in time, or a broken stream: ask the next source.
    Failed,
}

/// The network, so tests can stand in for it: one `GET`, and one batch.
pub trait Get: Send + Sync {
    fn get(&self, url: &str, token: Option<&str>, deadline: Duration) -> Answer;

    /// Asks the seed at `base` for all of `ids` at once and hands each `(id, bytes)` record it
    /// streams to `each`, which returns `false` to stop reading (a record that failed its check).
    fn batch(
        &self,
        _base: &str,
        _ids: &[String],
        _first_byte: Duration,
        _each: &mut dyn FnMut(&str, Vec<u8>) -> bool,
    ) -> BatchAnswer {
        BatchAnswer::Unsupported
    }
}

/// The network: one blocking client with short deadlines, so a stalled source costs a deadline,
/// never a stall.
pub struct Http {
    client: reqwest::blocking::Client,
}

impl Http {
    pub fn new() -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = cmux_egress::blocking_client_builder("cmux_projection::peers")
            .connect_timeout(Duration::from_millis(500))
            .timeout(Duration::from_secs(20))
            .pool_max_idle_per_host(PARALLEL)
            .build()?;
        Ok(Self { client })
    }
}

impl Get for Http {
    fn get(&self, url: &str, token: Option<&str>, deadline: Duration) -> Answer {
        let mut request = self.client.get(url).timeout(deadline);
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        match request.send() {
            Ok(response) if response.status().as_u16() == 404 => Answer::Absent,
            Ok(response) if matches!(response.status().as_u16(), 429 | 503) => Answer::Busy,
            Ok(response) if response.status().is_success() => {
                response.bytes().map_or(Answer::Failed, |bytes| Answer::Found(bytes.to_vec()))
            }
            _ => Answer::Failed,
        }
    }

    fn batch(
        &self,
        base: &str,
        ids: &[String],
        first_byte: Duration,
        each: &mut dyn FnMut(&str, Vec<u8>) -> bool,
    ) -> BatchAnswer {
        batch_request(base, ids, first_byte, each)
    }
}

/// The largest blob a batch record may carry; a bigger length is a broken stream.
const MAX_RECORD: usize = 1 << 30;
/// The largest batch request body a seed reads: 8 MiB is about 190,000 ids.
const MAX_BATCH_BODY: usize = 8 << 20;
/// How long a batch stream may go quiet once it has started.
const BATCH_IDLE: Duration = Duration::from_secs(2);

/// One batch over plain HTTP/1.1 on the tailnet: `POST <base>/objects` with one id per line,
/// answered `200` with `<id> <len>\n<bytes>` records until the seed closes the connection. The
/// status line must start within `first_byte`, so a slow peer costs one short deadline. An
/// `https://` base is not a tailnet seed and is asked per blob.
pub fn batch_request(
    base: &str,
    ids: &[String],
    first_byte: Duration,
    each: &mut dyn FnMut(&str, Vec<u8>) -> bool,
) -> BatchAnswer {
    let Some(rest) = base.trim_end_matches('/').strip_prefix("http://") else {
        return BatchAnswer::Unsupported;
    };
    let (authority, path) = rest.split_once('/').map_or((rest, ""), |(host, path)| (host, path));
    let Some(addr) = authority.to_socket_addrs().ok().and_then(|mut addrs| addrs.next()) else {
        return BatchAnswer::Failed;
    };
    let Ok(stream) = TcpStream::connect_timeout(&addr, Duration::from_millis(500)) else {
        return BatchAnswer::Failed;
    };
    let _ = stream.set_nodelay(true);
    let mut body = ids.join("\n");
    body.push('\n');
    let prefix = if path.is_empty() { String::new() } else { format!("/{path}") };
    let head = format!(
        "POST {prefix}/objects HTTP/1.1\r\nHost: {authority}\r\nContent-Type: text/plain\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let mut writer = &stream;
    if stream.set_write_timeout(Some(BATCH_IDLE)).is_err()
        || writer.write_all(head.as_bytes()).is_err()
        || writer.write_all(body.as_bytes()).is_err()
        || stream.set_read_timeout(Some(first_byte)).is_err()
    {
        return BatchAnswer::Failed;
    }
    let mut reader = BufReader::new(&stream);
    let mut status = String::new();
    if reader.read_line(&mut status).unwrap_or(0) == 0 {
        return BatchAnswer::Failed;
    }
    match status.split_whitespace().nth(1) {
        Some("200") => {}
        Some("429" | "503") => return BatchAnswer::Busy,
        Some("400" | "404" | "405" | "501") => return BatchAnswer::Unsupported,
        _ => return BatchAnswer::Failed,
    }
    if stream.set_read_timeout(Some(BATCH_IDLE)).is_err() {
        return BatchAnswer::Failed;
    }
    loop {
        let mut header = String::new();
        match reader.read_line(&mut header) {
            Ok(0) | Err(_) => return BatchAnswer::Failed,
            Ok(_) if header.trim().is_empty() => break,
            Ok(_) => {}
        }
    }
    loop {
        let mut record = String::new();
        match reader.read_line(&mut record) {
            Ok(0) => return BatchAnswer::Streamed,
            Ok(_) => {}
            Err(_) => return BatchAnswer::Failed,
        }
        let mut parts = record.split_whitespace();
        let (Some(oid), Some(len)) = (parts.next(), parts.next().and_then(|len| len.parse().ok()))
        else {
            return BatchAnswer::Failed;
        };
        if !valid_id(oid) || len > MAX_RECORD {
            return BatchAnswer::Failed;
        }
        let mut bytes = vec![0; len];
        if reader.read_exact(&mut bytes).is_err() {
            return BatchAnswer::Failed;
        }
        if !each(oid, bytes) {
            return BatchAnswer::Streamed;
        }
    }
}

/// One place to ask, by name for the log.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Remote {
    pub tier: &'static str,
    pub base: String,
    pub token: Option<String>,
}

impl Remote {
    /// How long one answer from this tier may take: a peer is a host on the same network, so a
    /// slow one is dropped fast; the controller SSD and R2 are farther and get longer.
    fn deadline(&self) -> Duration {
        match self.tier {
            "peer" => Duration::from_secs(2),
            "ssd" => Duration::from_secs(10),
            _ => Duration::from_secs(20),
        }
    }
}

/// Requests in flight per checkout.
const PARALLEL: usize = 8;
/// Peers asked for one blob before the controller SSD.
const PEERS_PER_BLOB: usize = 2;
/// How long a peer may take to start answering a batch before the next source is asked.
const BATCH_FIRST_BYTE: Duration = Duration::from_millis(250);
/// Failures in a row (unreachable, timed out, busy, error status, wrong bytes) after which a
/// source is skipped for the rest of a fill, so a dead peer costs three deadlines, not one per
/// blob.
const DEAD_AFTER: usize = 3;

/// The sources, in the order they are asked.
pub struct Chain {
    remotes: Vec<Remote>,
    get: Box<dyn Get>,
    /// The object stores ([`crate::s3`]) among `remotes`, found by their `base`.
    stores: Vec<crate::s3::Store>,
}

/// What [`Chain::fill`] did, for the mount's timing line.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Filled {
    pub peer: usize,
    pub ssd: usize,
    /// From R2 or another S3-compatible store ([`crate::s3`]).
    pub r2: usize,
    /// Answers whose bytes did not hash to the id asked for (dropped).
    pub rejected: usize,
    /// Sources skipped for the rest of the fill after [`DEAD_AFTER`] failures in a row.
    pub dropped: usize,
}

/// Whether the chain runs, from the value of [`FLAG`]: on unless it is `0`, `false` or `off`.
#[must_use]
pub fn enabled(flag: Option<&str>) -> bool {
    !matches!(flag.map(str::trim), Some("0" | "false" | "off"))
}

impl Chain {
    #[must_use]
    pub fn new(remotes: Vec<Remote>, get: Box<dyn Get>) -> Self {
        Self { remotes, get, stores: Vec::new() }
    }

    /// The chain with `stores` asked after its other sources, in order.
    #[must_use]
    pub fn with_stores(mut self, stores: Vec<crate::s3::Store>) -> Self {
        self.remotes.extend(stores.iter().map(crate::s3::Store::remote));
        self.stores.extend(stores);
        self
    }

    /// The chain the environment names, or `None` when [`FLAG`] turns it off or no client can be
    /// built. Nothing here can fail the mount: a source that can't be read is left out, and with
    /// no sources every blob goes to git as before.
    #[must_use]
    pub fn from_env() -> Option<Self> {
        if !enabled(std::env::var(FLAG).ok().as_deref()) {
            return None;
        }
        let get = match Http::new() {
            Ok(get) => get,
            Err(error) => {
                eprintln!("cmux-projection: blob sources skipped, no HTTP client: {error}");
                return None;
            }
        };
        let mut remotes = Vec::new();
        if let Ok(index) = std::env::var("CMUX_PROJECTION_PEER_INDEX") {
            remotes.extend(peers_in(&get, &index));
        }
        if let Some(base) = std::env::var("CMUX_PROJECTION_CACHE_URL")
            .ok()
            .and_then(|url| crate::s3::http_base(&url))
        {
            let token = std::env::var("CMUX_PROJECTION_CACHE_TOKEN_FILE")
                .ok()
                .and_then(|file| std::fs::read_to_string(file).ok())
                .map(|token| token.trim().to_owned());
            remotes.push(Remote { tier: "ssd", base, token });
        }
        let stores = crate::s3::Config::from_env()
            .into_iter()
            .filter_map(|config| crate::s3::Store::new(config).ok())
            .collect();
        Some(Self::new(remotes, Box::new(get)).with_stores(stores))
    }

    /// The peers asked, as indexes: the nearest [`PEERS_PER_BLOB`] in index order (the
    /// controller's index lists the same zone first, then the same region, then the rest).
    fn nearest_peers(&self) -> Vec<usize> {
        self.remotes
            .iter()
            .enumerate()
            .filter(|(_, remote)| remote.tier == "peer")
            .map(|(at, _)| at)
            .take(PEERS_PER_BLOB)
            .collect()
    }

    /// The remotes one blob is asked of, as indexes: `peers` (the nearest peers that take no
    /// batches), then every non-peer source in order.
    fn order(&self, peers: &[usize]) -> Vec<usize> {
        let mut order = peers.to_vec();
        order.extend(
            self.remotes
                .iter()
                .enumerate()
                .filter(|(_, remote)| remote.tier != "peer")
                .map(|(at, _)| at),
        );
        order
    }

    /// The batch phase: each of the nearest peers in turn is asked for every blob still missing
    /// in one stream; a verified record is kept, a wrong one is counted and stops that peer. The
    /// peers that take no batches are returned, to be asked per blob.
    fn batches(
        &self,
        oids: &[String],
        have: &mut [Option<&'static str>],
        keep: &(dyn Fn(&str, &[u8]) -> anyhow::Result<()> + Sync),
        failures: &[AtomicUsize],
        rejected: &AtomicUsize,
    ) -> Vec<usize> {
        let mut per_blob = Vec::new();
        let at_of: HashMap<&str, usize> =
            oids.iter().enumerate().map(|(at, oid)| (oid.as_str(), at)).collect();
        for peer in self.nearest_peers() {
            let (Some(remote), Some(failed)) = (self.remotes.get(peer), failures.get(peer)) else {
                continue;
            };
            let missing: Vec<String> = oids
                .iter()
                .zip(have.iter())
                .filter(|(_, got)| got.is_none())
                .map(|(oid, _)| oid.clone())
                .collect();
            if missing.is_empty() {
                break;
            }
            let mut wrong = false;
            let answer = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                self.get.batch(&remote.base, &missing, BATCH_FIRST_BYTE, &mut |oid, bytes| {
                    let Some(&at) = at_of.get(oid) else { return true };
                    if !verify(oid, &bytes) {
                        wrong = true;
                        return false;
                    }
                    if let Some(slot) = have.get_mut(at)
                        && slot.is_none()
                        && keep(oid, &bytes).is_ok()
                    {
                        *slot = Some("peer");
                    }
                    true
                })
            }))
            .unwrap_or(BatchAnswer::Failed);
            if wrong {
                rejected.fetch_add(1, Ordering::Relaxed);
                failed.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            match answer {
                BatchAnswer::Streamed | BatchAnswer::Busy => failed.store(0, Ordering::Relaxed),
                BatchAnswer::Unsupported => per_blob.push(peer),
                BatchAnswer::Failed => {
                    failed.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        per_blob
    }

    /// The verified bytes of `oid` and the tier that gave them, or `None`. `failures` counts each
    /// source's failures in a row; one at [`DEAD_AFTER`] is not asked.
    fn one(
        &self,
        oid: &str,
        order: &[usize],
        failures: &[AtomicUsize],
        rejected: &AtomicUsize,
    ) -> Option<(&'static str, Vec<u8>)> {
        for &at in order {
            let (Some(failed), Some(remote)) = (failures.get(at), self.remotes.get(at)) else {
                continue;
            };
            if failed.load(Ordering::Relaxed) >= DEAD_AFTER {
                continue;
            }
            let url = format!("{}/objects/{oid}", remote.base.trim_end_matches('/'));
            let answer = match self.stores.iter().find(|store| store.config.base == remote.base) {
                None => self.get.get(&url, remote.token.as_deref(), remote.deadline()),
                Some(store) => match store.get(oid, remote.deadline()) {
                    crate::s3::Fetched::Answer(answer) => answer,
                    // Wrong or missing keys refuse every blob: drop the store on this first answer.
                    crate::s3::Fetched::Denied(status) => {
                        if failed.swap(DEAD_AFTER, Ordering::Relaxed) < DEAD_AFTER {
                            eprintln!(
                                "cmux-projection: {} store {} answered {status}; skipped",
                                remote.tier, remote.base
                            );
                        }
                        continue;
                    }
                },
            };
            match answer {
                Answer::Found(bytes) if verify(oid, &bytes) => {
                    failed.store(0, Ordering::Relaxed);
                    return Some((remote.tier, bytes));
                }
                Answer::Found(_) => {
                    rejected.fetch_add(1, Ordering::Relaxed);
                    failed.fetch_add(1, Ordering::Relaxed);
                }
                Answer::Absent | Answer::Busy => failed.store(0, Ordering::Relaxed),
                Answer::Failed => {
                    failed.fetch_add(1, Ordering::Relaxed);
                }
            }
        }
        None
    }

    /// Asks the chain for each of `oids`, hands each verified blob to `keep` (which writes it into
    /// the mirror), and returns the ids no source had, for the git fetch. A blob a source or
    /// `keep` failed on, even by panicking, is left for git.
    pub fn fill(
        &self,
        oids: &[String],
        keep: &(dyn Fn(&str, &[u8]) -> anyhow::Result<()> + Sync),
    ) -> (Vec<String>, Filled) {
        if self.remotes.is_empty() || oids.is_empty() {
            return (oids.to_vec(), Filled::default());
        }
        let next = AtomicUsize::new(0);
        let rejected = AtomicUsize::new(0);
        let failures: Vec<AtomicUsize> = self.remotes.iter().map(|_| AtomicUsize::new(0)).collect();
        let mut batched: Vec<Option<&'static str>> = vec![None; oids.len()];
        let per_blob = self.batches(oids, &mut batched, keep, &failures, &rejected);
        let order = self.order(&per_blob);
        let found: Mutex<Vec<(usize, &'static str)>> = Mutex::new(
            batched
                .iter()
                .enumerate()
                .filter_map(|(at, tier)| tier.map(|tier| (at, tier)))
                .collect(),
        );
        let (batched, order) = (&batched, &order);
        std::thread::scope(|scope| {
            for _ in 0..PARALLEL.min(oids.len()) {
                scope.spawn(|| {
                    loop {
                        let at = next.fetch_add(1, Ordering::Relaxed);
                        let Some(oid) = oids.get(at) else { return };
                        if batched.get(at).is_some_and(Option::is_some) {
                            continue;
                        }
                        let got = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            self.one(oid, order, &failures, &rejected)
                                .filter(|(_, bytes)| keep(oid, bytes).is_ok())
                                .map(|(tier, _)| tier)
                        }));
                        if let Ok(Some(tier)) = got {
                            found.lock().unwrap_or_else(PoisonError::into_inner).push((at, tier));
                        }
                    }
                });
            }
        });
        let found = found.into_inner().unwrap_or_else(PoisonError::into_inner);
        let dropped =
            failures.iter().filter(|failed| failed.load(Ordering::Relaxed) >= DEAD_AFTER).count();
        let mut filled = Filled { rejected: rejected.into_inner(), dropped, ..Filled::default() };
        let mut have = vec![false; oids.len()];
        for (at, tier) in found {
            if let Some(slot) = have.get_mut(at) {
                *slot = true;
            }
            match tier {
                "peer" => filled.peer += 1,
                "ssd" => filled.ssd += 1,
                _ => filled.r2 += 1,
            }
        }
        let rest =
            oids.iter().zip(have).filter(|(_, have)| !have).map(|(oid, _)| oid.clone()).collect();
        (rest, filled)
    }

    /// One counter per source for [`Chain::blob`], kept for as long as the caller asks (a mount),
    /// so a dead source is skipped after [`DEAD_AFTER`] failures in a row rather than costing a
    /// deadline on every fault.
    #[must_use]
    pub fn counters(&self) -> Vec<AtomicUsize> {
        self.remotes.iter().map(|_| AtomicUsize::new(0)).collect()
    }

    /// The verified bytes of one blob from the first source that has it, or `None`: what a
    /// projected folder's fault asks before the Mac ([`crate::store_fetch`]).
    pub fn blob(&self, oid: &str, failures: &[AtomicUsize]) -> Option<Vec<u8>> {
        let rejected = AtomicUsize::new(0);
        let order = self.order(&self.nearest_peers());
        self.one(oid, &order, failures, &rejected).map(|(_, bytes)| bytes)
    }
}

/// The peers a peer index names: `index` is a file, or an `http(s)` URL asked once with a short
/// deadline. An index that can't be read names no peers, so the chain starts at the controller.
#[must_use]
pub fn peers_in(get: &dyn Get, index: &str) -> Vec<Remote> {
    peers_in_cached(get, index, index_cache(index).as_deref())
}

/// How long a URL index's answer is reused (the controller forgets a seed after three minutes).
const INDEX_FRESH: Duration = Duration::from_secs(60);

/// Where a URL index's last answer is kept: the user cache dir, one file per index URL.
fn index_cache(index: &str) -> Option<PathBuf> {
    let dir = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))?;
    // FNV-1a: a stable file name per URL.
    let hash = index.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |hash, byte| {
        (hash ^ u64::from(byte)).wrapping_mul(0x0100_0000_01b3)
    });
    Some(dir.join("cmux-projection").join(format!("peer-index-{hash:016x}")))
}

/// [`peers_in`] with the answer cache at `cache`: a URL index answered under [`INDEX_FRESH`] ago
/// is read from it, so back-to-back checkouts ask the controller once a minute.
#[must_use]
pub fn peers_in_cached(get: &dyn Get, index: &str, cache: Option<&Path>) -> Vec<Remote> {
    let text = if index.starts_with("http://") || index.starts_with("https://") {
        let fresh = cache.and_then(|cache| {
            let age = std::fs::metadata(cache).ok()?.modified().ok()?.elapsed().ok()?;
            (age < INDEX_FRESH).then(|| std::fs::read_to_string(cache).ok()).flatten()
        });
        if let Some(text) = fresh {
            text
        } else {
            match get.get(index, None, Duration::from_secs(2)) {
                Answer::Found(bytes) => {
                    let text = String::from_utf8_lossy(&bytes).into_owned();
                    if let Some(cache) = cache {
                        let _ = cache.parent().map(std::fs::create_dir_all);
                        let temp = cache.with_extension(format!("tmp{}", std::process::id()));
                        if std::fs::write(&temp, &text).is_ok() {
                            let _ = std::fs::rename(&temp, cache);
                        }
                    }
                    text
                }
                _ => {
                    eprintln!("cmux-projection: peer index {index} unreadable; no peers");
                    String::new()
                }
            }
        }
    } else {
        std::fs::read_to_string(index).unwrap_or_default()
    };
    peer_list(&text).into_iter().map(|base| Remote { tier: "peer", base, token: None }).collect()
}

/// The seed base URLs of a peer index: one per line; blank lines and `#` comments skipped.
#[must_use]
pub fn peer_list(text: &str) -> Vec<String> {
    text.lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .filter(|line| line.starts_with("http://") || line.starts_with("https://"))
        .map(str::to_owned)
        .collect()
}

/// Writes a verified blob into `git_dir` as a loose object (what `git hash-object -w` writes),
/// through a temporary file and a rename, so a reader never sees half an object.
pub fn write_loose(git_dir: &Path, oid: &str, bytes: &[u8]) -> anyhow::Result<()> {
    anyhow::ensure!(verify(oid, bytes), "{oid}: bytes do not hash to it");
    // `verify` checked `oid` is 40 or 64 ASCII hex, so these splits always succeed.
    let (Some(fan), Some(name), Some(short)) = (oid.get(..2), oid.get(2..), oid.get(2..10)) else {
        anyhow::bail!("{oid}: not an object id");
    };
    let dir = git_dir.join("objects").join(fan);
    let file = dir.join(name);
    if file.exists() {
        return Ok(());
    }
    std::fs::create_dir_all(&dir)?;
    let temp = dir.join(format!("tmp_obj_{}_{}", std::process::id(), short));
    {
        let mut encoder = flate2::write::ZlibEncoder::new(
            std::fs::File::create(&temp)?,
            flate2::Compression::fast(),
        );
        encoder.write_all(format!("blob {}\0", bytes.len()).as_bytes())?;
        encoder.write_all(bytes)?;
        encoder.finish()?.sync_all()?;
    }
    std::fs::rename(&temp, &file)?;
    Ok(())
}

/// A token bucket over an injected clock: [`Bucket::take`] says how long to wait before sending
/// `bytes`, so the rate holds without the bucket itself sleeping.
pub struct Bucket {
    rate: f64,
    burst: f64,
    tokens: f64,
    at: Instant,
}

impl Bucket {
    #[must_use]
    pub fn new(rate_bytes_per_s: u64, now: Instant) -> Self {
        let rate = rate_bytes_per_s.max(1) as f64;
        Self { rate, burst: rate, tokens: rate, at: now }
    }

    /// Takes `bytes` tokens (going into debt if need be) and returns the wait that repays it.
    pub fn take(&mut self, bytes: u64, now: Instant) -> Duration {
        let elapsed = now.saturating_duration_since(self.at).as_secs_f64();
        self.at = now;
        self.tokens = (self.tokens + elapsed * self.rate).min(self.burst) - bytes as f64;
        if self.tokens >= 0.0 {
            Duration::ZERO
        } else {
            Duration::from_secs_f64(-self.tokens / self.rate)
        }
    }
}

/// How a seed limits itself.
#[derive(Clone, Debug)]
pub struct SeedLimits {
    /// Bytes per second served, all requests together.
    pub rate: u64,
    /// Requests served at once; one more is answered 503.
    pub conns: usize,
    /// Above this load average per core, every request is answered 503.
    pub load_per_core: f64,
    /// Lock files the host's own work holds (`flock`): its build lock, and the lock a runner's
    /// job-started hook takes for a nightly or CI job. While one is held the seed answers 503,
    /// so the host's own builds never wait on seeding.
    pub yield_locks: Vec<PathBuf>,
}

impl Default for SeedLimits {
    fn default() -> Self {
        // 25% of a GCP lane VM's 2 Gbit/s; 4 at once; 1.5 per core (hq RFD 0008, "Bandwidth limits").
        Self { rate: 62_500_000, conns: 4, load_per_core: 1.5, yield_locks: Vec::new() }
    }
}

/// Whether some process holds `lock` (an exclusive `flock`): probed without waiting, never left
/// held. A lock file that does not exist is not held.
#[must_use]
pub fn lock_held(lock: &Path) -> bool {
    std::fs::File::open(lock).is_ok_and(|file| {
        cmux_file_lock::FileLock::held_elsewhere(&file, cmux_file_lock::Kind::Shared)
            .unwrap_or(false)
    })
}

/// Whether the host's own work wants the machine: one of its yield locks is held.
fn host_busy(limits: &SeedLimits) -> bool {
    limits.yield_locks.iter().any(|lock| lock_held(lock))
}

/// The 1-minute load average per core (Linux), or 0 where unknown.
fn load_per_core() -> f64 {
    let load = std::fs::read_to_string("/proc/loadavg")
        .ok()
        .and_then(|text| text.split_whitespace().next().and_then(|first| first.parse::<f64>().ok()))
        .unwrap_or(0.0);
    let cores = std::thread::available_parallelism().map_or(1, std::num::NonZero::get);
    load / cores as f64
}

/// The id of a `GET /objects/<id>` request line, or `None`.
#[must_use]
pub fn requested_id(line: &str) -> Option<&str> {
    let mut parts = line.split_whitespace();
    let (Some("GET"), Some(path)) = (parts.next(), parts.next()) else { return None };
    let oid = path.strip_prefix("/objects/")?;
    valid_id(oid).then_some(oid)
}

/// Serves `git_dir`'s blobs on `listen` until the process ends: `GET /objects/<id>`, read only,
/// HTTP/1.1 keep-alive, nothing else.
pub fn serve(git_dir: &Path, listen: &str, limits: SeedLimits) -> anyhow::Result<()> {
    serve_on(git_dir, TcpListener::bind(listen)?, &limits);
    Ok(())
}

/// [`serve`] on a listener already bound, so a caller that needs the port (a test) has it before
/// the first connection and no other socket can take it in between.
pub fn serve_on(git_dir: &Path, listener: TcpListener, limits: &SeedLimits) {
    let bucket = Mutex::new(Bucket::new(limits.rate, Instant::now()));
    let active = AtomicUsize::new(0);
    // The yield probe opens files, so its answer is kept for 2 s, not taken per connection.
    let mut busy: Option<(Instant, bool)> = None;
    // Each connection is a thread of this scope, so none outlives the seed.
    std::thread::scope(|scope| {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let _ = stream.set_nodelay(true);
            let now = Instant::now();
            let yielding = match busy {
                Some((at, answer))
                    if now.saturating_duration_since(at) < Duration::from_secs(2) =>
                {
                    answer
                }
                _ => {
                    let answer = host_busy(limits);
                    busy = Some((now, answer));
                    answer
                }
            };
            if yielding
                || active.load(Ordering::Relaxed) >= limits.conns
                || load_per_core() > limits.load_per_core
            {
                let _ = respond(&mut stream, "503 Service Unavailable", b"busy\n", true);
                continue;
            }
            active.fetch_add(1, Ordering::Relaxed);
            let (bucket, active) = (&bucket, &active);
            scope.spawn(move || {
                let _ = connection(git_dir, stream, bucket);
                active.fetch_sub(1, Ordering::Relaxed);
            });
        }
    });
}

fn respond(stream: &mut TcpStream, status: &str, body: &[u8], close: bool) -> std::io::Result<()> {
    let connection = if close { "close" } else { "keep-alive" };
    let mut out = format!(
        "HTTP/1.1 {status}\r\nContent-Length: {}\r\nContent-Type: application/octet-stream\r\nConnection: {connection}\r\n\r\n",
        body.len()
    )
    .into_bytes();
    out.extend_from_slice(body);
    stream.write_all(&out)
}

fn connection(git_dir: &Path, stream: TcpStream, bucket: &Mutex<Bucket>) -> anyhow::Result<()> {
    // A client's idle pooled connection holds one of the seed's few slots, so an idle one is
    // closed after 5 s, not held open for other checkouts to be answered busy.
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let mut objects = crate::git::ObjectReader::spawn(git_dir)?;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line)? == 0 {
            return Ok(());
        }
        // Headers: only a body's length is read.
        let mut length = 0usize;
        loop {
            let mut header = String::new();
            if reader.read_line(&mut header)? == 0 || header.trim().is_empty() {
                break;
            }
            if let Some((name, value)) = header.split_once(':')
                && name.trim().eq_ignore_ascii_case("content-length")
            {
                length = value.trim().parse().unwrap_or(usize::MAX);
            }
        }
        if is_batch(&line) {
            if length > MAX_BATCH_BODY {
                respond(&mut writer, "413 Content Too Large", b"", true)?;
                return Ok(());
            }
            let mut body = vec![0; length];
            reader.read_exact(&mut body)?;
            return stream_batch(&mut writer, &body, &mut objects, bucket);
        }
        if length > 0 {
            // A body on anything else is read past, so the next request line is a request line.
            std::io::copy(&mut (&mut reader).take(length as u64), &mut std::io::sink())?;
        }
        let Some(oid) = requested_id(&line) else {
            respond(&mut writer, "404 Not Found", b"", false)?;
            continue;
        };
        match objects.blob(oid) {
            Some(bytes) => {
                let wait = bucket
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .take(bytes.len() as u64, Instant::now());
                if !wait.is_zero() {
                    // The rate limit's intentional, bounded delay.
                    std::thread::sleep(wait.min(Duration::from_secs(5)));
                }
                respond(&mut writer, "200 OK", &bytes, false)?;
            }
            None => respond(&mut writer, "404 Not Found", b"", false)?,
        }
    }
}

/// Whether a request line is a batch: `POST /objects`.
fn is_batch(line: &str) -> bool {
    let mut parts = line.split_whitespace();
    matches!((parts.next(), parts.next()), (Some("POST"), Some("/objects")))
}

/// Answers a batch: one `<id> <len>\n<bytes>` record per id of `body` the store holds, under
/// the seed's rate, then closes the connection (the end of the stream is the end of the answer).
fn stream_batch(
    writer: &mut TcpStream,
    body: &[u8],
    objects: &mut crate::git::ObjectReader,
    bucket: &Mutex<Bucket>,
) -> anyhow::Result<()> {
    writer.write_all(
        b"HTTP/1.1 200 OK\r\nContent-Type: application/x-git-blobs\r\nConnection: close\r\n\r\n",
    )?;
    let mut out = std::io::BufWriter::new(writer);
    for oid in String::from_utf8_lossy(body).split_whitespace() {
        if !valid_id(oid) {
            continue;
        }
        let Some(bytes) = objects.blob(oid) else { continue };
        let wait = bucket
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .take(bytes.len() as u64, Instant::now());
        if !wait.is_zero() {
            out.flush()?;
            // The rate limit's intentional, bounded delay.
            std::thread::sleep(wait.min(Duration::from_secs(5)));
        }
        out.write_all(format!("{oid} {}\n", bytes.len()).as_bytes())?;
        out.write_all(&bytes)?;
    }
    out.flush()?;
    Ok(())
}

/// What a seed tells the controller's seed index each minute (`POST /v1/seeds/heartbeat`).
#[derive(Debug, serde::Serialize)]
pub struct Beat {
    pub host: String,
    pub seed_url: String,
    pub zone: String,
    pub repos: Vec<BeatRepo>,
}

/// One repo a seed holds: its pack names and branch tips.
#[derive(Debug, serde::Serialize)]
pub struct BeatRepo {
    pub repo: String,
    pub packs: Vec<String>,
    pub tips: std::collections::BTreeMap<String, String>,
}

/// The branches whose tips a heartbeat names.
const BEAT_BRANCHES: [&str; 3] = ["main", "feat-cmux-next", "nightly-next"];

/// What `git_dir` holds for `repo`: its `pack-<hex>` names and the tips of [`BEAT_BRANCHES`]
/// (local or `origin/` refs).
#[must_use]
pub fn beat_repo(git_dir: &Path, repo: &str) -> BeatRepo {
    let mut packs: Vec<String> = std::fs::read_dir(git_dir.join("objects").join("pack"))
        .map(|entries| {
            entries
                .flatten()
                .filter_map(|entry| {
                    if !entry.file_type().ok()?.is_file() {
                        return None;
                    }
                    let name = entry.file_name();
                    let pack = name.to_str()?.strip_suffix(".pack")?;
                    // Mirrors also hold loose-*.pack and temporary packs. The index accepts
                    // only checksum-named packs; one other name rejects the whole heartbeat.
                    valid_id(pack.strip_prefix("pack-")?).then(|| pack.to_owned())
                })
                .collect()
        })
        .unwrap_or_default();
    packs.sort();
    let mut tips = std::collections::BTreeMap::new();
    for branch in BEAT_BRANCHES {
        for name in [format!("refs/remotes/origin/{branch}"), format!("refs/heads/{branch}")] {
            let out = std::process::Command::new("git")
                .arg("--git-dir")
                .arg(git_dir)
                .args(["rev-parse", "--verify", "--quiet"])
                .arg(&name)
                .output();
            if let Ok(out) = out
                && out.status.success()
            {
                tips.insert(
                    branch.to_owned(),
                    String::from_utf8_lossy(&out.stdout).trim().to_owned(),
                );
                break;
            }
        }
    }
    BeatRepo { repo: repo.to_owned(), packs, tips }
}

/// How a heartbeat posts: each try's bound, the beat period, and the first retry's backoff.
#[derive(Debug, Clone, Copy)]
pub struct BeatPolicy {
    /// One try's bound. The index has answered in anywhere from 0.13 s to more than 15 s, so a
    /// 10 s bound failed a beat the index would have taken.
    pub attempt: Duration,
    /// Time from one beat's start to the next.
    pub period: Duration,
    /// The first retry's backoff. Each retry doubles it, up to `period / 4`, jittered to 50-150%.
    pub backoff: Duration,
}

impl BeatPolicy {
    /// Production: try for up to 30 s, beat every minute, retry from 2 s.
    pub const DEFAULT: Self = Self {
        attempt: Duration::from_secs(30),
        period: Duration::from_secs(60),
        backoff: Duration::from_secs(2),
    };
}

/// A factor in [0.5, 1.5) from the std hasher's random keys, so seeds that fail together
/// don't all retry at once.
fn jitter() -> f64 {
    use std::hash::{BuildHasher as _, Hasher as _};
    let mut hasher = std::collections::hash_map::RandomState::new().build_hasher();
    hasher.write_u128(Instant::now().elapsed().as_nanos());
    0.5 + (hasher.finish() % 1000) as f64 / 1000.0
}

/// Posts one beat's `body` to `url`, retrying with jittered backoff until it lands or the next
/// beat is due (`start + policy.period`). Returns the number of tries it took, or the last error.
/// A 4xx other than 408 and 429 is the index refusing the beat itself, so it is not retried.
pub fn post_beat(
    client: &reqwest::blocking::Client,
    url: &str,
    token: Option<&str>,
    body: &[u8],
    policy: BeatPolicy,
    start: Instant,
) -> Result<usize, String> {
    let deadline = start + policy.period;
    let mut backoff = policy.backoff;
    let mut tries = 0;
    loop {
        tries += 1;
        let left = deadline.saturating_duration_since(Instant::now());
        let mut request = client
            .post(url)
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .timeout(policy.attempt.min(left).max(Duration::from_millis(100)))
            .body(body.to_vec());
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        let error = match request.send() {
            Ok(response) if response.status().is_success() => return Ok(tries),
            Ok(response) => {
                let status = response.status();
                if status.is_client_error()
                    && status != reqwest::StatusCode::REQUEST_TIMEOUT
                    && status != reqwest::StatusCode::TOO_MANY_REQUESTS
                {
                    return Err(format!("{status} (not retried)"));
                }
                status.to_string()
            }
            Err(error) => format!("{error:#}"),
        };
        let wait = backoff.mul_f64(jitter());
        if Instant::now() + wait >= deadline {
            return Err(format!("{error} after {tries} tries"));
        }
        eprintln!("cmux-projection seed: heartbeat {url}: {error}; retry in {wait:?}");
        // The retry's backoff, not a synchronization wait.
        std::thread::sleep(wait);
        backoff = (backoff * 2).min(policy.period / 4);
    }
}

/// Posts `beat()` to `url` now and every minute after, never returning, so the controller's
/// index (which forgets a seed after three minutes) lists this host while it seeds. Run it on a
/// thread of the seed's scope. A failed try is retried with jittered backoff until the next beat
/// is due ([`post_beat`]), so one slow or failed answer never costs the seed its listing; it never
/// stops the seed.
pub fn heartbeat(url: &str, token: Option<&str>, beat: &dyn Fn() -> Beat) {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let policy = BeatPolicy::DEFAULT;
    let Ok(client) = cmux_egress::blocking_client_builder("cmux_projection::peers")
        .connect_timeout(Duration::from_secs(5))
        .build()
    else {
        eprintln!("cmux-projection seed: no HTTP client; no heartbeat");
        return;
    };
    loop {
        let start = Instant::now();
        let body = serde_json::to_vec(&beat()).unwrap_or_default();
        if let Err(error) = post_beat(&client, url, token, &body, policy, start) {
            eprintln!("cmux-projection seed: heartbeat {url}: {error}");
        }
        // The heartbeat's period, not a synchronization wait.
        std::thread::sleep(policy.period.saturating_sub(start.elapsed()));
    }
}

#[cfg(test)]
#[path = "peers_tests.rs"]
mod tests;
