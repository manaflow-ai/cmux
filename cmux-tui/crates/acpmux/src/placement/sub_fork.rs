//! Sub VMs (RFD 0144, "Sub-agents", piece 7): a working sub-agent of a Cloud session runs on a fork
//! of the parent's machine (the same repo state, dependencies and caches at that instant), and what
//! it changed comes back as a patch applied to the parent's checkout. The fork is deleted when the
//! sub-agent ends, whether it succeeded, failed or was cancelled. Nobody picks a machine.
//!
//! Off unless the hidden AutoCloud key is on (`cloud.autoCloud: true` in the settings file); with
//! it off nothing here runs and a sub-agent starts as it does today. With it on, any failure to
//! fork, run or apply the patch back falls back to today's behaviour (the sub-agent runs on the
//! parent's machine) and the cause is logged.
//!
//! The order of one placement ([`place`]):
//! 1. snapshot the parent's checkout as a git tree ([`snapshot`]), so the patch is relative to the
//!    files the fork starts from, uncommitted edits included;
//! 2. fork the parent's machine ([`Machines::fork`]); a [`ForkGuard`] owns the fork from here and
//!    deletes it on every exit, a dropped (cancelled) future included;
//! 3. run the sub-agent on the fork ([`SubRun::run`]); it returns its report and the fork's
//!    changes as a binary patch against the snapshot ([`capture`] run there);
//! 4. apply the patch to the parent's checkout ([`apply`]); a patch that does not apply leaves the
//!    checkout untouched;
//! 5. delete the fork.
//!
//! The fork call is cmux-cloud-api's `fork_machine` (cmux-platform `POST /v1/machines/{id}/fork`);
//! this file only names it through [`Machines`], so the tests run against a fake.

use serde::Serialize;
use serde_json::Value;
use std::future::Future;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

/// The settings key that turns sub VMs on (AutoCloud's hidden key, default off).
pub use super::{AUTO_CLOUD_KEY, auto_cloud_in as key_on, auto_cloud_on as enabled};

/// The machine calls a placement needs: fork the parent's machine, and delete the fork.
pub trait Machines: Send + Sync + 'static {
    /// Fork `machine` (copy-on-write disk). `client_key` makes a retried call return the same
    /// fork. Answers the fork's machine id.
    fn fork(
        &self,
        machine: &str,
        client_key: &str,
    ) -> impl Future<Output = Result<String, String>> + Send;
    /// Delete a fork this placement made. Deleting one that is already gone is not an error.
    fn delete(&self, machine: &str) -> impl Future<Output = Result<(), String>> + Send;
}

/// Runs the sub-agent on a fork and brings its result back.
pub trait SubRun: Send + Sync {
    /// Run `task` on `fork` to its end; the answer carries the sub-agent's report and the fork's
    /// changes as a binary patch against `task.base_tree`.
    fn run(&self, fork: &str, task: &Task) -> impl Future<Output = Result<Ran, String>> + Send;
}

/// What a sub-agent on a fork is asked to do.
#[derive(Debug, Clone)]
pub struct Task {
    /// The sub-agent's first message.
    pub prompt: String,
    /// The checkout on the parent's machine, and so on the fork (the same path).
    pub checkout: PathBuf,
    /// The snapshot tree the fork starts from ([`snapshot`]).
    pub base_tree: String,
    /// The sub-agent's model or harness, as `start_session` was given it.
    pub model: Option<String>,
    /// For a warm fork (taken earlier, at another snapshot): the patch that brings its files to
    /// `base_tree` ([`capture`] against its own snapshot); empty for a fork taken for this task.
    pub sync_patch: Vec<u8>,
}

