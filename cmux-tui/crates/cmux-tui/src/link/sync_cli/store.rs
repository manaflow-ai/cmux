//! The content-addressed store of `cmux link sync push` (cmux-platform
//! `/v1/sync/blobs`, the signed-in person's own blobs in Cloudflare R2).
//!
//! With a store configured ([`configure`]: `--store` and the cmux credential
//! on stdin) and a machine that serves `blob-fetch-v2`, a push does not send
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

/// Whether the machine at `socket` serves `blob-fetch-v2`: a fetch job of an
/// earlier push may still be running there. `None` when `identify` did not
/// answer or answered with no list of capabilities: such a machine may serve
/// it, so the caller still fences.
pub(super) fn fetch_served(socket: &std::path::Path) -> Option<bool> {
    serves_fetch(&super::super::machine_gate::reach(socket).ok()?)
}

/// [`fetch_served`] for one `identify` answer: `None` when it has no list of
/// capabilities, which says nothing about what the machine serves.
fn serves_fetch(identity: &Value) -> Option<bool> {
    let served = super::super::machine_gate::served(identity)?;
    Some(served.contains(&cmux_tui_core::blob_fetch::BLOB_FETCH_CAPABILITY))
}

/// [`fence`], for a machine whose capabilities are not known: one that
/// refuses the cancel serves no fetch, so nothing of it can be running.
pub(super) fn fence_unknown(remote: &mut Remote, remote_root: &str) -> anyhow::Result<Left> {
    match fence(remote, remote_root) {
        Err(error) if error.root_cause().downcast_ref::<super::remote::FsRefusal>().is_some() => {
            Ok(Left::default())
        }
        other => other,
    }
}

/// Whether a push goes through the store, given [`fetch_served`]. Never under a held copy's
/// fence ([`super::fence`]): a fetch names no hold the machine checks when it writes, so a held
/// copy writes every file itself, each under its hold.
pub(super) fn usable(fetch_served: bool) -> bool {
    configured().is_some() && fetch_served && !super::fence::raised()
}

/// What earlier fetch jobs under a folder left: the jobs, and each file they
/// wrote, by its path there, with every revision those writes left (two
/// jobs may have written one path; the machine's current file says which).
#[derive(Default)]
pub(super) struct Left {
    pub jobs: Vec<String>,
    pub written: BTreeMap<String, BTreeSet<String>>,
}

/// Cancels every fetch job still running under `remote_root` on the machine,
/// and returns once none of them can write: whatever this push writes next,
/// over the link or through a new job, no earlier job overwrites it. Answers
/// what every job kept there wrote: a push that failed after its fetch wrote
/// (or never learned it did) has no manifest naming those files, so the
/// caller does, then [`forget`]s the jobs once its manifest is saved.
pub(super) fn fence(remote: &mut Remote, remote_root: &str) -> anyhow::Result<Left> {
    let answer = remote
        .call("blob.fetch.cancel", json!({ "target": remote_root }))
        .context("cannot stop the machine's earlier store fetch")?;
    let mut left = Left::default();
    for job in answer.get("jobs").and_then(Value::as_array).into_iter().flatten() {
        let Some(job) = job.as_str() else { continue };
        let read = written_by(remote, job, &mut |path, revision| {
            left.written.entry(path).or_default().insert(revision);
        });
        match read {
            Ok(()) => left.jobs.push(job.to_owned()),
            // Retired since the cancel answered: nothing left to read.
            Err(error)
                if error
                    .downcast_ref::<super::remote::FsRefusal>()
                    .is_some_and(|refusal| refusal.code == "blob.no_job") => {}
            Err(error) => {
                return Err(
                    error.context("cannot read what the machine's earlier store fetch wrote")
                );
            }
        }
    }
    Ok(left)
}

/// Lets the machine drop `jobs`, whose files a saved manifest now names. A
/// failure only keeps them for the next push to read again.
pub(super) fn forget(remote: &mut Remote, jobs: &[String]) {
    if !jobs.is_empty() {
        let _ = remote.call("blob.fetch.forget", json!({ "jobs": jobs }));
    }
}

/// Every file job `job` committed, with its revision, a page at a time.
fn written_by(
    remote: &mut Remote,
    job: &str,
    into: &mut dyn FnMut(String, String),
) -> anyhow::Result<()> {
    let mut from = 0u64;
    loop {
        let page = remote.call("blob.fetch.status", json!({ "job": job, "written_from": from }))?;
        let entries = page.get("written").and_then(Value::as_array).cloned().unwrap_or_default();
        for entry in &entries {
            if let (Some(path), Some(revision)) = (
                entry.get("path").and_then(Value::as_str),
                entry.get("revision").and_then(Value::as_str),
            ) {
                into(path.to_owned(), revision.to_owned());
            }
        }
        from += entries.len() as u64;
        let total = page.get("written_count").and_then(Value::as_u64).unwrap_or(0);
        if entries.is_empty() || from >= total {
            return Ok(());
        }
    }
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

/// The machine's fetch may have started and could not be stopped (a start or
/// status answer was lost and the cancel failed too, or the deadline passed
/// while it ran): a copy over the link now could race the job's later
/// writes, so the push fails instead. The next push fences the job off
/// ([`fence`]) before it writes anything.
#[derive(Debug)]
pub(super) struct Unsettled(pub String);

impl std::fmt::Display for Unsettled {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "the machine's store fetch has not finished: {}", self.0)
    }
}

impl std::error::Error for Unsettled {}

/// A newer push to the same folder cancelled this push's fetch: copying the
/// files over the link now would overwrite what that push writes, so this
/// push fails instead.
#[derive(Debug)]
pub(super) struct Superseded;

