//! The content-addressed store of `cmux link sync push` (cmux-platform
//! `/v1/sync/blobs`, the signed-in person's own blobs in Cloudflare R2).
//!
//! With a store configured ([`configure`]: `--store` and the cmux credential
//! on stdin) and a machine that serves `blob-fetch-v1`, a push does not send
//! the bytes of the files it writes over the link. It splits each file into
//! blobs (a small file is one blob, its SHA-256; a large one is cut by
//! content-defined chunking, [`chunks`], so an edit changes only the blobs
//! around it), asks the store which it lacks, uploads only those, uploads the
//! plan (the files, their permissions and blobs: itself one blob), and starts
//! `blob.fetch.start` on the machine with the plan's hash and an hour's read
//! grant. The machine fetches over the data-centre network. So a second
//! machine, a resume after a pause and a re-sync after a small edit move
//! almost nothing from this Mac, and a file two projects share is stored
//! once per person.
//!
//! Anything that goes wrong before the machine wrote a file (no store, an
//! older machine, the store unreachable or refusing) leaves the push to the
//! direct copy over the link, as before; the caller does that.
//!
//! From Mutagen: content addressed by digest and verified on arrival before
//! it is renamed into place (its staging), the writing side pulling what it
//! lacks, and three-way state kept apart from the transfer (the manifest).
//! Unlike Mutagen, which moves rsync deltas between the two ends, the
//! middle is a store, so a third end (another machine) costs the Mac
//! nothing.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read as _, Seek as _, SeekFrom};
use std::sync::OnceLock;
use std::time::{Duration, Instant};

use anyhow::{Context as _, anyhow, bail};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::local::{LocalFile, Source};
use super::remote::Remote;

/// Files up to this size are one blob.
const WHOLE_FILE_MAX: u64 = 4 * 1024 * 1024;
/// Content-defined chunk bounds (FastCDC with normalized chunking).
const CHUNK_MIN: usize = 512 * 1024;
const CHUNK_AVG: usize = 2 * 1024 * 1024;
const CHUNK_MAX: usize = 8 * 1024 * 1024;
/// Bits the cut test checks below and above the average: harder to cut
/// before it, easier after, so sizes cluster around it.
const MASK_HARD_BITS: u32 = 23;
const MASK_EASY_BITS: u32 = 19;
/// Hashes per `missing` request (the store's limit is 1000).
const MISSING_BATCH: usize = 500;
/// Uploads at once.
const PARALLEL_UPLOADS: usize = 16;
/// Tries per upload (network errors and 5xx).
const TRIES: u32 = 4;
/// Time between two `blob.fetch.status` reads.
const STATUS_EVERY: Duration = Duration::from_millis(300);
/// Longest a fetch job is waited for.
const FETCH_DEADLINE: Duration = Duration::from_secs(45 * 60);

/// Where the store is and who signs in to it.
#[derive(Clone)]
pub(crate) struct Config {
    pub origin: String,
    pub credential: String,
}

static CONFIG: OnceLock<Config> = OnceLock::new();

/// Turns the store on for this process's pushes.
pub(crate) fn configure(config: Config) {
    let _ = CONFIG.set(config);
}

fn configured() -> Option<&'static Config> {
    CONFIG.get()
}

/// Whether a push to the machine at `socket` goes through the store.
pub(super) fn usable(socket: &std::path::Path) -> bool {
    configured().is_some()
        && super::super::machine_gate::identify(socket).is_some_and(|identity| {
            super::super::machine_gate::served(&identity).is_some_and(|served| {
                served.contains(&cmux_tui_core::blob_fetch::BLOB_FETCH_CAPABILITY)
            })
        })
}

/// One piece of a file: where it is in the file and its hash.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Piece {
    pub offset: u64,
    pub size: u64,
    pub sha256: String,
}

/// A file the push writes: its path on the machine and here.
pub(super) struct Pending<'a> {
    pub target: String,
    pub file: &'a LocalFile,
    pub sha256: String,
    pub size: u64,
}