/// What came back from a sub-agent on a fork.
#[derive(Debug, Clone, Default)]
pub struct Ran {
    /// Its report, as its last message said it.
    pub report: String,
    /// The fork's changes inside the checkout (`git diff --binary`), empty when it changed none.
    pub patch: Vec<u8>,
    /// Milliseconds from the run's start (the fork ready, its wake call included) to the
    /// sub-agent's first output, when the runner saw it.
    pub first_output_ms: Option<u64>,
    /// Milliseconds from the fork's last frame to its patch in hand, when the runner timed it.
    pub files_back_ms: Option<u64>,
}

/// The step a fallback came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Cause {
    /// The parent is not a Cloud machine, or its machine id is unknown.
    NotCloud,
    /// The checkout could not be snapshotted (not a git checkout, git failed).
    Snapshot,
    /// The fork call failed or the pool had no room.
    Fork,
    /// The sub-agent failed, or its result could not be read, on the fork.
    Run,
    /// Its patch did not apply to the parent's checkout.
    Apply,
}

/// How one placement ended.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "outcome", rename_all = "camelCase")]
pub enum Outcome {
    /// The key is off: nothing was placed, the sub-agent starts as today.
    Off,
    /// Placed on a fork, and its patch is applied to the parent's checkout.
    #[serde(rename_all = "camelCase")]
    Applied {
        fork: String,
        report: String,
        /// Files the patch touched.
        files: usize,
        first_output_ms: Option<u64>,
        /// Whether the fork's delete call succeeded (a failed delete is logged, never fatal).
        fork_deleted: bool,
        /// The fork call's time, for a warm fork the time it took when it was made.
        fork_ms: u64,
        /// Whether the fork was a warm one, made ahead of this sub-agent.
        warm: bool,
        /// The patch's way back and its apply to the parent's checkout.
        files_back_ms: u64,
    },
    /// Something failed: the sub-agent runs on the parent's machine, as today.
    #[serde(rename_all = "camelCase")]
    Fallback { cause: Cause, detail: String, fork_deleted: Option<bool> },
}

impl Outcome {
    /// Whether the caller still has to start the sub-agent on the parent's machine.
    pub fn runs_here(&self) -> bool {
        !matches!(self, Outcome::Applied { .. })
    }
}

/// How a `start_session` sub-agent starts, read before anything starts: on a fork only when the
/// AutoCloud key is on, this daemon runs on a Cloud machine with an id, and the sub-agent works
/// (it asked for a worktree: it edits files or runs commands). A read-only one, or any start with
/// the key off, starts as today.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StartPlan {
    /// Today's start on this machine; nothing of this module runs.
    Today,
    /// Place it on a fork of `machine`.
    Fork { machine: String },
}

pub fn start_plan(on: bool, working: bool, machine: Option<&str>) -> StartPlan {
    match machine.map(str::trim).filter(|m| !m.is_empty()) {
        Some(machine) if on && working => StartPlan::Fork { machine: machine.to_owned() },
        _ => StartPlan::Today,
    }
}

/// This daemon's Cloud machine id (`CMUX_VM_ID`, the Cloud image sets it), when it runs on one.
pub fn this_machine() -> Option<String> {
    if !crate::cloud_host::is_cloud_vm() {
        return None;
    }
    std::env::var("CMUX_VM_ID").ok().filter(|id| !id.trim().is_empty())
}

/// The Cloud backend: forks through cmux-cloud-api's `machine.fork` op (`fork_machine`,
/// cmux-platform `POST /v1/machines/{id}/fork`) and deletes through its `destroy_machine`
/// (`DELETE /v1/machines/{id}`), with the Cloud API, credential and team this daemon was given
/// (`CMUX_CLOUD_API_URL`, `CMUX_CLOUD_ACCESS_TOKEN`, `CMUX_CLOUD_TEAM`, as `acpmux fork-run`
/// reads them). A build whose cmux-cloud-api has no `machine.fork` yet refuses at the fork, and
/// the placement falls back with that refusal as its cause.
pub struct CloudMachines {
    pub(crate) request: cmux_cloud_api::Request,
}