impl std::fmt::Display for Superseded {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("a newer push to this folder took over; this push stopped")
    }
}

impl std::error::Error for Superseded {}

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
    let roll = |hash: u64, byte: &u8| {
        (hash << 1).wrapping_add(gear.get(usize::from(*byte)).copied().unwrap_or_default())
    };
    let (Some(hard), Some(easy)) = (data.get(CHUNK_MIN..normal), data.get(normal..end)) else {
        return end;
    };
    let mut hash = 0u64;
    for (at, byte) in (CHUNK_MIN..).zip(hard) {
        hash = roll(hash, byte);
        if hash & top(MASK_HARD_BITS) == 0 {
            return at + 1;
        }
    }
    for (at, byte) in (normal..).zip(easy) {
        hash = roll(hash, byte);
        if hash & top(MASK_EASY_BITS) == 0 {
            return at + 1;
        }
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
            let read = reader.read(buffer.split_at_mut(start).1)?;
            buffer.truncate(start + read);
            eof = read == 0;
        }
        if buffer.is_empty() {
            return Ok(pieces);
        }
        let size = cut(&buffer);
        let (piece, _) = buffer.split_at(size);
        pieces.push(Piece { offset, size: size as u64, sha256: hex(&Sha256::digest(piece)) });
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
            let mut opened = super::local::open_listed(path, file.id)?;
            opened.seek(SeekFrom::Start(piece.offset))?;
            opened.read_exact(&mut bytes)?;
        }
        Source::Checked(checked) => {
            let mut opened = super::place::open_beneath(&checked.root, &checked.relative)?.0;
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
    remote_root: &str,
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
        let whole = pieces.len() == 1 && pieces.first().is_some_and(|p| p.sha256 == file.sha256);
        if !whole
            && file.size > 0
            && let Some(entry) = entry.as_object_mut()
        {
            entry.insert(
                "chunks".into(),
                Value::Array(
                    pieces.iter().map(|p| json!({"sha256": p.sha256, "size": p.size})).collect(),
                ),
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
        .filter_map(|(index, piece)| Some((pending.get(*index)?.file, piece.clone())))
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

    // The machine fetches and writes. A refusal means no job; any other
    // failure may have started one, which is stopped before the link writes.
    let started = remote.call(
        "blob.fetch.start",
        json!({
            "store": {"origin": config.origin, "grant": grant},
            "plan": plan_sha,
            "plan_size": plan.len(),
            "target": remote_root,
        }),
    );
    let started = match started {
        Ok(started) => started,
        Err(error) if error.is::<super::remote::FsRefusal>() => return Err(error),
        Err(error) => {
            return Err(match fence(remote, remote_root) {
                Ok(_) => error.context("blob.fetch.start was not answered"),
                Err(fenced) => {
                    Unsettled(format!("{error:#}; and the cancel failed: {fenced:#}")).into()
                }
            });
        }
    };
    // An answer with no job may still have started one: it is stopped before
    // the link writes, as for a lost answer.
    let Some(job) = started.get("job").and_then(Value::as_str).map(str::to_owned) else {
        return Err(match fence(remote, remote_root) {
            Ok(_) => anyhow!("blob.fetch.start answered no job"),
            Err(fenced) => Unsettled(format!(
                "blob.fetch.start answered no job; and the cancel failed: {fenced:#}"
            ))
            .into(),
        });
    };
    let deadline = Instant::now() + FETCH_DEADLINE;
    // A job whose end is not known is stopped before the link writes; one
    // that cannot be stopped fails the push.
    let unsettled = |remote: &mut Remote, why: String| -> anyhow::Error {
        match fence(remote, remote_root) {
            Ok(_) => anyhow!("the machine's store fetch was stopped: {why}"),
            Err(fenced) => Unsettled(format!("{why}; and the cancel failed: {fenced:#}")).into(),
        }
    };
    let status = loop {
        let status = match remote.call("blob.fetch.status", json!({ "job": job })) {
            Ok(status) => status,
            Err(error) => return Err(unsettled(remote, format!("{error:#}"))),
        };
        match status.get("state").and_then(Value::as_str) {
            Some("running") if Instant::now() < deadline => {
                std::thread::sleep(STATUS_EVERY);
            }
            Some("running") => return Err(unsettled(remote, "it did not finish in time".into())),
            Some("done" | "failed") => break status,
            _ => return Err(unsettled(remote, "its state is not known".into())),
        }
    };
    if status.get("state").and_then(Value::as_str) != Some("done") {
        let code = status.get("error_code").and_then(Value::as_str).unwrap_or("blob.failure");
        let error = status.get("error").and_then(Value::as_str).unwrap_or("the fetch failed");
        // A newer push to this folder took over: this one writes nothing
        // more, over the link or otherwise.
        if code == "blob.superseded" {
            return Err(Superseded.into());
        }
        bail!("the machine's fetch failed ({code}): {error}");
    }
    written_by(remote, &job, &mut |path, revision| {
        sent.written.insert(path, revision);
    })
    .context("cannot read what the machine's fetch wrote")?;
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
    use serde_json::json;

    use super::{CHUNK_MAX, CHUNK_MIN, chunks, serves_fetch};

    #[test]
    fn an_identify_answer_without_capabilities_says_nothing_about_fetch() {
        // Unknown, so the push takes the fence of a machine it cannot read.
        assert_eq!(serves_fetch(&json!({"build_id": "b"})), None);
        assert_eq!(serves_fetch(&json!({"capabilities": "blob-fetch-v2"})), None);
        assert_eq!(serves_fetch(&json!({"capabilities": ["fs-v1"]})), Some(false));
        assert_eq!(serves_fetch(&json!({"capabilities": ["fs-v1", "blob-fetch-v2"]})), Some(true));
    }

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