/// What the store path did.
#[derive(Debug, Default)]
pub(super) struct Sent {
    /// Bytes this Mac uploaded to the store (blobs it lacked, and the plan).
    pub uploaded: u64,
    /// Bytes the store already had.
    pub reused: u64,
    /// Each file the machine wrote, by its path there, and the revision its
    /// write left: the caller records that one, never a later listing, and
    /// writes every other file over the link.
    pub written: BTreeMap<String, String>,
}

/// The machine's fetch started and its end is not known (a status read
/// failed, or the deadline passed while it ran): a copy over the link now
/// could race the job's later writes, so the push fails instead. The next
/// push of the same plan picks the job up while it runs.
#[derive(Debug)]
pub(super) struct Unsettled(pub String);

impl std::fmt::Display for Unsettled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "the machine's store fetch has not finished: {}", self.0)
    }
}

impl std::error::Error for Unsettled {}

/// The gear table of the rolling hash: fixed, so the same bytes always cut
/// at the same places on every Mac.
fn gear() -> &'static [u64; 256] {
    static GEAR: OnceLock<[u64; 256]> = OnceLock::new();
    GEAR.get_or_init(|| {
        let mut table = [0u64; 256];
        let mut state: u64 = 0x9e37_79b9_7f4a_7c15;
        for entry in &mut table {
            // splitmix64
            state = state.wrapping_add(0x9e37_79b9_7f4a_7c15);
            let mut z = state;
            z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
            *entry = z ^ (z >> 31);
        }
        table
    })
}

/// The top `bits` bits of a u64.
const fn top(bits: u32) -> u64 {
    !0u64 << (64 - bits)
}

/// Where the first chunk of `data` ends (FastCDC, normalized chunking).
/// `data` is the rest of the file, or at least [`CHUNK_MAX`] of it.
pub(super) fn cut(data: &[u8]) -> usize {
    if data.len() <= CHUNK_MIN {
        return data.len();
    }
    let end = data.len().min(CHUNK_MAX);
    let normal = end.min(CHUNK_AVG);
    let gear = gear();
    let mut hash = 0u64;
    let mut at = CHUNK_MIN;
    while at < normal {
        hash = (hash << 1).wrapping_add(gear[usize::from(data[at])]);
        if hash & top(MASK_HARD_BITS) == 0 {
            return at + 1;
        }
        at += 1;
    }
    while at < end {
        hash = (hash << 1).wrapping_add(gear[usize::from(data[at])]);
        if hash & top(MASK_EASY_BITS) == 0 {
            return at + 1;
        }
        at += 1;
    }
    end
}

/// The pieces of `reader`'s bytes, cut by [`cut`].
pub(super) fn chunks(reader: &mut dyn std::io::Read) -> std::io::Result<Vec<Piece>> {
    let mut pieces = Vec::new();
    let mut buffer: Vec<u8> = Vec::with_capacity(2 * CHUNK_MAX);
    let mut offset = 0u64;
    let mut eof = false;
    loop {
        while !eof && buffer.len() < CHUNK_MAX {
            let start = buffer.len();
            buffer.resize(start + CHUNK_MAX, 0);
            let read = reader.read(&mut buffer[start..])?;
            buffer.truncate(start + read);
            eof = read == 0;
        }
        if buffer.is_empty() {
            return Ok(pieces);
        }
        let size = cut(&buffer);
        pieces.push(Piece {
            offset,
            size: size as u64,
            sha256: hex(&Sha256::digest(&buffer[..size])),
        });
        offset += size as u64;
        buffer.drain(..size);
    }
}

/// The pieces of `pending`: the whole file when small.
fn pieces_of(pending: &Pending<'_>) -> anyhow::Result<Vec<Piece>> {
    if pending.size <= WHOLE_FILE_MAX {
        if pending.size == 0 {
            return Ok(Vec::new());
        }
        return Ok(vec![Piece { offset: 0, size: pending.size, sha256: pending.sha256.clone() }]);
    }
    let mut reader = super::open(pending.file)?;
    Ok(chunks(&mut reader)?)
}

