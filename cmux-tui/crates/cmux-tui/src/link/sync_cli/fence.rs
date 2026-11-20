//! The fence of a held copy (`seed_cli::held`): while one is up, no write of this process
//! reaches the machine unless the machine said the hold runs within half its lease.
//!
//! The hold lives on a lease, and the machine lets a later push hold a folder whose hold ran
//! out. A copy that stopped past its lease (a Mac asleep, a process suspended) must not go on
//! writing over that later push once it wakes: the first write after it reads the hold's job
//! again, on both clocks (one stops while a Mac sleeps), and a job that no longer runs ends
//! the copy with `seed.hold_expired`. What the fence cannot stop is a stop between its read
//! and the write it let through.

use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};

use super::remote::FsRefusal;

/// The requests that change the machine's folder, each sent naming the hold.
const WRITES: [&str; 5] = ["fs.write", "fs.mkdir", "fs.rename", "fs.delete", "fs.symlink"];

/// A store fetch names no hold the machine checks when it writes: a held copy starts none
/// ([`super::store::usable`]), and one asked for under the fence is refused.
const UNHELD_WRITES: [&str; 1] = ["blob.fetch.start"];

static FENCE: Mutex<Option<Held>> = Mutex::new(None);

/// The fence, up until dropped.
pub(in crate::link) struct Raised(());

/// Raises the fence of `job` on `socket`; `heard` is when the machine last said it runs
/// (None: the first write reads it).
pub(in crate::link) fn raise(
    socket: &Path,
    job: &str,
    lease: Duration,
    heard: Option<Now>,
) -> Raised {
    let held = Held { socket: socket.to_path_buf(), job: job.to_owned(), lease, heard, lost: None };
    *lock() = Some(held);
    Raised(())
}

impl Drop for Raised {
    fn drop(&mut self) {
        *lock() = None;
    }
}

/// Now, on both clocks.
pub(in crate::link) fn now() -> Now {
    (Instant::now(), SystemTime::now())
}

/// What a renewal asked at `asked` heard of `job` (`git.seed.status`): an answer is as old
/// as its question. A late answer of an earlier hold's renewal goes nowhere.
pub(in crate::link) fn heard(job: &str, asked: Now, answer: &anyhow::Result<Value>) {
    if let Some(held) = lock().as_mut().filter(|held| held.job == job) {
        held.heard_now(answer, asked);
    }
}

/// The hold a write of `cmd` names (`"hold": JOB`): the machine applies it only while that hold
/// runs (`git-seed-hold-v2`), which no check here can promise for a write already on its way.
pub(super) fn hold_for(cmd: &str) -> Option<String> {
    if !cmd.starts_with("fs.") || !WRITES.contains(&cmd) {
        return None;
    }
    lock().as_ref().map(|held| held.job.clone())
}

/// Whether a write may go now ([`check`]): the machine says the hold runs.
pub(in crate::link) fn confirm() -> anyhow::Result<()> {
    check("fs.write")
}

/// Whether a held copy's fence is up in this process.
pub(super) fn raised() -> bool {
    lock().is_some()
}

/// Before `cmd` goes to the machine: a write under a fence whose hold is not known to run
/// is refused, and so is a store fetch.
pub(super) fn check(cmd: &str) -> anyhow::Result<()> {
    if !WRITES.contains(&cmd) && !UNHELD_WRITES.contains(&cmd) {
        return Ok(());
    }
    let mut fence = lock();
    let Some(held) = fence.as_mut() else { return Ok(()) };
    if UNHELD_WRITES.contains(&cmd) {
        return Err(FsRefusal {
            code: "seed.copy_failed".to_owned(),
            message: "a held copy writes every file itself, never through the store".to_owned(),
        }
        .into());
    }
    let (socket, job) = (held.socket.clone(), held.job.clone());
    held.allows(now(), || {
        let answer = super::machine_call(&socket, "git.seed.status", json!({"job": job}));
        (answer, now())
    })
}

fn lock() -> std::sync::MutexGuard<'static, Option<Held>> {
    FENCE.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// One hold's fence.
struct Held {
    socket: PathBuf,
    job: String,
    lease: Duration,
    /// When the machine last said the job runs.
    heard: Option<(Instant, SystemTime)>,
    /// How the job ended, once a read said it no longer runs.
    lost: Option<FsRefusal>,
}

pub(in crate::link) type Now = (Instant, SystemTime);

impl Held {
    fn heard_now(&mut self, answer: &anyhow::Result<Value>, now: Now) {
        match answer {
            Ok(job) if job.get("state").and_then(Value::as_str) == Some("running") => {
                // Never older than what is heard already.
                if self.heard.is_none_or(|(heard, _)| heard < now.0) {
                    self.heard = Some(now);
                }
            }
            Ok(job) => {
                let said = |key: &str| job.get(key).and_then(Value::as_str);
                self.lost = Some(FsRefusal {
                    code: said("error_code").unwrap_or("seed.hold_expired").to_owned(),
                    message: said("error").unwrap_or("the hold on this folder ended").to_owned(),
                });
            }
            // The machine forgot the job.
            Err(error) if super::is_refusal(error) => {
                self.lost = Some(FsRefusal {
                    code: "seed.hold_expired".to_owned(),
                    message: format!("the hold on this folder ended: {error:#}"),
                });
            }
            // Not heard: the next write reads it again.
            Err(_) => {}
        }
    }

