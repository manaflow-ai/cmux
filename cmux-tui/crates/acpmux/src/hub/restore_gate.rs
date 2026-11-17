//! Staged restore: the prompts a restart cut short resume a few at a time, never all at once.
//!
//! On 2026-11-16 a host came back from a stop and this daemon resumed about 100 chats together
//! (`resume_queues` gave each restored prompt its own task, and every task started its agent the
//! moment startup was done). The load went to 240-285 on 32 cores, the host's network and broker
//! daemons stopped answering, `acpmux session info` timed out, and the host thrashed at 45 live
//! sessions against its cap of 12 for over an hour. A restart is when every
//! chat wants its agent back at once and when the host can least afford it.
//!
//! So a restored prompt waits here for its turn ([`Hub::admit_restored`]), and one driver
//! admits them in order:
//!
//! 1. The host's own services first: `ACPMUX_RESTORE_READY_CMD`, when set, is a shell command
//!    that must exit 0 before any restored agent starts (a fleet host names its network and
//!    broker checks there). It is tried every few seconds for up to
//!    `ACPMUX_RESTORE_READY_WAIT_SECS` (300); past that, restore goes on and says so.
//! 2. Then stages: each admits a few chats while the host has headroom (the host budget meter:
//!    load per core, memory pressure, free RAM, swap) and room under its lane cap
//!    (`lanes.max_lanes`, `admission.rs`), then waits a jittered gap so the next stage reads the
//!    load the last one made. Under pressure one chat still starts per `TRICKLE`: a busy host
//!    makes recovery slower, never stuck.
//! 3. Chats past the lane cap stay parked, each with its reason in its log
//!    (`restore_parked`) and in `_acpmux/status` `restore.parked`, where a coordinator can see
//!    them and move them to another host. Each resumes when a slot frees.
//!
//! A person's own prompt is never held here: only what the restart restored. A chat that closed
//! while it waited is skipped. `ACPMUX_RESTORE_STAGED=0` resumes everything at once, as before.

use super::*;
use std::collections::VecDeque;
use std::time::Duration;
// Tokio's clock, so a test's paused clock moves the stages too.
use tokio::time::Instant;

/// How long the driver waits between stages, before jitter (x0.5 to x1.5).
const STAGE_GAP: Duration = Duration::from_secs(5);
/// Under pressure, one chat still starts this often.
const TRICKLE: Duration = Duration::from_secs(60);
/// How often a parked or pressured driver reads the host again, before jitter.
const RECHECK: Duration = Duration::from_secs(10);
/// How often the readiness command is tried.
const READY_RETRY: Duration = Duration::from_secs(3);
/// The readiness command's default overall wait.
const READY_WAIT: Duration = Duration::from_secs(300);
/// One run of the readiness command.
const READY_CALL: Duration = Duration::from_secs(20);
/// How long a chat a stage let start counts as live before its agent reports in.
const STARTING: Duration = Duration::from_secs(120);

/// One restored chat waiting for its turn.
struct Waiter {
    session: Arc<Session>,
    go: tokio::sync::oneshot::Sender<()>,
}

/// A chat held past the lane cap, as `_acpmux/status` shows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Parked {
    pub session_id: String,
    pub name: String,
    pub reason: String,
    pub since_ms: u64,
}

#[derive(Default)]
struct State {
    queue: VecDeque<Waiter>,
    /// The driver runs (one at a time).
    driving: bool,
    admitted: usize,
    stages: u32,
    parked: Vec<Parked>,
    /// Chats a stage let start, and when: live until their agent reports in (`STARTING`).
    recent: Vec<(String, Instant)>,
    /// Chats a new prompt came to (`Hub::expedite_restored`): their restored prompts skip the gate.
    expedited: std::collections::HashSet<String>,
    /// Why the driver holds now (readiness, pressure), shown in `_acpmux/status`.
    holding: Option<String>,
    ready_check: Option<String>,
    started_at: Option<Instant>,
    drained_at: Option<Instant>,
}

/// The gate's state on the hub.
#[derive(Default)]
pub(crate) struct RestoreGate {
    state: StdMutex<State>,
    /// Restored prompts handed a task and not yet let through: counted when `start_restored`
    /// spawns them, so a reader never sees "drained" before they reach the queue.
    pending: std::sync::atomic::AtomicUsize,
    drained: tokio::sync::Notify,
    /// A test's host: the reading for how many chats were let through so far.
    #[cfg(test)]
    pub(super) fake: StdMutex<Option<FakeHost>>,
}

