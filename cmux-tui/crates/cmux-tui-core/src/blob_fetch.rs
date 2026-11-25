//! `blob-fetch-v2`: a Cloud machine fetches the files of a `cmux link sync
//! push` from its owner's content-addressed store (cmux-platform
//! `/v1/sync/blobs`, Cloudflare R2) instead of receiving every byte over the
//! link. The Mac uploads only the blobs the store lacks, then uploads a plan
//! (itself a blob) and starts a job here with the plan's hash and a read grant
//! (`csg_...`, an hour, read-only, the owner's blobs only). The machine reads
//! the plan and every blob over the data-centre network, checks each one's
//! SHA-256, and writes each file atomically under the `fs-v1` roots
//! ([`crate::fs_ops::PendingWrite`]). A second machine, a resume after a pause
//! or a re-sync after a small edit moves almost nothing from the Mac.
//!
//! Served exactly where `fs-v1` is (Cloud hosts), with its sandbox: every
//! path the plan names must resolve under the roots. `blob.fetch.start`
//! answers at once with a job; `blob.fetch.status` reads it. Every job names
//! the folder it writes under (`target`); a start, and `blob.fetch.cancel`,
//! cancel each running job whose folder overlaps, and answer only once none of
//! those can commit another file. So a client that lost an answer, or retries
//! with a changed plan, or writes over the link instead, first fences off what
//! an earlier job might still write. The grant is kept only in the job's
//! memory and never written to disk or logged.
//!
//! Prior art: Mutagen's staging (content is received by digest into a
//! staging area, verified, then moved into place atomically) and its
//! receiver-driven transfer (the side that writes asks for what it lacks).

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use crate::fs_ops::{FsError, PendingWrite, Roots, WriteMode};

/// The capability that carries the `blob.fetch.*` ops.
/// `v2`: `v1`, which only pre-release builds served, had no
/// `blob.fetch.cancel`; a Mac treats a `v1` machine as serving no store.
pub const BLOB_FETCH_CAPABILITY: &str = "blob-fetch-v2";

/// The ops of `blob-fetch-v2`, exactly. The link's remote gate admits these
/// beside the `fs-v1` ops.
pub const BLOB_FETCH_COMMANDS: [&str; 4] =
    ["blob.fetch.start", "blob.fetch.status", "blob.fetch.cancel", "blob.fetch.forget"];

/// The largest plan a job reads.
const MAX_PLAN_BYTES: u64 = 64 * 1024 * 1024;
/// The largest blob (one file or one chunk of a file) a job reads.
const MAX_BLOB_BYTES: u64 = 64 * 1024 * 1024;
/// Files fetched at once.
const PARALLEL_FILES: usize = 16;
/// Tries per blob before the job fails (network errors and 5xx).
const TRIES: u32 = 4;
/// Longest one blob request may take.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(120);
/// Finished jobs that wrote nothing kept for `blob.fetch.status`; one that
/// wrote stays until it is forgotten.
const KEPT_FINISHED: usize = 32;
/// At most this many fetch workers live at once, a cancelled one counting
/// until its thread ends; a start past it is refused (`blob.busy`) and the
/// Mac copies over the link instead.
const MAX_RUNNING: usize = 4;
/// Paths named in a status answer's `failed` list (the rest are counted).
const LISTED_FAILURES: usize = 200;

static SERVICE: OnceLock<BlobFetchService> = OnceLock::new();

/// The fetch owner, when this daemon serves `fs-v1` (it writes under the
/// same roots).
#[must_use]
pub fn installed() -> Option<&'static BlobFetchService> {
    let fs = crate::fs_ops::installed()?;
    Some(SERVICE.get_or_init(|| BlobFetchService::new(fs.roots().clone())))
}

/// The capability to advertise in `identify`, when served.
#[must_use]
pub fn advertised() -> Option<&'static str> {
    crate::fs_ops::installed().map(|_| BLOB_FETCH_CAPABILITY)
}

