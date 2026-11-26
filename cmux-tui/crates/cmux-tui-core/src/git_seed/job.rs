//! Seed jobs: `git.seed.start` answers at once and the seed runs on a thread
//! of its own; `git.seed.status` reads it. A start with the same folder,
//! bundle and WORK commit as a running or finished job returns that job, so a
//! client that lost the answer retries safely. `git.seed.export` runs as a
//! job the same way ([`super::export`]); one folder has one running job.
//!
//! A head-first seed ([`super::params::HeadFirst`]) says `head_ready: true` in its
//! status once its head is in place and marked on the sync barrier, while it still
//! runs: a client may open the chat then, and every tool still waits for the whole
//! checkout. (`head` is the checked-out commit once done, so the mark has its own name.)

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Condvar, Mutex, PoisonError, mpsc};
use std::time::{Duration, Instant};

use serde::Deserialize;
use serde_json::{Value, json};

use super::export::{Export, ExportParams};
use super::git::{Credential, Git, Progress};
use super::params::StartParams;
use super::{SeedRefusal, hold, place, run};
use crate::fs_ops::Roots;

/// Finished jobs kept for `git.seed.status`.
const KEPT_FINISHED: usize = 64;

/// Longest a `git.seed.status` with `wait_ms` holds its answer for the job to end (or reach
/// its head). It answers at once when the job ends, so a client asks again at most this
/// often while it runs and still hears progress.
const STATUS_WAIT_CEILING: Duration = Duration::from_millis(1000);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum State {
    Running,
    Done,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    Clone,
    Fetch,
    Bundle,
    Checkout,
    Submodules,
    Lfs,
    Export,
    /// A copy this Mac streams in under a hold ([`super::hold`]).
    Copy,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Clone => "clone",
            Self::Fetch => "fetch",
            Self::Bundle => "bundle",
            Self::Checkout => "checkout",
            Self::Submodules => "submodules",
            Self::Lfs => "lfs",
            Self::Export => "export",
            Self::Copy => "copy",
        }
    }
}

/// Why a job failed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Failed {
    pub code: &'static str,
    pub error: String,
    pub install_url: Option<String>,
}

#[derive(Clone, Debug)]
struct Status {
    state: State,
    phase: Phase,
    progress: Progress,
    failed: Option<Failed>,
    notes: Vec<&'static str>,
    /// When done: what the folder has checked out.
    head: Option<(String, Option<String>)>,
    /// When an export is done: its answer's fields.
    exported: Option<serde_json::Map<String, Value>>,
    /// The seed marked its head on the sync barrier and fills the rest.
    head_ready: bool,
    /// Where the job's time went, its status `timings`: since it began, since `phase` began,
    /// each phase it left, its whole time once ended, and its thread's git runs and waits
    /// ([`super::git::take_runs`]).
    began: Instant,
    phase_began: Instant,
    phase_times: Vec<(&'static str, Duration)>,
    took: Option<Duration>,
    runs: Value,
}

impl Status {
    /// Adds the time since `phase` began to it.
    fn close_phase(&mut self, now: Instant) {
        let took = now.duration_since(self.phase_began);
        let name = self.phase.name();
        match self.phase_times.iter_mut().find(|(phase, _)| *phase == name) {
            Some((_, sum)) => *sum += took,
            None => self.phase_times.push((name, took)),
        }
        self.phase_began = now;
    }

    fn timings(&self) -> Value {
        let mut phases: Vec<(&'static str, Duration)> = self.phase_times.clone();
        if self.took.is_none() {
            phases.push((self.phase.name(), self.phase_began.elapsed()));
        }
        let phases: serde_json::Map<String, Value> = phases
            .into_iter()
            .map(|(name, took)| (name.to_owned(), json!(took.as_millis())))
            .collect();
        json!({
            "job_ms": self.took.unwrap_or_else(|| self.began.elapsed()).as_millis(),
            "phases": phases,
            "git": self.runs,
        })
    }
}

/// One seed.
pub struct Job {
    id: String,
    folder: PathBuf,
    /// With `folder`, what makes a retry this job ([`StartParams::retry_key`]).
    key: String,
    status: Mutex<Status>,
    /// Told on every status change, for a `git.seed.status` that waits ([`Self::wait_end`]).
    changed: Condvar,
}

impl Job {
    fn running(id: String, folder: PathBuf, key: String, phase: Phase) -> Self {
        Self {
            id,
            folder,
            key,
            status: Mutex::new(Status::running(phase)),
            changed: Condvar::new(),
        }
    }