#[cfg(test)]
pub(super) type FakeHost = Arc<dyn Fn(usize) -> Reading + Send + Sync>;

/// What the driver reads before each stage. A test gives its own.
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Reading {
    /// Live sessions on this host (`admission.rs`'s count), plus the ones admitted here.
    pub live: usize,
    /// `lanes.max_lanes` for this host, when the fleet registry names one.
    pub cap: Option<u64>,
    /// Why the host is over its budget, one phrase each; empty within it or with no reading.
    pub over: Vec<String>,
    /// The cores the budget measures load against.
    pub cores: u32,
    /// Sessions whose agent host outlived the daemon: they reattach outside any stage.
    pub hosted: std::collections::HashSet<String>,
}

/// What the driver does next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Step {
    /// Start this many chats now.
    Admit(usize),
    /// At the lane cap: park the rest with this reason and read again later.
    Park(String),
    /// Over budget: hold with this reason (one chat still starts per `TRICKLE`).
    Hold(String),
}

/// How many chats one stage starts on `cores`: about one per 8 cores, at least 2.
pub(crate) fn stage_size(cores: u32) -> usize {
    (cores as usize / 8).max(2)
}

/// The next step for `r` with `waiting` chats queued. Pure.
pub(crate) fn decide(r: &Reading, waiting: usize) -> Step {
    if let Some(cap) = r.cap {
        let cap = usize::try_from(cap).unwrap_or(usize::MAX);
        if r.live >= cap {
            return Step::Park(format!(
                "parked on restore: this host has {} live sessions at its lane cap of {cap}; it resumes when one ends, or move it to a host with room",
                r.live
            ));
        }
        if !r.over.is_empty() {
            return Step::Hold(format!("restore waits for headroom: {}", r.over.join(", ")));
        }
        return Step::Admit(stage_size(r.cores).min(cap - r.live).min(waiting));
    }
    if !r.over.is_empty() {
        return Step::Hold(format!("restore waits for headroom: {}", r.over.join(", ")));
    }
    Step::Admit(stage_size(r.cores).min(waiting))
}

/// `d` times a random factor in 0.5..1.5.
fn jitter(d: Duration) -> Duration {
    let mut b = [0u8; 2];
    let r = getrandom::fill(&mut b).map(|()| u16::from_le_bytes(b)).unwrap_or(u16::MAX / 2);
    d.mul_f64(0.5 + f64::from(r) / f64::from(u16::MAX))
}

/// Whether staged restore is on (`ACPMUX_RESTORE_STAGED=0` turns it off).
fn staged() -> bool {
    std::env::var("ACPMUX_RESTORE_STAGED").map_or(true, |v| v.trim() != "0")
}

