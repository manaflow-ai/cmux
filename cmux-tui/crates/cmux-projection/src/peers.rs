//! Fleet blob seeding (hq `docs/rfd/0008-fleet-blob-seeding.md`): where a projected checkout gets
//! the blobs its host's mirror lacks before it asks GitHub, and how a host seeds what it holds.
//!
//! On unless `CMUX_PROJECTION_PEERS=0`. A missing blob is asked of, in order:
//!
//! 1. the tailnet peers that hold it (`CMUX_PROJECTION_PEER_INDEX`: a file, or an `http(s)` URL,
//!    of one seed base URL per line);
//! 2. the controller SSD (`CMUX_PROJECTION_CACHE_URL`, read token in
//!    `CMUX_PROJECTION_CACHE_TOKEN_FILE`);
//! 3. R2 (`CMUX_PROJECTION_R2_URL`);
//!
//! each as `GET <base>/objects/<id>`, then 4. git: whatever none of them has goes to the existing
//! one-request `git fetch` ([`crate::git::fetch_missing`]). A source that is not configured is
//! skipped, one that fails three times in a row is dropped for the rest of the mount, and nothing
//! in the chain can fail the mount: with no source left every blob goes to git as before. Every answer is hashed and must match the id it was
//! asked for, so any source is untrusted transport: a wrong answer is dropped and the next source
//! is asked. A verified blob is written into the host's mirror as a loose object, so the host now
//! seeds it too.
//!
//! [`serve`] is the seeding side: `GET /objects/<id>` from the host's object store, read only,
//! bound to the address it is given, with an upload rate limit, a cap on requests served at once
//! and a load cutoff, so seeding never starves the host's own work. A seed that is over any of
//! them answers 503 at once and the client moves on.

use std::fs::OpenOptions;
use std::io::{BufRead as _, BufReader, Write as _};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use sha1::{Digest as _, Sha1};

/// The flag that turns the chain off (`0`).
pub const FLAG: &str = "CMUX_PROJECTION_PEERS";