    pub(super) fn id(&self) -> &str {
        &self.id
    }

    fn status(&self) -> Status {
        self.status.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn update(&self, change: impl FnOnce(&mut Status)) {
        change(&mut self.status.lock().unwrap_or_else(PoisonError::into_inner));
        self.changed.notify_all();
    }

    /// Waits up to `limit` while the job runs and its head mark is what it was: the
    /// answer a client would otherwise poll for comes as soon as it changes. Whether it
    /// waited at all (a job already ended answers at once).
    fn wait_end(&self, limit: Duration) -> bool {
        let status = self.status.lock().unwrap_or_else(PoisonError::into_inner);
        let head_ready = status.head_ready;
        if status.state != State::Running {
            return false;
        }
        let _ = self
            .changed
            .wait_timeout_while(status, limit, |status| {
                status.state == State::Running && status.head_ready == head_ready
            })
            .unwrap_or_else(PoisonError::into_inner);
        true
    }

    pub(super) fn enter(&self, phase: Phase) {
        self.update(|status| {
            status.close_phase(Instant::now());
            status.phase = phase;
        });
    }

    pub(super) fn progress(&self, line: &str) {
        self.update(|status| super::git::read_progress(line, &mut status.progress));
    }

    /// The checked-out commit and branch ref (`refs/heads/...`) when done.
    pub(super) fn checked_out(&self, head: String, head_ref: Option<String>) {
        self.update(|status| status.head = Some((head, head_ref)));
    }

    /// An export's result, added to the status answer once done.
    pub(super) fn exported(&self, fields: serde_json::Map<String, Value>) {
        self.update(|status| status.exported = Some(fields));
    }

    /// The head is in place and marked on the barrier (`Sync::head_ready`).
    pub(super) fn reached_head(&self) {
        self.update(|status| status.head_ready = true);
    }

    /// Whether the head is marked already.
    pub(super) fn status_head_ready(&self) -> bool {
        self.status().head_ready
    }

    pub(super) fn note(&self, note: &'static str) {
        self.update(|status| status.notes.push(note));
    }

    pub(super) fn finish(&self, result: Result<(), Failed>) {
        let runs = super::git::take_runs();
        self.update(|status| {
            let now = Instant::now();
            status.close_phase(now);
            status.took = Some(now.duration_since(status.began));
            status.runs = runs;
        });
        self.update(|status| match result {
            Ok(()) => status.state = State::Done,
            Err(failed) => {
                status.state = State::Failed;
                status.failed = Some(failed);
            }
        });
    }

    fn answer(&self) -> Value {
        let status = self.status();
        let state = match status.state {
            State::Running => "running",
            State::Done => "done",
            State::Failed => "failed",
        };
        let mut answer = json!({
            "job": self.id,
            "state": state,
            "phase": status.phase.name(),
            "progress": {
                "received_bytes": status.progress.received_bytes,
                "objects": status.progress.objects,
                "total_objects": status.progress.total_objects,
            },
            "notes": status.notes,
            "timings": status.timings(),
        });
        if status.head_ready
            && let Some(object) = answer.as_object_mut()
        {
            object.insert("head_ready".into(), true.into());
        }
        if let (State::Done, Some((head, head_ref)), Some(object)) =
            (status.state, status.head, answer.as_object_mut())
        {
            object.insert("head".into(), head.into());
            object.insert("head_ref".into(), head_ref.map_or(Value::Null, Value::from));
        }
        if let (State::Done, Some(fields), Some(object)) =
            (status.state, status.exported, answer.as_object_mut())
        {
            object.extend(fields);
        }
        if let (Some(failed), Some(object)) = (status.failed, answer.as_object_mut()) {
            object.insert("error_code".into(), failed.code.into());
            object.insert("error".into(), failed.error.into());
            if let Some(url) = failed.install_url {
                object.insert("install_url".into(), url.into());
            }
        }
        answer
    }
}

/// How a service runs git: the credential paths (the machine's own unless a
/// test names them) and extra config (tests only).
#[derive(Clone, Debug, Default)]
pub struct Config {
    pub git: Git,
    pub credentials: Option<Vec<Credential>>,
}

#[derive(Default)]
struct Jobs {
    by_id: HashMap<String, Arc<Job>>,
    order: VecDeque<String>,
}

/// The daemon's seed owner over the `fs-v1` roots.
pub struct GitSeedService {
    roots: Roots,
    config: Config,
    jobs: Mutex<Jobs>,
    /// The running holds' owner threads, and whether each still runs, by job ([`super::hold`]).
    holds: Arc<Mutex<HashMap<String, Holder>>>,
    /// Holds taken while set run on [`hold::Lease::Ticks`] (tests; see [`Self::lease_tick`]).
    #[cfg(test)]
    pub(super) ticked_leases: std::sync::atomic::AtomicBool,
}

/// A running hold's owner thread, and whether the hold still runs.
type Holder = (mpsc::Sender<hold::Op>, hold::Alive);

#[derive(Deserialize)]
struct StatusParams {
    job: String,
    /// Hold the answer up to this long (at most [`STATUS_WAIT_CEILING`]) while the job runs
    /// and has not reached its head; the answer then says `waited: true`. Older daemons ignore
    /// it and answer at once, so a client still pauses when `waited` is missing.
    #[serde(default)]
    wait_ms: Option<u64>,
}

impl GitSeedService {
    #[must_use]
    pub fn new(roots: Roots) -> Self {
        Self::with_config(roots, Config::default())
    }