/// The `cmd` of `line` when it is one of [`BLOB_FETCH_COMMANDS`], exactly.
#[must_use]
pub fn frame_command(line: &str) -> Option<&'static str> {
    let value: Value = serde_json::from_str(line).ok()?;
    let object = value.as_object()?;
    // A frame with `protocol` goes to the resource router, never here.
    if object.contains_key("protocol") {
        return None;
    }
    let cmd = object.get("cmd")?.as_str()?;
    BLOB_FETCH_COMMANDS.iter().copied().find(|known| *known == cmd)
}

/// A refused request: its wire code and display text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub code: &'static str,
    pub message: String,
}

impl Refusal {
    fn bad_request(message: impl Into<String>) -> Self {
        Self { code: "blob.bad_request", message: message.into() }
    }
}

/// The answer to one `blob.fetch.*` request line, in the daemon's envelope.
/// `service` is `None` on a host that is not a Cloud host;
/// `transport_allowed` is the connection's check.
#[must_use]
pub fn answer_line(
    service: Option<&BlobFetchService>,
    transport_allowed: bool,
    line: &str,
) -> Value {
    let Ok(Value::Object(request)) = serde_json::from_str::<Value>(line) else {
        return envelope(&Value::Null, Err(Refusal::bad_request("not a JSON object")));
    };
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let Some(cmd) = frame_command(line) else {
        return envelope(&id, Err(Refusal::bad_request("unknown blob.fetch op")));
    };
    if !transport_allowed {
        return envelope(
            &id,
            Err(Refusal { code: "blob.permission_denied", message: "permission denied".into() }),
        );
    }
    let Some(service) = service else {
        return envelope(
            &id,
            Err(Refusal {
                code: "blob.unavailable",
                message: "store fetches are served only on cmux Cloud hosts".into(),
            }),
        );
    };
    let request = Value::Object(request);
    let result = match cmd {
        "blob.fetch.start" => service.start(&request),
        "blob.fetch.cancel" => service.cancel(&request),
        "blob.fetch.forget" => Ok(service.forget(&request)),
        _ => service.status(&request),
    };
    envelope(&id, result)
}

fn envelope(id: &Value, result: Result<Value, Refusal>) -> Value {
    match result {
        Ok(data) => json!({ "id": id, "ok": true, "data": data }),
        Err(refusal) => json!({
            "id": id,
            "ok": false,
            "error": refusal.message,
            "error_code": refusal.code,
        }),
    }
}

/// Where the blobs are and the grant that reads them.
#[derive(Clone, Deserialize)]
struct Store {
    origin: String,
    grant: String,
}

#[derive(Deserialize)]
struct StartParams {
    store: Store,
    target: String,
    plan: String,
    plan_size: u64,
}

/// What a plan asks for: every file to write, with its content as blobs.
#[derive(Debug, Deserialize, PartialEq, Eq)]
pub struct Plan {
    pub version: u32,
    pub files: Vec<PlanFile>,
}

/// One file of a plan: its absolute path on this machine, its permissions,
/// size and SHA-256, and the blobs whose bytes, in order, are its content
/// (one blob, the file's own hash, when `chunks` is absent).
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct PlanFile {
    pub path: String,
    pub permissions: u32,
    pub size: u64,
    pub sha256: String,
    #[serde(default)]
    pub chunks: Option<Vec<Chunk>>,
}

/// One blob of a file.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Chunk {
    pub sha256: String,
    pub size: u64,
}

impl PlanFile {
    fn blobs(&self) -> Vec<Chunk> {
        match &self.chunks {
            Some(chunks) => chunks.clone(),
            None if self.size == 0 => Vec::new(),
            None => vec![Chunk { sha256: self.sha256.clone(), size: self.size }],
        }
    }
}