/// The git object id of a blob with these bytes: sha1 for a 40-hex id, sha256 for a 64-hex id.
#[must_use]
pub fn blob_id(bytes: &[u8], hex_len: usize) -> String {
    let header = format!("blob {}\0", bytes.len());
    if hex_len == 64 {
        let mut hash = sha2::Sha256::new();
        sha2::Digest::update(&mut hash, header.as_bytes());
        sha2::Digest::update(&mut hash, bytes);
        hex(&sha2::Digest::finalize(hash))
    } else {
        let mut hash = Sha1::new();
        hash.update(header.as_bytes());
        hash.update(bytes);
        hex(&hash.finalize())
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

fn hex_digit(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
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

/// One `GET`, so tests can stand in for the network.
pub trait Get: Send + Sync {
    fn get(&self, url: &str, token: Option<&str>, deadline: Duration) -> Answer;
}

/// The network: one blocking client with short deadlines, so a stalled source costs a deadline,
/// never a stall.
pub struct Http {
    client: reqwest::blocking::Client,
}

impl Http {
    pub fn new() -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let client = reqwest::blocking::Client::builder()
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
/// Failures in a row (unreachable, timed out, busy, error status, wrong bytes) after which a
/// source is skipped for the rest of a fill, so a dead peer costs three deadlines, not one per
/// blob.
const DEAD_AFTER: usize = 3;

/// The sources, in the order they are asked.
pub struct Chain {
    remotes: Vec<Remote>,
    get: Box<dyn Get>,
}

/// What [`Chain::fill`] did, for the mount's timing line.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Filled {
    pub peer: usize,
    pub ssd: usize,
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
        Self { remotes, get }
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
        if let Ok(base) = std::env::var("CMUX_PROJECTION_CACHE_URL") {
            let token = std::env::var("CMUX_PROJECTION_CACHE_TOKEN_FILE")
                .ok()
                .and_then(|file| std::fs::read_to_string(file).ok())
                .map(|token| token.trim().to_owned());
            remotes.push(Remote { tier: "ssd", base, token });
        }
        if let Ok(base) = std::env::var("CMUX_PROJECTION_R2_URL") {
            remotes.push(Remote { tier: "r2", base, token: None });
        }
        Some(Self::new(remotes, Box::new(get)))
    }

    /// The remotes one blob is asked of, as indexes: at most [`PEERS_PER_BLOB`] peers (spread by
    /// the id, so one checkout's blobs spread over the peers), then every non-peer source in order.
    fn order(&self, oid: &str) -> Vec<usize> {
        let peers: Vec<usize> = self
            .remotes
            .iter()
            .enumerate()
            .filter_map(|(at, remote)| (remote.tier == "peer").then_some(at))
            .collect();
        let mut order = Vec::new();
        if !peers.is_empty() {
            let prefix = oid
                .bytes()
                .take(4)
                .try_fold(0usize, |value, byte| Some(value * 16 + usize::from(hex_digit(byte)?)));
            let start = prefix.unwrap_or(0) % peers.len();
            for step in 0..PEERS_PER_BLOB.min(peers.len()) {
                if let Some(&at) = peers.get((start + step) % peers.len()) {
                    order.push(at);
                }
            }
        }
        order.extend(
            self.remotes
                .iter()
                .enumerate()
                .filter_map(|(at, remote)| (remote.tier != "peer").then_some(at)),
        );
        order
    }

    /// The verified bytes of `oid` and the tier that gave them, or `None`. `failures` counts each
    /// source's failures in a row; one at [`DEAD_AFTER`] is not asked.
    fn one(
        &self,
        oid: &str,
        failures: &[AtomicUsize],
        rejected: &AtomicUsize,
    ) -> Option<(&'static str, Vec<u8>)> {
        for at in self.order(oid) {
            let (Some(failure), Some(remote)) = (failures.get(at), self.remotes.get(at)) else {
                continue;
            };
            if failure.load(Ordering::Relaxed) >= DEAD_AFTER {
                continue;
            }
            let url = format!("{}/objects/{oid}", remote.base.trim_end_matches('/'));
            match self.get.get(&url, remote.token.as_deref(), remote.deadline()) {
                Answer::Found(bytes) if verify(oid, &bytes) => {
                    failure.store(0, Ordering::Relaxed);
                    return Some((remote.tier, bytes));
                }
                Answer::Found(_) => {
                    rejected.fetch_add(1, Ordering::Relaxed);
                    failure.fetch_add(1, Ordering::Relaxed);
                }
                Answer::Absent | Answer::Busy => failure.store(0, Ordering::Relaxed),
                Answer::Failed => {
                    failure.fetch_add(1, Ordering::Relaxed);
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
        let found: Mutex<Vec<(usize, &'static str)>> = Mutex::new(Vec::new());
        std::thread::scope(|scope| {
            for _ in 0..PARALLEL.min(oids.len()) {
                scope.spawn(|| {
                    loop {
                        let at = next.fetch_add(1, Ordering::Relaxed);
                        let Some(oid) = oids.get(at) else { return };
                        let got = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                            self.one(oid, &failures, &rejected)
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
}

/// The peers a peer index names: `index` is a file, or an `http(s)` URL asked once with a short
/// deadline. An index that can't be read names no peers, so the chain starts at the controller.
#[must_use]
pub fn peers_in(get: &dyn Get, index: &str) -> Vec<Remote> {
    let text = if index.starts_with("http://") || index.starts_with("https://") {
        match get.get(index, None, Duration::from_secs(2)) {
            Answer::Found(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            _ => {
                eprintln!("cmux-projection: peer index {index} unreadable; no peers");
                String::new()
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

fn unique_temp(dir: &Path, suffix: &str) -> anyhow::Result<(std::path::PathBuf, std::fs::File)> {
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
        Self { rate: 62_500_000, conns: 4, load_per_core: 1.5 }
    }
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
    // Each connection is a thread of this scope, so none outlives the seed.
    std::thread::scope(|scope| {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let _ = stream.set_nodelay(true);
            if active.load(Ordering::Relaxed) >= limits.conns
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
    respond_headers(stream, status, body.len(), close)?;
    stream.write_all(body)
}

fn respond_headers(
    stream: &mut TcpStream,
    status: &str,
    length: usize,
    close: bool,
) -> std::io::Result<()> {
    let connection = if close { "close" } else { "keep-alive" };
    write!(
        stream,
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
        // Headers: read and ignore (no body on a GET).
        loop {
            let mut header = String::new();
            if reader.read_line(&mut header)? == 0 || header.trim().is_empty() {
                break;
            }
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

#[cfg(test)]
#[path = "peers_tests.rs"]
mod tests;