/// The bytes of `piece` of `file`.
fn read_piece(file: &LocalFile, piece: &Piece) -> anyhow::Result<Vec<u8>> {
    let mut bytes = vec![0u8; usize::try_from(piece.size)?];
    match &file.source {
        Source::File(path) => {
            let mut opened = std::fs::File::open(path)
                .with_context(|| format!("cannot read {}", path.display()))?;
            opened.seek(SeekFrom::Start(piece.offset))?;
            opened.read_exact(&mut bytes)?;
        }
        Source::Bytes(source) => {
            let start = usize::try_from(piece.offset)?;
            let end = start + bytes.len();
            bytes.copy_from_slice(source.get(start..end).ok_or_else(|| anyhow!("short source"))?);
        }
    }
    if hex(&Sha256::digest(&bytes)) != piece.sha256 {
        bail!("a file changed while it was pushed");
    }
    Ok(bytes)
}

/// Pushes `pending` through the store: uploads what it lacks, then has the
/// machine fetch and write every file. `progress` hears the bytes done.
pub(super) fn send(
    remote: &mut Remote,
    pending: &[Pending<'_>],
    progress: &mut dyn FnMut(u64),
) -> anyhow::Result<Sent> {
    let config = configured().ok_or_else(|| anyhow!("no store"))?;
    let client = Client::new(config)?;
    let mut sent = Sent::default();

    // Every piece of every file, and the plan that names them.
    let mut plan_files = Vec::with_capacity(pending.len());
    let mut wanted: BTreeMap<String, (usize, Piece)> = BTreeMap::new();
    for (index, file) in pending.iter().enumerate() {
        let pieces = pieces_of(file)?;
        let mut entry = json!({
            "path": file.target,
            "permissions": file.file.permissions,
            "size": file.size,
            "sha256": file.sha256,
        });
        if !(pieces.len() == 1 && pieces[0].sha256 == file.sha256) && file.size > 0 {
            entry["chunks"] = Value::Array(
                pieces.iter().map(|p| json!({"sha256": p.sha256, "size": p.size})).collect(),
            );
        }
        plan_files.push(entry);
        for piece in pieces {
            wanted.entry(piece.sha256.clone()).or_insert((index, piece));
        }
    }
    let plan = serde_json::to_vec(&json!({"version": 1, "files": plan_files}))?;
    let plan_sha = hex(&Sha256::digest(&plan));

    let hashes: Vec<String> = wanted.keys().cloned().collect();
    let missing = client.missing(&hashes)?;
    sent.reused = wanted
        .iter()
        .filter(|(sha, _)| !missing.contains(*sha))
        .map(|(_, (_, piece))| piece.size)
        .sum();
    progress(sent.reused);
    let uploads: Vec<(&LocalFile, Piece)> = missing
        .iter()
        .filter_map(|sha| wanted.get(sha))
        .map(|(index, piece)| (pending[*index].file, piece.clone()))
        .collect();
    let mut done = sent.reused;
    sent.uploaded += client.upload_all(&uploads, &mut |bytes| {
        done += bytes;
        progress(done);
    })?;
    if client.missing(std::slice::from_ref(&plan_sha))?.contains(&plan_sha) {
        client.put(&plan_sha, plan.clone())?;
        sent.uploaded += plan.len() as u64;
    }
    let grant = client.grant()?;

    // The machine fetches and writes.
    let started = remote.call(
        "blob.fetch.start",
        json!({
            "store": {"origin": config.origin, "grant": grant},
            "plan": plan_sha,
            "plan_size": plan.len(),
        }),
    )?;
    let job = started
        .get("job")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("blob.fetch.start answered no job"))?
        .to_string();
    let deadline = Instant::now() + FETCH_DEADLINE;
    let status = loop {
        let status = remote
            .call("blob.fetch.status", json!({ "job": job }))
            .map_err(|error| Unsettled(format!("{error:#}")))?;
        match status.get("state").and_then(Value::as_str) {
            Some("running") if Instant::now() < deadline => {
                std::thread::sleep(STATUS_EVERY);
            }
            Some("running") => return Err(Unsettled("it did not finish in time".into()).into()),
            Some("done" | "failed") => break status,
            _ => return Err(Unsettled("its state is not known".into()).into()),
        }
    };
    if status.get("state").and_then(Value::as_str) != Some("done") {
        let code = status.get("error_code").and_then(Value::as_str).unwrap_or("blob.failure");
        let error = status.get("error").and_then(Value::as_str).unwrap_or("the fetch failed");
        bail!("the machine's fetch failed ({code}): {error}");
    }
    // What the job wrote, a page at a time.
    let mut from = 0u64;
    loop {
        let page = remote
            .call("blob.fetch.status", json!({ "job": job, "written_from": from }))
            .context("cannot read what the machine's fetch wrote")?;
        let entries = page.get("written").and_then(Value::as_array).cloned().unwrap_or_default();
        for entry in &entries {
            if let (Some(path), Some(revision)) = (
                entry.get("path").and_then(Value::as_str),
                entry.get("revision").and_then(Value::as_str),
            ) {
                sent.written.insert(path.to_owned(), revision.to_owned());
            }
        }
        from += entries.len() as u64;
        let total = page.get("written_count").and_then(Value::as_u64).unwrap_or(0);
        if entries.is_empty() || from >= total {
            break;
        }
    }
    Ok(sent)
}

