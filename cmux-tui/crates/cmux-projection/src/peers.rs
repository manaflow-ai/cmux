//! Fleet blob seeding (hq `docs/rfd/0008-fleet-blob-seeding.md`): where a projected checkout gets
//! the blobs its host's mirror lacks before it asks GitHub, and how a host seeds what it holds.
//!
//! Off unless `CMUX_PROJECTION_PEERS=1`. Then a missing blob is asked of, in order:
//!
//! 1. the tailnet peers that hold it (`CMUX_PROJECTION_PEER_INDEX`: a file, or an `http(s)` URL,
//!    of one seed base URL per line);
//! 2. the controller SSD (`CMUX_PROJECTION_CACHE_URL`, read token in
//!    `CMUX_PROJECTION_CACHE_TOKEN_FILE`);
//! 3. R2 (`CMUX_PROJECTION_R2_URL`);
//!
//! each as `GET <base>/objects/<id>`. Whatever none of them has goes to the existing one-request
//! `git fetch` ([`crate::git::fetch_missing`]). Every answer is hashed and must match the id it was
//! asked for, so any source is untrusted transport: a wrong answer is dropped and the next source
//! is asked. A verified blob is written into the host's mirror as a loose object, so the host now
//! seeds it too.
//!
//! [`serve`] is the seeding side: `GET /objects/<id>` from the host's object store, read only,
//! bound to the address it is given, with an upload rate limit, a cap on requests served at once
//! and a load cutoff, so seeding never starves the host's own work. A seed that is over any of
//! them answers 503 at once and the client moves on.

use std::io::{BufRead as _, BufReader, Write as _};
use std::net::{TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use sha1::{Digest as _, Sha1};

/// The flag that turns the chain on.
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

/// What one source answered for one id.
#[derive(Debug, PartialEq, Eq)]
pub enum Answer {
    Found(Vec<u8>),
    /// The source does not hold it (404).
    Absent,
    /// Busy, unreachable, timed out or another status: ask the next source.
    Failed,
}

/// One `GET`, so tests can stand in for the network.
pub trait Get: Send + Sync {
    fn get(&self, url: &str, token: Option<&str>) -> Answer;
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
    fn get(&self, url: &str, token: Option<&str>) -> Answer {
        let mut request = self.client.get(url);
        if let Some(token) = token {
            request = request.bearer_auth(token);
        }
        match request.send() {
            Ok(response) if response.status().as_u16() == 404 => Answer::Absent,
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

/// Requests in flight per checkout.
const PARALLEL: usize = 8;
/// Peers asked for one blob before the controller SSD.
const PEERS_PER_BLOB: usize = 2;

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
}

impl Chain {
    #[must_use]
    pub fn new(remotes: Vec<Remote>, get: Box<dyn Get>) -> Self {
        Self { remotes, get }
    }

    /// The chain the environment names, or `None` when the flag is off.
    pub fn from_env() -> anyhow::Result<Option<Self>> {
        if std::env::var(FLAG).ok().as_deref() != Some("1") {
            return Ok(None);
        }
        let get = Http::new()?;
        let mut remotes = Vec::new();
        if let Ok(index) = std::env::var("CMUX_PROJECTION_PEER_INDEX") {
            let text = if index.starts_with("http://") || index.starts_with("https://") {
                match get.get(&index, None) {
                    Answer::Found(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                    _ => String::new(),
                }
            } else {
                std::fs::read_to_string(&index).unwrap_or_default()
            };
            remotes.extend(peer_list(&text).into_iter().map(|base| Remote {
                tier: "peer",
                base,
                token: None,
            }));
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
        Ok(Some(Self::new(remotes, Box::new(get))))
    }

    /// The remotes one blob is asked of: at most [`PEERS_PER_BLOB`] peers (spread by the id, so
    /// one checkout's blobs spread over the peers), then every non-peer source in order.
    fn order(&self, oid: &str) -> Vec<&Remote> {
        let peers: Vec<&Remote> =
            self.remotes.iter().filter(|remote| remote.tier == "peer").collect();
        let mut order = Vec::new();
        if !peers.is_empty() {
            let start =
                usize::from_str_radix(&oid[..4.min(oid.len())], 16).unwrap_or(0) % peers.len();
            for step in 0..PEERS_PER_BLOB.min(peers.len()) {
                order.push(peers[(start + step) % peers.len()]);
            }
        }
        order.extend(self.remotes.iter().filter(|remote| remote.tier != "peer"));
        order
    }

    /// The verified bytes of `oid` and the tier that gave them, or `None`.
    fn one(&self, oid: &str, rejected: &AtomicUsize) -> Option<(&'static str, Vec<u8>)> {
        for remote in self.order(oid) {
            let url = format!("{}/objects/{oid}", remote.base.trim_end_matches('/'));
            if let Answer::Found(bytes) = self.get.get(&url, remote.token.as_deref()) {
                if verify(oid, &bytes) {
                    return Some((remote.tier, bytes));
                }
                rejected.fetch_add(1, Ordering::Relaxed);
            }
        }
        None
    }

    /// Asks the chain for each of `oids`, hands each verified blob to `keep` (which writes it into
    /// the mirror), and returns the ids no source had, for the git fetch.
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
        let found: Mutex<Vec<(usize, &'static str)>> = Mutex::new(Vec::new());
        std::thread::scope(|scope| {
            for _ in 0..PARALLEL.min(oids.len()) {
                scope.spawn(|| {
                    loop {
                        let at = next.fetch_add(1, Ordering::Relaxed);
                        let Some(oid) = oids.get(at) else { return };
                        if let Some((tier, bytes)) = self.one(oid, &rejected)
                            && keep(oid, &bytes).is_ok()
                        {
                            found.lock().unwrap_or_else(PoisonError::into_inner).push((at, tier));
                        }
                    }
                });
            }
        });
        let found = found.into_inner().unwrap_or_else(PoisonError::into_inner);
        let mut filled = Filled { rejected: rejected.into_inner(), ..Filled::default() };
        let mut have = vec![false; oids.len()];
        for (at, tier) in found {
            have[at] = true;
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
    let dir = git_dir.join("objects").join(&oid[..2]);
    let file = dir.join(&oid[2..]);
    if file.exists() {
        return Ok(());
    }
    std::fs::create_dir_all(&dir)?;
    let temp = dir.join(format!("tmp_obj_{}_{}", std::process::id(), &oid[2..10]));
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
    let listener = TcpListener::bind(listen)?;
    let bucket = Arc::new(Mutex::new(Bucket::new(limits.rate, Instant::now())));
    let active = Arc::new(AtomicUsize::new(0));
    for stream in listener.incoming() {
        let Ok(mut stream) = stream else { continue };
        let _ = stream.set_nodelay(true);
        if active.load(Ordering::Relaxed) >= limits.conns || load_per_core() > limits.load_per_core
        {
            let _ = respond(&mut stream, "503 Service Unavailable", b"busy\n", true);
            continue;
        }
        active.fetch_add(1, Ordering::Relaxed);
        let (git_dir, bucket, active) = (git_dir.to_owned(), bucket.clone(), active.clone());
        std::thread::spawn(move || {
            let _ = connection(&git_dir, stream, &bucket);
            active.fetch_sub(1, Ordering::Relaxed);
        });
    }
    Ok(())
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
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut writer = stream.try_clone()?;
    let mut reader = BufReader::new(stream);
    let mut objects = crate::git::ObjectReader::spawn(git_dir)?;
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

#[cfg(test)]
#[path = "peers_tests.rs"]
mod tests;