/// The variables [`CloudMachines::from_env`] reads.
pub const API_ENV: &str = "CMUX_CLOUD_API_URL";
pub const TOKEN_ENV: &str = "CMUX_CLOUD_ACCESS_TOKEN";
pub const TEAM_ENV: &str = "CMUX_CLOUD_TEAM";

impl CloudMachines {
    /// The backend from `env` (a lookup, `std::env::var` in the daemon), or which value is missing.
    pub fn from_env(env: impl Fn(&str) -> Option<String>) -> Result<Self, String> {
        let set = |k: &str| env(k).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
        let api = set(API_ENV).ok_or_else(|| format!("{API_ENV} is not set"))?;
        let credential = set(TOKEN_ENV).ok_or_else(|| format!("{TOKEN_ENV} is not set"))?;
        Ok(Self {
            request: cmux_cloud_api::Request {
                call: String::new(),
                api,
                auth: cmux_cloud_api::Auth::Owner,
                credential,
                refresh: None,
                team: set(TEAM_ENV),
                app_version: None,
                local_only: false,
                args: serde_json::Map::new(),
            },
        })
    }

    fn failure(failure: &cmux_cloud_api::Failure, request: &cmux_cloud_api::Request) -> String {
        cmux_cloud_api::scrub(cmux_cloud_api::answer_line(&Err(failure.clone())), request)
    }
}

impl Machines for CloudMachines {
    async fn fork(&self, machine: &str, client_key: &str) -> Result<String, String> {
        let mut request = self.request.clone();
        request.call = "machine.fork".into();
        request.args = serde_json::json!({"machine": machine, "clientKey": client_key, "visibility": "private"})
            .as_object()
            .cloned()
            .unwrap_or_default();
        let answer = cmux_cloud_api::perform(&request, zeroize::Zeroizing::new(Vec::new()))
            .await
            .map_err(|f| Self::failure(&f, &request))?;
        answer
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| "machine.fork answered no machine id".to_owned())
    }

    async fn delete(&self, machine: &str) -> Result<(), String> {
        cmux_cloud_api::machine_destroy::destroy_machine(&self.request, machine)
            .await
            .map(|_| ())
            .map_err(|f| Self::failure(&f, &self.request))
    }
}

/// Runs the sub-agent on a fork. Not in this slice: a fork's daemon is reached through the
/// machine's exec route once the fork backend is live on staging; until then the run step
/// refuses, the fork is deleted, and the sub-agent runs here.
pub struct NoForkRunner;

impl SubRun for NoForkRunner {
    async fn run(&self, _fork: &str, _task: &Task) -> Result<Ran, String> {
        Err("no sub-agent runner for a fork in this build".into())
    }
}

/// `start_session`'s hook: with [`StartPlan::Fork`], try the placement; answers the outcome to
/// put on the reply, `None` when the plan is today's (the key off: nothing ran, nothing changes).
pub async fn on_start(
    plan: &StartPlan,
    prompt: &str,
    model: Option<&str>,
    checkout: &Path,
) -> Option<Outcome> {
    let StartPlan::Fork { machine } = plan else { return None };
    let machines = match CloudMachines::from_env(|k| std::env::var(k).ok()) {
        Ok(m) => Arc::new(m),
        Err(detail) => {
            let out = Outcome::Fallback { cause: Cause::Fork, detail, fork_deleted: None };
            tracing::warn!(?out, "sub_fork: fell back to the parent's machine");
            return Some(out);
        }
    };
    let runner = super::sub_fork_run::ForkRunner::new(super::sub_fork_run::CloudLink::new(
        machines.request.clone(),
    ));
    let warm = CLOUD_WARM.get_or_init(|| Arc::new(WarmSlot::default())).clone();
    let opts = Placing { budget: FORK_BUDGET, warm, model: model.map(str::to_owned) };
    Some(place_with(true, Some(machine), machines, &runner, &opts, prompt, checkout).await)
}