    pub(crate) fn with_config(roots: Roots, config: Config) -> Self {
        Self {
            roots,
            config,
            jobs: Mutex::new(Jobs::default()),
            holds: Arc::default(),
            #[cfg(test)]
            ticked_leases: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// For tests (and the debug-only daemon seam in [`super::installed`]):
    /// a service whose GitHub is the folder `github`, so
    /// `https://github.com/OWNER/NAME.git` is cloned from
    /// `file://<github>/OWNER/NAME.git`, with no credential. Nothing on the
    /// wire reaches it.
    #[doc(hidden)]
    #[must_use]
    pub fn with_test_github(roots: Roots, github: &std::path::Path) -> Self {
        let local = format!("file://{}/", github.display());
        let config = Config {
            git: Git {
                extra_config: vec![
                    format!("url.{local}.insteadOf=https://github.com/"),
                    "protocol.file.allow=always".into(),
                ],
            },
            credentials: Some(vec![Credential::Anonymous]),
        };
        Self::with_config(roots, config)
    }

    /// Runs `cmd` with the request object `params`.
    pub fn call(&self, cmd: &str, params: &Value) -> Result<Value, SeedRefusal> {
        match cmd {
            "git.seed.start" => self.start(params),
            "git.seed.export" => self.export(params),
            "git.seed.hold" => self.hold(params),
            "git.seed.hold.head" => self.hold_head(params),
            "git.seed.hold.end" => self.hold_end(params),
            "git.seed.status" => {
                let params: StatusParams =
                    serde_json::from_value(params.clone()).map_err(|error| {
                        SeedRefusal::bad_request(format!("invalid params: {error}"))
                    })?;
                // A copy reading its hold's status keeps the hold's lease.
                if let Some(owner) = self.holder(&params.job) {
                    let _ = owner.send(hold::Op::Renew);
                }
                let job = self.jobs().by_id.get(&params.job).cloned();
                let job = job.ok_or_else(|| SeedRefusal {
                    code: "seed.unknown_job",
                    message: "no such seed job on this machine (the daemon may have restarted)"
                        .into(),
                })?;
                let waited = params.wait_ms.is_some_and(|wait| {
                    job.wait_end(Duration::from_millis(wait).min(STATUS_WAIT_CEILING))
                });
                let mut answer = job.answer();
                if waited && let Some(object) = answer.as_object_mut() {
                    object.insert("waited".into(), true.into());
                }
                Ok(answer)
            }
            _ => Err(SeedRefusal::bad_request("unknown git.seed op")),
        }
    }

    fn jobs(&self) -> std::sync::MutexGuard<'_, Jobs> {
        self.jobs.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn start(&self, params: &Value) -> Result<Value, SeedRefusal> {
        let params = StartParams::parse(params)?;
        let folder = place::folder(&self.roots, &params.folder)?;
        let mut jobs = self.jobs();
        if let Some(id) = same_job(&jobs, &folder, Some(&params.retry_key()), true)? {
            return Ok(json!({ "job": id }));
        }
        let mut others = jobs.by_id.values().map(|job| job.folder.as_path());
        place::not_nested(&self.roots, &folder, &mut others)?;
        let id = new_id();
        let bundle = match params.clone_only {
            Some(_) => None,
            None => Some(place::bundle(&self.roots, &params.bundle, &id)?),
        };
        let carry =
            params.carry.as_deref().map(|path| place::carry(&self.roots, path, &id)).transpose()?;
        let job = Arc::new(Job::running(id, folder.clone(), params.retry_key(), Phase::Clone));
        // A delta only applies source changes to a folder already in use: its
        // dependencies are left alone.
        let first = params.since.is_none();
        // Clone-only refuses a nonempty folder without touching it. Do not
        // replace an existing ready barrier with an incomplete one for that
        // no-op refusal (the worker repeats this check before cloning).
        if params.clone_only.is_some()
            && std::fs::read_dir(&folder).is_ok_and(|mut entries| entries.next().is_some())
        {
            job.finish(Err(Failed {
                code: "seed.folder_not_empty",
                error: "the folder exists and is not empty".into(),
                install_url: None,
            }));
            jobs.order.push_back(job.id.clone());
            jobs.by_id.insert(job.id.clone(), job.clone());
            prune(&mut jobs);
            return Ok(json!({ "job": job.id }));
        }
        let credentials =
            self.config.credentials.clone().unwrap_or_else(super::git::machine_credentials);
        let seed = run::Seed::new(
            job.clone(),
            params,
            folder,
            bundle,
            carry,
            self.roots.clone(),
            self.config.git.clone(),
            credentials,
        );
        // Publish the barrier before start answers: no agent may observe a
        // partially cloned or checked-out repository as ready.
        let mut barrier = cmux_git::sync_barrier::Sync::begin(&job.folder).map_err(|error| {
            SeedRefusal::bad_request(format!("cannot begin repository sync: {error}"))
        })?;
        let worker = job.clone();
        std::thread::Builder::new()
            .name("cmux-git-seed".into())
            .spawn(move || {
                let result = seed.run(&mut barrier).and_then(|()| {
                    barrier.complete().map_err(|error| Failed {
                        code: "seed.clone_failed",
                        error: format!("cannot finish repository sync: {error}"),
                        install_url: None,
                    })
                });
                let ok = result.is_ok();
                worker.finish(result);
                if ok && first {
                    super::seeded(&worker.folder);
                }
            })
            .map_err(|error| SeedRefusal::bad_request(format!("cannot start the seed: {error}")))?;
        jobs.order.push_back(job.id.clone());
        jobs.by_id.insert(job.id.clone(), job.clone());
        prune(&mut jobs);
        Ok(json!({ "job": job.id }))
    }
}

impl GitSeedService {
    /// `git.seed.export`: the folder must be a clone already (a seed's), and
    /// the bundle goes outside it under the roots.
    fn export(&self, params: &Value) -> Result<Value, SeedRefusal> {
        let params = ExportParams::parse(params)?;
        let folder = place::folder(&self.roots, &params.folder)?;
        if !std::fs::symlink_metadata(folder.join(".git")).is_ok_and(|meta| meta.is_dir()) {
            return Err(SeedRefusal {
                code: "seed.since_mismatch",
                message: "the folder is not a seed of a repository".into(),
            });
        }
        let mut jobs = self.jobs();
        // A retry whose answer was lost is the same job, even once its bundle
        // is written.
        if let Some(id) = same_job(&jobs, &folder, Some(&params.retry_key()), true)? {
            return Ok(json!({ "job": id }));
        }
        refuse_while_filling(&folder)?;
        place::output(&self.roots, &params.bundle, &folder)?;
        let id = new_id();
        let job = Arc::new(Job::running(id, folder.clone(), params.retry_key(), Phase::Export));
        let export =
            Export::new(job.clone(), params, folder, self.roots.clone(), self.config.git.clone());
        let worker = job.clone();
        std::thread::Builder::new()
            .name("cmux-git-seed-export".into())
            .spawn(move || worker.finish(export.run()))
            .map_err(|error| {
                SeedRefusal::bad_request(format!("cannot start the export: {error}"))
            })?;
        jobs.order.push_back(job.id.clone());
        jobs.by_id.insert(job.id.clone(), job.clone());
        prune(&mut jobs);
        Ok(json!({ "job": job.id }))
    }
}

impl GitSeedService {
    /// `git.seed.hold`: the barrier for a new folder a copy streams in ([`super::hold`]).
    fn hold(&self, params: &Value) -> Result<Value, SeedRefusal> {
        let params = hold::HoldParams::parse(params)?;
        let head = params.head()?;
        let folder = place::folder(&self.roots, &params.folder)?;
        let mut jobs = self.jobs();
        // Only a running hold is a retry: a done one is a copy that already ended, and a
        // hold with no key is never one.
        let key = params.retry_key();
        if let Some(id) = same_job(&jobs, &folder, key.as_deref(), false)? {
            if let Some(owner) = self.holder(&id) {
                let _ = owner.send(hold::Op::Renew);
            }
            return Ok(json!({ "job": id }));
        }
        let mut others = jobs.by_id.values().map(|job| job.folder.as_path());
        place::not_nested(&self.roots, &folder, &mut others)?;
        hold::fresh(&folder)?;
        let job =
            Arc::new(Job::running(new_id(), folder.clone(), key.unwrap_or_default(), Phase::Copy));
        // The barrier is taken before the hold answers: nothing the copy writes reads ready.
        let barrier = cmux_git::sync_barrier::Sync::begin(&folder).map_err(|error| {
            SeedRefusal::bad_request(format!("cannot begin repository sync: {error}"))
        })?;
        let holds = self.holds.clone();
        let id = job.id.clone();
        let alive = hold::Alive::new(std::sync::RwLock::new(true));
        let mut owners = self.holds.lock().unwrap_or_else(PoisonError::into_inner);
        let lease = hold::Lease::Wall(params.lease());
        #[cfg(test)]
        let lease = if self.ticked_leases.load(std::sync::atomic::Ordering::Relaxed) {
            hold::Lease::Ticks
        } else {
            lease
        };
        let owner =
            hold::spawn(job.clone(), folder, head, lease, barrier, alive.clone(), move || {
                holds.lock().unwrap_or_else(PoisonError::into_inner).remove(&id);
            })?;
        owners.insert(job.id.clone(), (owner, alive));
        drop(owners);
        jobs.order.push_back(job.id.clone());
        jobs.by_id.insert(job.id.clone(), job.clone());
        prune(&mut jobs);
        Ok(json!({ "job": job.id }))
    }

    /// `git.seed.hold.head`: marks the copy's head when a start there is safe.
    fn hold_head(&self, params: &Value) -> Result<Value, SeedRefusal> {
        let (job, owner) = self.running_hold(params)?;
        let (reply, marked) = mpsc::channel();
        owner.send(hold::Op::Head(reply)).map_err(|_| hold_ended())?;
        let marked = marked.recv().map_err(|_| hold_ended())?;
        Ok(hold::head_answer(&job, marked))
    }

    /// `git.seed.hold.end {ok}`: the barrier ready, or left failed; answers the job's status.
    fn hold_end(&self, params: &Value) -> Result<Value, SeedRefusal> {
        let parsed = serde_json::from_value::<hold::JobParams>(params.clone()).ok();
        let ok = parsed
            .as_ref()
            .and_then(|params| params.ok)
            .ok_or_else(|| SeedRefusal::bad_request("hold.end needs ok: true or false"))?;
        let partial = parsed.and_then(|params| params.partial);
        if partial.as_deref().is_some_and(|reason| !hold::PARTIAL_REASONS.contains(&reason)) {
            return Err(SeedRefusal::bad_request("hold.end's partial names no known reason"));
        }
        let (job, owner) = self.running_hold(params)?;
        let (reply, ended) = mpsc::channel();
        owner.send(hold::Op::End(ok, partial, reply)).map_err(|_| hold_ended())?;
        // A copy that could not finish is the job's own failed status, answered below.
        let _finished: Result<(), Failed> = ended.recv().map_err(|_| hold_ended())?;
        let job = self.jobs().by_id.get(&job).cloned().ok_or_else(hold_ended)?;
        Ok(job.answer())
    }

    /// Ends one lease window of the ticked hold `job` (tests): the hold ends unless an op came
    /// since the window before.
    #[cfg(test)]
    pub(super) fn lease_tick(&self, job: &str) {
        if let Some(owner) = self.holder(job) {
            let _ = owner.send(hold::Op::LeaseTick);
        }
    }

    fn holder(&self, job: &str) -> Option<mpsc::Sender<hold::Op>> {
        let holds = self.holds.lock().unwrap_or_else(PoisonError::into_inner);
        holds.get(job).map(|(ops, _)| ops.clone())
    }

    /// Runs `write`, a copy's `fs.*` op that names the hold `job`, only while that hold runs:
    /// its owner cannot end it or let its lease run out until `write` returns, and once it
    /// has, `write` never runs (`seed.unknown_job`). A write renews the lease.
    pub fn under_hold<T>(&self, job: &str, write: impl FnOnce() -> T) -> Result<T, SeedRefusal> {
        let (owner, alive) = self
            .holds
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .get(job)
            .cloned()
            .ok_or_else(hold_ended)?;
        let running = alive.read().unwrap_or_else(PoisonError::into_inner);
        if !*running {
            return Err(hold_ended());
        }
        let wrote = write();
        drop(running);
        let _ = owner.send(hold::Op::Renew);
        Ok(wrote)
    }

    fn running_hold(
        &self,
        params: &Value,
    ) -> Result<(String, mpsc::Sender<hold::Op>), SeedRefusal> {
        let params: hold::JobParams = serde_json::from_value(params.clone())
            .map_err(|error| SeedRefusal::bad_request(format!("invalid params: {error}")))?;
        let owner = self.holder(&params.job).ok_or_else(hold_ended)?;
        Ok((params.job, owner))
    }
}

/// A hold op for a job that holds nothing: ended, expired, or never a hold.
fn hold_ended() -> SeedRefusal {
    SeedRefusal {
        code: "seed.unknown_job",
        message: "no running hold with that job on this machine (it ended or its lease ran out)"
            .into(),
    }
}

impl Status {
    fn running(phase: Phase) -> Self {
        Self {
            state: State::Running,
            phase,
            progress: Progress::default(),
            failed: None,
            notes: Vec::new(),
            head: None,
            exported: None,
            head_ready: false,
            began: Instant::now(),
            phase_began: Instant::now(),
            phase_times: Vec::new(),
            took: None,
            runs: Value::Null,
        }
    }
}

/// The job a retry of `key` in `folder` is (running, or done when `done_too`); a
/// refusal while another job runs in the folder.
fn same_job(
    jobs: &Jobs,
    folder: &std::path::Path,
    key: Option<&str>,
    done_too: bool,
) -> Result<Option<String>, SeedRefusal> {
    for job in jobs.by_id.values().filter(|job| job.folder == folder) {
        let state = job.status().state;
        let retried = state == State::Running || (done_too && state == State::Done);
        if key == Some(job.key.as_str()) && retried {
            return Ok(Some(job.id.clone()));
        }
        if state == State::Running && job.status().head_ready {
            return Err(filling("the folder's seed is still filling the checkout past its head"));
        }
        if state == State::Running {
            return Err(SeedRefusal::bad_request("another seed is running in this folder"));
        }
    }
    Ok(None)
}

fn filling(message: &str) -> SeedRefusal {
    SeedRefusal { code: "seed.filling", message: message.into() }
}

/// An export reads the working tree back to the Mac, so it waits for a whole checkout: a
/// head-first seed whose fill never finished (its daemon restarted) left most of the tree
/// out, and another producer may still be writing it (`cmux repo hold`). Either would send
/// the Mac a tree that lacks the person's files.
fn refuse_while_filling(folder: &std::path::Path) -> Result<(), SeedRefusal> {
    if run::fill_unfinished(folder) {
        return Err(filling("the folder's last seed never finished filling it; seed it again"));
    }
    use cmux_git::sync_barrier::{Probe, probe};
    match probe(folder) {
        Ok(Probe::HeadReady | Probe::Syncing) => {
            Err(filling("the folder's checkout is still being written"))
        }
        // A failed delta's barrier stays incomplete; its record still says what to export.
        Ok(Probe::Ready(_) | Probe::Incomplete) => Ok(()),
        Err(error) => Err(filling(&format!("cannot read the folder's sync state: {error}"))),
    }
}

/// Drops the oldest finished jobs past [`KEPT_FINISHED`].
fn prune(jobs: &mut Jobs) {
    let finished = |jobs: &Jobs, id: &String| {
        jobs.by_id.get(id).is_some_and(|job| job.status().state != State::Running)
    };
    while jobs.order.iter().filter(|id| finished(jobs, id)).count() > KEPT_FINISHED {
        let Some(at) = jobs.order.iter().position(|id| finished(jobs, id)) else { break };
        if let Some(id) = jobs.order.remove(at) {
            jobs.by_id.remove(&id);
        }
    }
}

fn new_id() -> String {
    let mut random = [0u8; 12];
    if getrandom::fill(&mut random).is_err() {
        // No randomness: the clock, which is still unique enough per daemon.
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.as_nanos());
        for (slot, byte) in random.iter_mut().zip(nanos.to_le_bytes()) {
            *slot = byte;
        }
    }
    let hex: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("seed_{hex}")
}

#[cfg(test)]
mod wait_tests {
    use super::*;