/// The store, as one signed-in person.
struct Client {
    origin: String,
    credential: String,
    http: reqwest::Client,
    runtime: tokio::runtime::Runtime,
}

impl Client {
    fn new(config: &Config) -> anyhow::Result<Self> {
        let _ = rustls::crypto::ring::default_provider().install_default();
        let runtime =
            tokio::runtime::Builder::new_multi_thread().worker_threads(4).enable_all().build()?;
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .timeout(Duration::from_secs(120))
            .build()?;
        Ok(Self {
            origin: config.origin.trim_end_matches('/').to_string(),
            credential: config.credential.clone(),
            http,
            runtime,
        })
    }

    fn url(&self, path: &str) -> String {
        format!("{}{path}", self.origin)
    }

    async fn json(&self, path: &str, body: Value) -> anyhow::Result<Value> {
        let response = self
            .http
            .post(self.url(path))
            .bearer_auth(&self.credential)
            .json(&body)
            .send()
            .await
            .map_err(|error| anyhow!("the store did not answer: {}", error.without_url()))?;
        let status = response.status();
        let value: Value = response.json().await.unwrap_or(Value::Null);
        if !status.is_success() {
            let code = value
                .get("code")
                .or_else(|| value.pointer("/error/code"))
                .and_then(Value::as_str)
                .unwrap_or("");
            bail!("the store refused {path}: {} {code}", status.as_u16());
        }
        Ok(value)
    }

    /// The hashes of `hashes` the store lacks.
    fn missing(&self, hashes: &[String]) -> anyhow::Result<BTreeSet<String>> {
        self.runtime.block_on(async {
            use futures_util::stream::{self, StreamExt as _, TryStreamExt as _};
            let answers: Vec<Value> = stream::iter(hashes.chunks(MISSING_BATCH))
                .map(|batch| self.json("/v1/sync/blobs/missing", json!({ "sha256": batch })))
                .buffer_unordered(4)
                .try_collect()
                .await?;
            let mut missing = BTreeSet::new();
            for answer in answers {
                let list = answer
                    .get("missing")
                    .and_then(Value::as_array)
                    .ok_or_else(|| anyhow!("the store's missing answer is unreadable"))?;
                missing.extend(list.iter().filter_map(Value::as_str).map(str::to_owned));
            }
            Ok(missing)
        })
    }