/// The longest a placement waits for a new fork before the sub-agent starts here instead:
/// RFD 0144's fork-to-first-command gate. Staging's fork call is p50 37 s (cmux#54532, run
/// 45439689156, n=5), so a new fork almost never makes it; it is kept warm for the next one.
pub const FORK_BUDGET: std::time::Duration = std::time::Duration::from_secs(2);
/// How long a warm fork waits for a sub-agent before it is deleted.
pub const WARM_TTL: std::time::Duration = std::time::Duration::from_secs(600);

/// The one warm fork of this daemon's Cloud backend.
static CLOUD_WARM: std::sync::OnceLock<Arc<WarmSlot<CloudMachines>>> = std::sync::OnceLock::new();

/// A fork made ahead of need: of `source`, at the snapshot `base_tree`.
#[derive(Debug, Clone)]
pub struct WarmFork {
    pub id: String,
    pub source: String,
    pub base_tree: String,
    pub fork_ms: u64,
    pub at: Instant,
}

/// At most one warm fork; a newer one replaces (and deletes) the older, and one unused for
/// [`WARM_TTL`] is deleted.
pub struct WarmSlot<M: Machines> {
    held: std::sync::Mutex<Option<WarmFork>>,
    ttl: std::time::Duration,
    _m: std::marker::PhantomData<fn() -> M>,
}

impl<M: Machines> Default for WarmSlot<M> {
    fn default() -> Self {
        Self::with_ttl(WARM_TTL)
    }
}

impl<M: Machines> WarmSlot<M> {
    pub fn with_ttl(ttl: std::time::Duration) -> Self {
        Self { held: std::sync::Mutex::new(None), ttl, _m: std::marker::PhantomData }
    }

    /// The warm fork of `source`, if one is ready and fresh; it is the caller's from here.
    pub fn take(&self, source: &str) -> Option<WarmFork> {
        let mut held = self.held.lock().ok()?;
        match held.as_ref() {
            Some(w) if w.source == source && w.at.elapsed() < self.ttl => held.take(),
            _ => None,
        }
    }

    pub fn peek(&self) -> Option<WarmFork> {
        self.held.lock().ok()?.clone()
    }

    /// Keep `fork` warm; an older one is deleted, and this one is deleted after the TTL unless a
    /// placement took it.
    pub fn park(self: &Arc<Self>, machines: Arc<M>, fork: WarmFork) {
        let old = self.held.lock().ok().and_then(|mut h| h.replace(fork.clone()));
        let Ok(rt) = tokio::runtime::Handle::try_current() else { return };
        if let Some(old) = old {
            let m = machines.clone();
            rt.spawn(async move {
                let _ = m.delete(&old.id).await;
            });
        }
        let slot = self.clone();
        rt.spawn(async move {
            tokio::time::sleep(slot.ttl).await;
            let expired = slot
                .held
                .lock()
                .ok()
                .and_then(|mut h| if h.as_ref().is_some_and(|w| w.id == fork.id) { h.take() } else { None });
            if let Some(w) = expired {
                tracing::info!(fork = %w.id, "sub_fork: an unused warm fork expired; deleting it");
                if let Err(e) = machines.delete(&w.id).await {
                    tracing::warn!(fork = %w.id, error = %e, "sub_fork: deleting an expired warm fork failed");
                }
            }
        });
    }
}

/// How a placement gets its fork: wait at most `budget` for a new one, else keep it warm in
/// `warm` for the next sub-agent.
pub struct Placing<M: Machines> {
    pub budget: std::time::Duration,
    pub warm: Arc<WarmSlot<M>>,
    pub model: Option<String>,
}

/// Owns a fork from the moment it exists: [`ForkGuard::delete`] deletes it, and a guard dropped
/// without it (the placement's future cancelled, a panic) deletes it on the runtime in the
/// background, so no exit leaves one running.
pub struct ForkGuard<M: Machines> {
    machines: Arc<M>,
    id: Option<String>,
}

