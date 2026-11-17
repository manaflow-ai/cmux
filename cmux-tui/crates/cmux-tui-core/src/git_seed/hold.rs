//! `git-seed-hold-v2`: the machine holds a folder's sync barrier for a copy this Mac streams
//! in itself (`cmux link sync push`: a folder with no GitHub remote, which no seed can clone),
//! so the chat may open at the copy's head while every tool waits for the whole folder
//! (cmuxterm-hq goals/cloud-no-network-wait.md, step 6).
//!
//! `git.seed.hold {folder, subpath?, key?, lease_ms?}` takes the barrier for a folder that is
//! absent or empty and answers a job at once. The copy then writes the root's files, the
//! harness folders and the subpath's folders and says `git.seed.hold.head {job}`: the machine
//! marks the head on the barrier when a start there would read all it needs and run nothing
//! (`cmux_git::harness_head::head_allowed`), and answers `head_ready`. The rest of the copy
//! follows, and `git.seed.hold.end {job, ok}` marks the barrier ready (`ok`) or leaves it
//! failed.
//!
//! The hold lives on a lease: each `git.seed.hold.*` op and each `git.seed.status` of the job
//! renews it, and a hold with no op for its lease is dropped as failed (`seed.hold_expired`), so
//! a copy whose Mac went away never leaves a partial folder that reads ready, and never keeps
//! the folder's tools waiting past the lease. A daemon restart drops the hold the same way.
//! `git.seed.status` reads the job as for a seed; while it holds, a seed or an export of the
//! folder is refused (`seed.filling` once at its head).

use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Duration;

use serde::Deserialize;
use serde_json::{Value, json};

use super::SeedRefusal;
use super::job::{Failed, Job};
use super::params::HeadFirst;
use cmux_git::sync_barrier::Sync as Barrier;

/// The lease a hold gets when the request names none, and its bounds.
const DEFAULT_LEASE: Duration = Duration::from_secs(60);
#[cfg(not(test))]
const MIN_LEASE: Duration = Duration::from_secs(5);
/// Tests wait out a lease, so theirs may be short.
#[cfg(test)]
const MIN_LEASE: Duration = Duration::from_millis(50);
const MAX_LEASE: Duration = Duration::from_secs(600);

#[derive(Deserialize)]
pub(super) struct HoldParams {
    pub folder: String,
    #[serde(default)]
    subpath: Option<String>,
    /// The copy's own name for this hold, unique to the copy: a retry whose answer was lost
    /// gets the same job while the hold runs.
    #[serde(default)]
    key: Option<String>,
    #[serde(default)]
    lease_ms: Option<u64>,
}

impl HoldParams {
    pub(super) fn parse(params: &Value) -> Result<Self, SeedRefusal> {
        let parsed: Self = serde_json::from_value(params.clone())
            .map_err(|error| SeedRefusal::bad_request(format!("invalid params: {error}")))?;
        if parsed.key.as_ref().is_some_and(|key| key.len() > 200) {
            return Err(SeedRefusal::bad_request("the hold's key is too long"));
        }
        Ok(parsed)
    }

    /// What makes a retry this hold ([`super::job`]'s same-job check); None with no key: a
    /// hold the copy gave no name of its own is never a retry.
    pub(super) fn retry_key(&self) -> Option<String> {
        let key = self.key.as_deref()?;
        Some(format!("hold\0{key}\0{}", self.subpath.as_deref().unwrap_or("")))
    }

    pub(super) fn lease(&self) -> Duration {
        self.lease_ms.map_or(DEFAULT_LEASE, Duration::from_millis).clamp(MIN_LEASE, MAX_LEASE)
    }

    /// The head's folders, or a refusal when the subpath cannot name one literally.
    pub(super) fn head(&self) -> Result<HeadFirst, SeedRefusal> {
        HeadFirst::of(self.subpath.as_deref())
            .ok_or_else(|| SeedRefusal::bad_request("the subpath is not a plain folder path"))
    }
}

#[derive(Deserialize)]
pub(super) struct JobParams {
    pub job: String,
    #[serde(default)]
    pub ok: Option<bool>,
}

/// Whether the hold still runs: a copy's write ([`super::GitSeedService::under_hold`]) reads it
/// for as long as it writes, and the owner thread sets it false before the barrier goes. So a
/// write lands while the hold runs, or not at all.
pub(super) type Alive = std::sync::Arc<std::sync::RwLock<bool>>;

