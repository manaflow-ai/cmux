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
mod tests;