impl<M: Machines> ForkGuard<M> {
    pub fn new(machines: Arc<M>, id: String) -> Self {
        Self { machines, id: Some(id) }
    }

    pub fn id(&self) -> &str {
        self.id.as_deref().unwrap_or_default()
    }

    /// Delete the fork now and say whether the call succeeded.
    pub async fn delete(mut self) -> bool {
        let Some(id) = self.id.take() else { return true };
        match self.machines.delete(&id).await {
            Ok(()) => true,
            Err(e) => {
                tracing::warn!(fork = %id, error = %e, "sub_fork: deleting the fork failed");
                false
            }
        }
    }
}

impl<M: Machines> Drop for ForkGuard<M> {
    fn drop(&mut self) {
        let Some(id) = self.id.take() else { return };
        let machines = self.machines.clone();
        match tokio::runtime::Handle::try_current() {
            Ok(rt) => {
                rt.spawn(async move {
                    if let Err(e) = machines.delete(&id).await {
                        tracing::warn!(fork = %id, error = %e, "sub_fork: deleting a cancelled fork failed");
                    }
                });
            }
            Err(_) => tracing::warn!(fork = %id, "sub_fork: no runtime to delete a cancelled fork"),
        }
    }
}

/// One placement, as the module comment orders it. `on` is the AutoCloud key; `machine` the
/// parent's Cloud machine id (`None` off Cloud). Every non-`Applied` answer is logged with its
/// cause here, and the fork is deleted before this returns (or by its guard when cancelled).
pub async fn place<M: Machines, R: SubRun>(
    on: bool,
    machine: Option<&str>,
    machines: Arc<M>,
    runner: &R,
    prompt: &str,
    checkout: &Path,
) -> Outcome {
    let opts = Placing { budget: FORK_BUDGET, warm: Arc::new(WarmSlot::default()), model: None };
    place_with(on, machine, machines, runner, &opts, prompt, checkout).await
}

/// [`place`] with its fork budget, warm slot and model.
pub async fn place_with<M: Machines, R: SubRun>(
    on: bool,
    machine: Option<&str>,
    machines: Arc<M>,
    runner: &R,
    opts: &Placing<M>,
    prompt: &str,
    checkout: &Path,
) -> Outcome {
    if !on {
        return Outcome::Off;
    }
    let outcome = place_on(machine, machines, runner, opts, prompt, checkout).await;
    if let Outcome::Fallback { cause, detail, fork_deleted } = &outcome {
        tracing::warn!(?cause, %detail, ?fork_deleted, "sub_fork: fell back to the parent's machine");
    }
    outcome
}

