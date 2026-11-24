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
pub const AUTO_CLOUD_KEY: &str = "cloud.autoCloud";

/// Whether the AutoCloud key is on in the settings file now. A missing or unreadable file is off.
pub fn enabled() -> bool {
    use crate::user_settings::{self, Settings};
    matches!(user_settings::read(), Settings::Parsed(doc)
        if key_on(&doc))
}

/// Whether a parsed settings document turns the key on (`true` only, never a truthy string).
pub fn key_on(doc: &Value) -> bool {
    crate::user_settings::value(doc, AUTO_CLOUD_KEY) == Some(Value::Bool(true))
}

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
}

/// What came back from a sub-agent on a fork.
#[derive(Debug, Clone, Default)]
pub struct Ran {
    /// Its report, as its last message said it.
    pub report: String,
    /// The fork's changes inside the checkout (`git diff --binary`), empty when it changed none.
    pub patch: Vec<u8>,
    /// Milliseconds from the fork call to the sub-agent's first output, when the runner saw it.
    pub first_output_ms: Option<u64>,
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

/// The fork backend this build has: none yet. cmux-cloud-api's `fork_machine` (cmux-platform
/// `POST /v1/machines/{id}/fork`) lands on its own lane; until this file is pointed at it every
/// placement falls back at the fork step, logged, and the sub-agent runs here as today.
pub struct NoForkBackend;

impl Machines for NoForkBackend {
    async fn fork(&self, _machine: &str, _client_key: &str) -> Result<String, String> {
        Err("no fork backend in this build (cmux-cloud-api fork_machine not wired yet)".into())
    }
    async fn delete(&self, _machine: &str) -> Result<(), String> {
        Ok(())
    }
}

impl SubRun for NoForkBackend {
    async fn run(&self, _fork: &str, _task: &Task) -> Result<Ran, String> {
        Err("no sub-agent runner for a fork in this build".into())
    }
}

/// `start_session`'s hook: with [`StartPlan::Fork`], try the placement; answers the outcome to
/// put on the reply, `None` when the plan is today's (the key off: nothing ran, nothing changes).
pub async fn on_start(plan: &StartPlan, prompt: &str, checkout: &Path) -> Option<Outcome> {
    let StartPlan::Fork { machine } = plan else { return None };
    let backend = Arc::new(NoForkBackend);
    Some(place(true, Some(machine), backend.clone(), backend.as_ref(), prompt, checkout).await)
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
    if !on {
        return Outcome::Off;
    }
    let outcome = place_on(machine, machines, runner, prompt, checkout).await;
    if let Outcome::Fallback { cause, detail, fork_deleted } = &outcome {
        tracing::warn!(?cause, %detail, ?fork_deleted, "sub_fork: fell back to the parent's machine");
    }
    outcome
}

async fn place_on<M: Machines, R: SubRun>(
    machine: Option<&str>,
    machines: Arc<M>,
    runner: &R,
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
    let client_key = format!("sub-fork-{}", uuid::Uuid::now_v7());
    let fork = match machines.fork(machine, &client_key).await {
        Ok(id) => ForkGuard::new(machines.clone(), id),
        Err(e) => return fallback(Cause::Fork, e, None),
    };
    let task = Task { prompt: prompt.to_owned(), checkout: checkout.to_owned(), base_tree };
    let ran = runner.run(fork.id(), &task).await;
    let fork_id = fork.id().to_owned();
    let ran = match ran {
        Ok(ran) => ran,
        Err(e) => {
            let deleted = fork.delete().await;
            return fallback(Cause::Run, e, Some(deleted));
        }
    };
    let applied = apply(checkout, &ran.patch);
    let deleted = fork.delete().await;
    match applied {
        Ok(files) => {
            tracing::info!(
                fork = %fork_id, files, first_output_ms = ?ran.first_output_ms,
                total_ms = started.elapsed().as_millis() as u64,
                "sub_fork: the sub-agent ran on a fork and its patch is applied"
            );
            Outcome::Applied {
                fork: fork_id,
                report: ran.report,
                files,
                first_output_ms: ran.first_output_ms,
                fork_deleted: deleted,
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
    let numstat = git(checkout, None, &["apply", "--numstat", "-"], Some(patch))?;
    Ok(numstat.split(|b| *b == b'\n').filter(|l| !l.is_empty()).count())
}

#[cfg(test)]
#[path = "sub_fork_tests.rs"]
mod tests;
