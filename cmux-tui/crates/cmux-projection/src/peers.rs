//! Fleet blob seeding (hq `docs/rfd/0008-fleet-blob-seeding.md`): where a projected checkout gets
//! the blobs its host's mirror lacks before it asks GitHub, and how a host seeds what it holds.
//!
//! On unless `CMUX_PROJECTION_PEERS=0`. A missing blob is asked of, in order:
//!
//! 1. the tailnet peers that hold it (`CMUX_PROJECTION_PEER_INDEX`: a file, or an `http(s)` URL
//!    such as the controller's `GET /v1/seeds?repo=R&zone=Z&format=text`, of one seed base URL per
//!    line, nearest first; a URL's answer is kept for a minute, so back-to-back checkouts ask once);
//!    the nearest two that answer at most, each asked for the whole missing set in one
//!    `POST <base>/objects` whose first byte must come within 250 ms ([`batch_request`]); a seed
//!    that does not take batches is asked per blob. A seed that answers busy does not use up
//!    those two: the next seed in the index is asked, up to [`PEERS_ASKED_MAX`] in all, and a
//!    seed that just answered busy is asked after the others for [`BUSY_BACKOFF`];
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
use std::fs::OpenOptions;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::net::{TcpListener, TcpStream, ToSocketAddrs as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use sha1collisiondetection::Sha1CD;
use sha2::Digest as _;

/// The flag that turns the chain off (`0`).
pub const FLAG: &str = "CMUX_PROJECTION_PEERS";

/// Maximum body retained from an optional peer or cache response.
pub const MAX_HTTP_BODY_BYTES: usize = 16 * 1024 * 1024;

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
    body_limit: usize,
}

impl Http {
    pub fn new() -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = cmux_egress::blocking_client_builder("cmux_projection::peers")
            .connect_timeout(Duration::from_millis(500))
            .timeout(Duration::from_secs(20))
            .pool_max_idle_per_host(PARALLEL)
            .build()?;
        Ok(Self { client, body_limit: MAX_HTTP_BODY_BYTES })
    }
}