async fn place_on<M: Machines, R: SubRun>(
    machine: Option<&str>,
    machines: Arc<M>,
    runner: &R,
    opts: &Placing<M>,
    prompt: &str,
    checkout: &Path,
) -> Outcome {
    let fallback =
        |cause, detail: String, fork_deleted| Outcome::Fallback { cause, detail, fork_deleted };
    let Some(machine) = machine.filter(|m| !m.trim().is_empty()) else {
        return fallback(Cause::NotCloud, "the parent has no Cloud machine id".into(), None);
    };
    let base_tree = match snapshot(checkout) {
        Ok(tree) => tree,
        Err(e) => return fallback(Cause::Snapshot, e, None),
    };
    let started = Instant::now();
    let (fork, fork_ms, warm, sync_patch) = match opts.warm.take(machine) {
        Some(w) => {
            let guard = ForkGuard::new(machines.clone(), w.id.clone());
            // The warm fork holds the files of its own snapshot: bring them to now.
            match capture(checkout, &w.base_tree) {
                Ok(sync) => (guard, w.fork_ms, true, sync),
                Err(e) => {
                    let deleted = guard.delete().await;
                    return fallback(
                        Cause::Snapshot,
                        format!("syncing the warm fork: {e}"),
                        Some(deleted),
                    );
                }
            }
        }
        None => {
            let client_key = format!("sub-fork-{}", uuid::Uuid::now_v7());
            let forking = {
                let machines = machines.clone();
                let machine = machine.to_owned();
                async move { machines.fork(&machine, &client_key).await }
            };
            let mut forking = Box::pin(forking);
            match tokio::time::timeout(opts.budget, &mut forking).await {
                Ok(Ok(id)) => (
                    ForkGuard::new(machines.clone(), id),
                    started.elapsed().as_millis() as u64,
                    false,
                    Vec::new(),
                ),
                Ok(Err(e)) => return fallback(Cause::Fork, e, None),
                Err(_) => {
                    // Never block the turn on the fork: this sub-agent starts here, and the fork,
                    // when it is ready, waits warm for the next one.
                    let budget_ms = opts.budget.as_millis() as u64;
                    let slot = opts.warm.clone();
                    let source = machine.to_owned();
                    let tree = base_tree.clone();
                    let m = machines.clone();
                    tokio::spawn(async move {
                        match forking.await {
                            Ok(id) => {
                                let fork_ms = started.elapsed().as_millis() as u64;
                                tracing::info!(fork = %id, fork_ms, "sub_fork: a fork past the budget is warm for the next sub-agent");
                                let w = WarmFork {
                                    id,
                                    source,
                                    base_tree: tree,
                                    fork_ms,
                                    at: Instant::now(),
                                };
                                slot.park(m, w);
                            }
                            Err(e) => tracing::warn!(error = %e, "sub_fork: the warm fork failed"),
                        }
                    });
                    return fallback(
                        Cause::Fork,
                        format!(
                            "no fork ready in {budget_ms} ms; one is being made warm for the next sub-agent"
                        ),
                        None,
                    );
                }
            }
        }
    };
    let task = Task {
        prompt: prompt.to_owned(),
        checkout: checkout.to_owned(),
        base_tree,
        model: opts.model.clone(),
        sync_patch,
    };
    let ran = runner.run(fork.id(), &task).await;
    let fork_id = fork.id().to_owned();
    let ran = match ran {
        Ok(ran) => ran,
        Err(e) => {
            let deleted = fork.delete().await;
            return fallback(Cause::Run, e, Some(deleted));
        }
    };
    let applying = Instant::now();
    let applied = apply(checkout, &ran.patch);
    let files_back_ms = ran.files_back_ms.unwrap_or(0) + applying.elapsed().as_millis() as u64;
    let deleted = fork.delete().await;
    match applied {
        Ok(files) => {
            tracing::info!(
                fork = %fork_id, files, fork_ms, warm, files_back_ms,
                first_output_ms = ?ran.first_output_ms,
                total_ms = started.elapsed().as_millis() as u64,
                "sub_fork: the sub-agent ran on a fork and its patch is applied"
            );
            Outcome::Applied {
                fork: fork_id,
                report: ran.report,
                files,
                first_output_ms: ran.first_output_ms,
                fork_deleted: deleted,
                fork_ms,
                warm,
                files_back_ms,
            }
        }
        Err(e) => fallback(Cause::Apply, e, Some(deleted)),
    }
}