    async fn put_async(&self, sha256: &str, bytes: Vec<u8>) -> anyhow::Result<()> {
        let url = self.url(&format!("/v1/sync/blobs/{sha256}"));
        let mut last = anyhow!("the store did not answer");
        for attempt in 0..TRIES {
            if attempt > 0 {
                tokio::time::sleep(Duration::from_millis(250 << attempt)).await;
            }
            let sent = self
                .http
                .put(&url)
                .bearer_auth(&self.credential)
                .header(reqwest::header::CONTENT_TYPE, "application/octet-stream")
                .body(bytes.clone())
                .send()
                .await;
            match sent {
                Ok(response) if response.status().is_success() => return Ok(()),
                Ok(response) if response.status().is_server_error() => {
                    last = anyhow!("the store answered {}", response.status().as_u16());
                }
                Ok(response) => {
                    bail!("the store refused a blob: {}", response.status().as_u16());
                }
                Err(error) => last = anyhow!("the store did not answer: {}", error.without_url()),
            }
        }
        Err(last)
    }

    fn put(&self, sha256: &str, bytes: Vec<u8>) -> anyhow::Result<()> {
        self.runtime.block_on(self.put_async(sha256, bytes))
    }

    /// Uploads every piece, [`PARALLEL_UPLOADS`] at once; the bytes sent.
    fn upload_all(
        &self,
        uploads: &[(&LocalFile, Piece)],
        progress: &mut dyn FnMut(u64),
    ) -> anyhow::Result<u64> {
        self.runtime.block_on(async {
            use futures_util::stream::{self, StreamExt as _};
            let mut results = stream::iter(uploads.iter())
                .map(|(file, piece)| async move {
                    let bytes = read_piece(file, piece)?;
                    self.put_async(&piece.sha256, bytes).await?;
                    anyhow::Ok(piece.size)
                })
                .buffer_unordered(PARALLEL_UPLOADS);
            let mut total = 0;
            while let Some(result) = results.next().await {
                let size = result?;
                total += size;
                progress(size);
            }
            Ok(total)
        })
    }

    /// An hour's read grant for this person's blobs, for the machine.
    fn grant(&self) -> anyhow::Result<String> {
        let answer = self.runtime.block_on(self.json("/v1/sync/grants", json!({})))?;
        answer
            .get("grant")
            .and_then(Value::as_str)
            .filter(|grant| grant.starts_with("csg_"))
            .map(str::to_owned)
            .ok_or_else(|| anyhow!("the store answered no grant"))
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::{CHUNK_MAX, CHUNK_MIN, chunks};

    fn noise(len: usize, seed: u64) -> Vec<u8> {
        let mut state = seed;
        (0..len)
            .map(|_| {
                state ^= state << 13;
                state ^= state >> 7;
                state ^= state << 17;
                state as u8
            })
            .collect()
    }

    #[test]
    fn chunks_cover_the_file_within_bounds() {
        let data = noise(40 * 1024 * 1024 + 123, 7);
        let pieces = chunks(&mut data.as_slice()).unwrap();
        assert_eq!(pieces.iter().map(|p| p.size).sum::<u64>(), data.len() as u64);
        let mut offset = 0;
        for (index, piece) in pieces.iter().enumerate() {
            assert_eq!(piece.offset, offset);
            assert!(piece.size as usize <= CHUNK_MAX);
            if index + 1 < pieces.len() {
                assert!(piece.size as usize > CHUNK_MIN);
            }
            offset += piece.size;
        }
        assert!(pieces.len() >= 5, "{} pieces", pieces.len());
    }

    #[test]
    fn an_edit_in_the_middle_changes_only_the_pieces_around_it() {
        let data = noise(48 * 1024 * 1024, 11);
        let mut edited = data.clone();
        edited.splice(20 * 1024 * 1024..20 * 1024 * 1024, b"inserted line\n".iter().copied());
        let before: std::collections::BTreeSet<String> =
            chunks(&mut data.as_slice()).unwrap().into_iter().map(|p| p.sha256).collect();
        let after = chunks(&mut edited.as_slice()).unwrap();
        let new = after.iter().filter(|p| !before.contains(&p.sha256)).count();
        assert!(new <= 2, "{new} of {} pieces changed", after.len());
    }

    #[test]
    fn the_same_bytes_always_cut_the_same_way() {
        let data = noise(20 * 1024 * 1024, 3);
        assert_eq!(chunks(&mut data.as_slice()).unwrap(), chunks(&mut data.as_slice()).unwrap());
    }
}