    /// Whether a write may go now, reading the job (`status`: its answer and when it came)
    /// when the last word on it is older than half the lease on either clock. The answer is
    /// as old as the question, and is judged when it comes: one that came back across a
    /// sleep past the lease lets nothing through.
    fn allows(
        &mut self,
        now: Now,
        status: impl FnOnce() -> (anyhow::Result<Value>, Now),
    ) -> anyhow::Result<()> {
        if self.lost.is_none() && !self.fresh(now) {
            let (answer, came) = status();
            self.heard_now(&answer, now);
            if self.lost.is_none() && !self.fresh(came) {
                return Err(FsRefusal {
                    code: "seed.hold_expired".to_owned(),
                    message: "the machine did not say this folder's hold still runs".to_owned(),
                }
                .into());
            }
        }
        match &self.lost {
            Some(lost) => {
                Err(FsRefusal { code: lost.code.clone(), message: lost.message.clone() }.into())
            }
            None => Ok(()),
        }
    }

    fn fresh(&self, (instant, wall): Now) -> bool {
        let half = self.lease / 2;
        self.heard.is_some_and(|(heard, heard_wall)| {
            instant.saturating_duration_since(heard) < half
                // A clock set back reads stale.
                && wall.duration_since(heard_wall).is_ok_and(|since| since < half)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LEASE: Duration = Duration::from_secs(60);

    fn held(heard: Now) -> Held {
        Held {
            socket: PathBuf::new(),
            job: "j".into(),
            lease: LEASE,
            heard: Some(heard),
            lost: None,
        }
    }

    fn running() -> (anyhow::Result<Value>, Now) {
        (Ok(json!({"state": "running"})), (Instant::now(), SystemTime::now()))
    }

    /// An answer `json` that came at `came`.
    fn said(json: Value, came: Now) -> impl FnOnce() -> (anyhow::Result<Value>, Now) {
        move || (Ok(json), came)
    }

    fn code(result: anyhow::Result<()>) -> String {
        result.unwrap_err().downcast::<FsRefusal>().unwrap().code
    }

    #[test]
    fn a_write_within_half_the_lease_reads_nothing() {
        let now = (Instant::now(), SystemTime::now());
        let mut fence = held(now);
        fence.allows(now, || panic!("no read within half the lease")).unwrap();
    }

    #[test]
    fn a_copy_that_slept_past_its_lease_writes_nothing_more() {
        let then = (Instant::now(), SystemTime::now());
        let mut fence = held(then);
        // A Mac asleep: the monotonic clock stood still, the wall clock did not.
        let woke = (then.0, then.1 + LEASE * 2);
        let expired = said(json!({"state": "failed", "error_code": "seed.hold_expired"}), woke);
        assert_eq!(code(fence.allows(woke, expired)), "seed.hold_expired");
        // Ended for good: no later write goes either.
        assert_eq!(code(fence.allows(woke, running)), "seed.hold_expired");
    }

    #[test]
    fn a_stopped_copy_whose_hold_still_runs_goes_on() {
        let then = (Instant::now(), SystemTime::now());
        let mut fence = held(then);
        let later = (then.0 + LEASE, then.1 + LEASE);
        fence.allows(later, said(json!({"state": "running"}), later)).unwrap();
        fence.allows(later, || panic!("just heard")).unwrap();
    }

    #[test]
    fn a_running_answer_that_came_back_past_the_lease_lets_nothing_through() {
        let then = (Instant::now(), SystemTime::now());
        let mut fence = held(then);
        let asked = (then.0 + LEASE, then.1 + LEASE);
        // The Mac slept while the answer waited: it came a lease later.
        let came = (asked.0, asked.1 + LEASE * 2);
        let late = said(json!({"state": "running"}), came);
        assert_eq!(code(fence.allows(asked, late)), "seed.hold_expired");
    }

    #[test]
    fn a_fence_raised_unheard_reads_the_job_before_its_first_write() {
        let now = (Instant::now(), SystemTime::now());
        let mut fence = Held { heard: None, ..held(now) };
        let expired = said(json!({"state": "failed", "error_code": "seed.hold_expired"}), now);
        assert_eq!(code(fence.allows(now, expired)), "seed.hold_expired");
        let mut fence = Held { heard: None, ..held(now) };
        fence.allows(now, said(json!({"state": "running"}), now)).unwrap();
    }

    #[test]
    fn a_job_the_machine_forgot_or_cannot_say_stops_the_writes() {
        let then = (Instant::now(), SystemTime::now());
        let later = (then.0 + LEASE, then.1 + LEASE);
        let unreachable = move || (Err(anyhow::anyhow!("connection refused")), later);
        assert_eq!(code(held(then).allows(later, unreachable)), "seed.hold_expired");
        let forgot = move || {
            let refusal =
                FsRefusal { code: "seed.job_unknown".into(), message: "no such job".into() };
            (Err(refusal.into()), later)
        };
        assert_eq!(code(held(then).allows(later, forgot)), "seed.hold_expired");
    }

    #[test]
    fn only_writes_are_fenced() {
        check("fs.stat").unwrap();
        check("blob.fetch.status").unwrap();
        // No fence up: a store fetch goes.
        check("blob.fetch.start").unwrap();
    }
}