/// Check the advertised length before allocating, but also count streamed bytes: lengths may
/// be absent or untrustworthy. Probe one byte past the limit to distinguish a complete body at
/// the boundary from a truncated one. Neither a read failure nor an oversize returns any bytes.
fn bounded_body(mut response: reqwest::blocking::Response, limit: usize) -> Answer {
    if response.content_length().is_some_and(|length| length > limit as u64) {
        return Answer::Failed;
    }
    let mut bytes = Vec::new();
    let mut chunk = [0_u8; 8192];
    loop {
        let remaining = limit - bytes.len();
        let read_limit = chunk.len().min(remaining.saturating_add(1));
        let Some(window) = chunk.get_mut(..read_limit) else { return Answer::Failed };
        let read = match response.read(window) {
            Ok(0) => return Answer::Found(bytes),
            Ok(read) if read <= remaining => read,
            _ => return Answer::Failed,
        };
        let needed = bytes.len() + read;
        if needed > bytes.capacity() {
            // Grow geometrically without reserving beyond the cap or trusting a remote's
            // length. Allocation pressure is another optional-source failure, not a panic.
            let capacity = needed.max(bytes.capacity().saturating_mul(2)).min(limit);
            if bytes.try_reserve_exact(capacity - bytes.len()).is_err() {
                return Answer::Failed;
            }
        }
        let Some(got) = chunk.get(..read) else { return Answer::Failed };
        bytes.extend_from_slice(got);
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
                bounded_body(response, self.body_limit)
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
/// Peers that answer (anything but busy) asked for one blob before the controller SSD.
const PEERS_PER_BLOB: usize = 2;
/// Peers asked for one blob or one batch at most, busy ones included: a busy seed does not use up
/// [`PEERS_PER_BLOB`], so the next one in the index is asked, but never more than this many.
const PEERS_ASKED_MAX: usize = 6;
/// How long a peer that answered busy is asked after the peers that did not.
const BUSY_BACKOFF: Duration = Duration::from_secs(5);
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
    /// Per remote, until when (ms since `epoch`, 0 for never) it is asked after the others
    /// because it answered busy.
    busy_until: Vec<AtomicU64>,
    epoch: Instant,
}

/// The peers one blob or batch asks: those that answer use up [`PEERS_PER_BLOB`], busy ones only
/// the hard bound [`PEERS_ASKED_MAX`].
#[derive(Default)]
struct PeerBudget {
    answered: usize,
    asked: usize,
}

impl PeerBudget {
    fn open(&self) -> bool {
        self.answered < PEERS_PER_BLOB && self.asked < PEERS_ASKED_MAX
    }

    fn spend(&mut self, busy: bool) {
        self.asked += 1;
        if !busy {
            self.answered += 1;
        }
    }
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
        let busy_until = remotes.iter().map(|_| AtomicU64::new(0)).collect();
        Self { remotes, get, stores: Vec::new(), busy_until, epoch: Instant::now() }
    }

    fn now_ms(&self) -> u64 {
        u64::try_from(self.epoch.elapsed().as_millis()).unwrap_or(u64::MAX)
    }

    /// Whether remote `at` answered busy within [`BUSY_BACKOFF`].
    fn recently_busy(&self, at: usize, now_ms: u64) -> bool {
        self.busy_until.get(at).is_some_and(|until| until.load(Ordering::Relaxed) > now_ms)
    }

    fn mark_busy(&self, at: usize) {
        if let Some(until) = self.busy_until.get(at) {
            let backoff = u64::try_from(BUSY_BACKOFF.as_millis()).unwrap_or(u64::MAX);
            until.store(self.now_ms().saturating_add(backoff), Ordering::Relaxed);
        }
    }

    /// The chain with `stores` asked after its other sources, in order.
    #[must_use]
    pub fn with_stores(mut self, stores: Vec<crate::s3::Store>) -> Self {
        self.remotes.extend(stores.iter().map(crate::s3::Store::remote));
        self.busy_until.extend(stores.iter().map(|_| AtomicU64::new(0)));
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

    /// The peers that may be asked, as indexes: the nearest [`PEERS_ASKED_MAX`] in index order
    /// (the controller's index lists the same zone first, then the same region, then the rest),
    /// those that just answered busy after the others. One pass that stops at the bound.
    fn nearest_peers(&self) -> Vec<usize> {
        let now = self.now_ms();
        let (mut ready, mut busy) = (Vec::new(), Vec::new());
        for (at, remote) in self.remotes.iter().enumerate() {
            if remote.tier != "peer" {
                continue;
            }
            if self.recently_busy(at, now) {
                if busy.len() < PEERS_ASKED_MAX {
                    busy.push(at);
                }
            } else {
                ready.push(at);
                if ready.len() == PEERS_ASKED_MAX {
                    break;
                }
            }
        }
        ready.extend(busy);
        ready.truncate(PEERS_ASKED_MAX);
        ready
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
    /// in one stream; a verified record is kept, a wrong one is counted and stops that peer. A busy
    /// peer spills to the next one ([`PeerBudget`]). The peers that take no batches are returned,
    /// to be asked per blob.
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
        let mut budget = PeerBudget::default();
        for peer in self.nearest_peers() {
            if !budget.open() {
                break;
            }
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
                budget.spend(false);
                continue;
            }
            match answer {
                BatchAnswer::Streamed => {
                    failed.store(0, Ordering::Relaxed);
                    budget.spend(false);
                }
                BatchAnswer::Busy => {
                    failed.store(0, Ordering::Relaxed);
                    self.mark_busy(peer);
                    budget.spend(true);
                }
                // Asked per blob next, under that phase's own budget.
                BatchAnswer::Unsupported => per_blob.push(peer),
                BatchAnswer::Failed => {
                    failed.fetch_add(1, Ordering::Relaxed);
                    budget.spend(false);
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
        // Peers that just answered busy go after the other peers (still before the controller
        // SSD); `order` lists the peers first and holds at most PEERS_ASKED_MAX of them.
        let now = self.now_ms();
        let is_peer = |at: usize| self.remotes.get(at).is_some_and(|remote| remote.tier == "peer");
        let mut order = order.to_vec();
        order.sort_by_key(|&at| (!is_peer(at), is_peer(at) && self.recently_busy(at, now)));
        let mut budget = PeerBudget::default();
        for at in order {
            let (Some(failed), Some(remote)) = (failures.get(at), self.remotes.get(at)) else {
                continue;
            };
            if failed.load(Ordering::Relaxed) >= DEAD_AFTER {
                continue;
            }
            let peer = remote.tier == "peer";
            if peer && !budget.open() {
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
            let busy = matches!(answer, Answer::Busy);
            match answer {
                Answer::Found(bytes) if verify(oid, &bytes) => {
                    failed.store(0, Ordering::Relaxed);
                    return Some((remote.tier, bytes));
                }
                Answer::Found(_) => {
                    rejected.fetch_add(1, Ordering::Relaxed);
                    failed.fetch_add(1, Ordering::Relaxed);
                }
                Answer::Absent => failed.store(0, Ordering::Relaxed),
                Answer::Busy => failed.store(0, Ordering::Relaxed),
                Answer::Failed => {
                    failed.fetch_add(1, Ordering::Relaxed);
                }
            }
            if peer {
                if busy {
                    self.mark_busy(at);
                }
                budget.spend(busy);
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

/// How old a URL index's last answer may be and still stand in when the index can't be read (the
/// controller restarting, or its tailnet identity lookup stalling past the 2 s deadline: on
/// one lane VM, 2026-11-26, every mount from 07:44Z to 12:17Z sent all its missing blobs to
/// git, while 14 of 25 seeds would have served them). A peer is untrusted transport and every
/// answer is checked against its git id, so an old list costs a deadline per seed that has since
/// gone, never a wrong byte.
const INDEX_STALE_MAX: Duration = Duration::from_secs(6 * 60 * 60);

/// The text and age of the answer kept at `cache` when it is younger than `max`.
fn cached_index(cache: Option<&Path>, max: Duration) -> Option<(Duration, String)> {
    let cache = cache?;
    let age = std::fs::metadata(cache).ok()?.modified().ok()?.elapsed().ok()?;
    if age >= max {
        return None;
    }
    std::fs::read_to_string(cache).ok().map(|text| (age, text))
}

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
/// When the index can't be read, an answer kept under [`INDEX_STALE_MAX`] ago stands in.
#[must_use]
pub fn peers_in_cached(get: &dyn Get, index: &str, cache: Option<&Path>) -> Vec<Remote> {
    let text = if index.starts_with("http://") || index.starts_with("https://") {
        if let Some((_, text)) = cached_index(cache, INDEX_FRESH) {
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
                    if let Some((age, text)) = cached_index(cache, INDEX_STALE_MAX) {
                        eprintln!(
                            "cmux-projection: peer index {index} unreadable; using its answer from {} s ago",
                            age.as_secs()
                        );
                        text
                    } else {
                        eprintln!("cmux-projection: peer index {index} unreadable; no peers");
                        String::new()
                    }
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
/// through a private temporary file and an atomic link, so a reader never sees half an object and
/// concurrent writers never replace one another's complete object.
pub fn write_loose(git_dir: &Path, oid: &str, bytes: &[u8]) -> anyhow::Result<()> {
    anyhow::ensure!(verify(oid, bytes), "{oid}: bytes do not hash to it");
    let prefix: String = oid.chars().take(2).collect();
    let suffix: String = oid.chars().skip(2).collect();
    let dir = git_dir.join("objects").join(prefix);
    let file = dir.join(&suffix);
    if file.exists() {
        return Ok(());
    }
    std::fs::create_dir_all(&dir)?;
    let (temp, temp_file) = unique_temp(&dir, &suffix)?;
    let result = (|| -> anyhow::Result<()> {
        let mut encoder = flate2::write::ZlibEncoder::new(temp_file, flate2::Compression::fast());
        encoder.write_all(format!("blob {}\0", bytes.len()).as_bytes())?;
        encoder.write_all(bytes)?;
        encoder.finish()?.sync_all()?;
        // A replacing `rename` could overwrite an object another writer installed after the
        // existence check. A hard link is atomic and refuses to replace it.
        match std::fs::hard_link(&temp, &file) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => Ok(()),
            Err(error) => Err(error.into()),
        }
    })();
    let cleanup = std::fs::remove_file(&temp);
    match result {
        Ok(()) => match cleanup {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error.into()),
        },
        Err(error) => {
            let _ = cleanup;
            Err(error)
        }
    }
}

static NEXT_TEMP: AtomicUsize = AtomicUsize::new(0);

fn unique_temp(dir: &Path, suffix: &str) -> anyhow::Result<(PathBuf, std::fs::File)> {
    let pid = std::process::id();
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    loop {
        let sequence = NEXT_TEMP.fetch_add(1, Ordering::Relaxed);
        let temp = dir.join(format!("tmp_obj_{pid}_{now:x}_{sequence:x}_{suffix}"));
        match OpenOptions::new().write(true).create_new(true).open(&temp) {
            Ok(file) => return Ok((temp, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(error.into()),
        }
    }
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

const MAX_CHUNK_DELAY: Duration = Duration::from_secs(5);
const MAX_CHUNK_BYTES: usize = 64 * 1024;

/// Keep each token-bucket reservation within the delay the seed is willing to impose. Holding
/// the bucket lock while sleeping serializes reservations, so concurrent connections cannot build
/// unbounded debt and then bypass the configured rate.
fn rate_chunk_size(rate: u64) -> usize {
    let bytes = rate.saturating_mul(MAX_CHUNK_DELAY.as_secs()).min(MAX_CHUNK_BYTES as u64).max(1);
    usize::try_from(bytes).unwrap_or(MAX_CHUNK_BYTES)
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

/// [`serve`] on a listener already bound, so callers that need the port have it before the first
/// connection and no other socket can take it in between.
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
                let _ = connection(git_dir, stream, bucket, limits.rate);
                active.fetch_sub(1, Ordering::Relaxed);
            });
        }
    });
}

fn respond(stream: &mut TcpStream, status: &str, body: &[u8], close: bool) -> std::io::Result<()> {
    // One write: a 503 that closes without reading the request must reach the client before the
    // close can reset the connection.
    let mut out = headers(status, body.len(), close).into_bytes();
    out.extend_from_slice(body);
    stream.write_all(&out)
}

fn respond_headers(
    stream: &mut TcpStream,
    status: &str,
    length: usize,
    close: bool,
) -> std::io::Result<()> {
    stream.write_all(headers(status, length, close).as_bytes())
}

fn headers(status: &str, length: usize, close: bool) -> String {
    let connection = if close { "close" } else { "keep-alive" };
    format!(
        "HTTP/1.1 {status}\r\nContent-Length: {length}\r\nContent-Type: application/octet-stream\r\nConnection: {connection}\r\n\r\n"
    )
}

fn write_rate_limited<W: std::io::Write>(
    writer: &mut W,
    bytes: &[u8],
    bucket: &Mutex<Bucket>,
    rate: u64,
) -> std::io::Result<()> {
    for chunk in bytes.chunks(rate_chunk_size(rate)) {
        let mut bucket = bucket.lock().unwrap_or_else(PoisonError::into_inner);
        let wait = bucket.take(chunk.len() as u64, Instant::now());
        if !wait.is_zero() {
            std::thread::sleep(wait);
        }
        drop(bucket);
        writer.write_all(chunk)?;
    }
    Ok(())
}

fn connection(
    git_dir: &Path,
    stream: TcpStream,
    bucket: &Mutex<Bucket>,
    rate: u64,
) -> anyhow::Result<()> {
    // An idle pooled connection should not hold one of the seed's few slots indefinitely.
    stream.set_read_timeout(Some(Duration::from_secs(5)))?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let mut objects = crate::git::ObjectReader::spawn_local(git_dir)?;
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
                respond_headers(&mut writer, "200 OK", bytes.len(), false)?;
                write_rate_limited(&mut writer, &bytes, bucket, rate)?;
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