    fn job() -> Arc<Job> {
        Arc::new(Job::running("seed_t".into(), PathBuf::from("/t"), String::new(), Phase::Clone))
    }

    #[test]
    fn a_held_status_answers_when_the_job_ends() {
        let job = job();
        let worker = job.clone();
        let ender = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(100));
            worker.finish(Ok(()));
        });
        let began = Instant::now();
        assert!(job.wait_end(Duration::from_secs(5)));
        let took = began.elapsed();
        ender.join().unwrap();
        assert_eq!(job.answer()["state"], "done");
        assert!(took >= Duration::from_millis(90), "answered before the end: {took:?}");
        assert!(took < Duration::from_secs(3), "waited past the end: {took:?}");
    }

    #[test]
    fn a_held_status_answers_when_the_head_is_ready() {
        let job = job();
        let worker = job.clone();
        let marker = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(50));
            // Progress alone does not end the wait.
            worker.enter(Phase::Fetch);
            std::thread::sleep(Duration::from_millis(50));
            worker.reached_head();
        });
        let began = Instant::now();
        assert!(job.wait_end(Duration::from_secs(5)));
        marker.join().unwrap();
        assert!(began.elapsed() >= Duration::from_millis(90));
        assert_eq!(job.answer()["head_ready"], true);
        assert_eq!(job.answer()["state"], "running");
    }

    #[test]
    fn a_held_status_answers_at_its_limit_or_at_once_when_ended() {
        let job = job();
        let began = Instant::now();
        assert!(job.wait_end(Duration::from_millis(60)));
        assert!(began.elapsed() >= Duration::from_millis(55));
        job.finish(Err(Failed { code: "seed.t", error: "t".into(), install_url: None }));
        let began = Instant::now();
        assert!(!job.wait_end(Duration::from_secs(5)), "an ended job does not wait");
        assert!(began.elapsed() < Duration::from_millis(500));
    }
}