fn env_secs(name: &str, default: Duration) -> Duration {
    std::env::var(name)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .map_or(default, Duration::from_secs)
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

impl RestoreGate {
    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// `_acpmux/status` `restore`: where staged restore is.
    pub(crate) fn status(&self) -> Value {
        let s = self.lock();
        let secs = |a: Option<Instant>, b: Option<Instant>| match (a, b) {
            (Some(a), Some(b)) => json!(b.saturating_duration_since(a).as_secs_f64()),
            (Some(a), None) => json!(a.elapsed().as_secs_f64()),
            _ => Value::Null,
        };
        json!({
            "waiting": s.queue.len(),
            "admitted": s.admitted,
            "stages": s.stages,
            "holding": s.holding,
            "readyCheck": s.ready_check,
            "seconds": secs(s.started_at, s.drained_at),
            "drained": s.drained_at.is_some() || s.started_at.is_none(),
            "parked": s.parked.iter().map(|p| json!({
                "sessionId": p.session_id, "name": p.name, "reason": p.reason, "since": p.since_ms,
            })).collect::<Vec<_>>(),
        })
    }
}

impl RestoreGate {
    /// A restored prompt's task was spawned: it counts until [`Hub::admit_restored`] lets it go.
    pub(super) fn count_restored(&self) {
        self.pending.fetch_add(1, Ordering::SeqCst);
    }

    fn release_one(&self) {
        let left = self.pending.fetch_sub(1, Ordering::SeqCst) - 1;
        if left == 0 || left <= self.lock().parked.len() {
            self.drained.notify_waiters();
        }
    }

    /// A deleted chat: nothing of it stays here.
    pub(super) fn forget(&self, session_id: &str) {
        let mut s = self.lock();
        s.expedited.remove(session_id);
        s.parked.retain(|p| p.session_id != session_id);
    }

    /// Waits until no restored prompt waits for its stage, so work that can wait (warm spares)
    /// starts after the chats people were using.
    /// A chat parked past the cap does not hold them up: every prompt still waiting is parked.
    pub(super) async fn wait_drained(&self) {
        loop {
            let notified = self.drained.notified();
            let pending = self.pending.load(Ordering::SeqCst);
            if pending == 0 || pending <= self.lock().parked.len() {
                return;
            }
            notified.await;
        }
    }
}

/// Ends a driver however it ends: one that did not finish (its scope cancelled, before or after
/// it first ran, or a panic) drops its waiters' senders, so each prompt goes on unstaged rather
/// than waiting for ever, and the next restored prompt starts a new driver.
struct Driving {
    hub: Arc<Hub>,
    finished: bool,
}

impl Drop for Driving {
    fn drop(&mut self) {
        if self.finished {
            return;
        }
        let mut s = self.hub.restore_gate.lock();
        s.driving = false;
        s.queue.clear();
        s.parked.clear();
        s.holding = None;
    }
}

impl Hub {
    /// Waits until the staged restore lets `session`'s restored prompt start (module docs).
    /// Returns at once when staged restore is off. Pairs with one [`RestoreGate::count_restored`].
    pub(super) async fn admit_restored(self: &Arc<Self>, session: &Arc<Session>) {
        self.wait_staged(session).await;
        self.restore_gate.release_one();
    }

    /// A person's new prompt came to `session_id` (`queue_slot`): its restored prompts waiting
    /// for a stage go now, and any still on their way to the gate (startup not yet done) skip it.
    /// Another agent's message does not: lanes messaging each other after a restart would
    /// start every parked chat at once.
    pub(super) fn expedite_restored(&self, session_id: &str) {
        let mut s = self.restore_gate.lock();
        s.expedited.insert(session_id.to_owned());
        let (go, stay): (VecDeque<Waiter>, VecDeque<Waiter>) =
            std::mem::take(&mut s.queue).into_iter().partition(|w| w.session.id == session_id);
        s.queue = stay;
        s.parked.retain(|p| p.session_id != session_id);
        for w in go {
            if w.go.send(()).is_ok() {
                s.admitted += 1;
            }
        }
    }

    async fn wait_staged(self: &Arc<Self>, session: &Arc<Session>) {
        if !staged() {
            return;
        }
        let (tx, rx) = tokio::sync::oneshot::channel();
        let start = {
            let mut s = self.restore_gate.lock();
            if s.expedited.contains(&session.id) {
                return;
            }
            s.queue.push_back(Waiter { session: session.clone(), go: tx });
            s.started_at.get_or_insert_with(Instant::now);
            s.drained_at = None;
            !std::mem::replace(&mut s.driving, true)
        };
        if start {
            // Made before the spawn: a scope already cancelled drops it unrun, and that too
            // lets the waiters go.
            let driving = Driving { hub: self.clone(), finished: false };
            self.scope.spawn_until_cancelled("restore-stages", async move {
                let hub = driving.hub.clone();
                hub.drive_restore(driving).await;
            });
        }
        // A dropped sender (the driver ended without it) lets the prompt go on: never stuck.
        let _ = rx.await;
    }

    /// The one driver: readiness first, then stages until the queue is empty.
    async fn drive_restore(self: Arc<Self>, mut driving: Driving) {
        self.wait_restore_ready().await;
        let mut last_start = Instant::now();
        loop {
            let waiting = {
                let mut s = self.restore_gate.lock();
                s.queue.retain(|w| !queue::closing(&w.session));
                let queued: std::collections::HashSet<&str> =
                    s.queue.iter().map(|w| w.session.id.as_str()).collect();
                let parked = std::mem::take(&mut s.parked);
                s.parked =
                    parked.into_iter().filter(|p| queued.contains(p.session_id.as_str())).collect();
                if s.queue.is_empty() {
                    s.driving = false;
                    s.holding = None;
                    s.drained_at = Some(Instant::now());
                    driving.finished = true;
                    tracing::info!(admitted = s.admitted, stages = s.stages, "staged restore done");
                    return;
                }
                s.queue.len()
            };
            let reading = self.restore_reading().await;
            // A chat whose agent host outlived the daemon (a daemon-only restart) reattaches
            // at no cost: it goes at once, outside any stage.
            if self.release_hosted(&reading.hosted) {
                continue;
            }
            match decide(&reading, waiting) {
                Step::Admit(n) => {
                    self.release_restored(n.max(1), None);
                    last_start = Instant::now();
                    tokio::time::sleep(jitter(STAGE_GAP)).await;
                }
                Step::Hold(reason) => {
                    if last_start.elapsed() >= TRICKLE {
                        self.release_restored(1, Some(&reason));
                        last_start = Instant::now();
                    } else {
                        self.set_holding(Some(reason));
                    }
                    tokio::time::sleep(jitter(RECHECK)).await;
                }
                Step::Park(reason) => {
                    self.park_waiting(&reason);
                    tokio::time::sleep(jitter(RECHECK)).await;
                }
            }
        }
    }

    fn set_holding(&self, reason: Option<String>) {
        let mut s = self.restore_gate.lock();
        if s.holding != reason {
            if let Some(r) = &reason {
                tracing::info!(waiting = s.queue.len(), "{r}");
            }
            s.holding = reason;
        }
    }

    /// Starts the first `n` waiting chats (a stage; `trickle`: the one let through under pressure).
    fn release_restored(&self, n: usize, trickle: Option<&str>) {
        let mut s = self.restore_gate.lock();
        s.stages += 1;
        let stage = s.stages;
        let mut released = 0;
        while released < n {
            let Some(w) = s.queue.pop_front() else { break };
            s.parked.retain(|p| p.session_id != w.session.id);
            let id = w.session.id.clone();
            if w.go.send(()).is_ok() {
                s.recent.push((id, Instant::now()));
                released += 1;
                s.admitted += 1;
            }
        }
        s.holding = trickle.map(|r| format!("{r} (one start per {}s)", TRICKLE.as_secs()));
        tracing::info!(
            stage,
            released,
            waiting = s.queue.len(),
            trickle = trickle.is_some(),
            "restore stage"
        );
    }

    /// Lets every waiting chat in `hosted` go; whether any went.
    fn release_hosted(&self, hosted: &std::collections::HashSet<String>) -> bool {
        if hosted.is_empty() {
            return false;
        }
        let mut s = self.restore_gate.lock();
        let (go, stay): (VecDeque<Waiter>, VecDeque<Waiter>) =
            std::mem::take(&mut s.queue).into_iter().partition(|w| hosted.contains(&w.session.id));
        s.queue = stay;
        let any = !go.is_empty();
        for w in go {
            s.parked.retain(|p| p.session_id != w.session.id);
            if w.go.send(()).is_ok() {
                s.admitted += 1;
            }
        }
        if any {
            tracing::info!(
                waiting = s.queue.len(),
                "restore: chats whose agent still runs reattach"
            );
        }
        any
    }

    /// Marks every waiting chat parked with `reason`, logging it in each chat once.
    fn park_waiting(self: &Arc<Self>, reason: &str) {
        let newly: Vec<Arc<Session>> = {
            let mut s = self.restore_gate.lock();
            s.holding = Some(reason.to_owned());
            let fresh: Vec<Arc<Session>> = s
                .queue
                .iter()
                .filter(|w| !s.parked.iter().any(|p| p.session_id == w.session.id))
                .map(|w| w.session.clone())
                .collect();
            let since = now_ms();
            for session in &fresh {
                s.parked.push(Parked {
                    session_id: session.id.clone(),
                    name: session.meta().name.clone(),
                    reason: reason.to_owned(),
                    since_ms: since,
                });
            }
            fresh
        };
        if !newly.is_empty() {
            tracing::warn!(parked = newly.len(), "{reason}");
            // Spares wait for the restore, not for chats parked past the cap.
            self.restore_gate.drained.notify_waiters();
        }
        for session in newly {
            self.append(&session, "mux", "restore_parked", json!({"reason": reason}));
        }
    }

    /// Live sessions, the lane cap and the host budget, read off the async workers.
    async fn restore_reading(&self) -> Reading {
        #[cfg(test)]
        {
            let fake = self
                .restore_gate
                .fake
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone();
            if let Some(fake) = fake {
                return fake(self.restore_gate.lock().admitted);
            }
        }
        let read = tokio::task::spawn_blocking(|| {
            let (source, set) = admission::registry_source();
            let (registry, _) = admission::read_registry(&source, set);
            let origin = std::env::var("FLEET_ORIGIN").ok();
            let cap = registry.as_ref().and_then(|r| {
                let machine =
                    admission::machine_of(r, origin.as_deref(), super::start_gate::host_label())?;
                r.pointer(&format!("/machines/{machine}/lanes/max_lanes")).and_then(Value::as_u64)
            });
            (cap, Hub::live_host_sessions())
        });
        let (cap, hosted) = read.await.unwrap_or_default();
        let live = self.live_restore_count(&hosted);
        let verdict = crate::host_pressure::Meter::shared().current().await;
        let (over, cores) = verdict.map_or_else(
            || {
                let n = std::thread::available_parallelism().map_or(1, std::num::NonZero::get);
                (Vec::new(), u32::try_from(n).unwrap_or(u32::MAX))
            },
            |v| (v.over, v.cores),
        );
        Reading { live, cap, over, cores, hosted }
    }

    /// Sessions whose agent runs and creates still starting (`admission.rs`'s count), plus the
    /// ones a recent stage let start whose agent has not reported in yet, so a stage's starts
    /// count at once.
    fn live_restore_count(&self, hosted: &std::collections::HashSet<String>) -> usize {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let live: std::collections::HashSet<&str> = sessions
            .iter()
            .filter(|s| admission::is_live(s.status(), hosted.contains(&s.id)))
            .map(|s| s.id.as_str())
            .collect();
        let counted = {
            let admitting = self.admitting.0.lock().unwrap_or_else(|e| e.into_inner());
            admission::counted(&live, &admitting)
        };
        let mut gate = self.restore_gate.lock();
        gate.recent.retain(|(_, at)| at.elapsed() < STARTING);
        let starting = gate.recent.iter().filter(|(id, _)| !live.contains(id.as_str())).count();
        counted + starting
    }

    /// `ACPMUX_RESTORE_READY_CMD` until it exits 0, or its wait passes (module docs). Once per
    /// daemon: a later driver (a chat whose log loads later) does not wait again.
    async fn wait_restore_ready(&self) {
        if self.restore_gate.lock().ready_check.is_some() {
            return;
        }
        let Some(cmd) =
            std::env::var("ACPMUX_RESTORE_READY_CMD").ok().filter(|c| !c.trim().is_empty())
        else {
            return;
        };
        let wait = env_secs("ACPMUX_RESTORE_READY_WAIT_SECS", READY_WAIT);
        let started = Instant::now();
        self.set_holding(Some(format!("restore waits for the host to be ready: {cmd}")));
        let mut tries = 0u32;
        loop {
            tries += 1;
            let ok = tokio::time::timeout(
                READY_CALL,
                tokio::process::Command::new("/bin/sh")
                    .arg("-c")
                    .arg(&cmd)
                    .stdin(std::process::Stdio::null())
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .kill_on_drop(true)
                    .status(),
            )
            .await
            .is_ok_and(|s| s.is_ok_and(|s| s.success()));
            let took = started.elapsed().as_secs_f64();
            if ok {
                tracing::info!(tries, seconds = took, "restore ready check passed");
                self.restore_gate.lock().ready_check =
                    Some(format!("passed after {took:.1}s ({tries} tries)"));
                return;
            }
            if started.elapsed() >= wait {
                tracing::warn!(
                    tries,
                    seconds = took,
                    "restore ready check still failing; restoring anyway"
                );
                self.restore_gate.lock().ready_check = Some(format!(
                    "still failing after {took:.0}s ({tries} tries); restored anyway"
                ));
                return;
            }
            tokio::time::sleep(READY_RETRY).await;
        }
    }
}

#[cfg(test)]
#[path = "restore_gate_tests.rs"]
mod tests;