/// Whether `text` is 64 lowercase hex digits.
#[must_use]
pub fn is_sha256(text: &str) -> bool {
    text.len() == 64 && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// The store's origin when it is one a machine may read from: https, or
/// http on a loopback address in debug builds (the tests' store).
fn checked_origin(origin: &str) -> Result<String, Refusal> {
    let origin = origin.trim_end_matches('/');
    let rest = origin
        .strip_prefix("https://")
        .or_else(|| {
            if cfg!(debug_assertions) {
                origin
                    .strip_prefix("http://")
                    .filter(|rest| rest.starts_with("127.0.0.1:") || rest.starts_with("localhost:"))
            } else {
                None
            }
        })
        .ok_or_else(|| Refusal::bad_request("store.origin is https"))?;
    if rest.is_empty() || rest.contains(['/', '?', '#', '@', ' ']) {
        return Err(Refusal::bad_request("store.origin is an origin, with no path"));
    }
    Ok(origin.to_string())
}

/// `target` when it is an absolute folder with no `.` or `..` parts, without
/// a trailing slash.
fn checked_target(target: &str) -> Result<String, Refusal> {
    let trimmed = target.trim_end_matches('/');
    if !target.starts_with('/')
        || trimmed.is_empty()
        || trimmed.split('/').skip(1).any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(Refusal::bad_request("target is an absolute folder"));
    }
    Ok(trimmed.to_string())
}

/// Whether `path` is `folder` or under it.
fn under(path: &str, folder: &str) -> bool {
    path.strip_prefix(folder).is_some_and(|rest| rest.is_empty() || rest.starts_with('/'))
}

