//! Seed jobs: `git.seed.start` answers at once and the seed runs on a thread
//! of its own; `git.seed.status` reads it. A start with the same folder,
//! bundle and WORK commit as a running or finished job returns that job, so a
//! client that lost the answer retries safely. `git.seed.export` runs as a
//! job the same way ([`super::export`]); one folder has one running job.

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError};

use serde::Deserialize;
use serde_json::{Value, json};

use super::export::{Export, ExportParams};
use super::git::{Credential, Git, Progress};
use super::params::StartParams;
use super::{SeedRefusal, place, run};
use crate::fs_ops::Roots;

/// Finished jobs kept for `git.seed.status`.
const KEPT_FINISHED: usize = 64;

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
}

/// One seed.
pub struct Job {
    id: String,
    folder: PathBuf,
    /// With `folder`, what makes a retry this job ([`StartParams::retry_key`]).
    key: String,
    status: Mutex<Status>,
}

impl Job {
    pub(super) fn id(&self) -> &str {
        &self.id
    }

    fn status(&self) -> Status {
        self.status.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn update(&self, change: impl FnOnce(&mut Status)) {
        change(&mut self.status.lock().unwrap_or_else(PoisonError::into_inner));
    }

    pub(super) fn enter(&self, phase: Phase) {
        self.update(|status| status.phase = phase);
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

    pub(super) fn note(&self, note: &'static str) {
        self.update(|status| status.notes.push(note));
    }

    fn finish(&self, result: Result<(), Failed>) {
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
        });
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
}

#[derive(Deserialize)]
struct StatusParams {
    job: String,
}

impl GitSeedService {
    #[must_use]
    pub fn new(roots: Roots) -> Self {
        Self::with_config(roots, Config::default())
    }

    pub(crate) fn with_config(roots: Roots, config: Config) -> Self {
        Self { roots, config, jobs: Mutex::new(Jobs::default()) }
    }

    /// Runs `cmd` with the request object `params`.
    pub fn call(&self, cmd: &str, params: &Value) -> Result<Value, SeedRefusal> {
        match cmd {
            "git.seed.start" => self.start(params),
            "git.seed.export" => self.export(params),
            "git.seed.status" => {
                let params: StatusParams =
                    serde_json::from_value(params.clone()).map_err(|error| {
                        SeedRefusal::bad_request(format!("invalid params: {error}"))
                    })?;
                let job = self.jobs().by_id.get(&params.job).cloned();
                let job = job.ok_or_else(|| SeedRefusal {
                    code: "seed.unknown_job",
                    message: "no such seed job on this machine (the daemon may have restarted)"
                        .into(),
                })?;
                Ok(job.answer())
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
        if let Some(id) = same_job(&jobs, &folder, &params.retry_key())? {
            return Ok(json!({ "job": id }));
        }
        let mut others = jobs.by_id.values().map(|job| job.folder.as_path());
        place::not_nested(&self.roots, &folder, &mut others)?;
        let id = new_id();
        let bundle = match params.clone_only {
            Some(_) => None,
            None => Some(place::bundle(&self.roots, &params.bundle, &id)?),
        };
        let job = Arc::new(Job {
            id,
            folder: folder.clone(),
            key: params.retry_key(),
            status: Mutex::new(Status::running(Phase::Clone)),
        });
        let credentials =
            self.config.credentials.clone().unwrap_or_else(super::git::machine_credentials);
        let seed = run::Seed::new(
            job.clone(),
            params,
            folder,
            bundle,
            self.roots.clone(),
            self.config.git.clone(),
            credentials,
        );
        let worker = job.clone();
        std::thread::Builder::new()
            .name("cmux-git-seed".into())
            .spawn(move || worker.finish(seed.run()))
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
        if let Some(id) = same_job(&jobs, &folder, &params.retry_key())? {
            return Ok(json!({ "job": id }));
        }
        place::output(&self.roots, &params.bundle, &folder)?;
        let id = new_id();
        let job = Arc::new(Job {
            id,
            folder: folder.clone(),
            key: params.retry_key(),
            status: Mutex::new(Status::running(Phase::Export)),
        });
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
        }
    }
}

/// The job a retry of `key` in `folder` is (running or done); a refusal
/// while another job runs in the folder.
fn same_job(
    jobs: &Jobs,
    folder: &std::path::Path,
    key: &str,
) -> Result<Option<String>, SeedRefusal> {
    for job in jobs.by_id.values().filter(|job| job.folder == folder) {
        let state = job.status().state;
        if job.key == key && state != State::Failed {
            return Ok(Some(job.id.clone()));
        }
        if state == State::Running {
            return Err(SeedRefusal::bad_request("another seed is running in this folder"));
        }
    }
    Ok(None)
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