/// What the hold's owner thread is asked.
pub(super) enum Op {
    /// Any op on the job: the lease starts again.
    Renew,
    Head(mpsc::Sender<bool>),
    End(bool, mpsc::Sender<Result<(), Failed>>),
}

/// Whether `folder` may take a hold: absent, an empty folder (the copy goes to a new folder of
/// its own; a hold never stands over files it did not write), or one whose last sync failed
/// (a copy that ended short or went quiet): no tool runs in such a folder until a sync
/// completes it, so the copy's retry holds it again and repairs it, where a plain copy would
/// leave it failed.
pub(super) fn fresh(folder: &Path) -> Result<(), SeedRefusal> {
    use cmux_git::sync_barrier::{Probe, probe};
    let failed = || matches!(probe(folder), Ok(Probe::Incomplete));
    if std::fs::read_dir(folder).is_ok_and(|mut entries| entries.next().is_some()) && !failed() {
        return Err(SeedRefusal {
            code: "seed.folder_not_empty",
            message: "the folder exists and is not empty".into(),
        });
    }
    Ok(())
}

/// Runs the hold on a thread of its own: it owns the barrier until the copy ends it or the lease
/// runs out. Returns the thread's channel.
pub(super) fn spawn(
    job: std::sync::Arc<Job>,
    folder: PathBuf,
    head: HeadFirst,
    lease: Duration,
    barrier: Barrier,
    alive: Alive,
    done: impl FnOnce() + Send + 'static,
) -> Result<mpsc::Sender<Op>, SeedRefusal> {
    let (send, ops) = mpsc::channel();
    std::thread::Builder::new()
        .name("cmux-git-seed-hold".into())
        .spawn(move || {
            own(&job, &folder, &head, lease, barrier, &alive, &ops);
            done();
        })
        .map_err(|error| SeedRefusal::bad_request(format!("cannot start the hold: {error}")))?;
    Ok(send)
}

/// Owns the barrier until the copy ends the hold or its lease runs out, and finishes the job
/// before it answers the end, so the answer reads the job's last state.
fn own(
    job: &Job,
    folder: &Path,
    head: &HeadFirst,
    lease: Duration,
    mut barrier: Barrier,
    alive: &Alive,
    ops: &mpsc::Receiver<Op>,
) {
    // Waits out a write in flight; none lands after.
    let stop_writes = || *alive.write().unwrap_or_else(std::sync::PoisonError::into_inner) = false;
    loop {
        match ops.recv_timeout(lease) {
            Ok(Op::Renew) => {}
            Ok(Op::Head(reply)) => {
                let folders = head.folders();
                let folders: Vec<&Path> = folders.iter().map(Path::new).collect();
                // A head is marked only once its folders are there: a start in a folder the
                // copy has not made yet would read nothing.
                let there = std::iter::once(folder.to_path_buf())
                    .chain(folders.iter().map(|sub| folder.join(sub)))
                    .all(|dir| dir.is_dir());
                let marked = job.status_head_ready()
                    || (there && cmux_git::harness_head::head_allowed(folder, &folders));
                if marked && !job.status_head_ready() {
                    barrier.head_ready();
                    job.reached_head();
                }
                let _ = reply.send(marked);
            }
            Ok(Op::End(ok, reply)) => {
                stop_writes();
                let result = if ok {
                    barrier
                        .complete()
                        .map_err(|error| failed(format!("cannot finish the sync: {error}")))
                } else {
                    // Dropping the barrier unfinished leaves it failed, released before the job
                    // reads failed.
                    drop(barrier);
                    Err(failed("the copy ended without every file".into()))
                };
                job.finish(result.clone());
                let _ = reply.send(result);
                return;
            }
            Err(mpsc::RecvTimeoutError::Timeout | mpsc::RecvTimeoutError::Disconnected) => {
                stop_writes();
                // Released first: a retry that reads the job failed may begin the folder again.
                drop(barrier);
                job.finish(Err(Failed {
                    code: "seed.hold_expired",
                    error: format!(
                        "the copy sent nothing for {} s; its folder is left incomplete",
                        lease.as_secs()
                    ),
                    install_url: None,
                }));
                return;
            }
        }
    }
}

fn failed(error: String) -> Failed {
    Failed { code: "seed.copy_failed", error, install_url: None }
}

/// The answer to `git.seed.hold.head`.
pub(super) fn head_answer(job: &str, marked: bool) -> Value {
    json!({ "job": job, "head_ready": marked })
}