/// Whether one of two folders holds the other.
fn overlaps(a: &str, b: &str) -> bool {
    under(a, b) || under(b, a)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum State {
    Running,
    Done,
    Failed,
}

#[derive(Default)]
struct Counters {
    files_done: AtomicU64,
    bytes_done: AtomicU64,
    fetched_bytes: AtomicU64,
}

struct Job {
    id: String,
    /// The folder every file of the plan is under.
    target: String,
    /// Set by a newer start or a cancel: commit nothing more.
    cancelled: AtomicBool,
    counters: Counters,
    status: Mutex<JobStatus>,
    /// Each file this job committed and its revision, in commit order.
    written: Mutex<Vec<(String, String)>>,
}

/// At most this many `written` entries in one status answer.
const WRITTEN_PAGE: usize = 1000;

struct JobStatus {
    state: State,
    files_total: u64,
    bytes_total: u64,
    failed: Vec<(String, &'static str)>,
    error: Option<(&'static str, String)>,
}

impl Job {
    fn update(&self, change: impl FnOnce(&mut JobStatus)) {
        change(&mut self.status.lock().unwrap_or_else(PoisonError::into_inner));
    }

    fn answer(&self) -> Value {
        let status = self.status.lock().unwrap_or_else(PoisonError::into_inner);
        let state = match status.state {
            State::Running => "running",
            State::Done => "done",
            State::Failed => "failed",
        };
        let failed: Vec<Value> = status
            .failed
            .iter()
            .take(LISTED_FAILURES)
            .map(|(path, code)| json!({"path": path, "error_code": code}))
            .collect();
        let mut answer = json!({
            "job": self.id,
            "state": state,
            "files_done": self.counters.files_done.load(Ordering::Relaxed),
            "files_total": status.files_total,
            "bytes_done": self.counters.bytes_done.load(Ordering::Relaxed),
            "bytes_total": status.bytes_total,
            "fetched_bytes": self.counters.fetched_bytes.load(Ordering::Relaxed),
            "failed": failed,
            "failed_count": status.failed.len(),
        });
        if let (Some((code, message)), Some(object)) = (&status.error, answer.as_object_mut()) {
            object.insert("error_code".into(), json!(code));
            object.insert("error".into(), json!(message));
        }
        answer
    }
}

/// One live fetch thread in [`BlobFetchService::alive`], for as long as it
/// is held (dropped when the thread ends, or with it when it never starts).
struct Alive(Arc<AtomicUsize>);

impl Alive {
    fn enter(count: &Arc<AtomicUsize>) -> Self {
        count.fetch_add(1, Ordering::SeqCst);
        Self(count.clone())
    }
}

impl Drop for Alive {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The jobs of this daemon.
pub struct BlobFetchService {
    roots: Roots,
    jobs: Mutex<Jobs>,
    /// Held across a job's cancelled check and its commit, so a cancel that
    /// takes it once knows no cancelled job commits after it.
    commits: Arc<Mutex<()>>,
    /// Fetch threads not yet ended, cancelled ones included.
    alive: Arc<AtomicUsize>,
}

#[derive(Default)]
struct Jobs {
    by_id: HashMap<String, Arc<Job>>,
    finished: VecDeque<String>,
    next: u64,
}

impl BlobFetchService {
    #[must_use]
    pub fn new(roots: Roots) -> Self {
        Self {
            roots,
            jobs: Mutex::new(Jobs::default()),
            commits: Arc::new(Mutex::new(())),
            alive: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn start(&self, request: &Value) -> Result<Value, Refusal> {
        let params: StartParams = serde_json::from_value(request.clone())
            .map_err(|error| Refusal::bad_request(format!("invalid params: {error}")))?;
        if !is_sha256(&params.plan) {
            return Err(Refusal::bad_request("plan is a SHA-256"));
        }
        if params.plan_size == 0 || params.plan_size > MAX_PLAN_BYTES {
            return Err(Refusal::bad_request("plan_size is out of range"));
        }
        if !params.store.grant.starts_with("csg_") || params.store.grant.len() > 256 {
            return Err(Refusal::bad_request("store.grant is a csg_ grant"));
        }
        let origin = checked_origin(&params.store.origin)?;
        let target = checked_target(&params.target)?;
        let store = Store { origin, grant: params.store.grant };
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        // An earlier job under the same folder may still write: it stops
        // before this one starts, whatever its plan.
        self.cancel_overlapping(&jobs, &target);
        if self.alive.load(Ordering::SeqCst) >= MAX_RUNNING {
            return Err(Refusal {
                code: "blob.busy",
                message: format!("{MAX_RUNNING} store fetches are running already"),
            });
        }
        jobs.next += 1;
        let id = format!("fetch_{}_{}", std::process::id(), jobs.next);
        let job = Arc::new(Job {
            id: id.clone(),
            target,
            cancelled: AtomicBool::new(false),
            counters: Counters::default(),
            written: Mutex::new(Vec::new()),
            status: Mutex::new(JobStatus {
                state: State::Running,
                files_total: 0,
                bytes_total: 0,
                failed: Vec::new(),
                error: None,
            }),
        });
        jobs.by_id.insert(id, job.clone());
        // Counted under the jobs lock, as the cap was checked: two starts
        // at once cannot both take the last place.
        let alive = Alive::enter(&self.alive);
        drop(jobs);
        let roots = self.roots.clone();
        let commits = self.commits.clone();
        let (plan, plan_size) = (params.plan, params.plan_size);
        let running = job.clone();
        let spawned = std::thread::Builder::new().name("blob-fetch".into()).spawn(move || {
            let _alive = alive;
            let result = run(&roots, &store, &plan, plan_size, &running, &commits);
            // A cancelled job already reads as failed (`blob.superseded`).
            running.update(|status| match result {
                _ if status.state != State::Running => {}
                Ok(()) => status.state = State::Done,
                Err((code, message)) => {
                    status.state = State::Failed;
                    status.error = Some((code, message));
                }
            });
        });
        if spawned.is_err() {
            job.update(|status| {
                status.state = State::Failed;
                status.error = Some(("blob.failure", "could not start the fetch".into()));
            });
        }
        let answer = job.answer();
        self.retire_finished();
        Ok(answer)
    }

    /// `blob.fetch.cancel {target}`: cancels every running job under a folder
    /// that overlaps `target`, and answers once none of them can commit, with
    /// every kept job there (`jobs`): what each committed is readable with
    /// `blob.fetch.status` and `written_from` until the caller forgets it.
    fn cancel(&self, request: &Value) -> Result<Value, Refusal> {
        let target = request
            .get("target")
            .and_then(Value::as_str)
            .ok_or_else(|| Refusal::bad_request("target is required"))?;
        let target = checked_target(target)?;
        // Retired first, so each job this answer names is still kept.
        self.retire_finished();
        let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let (cancelled, kept) = self.cancel_overlapping(&jobs, &target);
        drop(jobs);
        Ok(json!({ "cancelled": cancelled, "jobs": kept }))
    }

    /// `blob.fetch.forget {jobs}`: drops each named job that is no longer
    /// running, once the caller has recorded what it wrote.
    fn forget(&self, request: &Value) -> Value {
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let mut forgotten = 0;
        for id in request.get("jobs").and_then(Value::as_array).into_iter().flatten() {
            let Some(id) = id.as_str() else { continue };
            let running = jobs.by_id.get(id).is_some_and(|job| {
                job.status.lock().unwrap_or_else(PoisonError::into_inner).state == State::Running
            });
            if !running && jobs.by_id.remove(id).is_some() {
                jobs.finished.retain(|kept| kept != id);
                forgotten += 1;
            }
        }
        json!({ "forgotten": forgotten })
    }

    /// Marks each running job whose folder overlaps `target` cancelled and
    /// failed, then waits out a commit one of them may be in. Answers how
    /// many it stopped, and every job kept there (stopped, failed or done
    /// and not yet forgotten).
    fn cancel_overlapping(&self, jobs: &Jobs, target: &str) -> (usize, Vec<String>) {
        let mut cancelled = 0;
        let mut kept = Vec::new();
        for job in jobs.by_id.values() {
            if !overlaps(&job.target, target) {
                continue;
            }
            let mut status = job.status.lock().unwrap_or_else(PoisonError::into_inner);
            match status.state {
                State::Done | State::Failed => {}
                State::Running => {
                    job.cancelled.store(true, Ordering::SeqCst);
                    status.state = State::Failed;
                    status.error =
                        Some(("blob.superseded", "a newer push to this folder took over".into()));
                    cancelled += 1;
                }
            }
            kept.push(job.id.clone());
        }
        if cancelled > 0 {
            drop(self.commits.lock().unwrap_or_else(PoisonError::into_inner));
        }
        (cancelled, kept)
    }

    fn status(&self, request: &Value) -> Result<Value, Refusal> {
        let id = request
            .get("job")
            .and_then(Value::as_str)
            .ok_or_else(|| Refusal::bad_request("job is required"))?;
        let jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let job = jobs
            .by_id
            .get(id)
            .cloned()
            .ok_or(Refusal { code: "blob.no_job", message: "no such fetch job".into() })?;
        drop(jobs);
        let mut answer = job.answer();
        // `written_from`: a page of the files committed so far, with their
        // revisions, from that index on.
        if let Some(from) = request.get("written_from").and_then(Value::as_u64) {
            let written = job.written.lock().unwrap_or_else(PoisonError::into_inner);
            let from = usize::try_from(from).unwrap_or(usize::MAX);
            let page: Vec<Value> = written
                .iter()
                .skip(from)
                .take(WRITTEN_PAGE)
                .map(|(path, revision)| json!({"path": path, "revision": revision}))
                .collect();
            if let Some(object) = answer.as_object_mut() {
                object.insert("written".into(), json!(page));
                object.insert("written_count".into(), json!(written.len()));
            }
        }
        self.retire_finished();
        Ok(answer)
    }

    /// Keeps at most [`KEPT_FINISHED`] finished jobs that wrote nothing. A
    /// job that committed a file stays until `blob.fetch.forget`: its push
    /// may have died before a manifest named those files, and the next push
    /// to the folder reads them from it ([`Self::cancel`]), however many jobs
    /// finished in between.
    fn retire_finished(&self) {
        let mut jobs = self.jobs.lock().unwrap_or_else(PoisonError::into_inner);
        let finished: Vec<String> = jobs
            .by_id
            .iter()
            .filter(|(id, job)| {
                // Under the jobs lock a job that is not running commits
                // nothing more (a cancel waits out its commit before it
                // lets go), so what it wrote is final.
                job.status.lock().unwrap_or_else(PoisonError::into_inner).state != State::Running
                    && job.written.lock().unwrap_or_else(PoisonError::into_inner).is_empty()
                    && !jobs.finished.contains(id)
            })
            .map(|(id, _)| id.clone())
            .collect();
        jobs.finished.extend(finished);
        while jobs.finished.len() > KEPT_FINISHED {
            if let Some(old) = jobs.finished.pop_front() {
                jobs.by_id.remove(&old);
            }
        }
    }
}

type Failure = (&'static str, String);

fn run(
    roots: &Roots,
    store: &Store,
    plan: &str,
    plan_size: u64,
    job: &Job,
    commits: &Mutex<()>,
) -> Result<(), Failure> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(4)
        .enable_all()
        .build()
        .map_err(|error| ("blob.failure", error.to_string()))?;
    runtime.block_on(async {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .user_agent(concat!("cmux/", env!("CARGO_PKG_VERSION")))
            .timeout(REQUEST_TIMEOUT)
            .build()
            .map_err(|error| ("blob.failure", error.to_string()))?;
        let bytes = fetch_blob(&client, store, plan, plan_size).await?;
        let plan: Plan = serde_json::from_slice(&bytes)
            .map_err(|error| ("blob.bad_plan", format!("the plan is not readable: {error}")))?;
        if plan.version != 1 {
            return Err(("blob.bad_plan", format!("plan version {} is not known", plan.version)));
        }
        check_plan(&plan, &job.target)?;
        job.update(|status| {
            status.files_total = plan.files.len() as u64;
            status.bytes_total = plan.files.iter().map(|file| file.size).sum();
        });
        use futures_util::stream::{self, StreamExt as _};
        let outcomes: Vec<Result<(), (String, Failure)>> = stream::iter(plan.files.iter())
            .map(|file| {
                let client = &client;
                async move {
                    let written = write_file(client, store, roots, file, job, commits).await;
                    job.counters.files_done.fetch_add(1, Ordering::Relaxed);
                    written.map_err(|failure| (file.path.clone(), failure))
                }
            })
            .buffer_unordered(PARALLEL_FILES)
            .collect()
            .await;
        // A file the sandbox refused (a folder in the way, say) is named for the
        // Mac to write itself; a store or disk failure fails the job.
        let mut fatal = None;
        for outcome in outcomes {
            if let Err((path, (code, message))) = outcome {
                if code.starts_with("fs.") && code != "fs.no_space" {
                    job.update(|status| status.failed.push((path, code)));
                } else if fatal.is_none() {
                    fatal = Some((code, message));
                }
            }
        }
        fatal.map_or(Ok(()), Err)
    })
}

/// Every file is under `target`, every hash is a SHA-256, every size within
/// bounds and every file's chunks add up to its size.
fn check_plan(plan: &Plan, target: &str) -> Result<(), Failure> {
    let bad = |why: String| ("blob.bad_plan", why);
    for file in &plan.files {
        if !is_sha256(&file.sha256)
            || !file.path.starts_with('/')
            || file.path.split('/').any(|part| part == "." || part == "..")
            || !under(&file.path, target)
            || file.path == target
        {
            return Err(bad(format!("{} is not a plan entry", file.path)));
        }
        let blobs = file.blobs();
        if blobs.iter().any(|chunk| !is_sha256(&chunk.sha256) || chunk.size > MAX_BLOB_BYTES) {
            return Err(bad(format!("{} names a bad chunk", file.path)));
        }
        if blobs.iter().map(|chunk| chunk.size).sum::<u64>() != file.size {
            return Err(bad(format!("{}'s chunks do not add up to its size", file.path)));
        }
    }
    Ok(())
}

async fn write_file(
    client: &reqwest::Client,
    store: &Store,
    roots: &Roots,
    file: &PlanFile,
    job: &Job,
    commits: &Mutex<()>,
) -> Result<(), Failure> {
    let fs = |error: FsError| (error.code(), error.message());
    let superseded = || ("blob.superseded", "a newer push to this folder took over".to_string());
    if job.cancelled.load(Ordering::SeqCst) {
        return Err(superseded());
    }
    // A symlink anywhere on the path, its last part or a folder, now or put
    // there before the commit: the write would land wherever it points, so
    // it is refused (`fs.symlink_in_path`). The file is named as failed, and
    // the Mac sends it over the link, which skips it the same way.
    let mut pending =
        PendingWrite::begin_no_follow(roots, &file.path, WriteMode::Overwrite, Some(file.size))
            .map_err(fs)?;
    pending.set_permissions(file.permissions).map_err(fs)?;
    let mut whole = Sha256::new();
    for chunk in file.blobs() {
        if job.cancelled.load(Ordering::SeqCst) {
            return Err(superseded());
        }
        let bytes = fetch_blob(client, store, &chunk.sha256, chunk.size).await?;
        job.counters.fetched_bytes.fetch_add(bytes.len() as u64, Ordering::Relaxed);
        whole.update(&bytes);
        pending.write(&bytes).map_err(fs)?;
        job.counters.bytes_done.fetch_add(bytes.len() as u64, Ordering::Relaxed);
    }
    if hex(&whole.finalize()) != file.sha256 {
        return Err(("blob.digest_mismatch", format!("{} did not match its hash", file.path)));
    }
    // Checked, committed and recorded under one lock: a cancel that returned
    // has seen this commit and its record, or this job sees the cancel and
    // writes nothing.
    let _commit = commits.lock().unwrap_or_else(PoisonError::into_inner);
    if job.cancelled.load(Ordering::SeqCst) {
        return Err(superseded());
    }
    let entry = pending.commit().map_err(fs)?;
    let revision = entry.revision.unwrap_or_default();
    job.written.lock().unwrap_or_else(PoisonError::into_inner).push((file.path.clone(), revision));
    Ok(())
}

/// The blob `sha256` of `size` bytes from the store, its hash checked; a
/// network error or 5xx is tried again.
async fn fetch_blob(
    client: &reqwest::Client,
    store: &Store,
    sha256: &str,
    size: u64,
) -> Result<Vec<u8>, Failure> {
    let url = format!("{}/v1/sync/blobs/{sha256}", store.origin);
    let mut last = ("blob.store_unreachable", String::new());
    for attempt in 0..TRIES {
        if attempt > 0 {
            tokio::time::sleep(Duration::from_millis(250 << attempt)).await;
        }
        let response = match client.get(&url).bearer_auth(&store.grant).send().await {
            Ok(response) => response,
            Err(error) => {
                last = ("blob.store_unreachable", error.without_url().to_string());
                continue;
            }
        };
        let status = response.status().as_u16();
        match status {
            200 => {}
            401 | 403 => {
                return Err((
                    "blob.store_refused",
                    format!("the store refused the grant ({status})"),
                ));
            }
            404 => return Err(("blob.not_found", format!("the store has no blob {sha256}"))),
            500.. => {
                last = ("blob.store_unreachable", format!("the store answered {status}"));
                continue;
            }
            _ => return Err(("blob.store_refused", format!("the store answered {status}"))),
        }
        if response.content_length().is_some_and(|length| length != size) {
            return Err(("blob.digest_mismatch", format!("blob {sha256} has the wrong size")));
        }
        // Read at most `size` bytes, whatever the store says the body holds.
        let mut response = response;
        let mut bytes = Vec::with_capacity(usize::try_from(size).unwrap_or(0));
        let mut cut = None;
        loop {
            match response.chunk().await {
                Ok(Some(chunk)) => {
                    if (bytes.len() + chunk.len()) as u64 > size {
                        return Err((
                            "blob.digest_mismatch",
                            format!("blob {sha256} is larger than its size"),
                        ));
                    }
                    bytes.extend_from_slice(&chunk);
                }
                Ok(None) => break,
                Err(error) => {
                    cut = Some(error.without_url().to_string());
                    break;
                }
            }
        }
        if let Some(error) = cut {
            last = ("blob.store_unreachable", error);
            continue;
        }
        if bytes.len() as u64 != size || hex(&Sha256::digest(&bytes)) != sha256 {
            return Err(("blob.digest_mismatch", format!("blob {sha256} did not match its hash")));
        }
        return Ok(bytes);
    }
    Err(last)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests;