fn git(
    dir: &Path,
    index: Option<&Path>,
    args: &[&str],
    stdin: Option<&[u8]>,
) -> Result<Vec<u8>, String> {
    let mut cmd = cmux_process::Command::new("git");
    cmd.arg("-C").arg(dir).args(args);
    // A user's or CI's settings must not change the bytes a patch carries.
    cmd.env("GIT_CONFIG_NOSYSTEM", "1").env_remove("GIT_DIR").env_remove("GIT_WORK_TREE");
    match index {
        Some(index) => cmd.env("GIT_INDEX_FILE", index),
        None => cmd.env_remove("GIT_INDEX_FILE"),
    };
    // Bytes for stdin go through a file: no pipe to feed while git runs.
    let _stdin_file = match stdin {
        Some(bytes) => {
            let mut file = tempfile::NamedTempFile::new().map_err(|e| format!("git stdin: {e}"))?;
            std::io::Write::write_all(&mut file, bytes).map_err(|e| format!("git stdin: {e}"))?;
            cmd.open_stdin_path(file.path());
            Some(file)
        }
        None => {
            cmd.stdin(cmux_process::Stdio::null());
            None
        }
    };
    let out = cmd.output().map_err(|e| format!("git {}: {e}", args.join(" ")))?;
    if !out.status.success() {
        return Err(format!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(out.stdout)
}

/// A private index file for one snapshot or capture, so the checkout's own index (what the agent
/// staged) is never touched. Seeded from HEAD's tree, or empty on an unborn branch.
fn scratch_index(checkout: &Path, base: Option<&str>) -> Result<tempfile::TempPath, String> {
    let dir = git(checkout, None, &["rev-parse", "--absolute-git-dir"], None)?;
    let dir = PathBuf::from(String::from_utf8_lossy(&dir).trim());
    let file = tempfile::Builder::new()
        .prefix("sub-fork-index-")
        .tempfile_in(&dir)
        .map_err(|e| format!("scratch index: {e}"))?
        .into_temp_path();
    // git refuses an empty file as an index; it creates one where none exists.
    std::fs::remove_file(&file).map_err(|e| format!("scratch index: {e}"))?;
    match base {
        Some(tree) => {
            git(checkout, Some(&file), &["read-tree", tree], None)?;
        }
        None => {
            if git(checkout, None, &["rev-parse", "--verify", "-q", "HEAD^{tree}"], None).is_ok() {
                git(checkout, Some(&file), &["read-tree", "HEAD"], None)?;
            }
        }
    }
    Ok(file)
}

/// The checkout's files as they are now (tracked, modified and untracked, `.gitignore`d left out),
/// written as a git tree in the checkout's object store; answers its id. A fork taken after this
/// has the tree in its copy of the store, so its patch can name it as the base.
pub fn snapshot(checkout: &Path) -> Result<String, String> {
    let index = scratch_index(checkout, None)?;
    git(checkout, Some(&index), &["add", "-A", "--", "."], None)?;
    let tree = git(checkout, Some(&index), &["write-tree"], None)?;
    Ok(String::from_utf8_lossy(&tree).trim().to_owned())
}

/// The checkout's changes since `base_tree` ([`snapshot`]) as a binary patch with renames found
/// and modes kept: what a runner sends back from the fork. Empty when nothing changed.
pub fn capture(checkout: &Path, base_tree: &str) -> Result<Vec<u8>, String> {
    let index = scratch_index(checkout, Some(base_tree))?;
    git(checkout, Some(&index), &["add", "-A", "--", "."], None)?;
    git(
        checkout,
        Some(&index),
        &[
            "diff",
            "--cached",
            "--binary",
            "--full-index",
            "-M",
            "--no-color",
            "--no-ext-diff",
            base_tree,
        ],
        None,
    )
}

/// Apply a [`capture`]d patch to the parent's checkout: the files only, never its index. Checked
/// first, so a patch that does not apply whole changes nothing. Answers how many files it touched.
pub fn apply(checkout: &Path, patch: &[u8]) -> Result<usize, String> {
    if patch.is_empty() {
        return Ok(0);
    }
    git(checkout, None, &["apply", "--check", "--binary", "-"], Some(patch))?;
    git(checkout, None, &["apply", "--binary", "-"], Some(patch))?;
    // One `diff --git` header per file the patch touched (the patch is git's own output).
    Ok(patch.split(|b| *b == b'\n').filter(|l| l.starts_with(b"diff --git ")).count())
}

#[cfg(test)]
#[path = "sub_fork_tests.rs"]
pub(crate) mod tests;
