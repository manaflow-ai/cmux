//! The agent roster's one owner, the `cmux-agent-roster` thread: every fold
//! of the journal into the roster and every save of its snapshot runs there.
//! A request (an agent hook's journal commit, a terminal close, a direct
//! report's echo) records what it needs under this owner's own short lock and
//! wakes it; it never folds, reads the journal or writes the snapshot itself
//! (plans/cmux-next/perf-lead.md D1: the request path changes memory and
//! answers, I/O runs in background workers).
//!
//! cmux-ad m11 2: request paths took the fold lock, which the maintenance
//! tick's catch-up held across the journal tail read and the snapshot write
//! (5-8 s on #34628's registry), so every later request of their connection
//! waited. A first fix let a request that found the fold free do the fold
//! itself; its review found a request's work left behind after a pass that
//! made no progress (F1) and a close that read the tail and saved the
//! snapshot on its request thread (F2). With one owner neither can happen: the
//! owner takes every recorded request before each pass and looks again after
//! it, and no request thread reads or writes.
//!
//! The thread runs at the daemon's default priority, as the journal writer,
//! the maintenance worker and `mux-history-feed` do (threading-model.md):
//! its passes hold locks that request paths take (the roster lock while it
//! applies a page, the writer's connection lock while it saves, the registry
//! lock while it commits a plugin delta), and a throttled holder would stall
//! those requests.

use super::*;

/// The roster owner's thread name.
const AGENT_ROSTER_THREAD: &str = "cmux-agent-roster";

/// How long a shutdown waits for the owner to finish the work recorded before
/// it. A pass saves on the journal writer's connection, which a stalled journal
/// commit can hold; shutdown must not wait on that without a limit.
const STOP_WAIT: Duration = Duration::from_secs(2);

/// What requests asked of the roster since its owner last took it. Held for
/// O(1) by a request and by the owner between passes, never across I/O.
#[derive(Debug, Default)]
struct RosterRequests {
    /// The highest journal sequence a request asked the roster to fold through.
    wanted: u64,
    /// A caller asked for a fold through the journal head (the catch-up).
    head: bool,
    /// Terminals closed since: retired once the roster folded a journal head
    /// read after they were recorded, so none of their earlier events brings
    /// an entry back.
    retire: Vec<String>,
    /// Work was recorded since the owner last took it.
    pending: bool,
    /// Passes a waiting caller asked for, and the last one the owner finished:
    /// a caller waits until the pass that took its request is done.
    asked: u64,
    done: u64,
    /// The owner takes another pass at this time with no request (a retry
    /// of background work: a rebuild read that failed).
    retry_at: Option<Instant>,
    /// The owner finishes what is recorded, then ends.
    stopping: bool,
    /// The owner's thread runs; once it ended, nobody waits for it.
    running: bool,
}

/// What one pass of the owner took from the requests.
pub(super) struct RosterPass {
    /// Fold through this journal sequence (a request's own commit).
    pub(super) wanted: u64,
    /// Fold through the journal head read in this pass.
    pub(super) head: bool,
    /// Retire these closed terminals once the roster folded that head.
    pub(super) retire: Vec<String>,
}

#[derive(Default)]
struct RosterControl {
    requests: Mutex<RosterRequests>,
    /// Wakes the owner: work was recorded, or it should stop.
    wake: Condvar,
    /// Wakes a caller that waits for a pass, or for the thread's end.
    settled: Condvar,
}

impl RosterControl {
    fn lock(&self) -> MutexGuard<'_, RosterRequests> {
        self.requests.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Records roster work and wakes the owner. O(1); never waits for a pass.
    fn record(&self, through: Option<u64>, retire: Option<String>) {
        let mut requests = self.lock();
        if let Some(through) = through {
            requests.wanted = requests.wanted.max(through);
        }
        if let Some(terminal) = retire {
            requests.retire.push(terminal);
        }
        requests.pending = true;
        self.wake.notify_one();
    }

    /// Asks the owner for a pass (through the journal head when `head`) and
    /// waits until the pass that took this request finished, or until `limit`
    /// passed. False when no owner runs or the limit came first.
    fn pass_and_wait(&self, head: bool, limit: Option<Duration>) -> bool {
        let started = Instant::now();
        let mut requests = self.lock();
        if !requests.running {
            return false;
        }
        requests.asked = requests.asked.saturating_add(1);
        let ticket = requests.asked;
        requests.head |= head;
        requests.pending = true;
        self.wake.notify_one();
        while requests.done < ticket {
            if !requests.running {
                return false;
            }
            requests = match limit {
                None => self.settled.wait(requests).unwrap_or_else(PoisonError::into_inner),
                Some(limit) => {
                    let left = limit.saturating_sub(started.elapsed());
                    if left.is_zero() {
                        return false;
                    }
                    self.settled
                        .wait_timeout(requests, left)
                        .unwrap_or_else(PoisonError::into_inner)
                        .0
                }
            };
        }
        true
    }

    /// Asks the owner for another pass of unfinished background work, unless
    /// it is stopping: work left then is saved and resumed at the next start.
    fn continue_later(&self) {
        let mut requests = self.lock();
        if !requests.stopping {
            requests.pending = true;
            self.wake.notify_one();
        }
    }

    /// Asks the owner for another pass after `delay`, unless it is stopping:
    /// a stop drops the retry, and the work resumes at the next start.
    fn continue_after(&self, delay: Duration) {
        let mut requests = self.lock();
        if !requests.stopping {
            let at = Instant::now() + delay;
            requests.retry_at = Some(requests.retry_at.map_or(at, |retry| retry.min(at)));
            self.wake.notify_one();
        }
    }

    /// The owner finishes the work recorded so far, then ends.
    fn stop(&self) {
        self.lock().stopping = true;
        self.wake.notify_all();
    }

    /// Waits until the owner's thread ended or `limit` passed: true when it
    /// ended.
    fn wait_until_ended(&self, limit: Duration) -> bool {
        let started = Instant::now();
        let mut requests = self.lock();
        while requests.running {
            let left = limit.saturating_sub(started.elapsed());
            if left.is_zero() {
                return false;
            }
            requests =
                self.settled.wait_timeout(requests, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        true
    }
}

/// The roster's owner: its fold state, what requests ask of it, and its thread.
/// The journal echoes of direct agent reports that are not in the journal
/// yet. A direct report commits its projection under the hook projector's
/// lock (`agent_hook_fences`) and appends its echo, the record the roster
/// folds, after releasing it. Until the echo is in the journal the roster
/// holds the agent's older state, so:
/// - the reconcile a replay or rebuild owes waits for every echo, then for
///   the roster to fold it, and only then writes the roster's entries: the
///   reducer's own verdict on each report, never a fence's guess at it;
/// - a guarded send (`expect_agent`) to a terminal with an echo not in the
///   journal is refused;
/// - an echo whose append failed is appended again by the roster's owner,
///   unless a later report of its terminal supersedes it.
#[derive(Default)]
pub(in crate::mux) struct ReportEchoes {
    terminals: HashMap<TerminalPublicId, TerminalEchoes>,
    /// Numbers the reports of every terminal, in commit order.
    numbered: u64,
    /// Echoes whose append failed, oldest first.
    failed: Vec<FailedEcho>,
    /// Retries of the failed echoes that failed in a row: their backoff.
    failed_retries: u32,
}

#[derive(Default)]
struct TerminalEchoes {
    /// The terminal's last committed direct report.
    latest: u64,
    /// Its echoes being appended now.
    appending: usize,
}

/// A direct report's journal echo ([`Mux::append_agent_report_echo`]).
pub(in crate::mux) struct ReportEcho {
    pub(in crate::mux) terminal_id: TerminalPublicId,
    pub(in crate::mux) state: AgentState,
    pub(in crate::mux) source: AgentSource,
    pub(in crate::mux) session: Option<String>,
    pub(in crate::mux) updated_at_ms: u64,
}

struct FailedEcho {
    number: u64,
    echo: ReportEcho,
}

/// Whether every direct report's echo is in the journal.
pub(in crate::mux) enum EchoesWritten {
    All,
    /// An echo is being appended; its writer wakes the owner.
    Appending,
    /// An echo's append failed; the owner retries it after a backoff.
    Failed,
}

impl ReportEchoes {
    fn forget_if_written(&mut self, terminal_id: &TerminalPublicId) {
        let written = self.terminals.get(terminal_id).is_some_and(|terminal| {
            terminal.appending == 0
                && !self.failed.iter().any(|failed| &failed.echo.terminal_id == terminal_id)
        });
        if written {
            self.terminals.remove(terminal_id);
        }
    }
}

#[derive(Default)]
pub(in crate::mux) struct AgentRosterWorker {
    /// The fold's own state (its journal reader); only the owner's passes
    /// take it, so it orders folds and snapshot saves.
    pub(in crate::mux) fold: Mutex<AgentRosterFold>,
    control: Arc<RosterControl>,
    thread: Mutex<Option<std::thread::JoinHandle<()>>>,
    /// The roster replay the daemon's start left for the owner
    /// (`agent_roster_restore::STARTUP_BUDGET`). Only the owner's passes
    /// take it, a slice at a time.
    pub(in crate::mux) replay: Mutex<Option<agent_roster_restore::AgentRosterReplay>>,
    /// The replay is not done: the roster may be behind the journal the
    /// start found, so the startup projection reconcile waits for it.
    pub(in crate::mux) replaying: AtomicBool,
    /// The replay's slices whose read failed in a row: the backoff of its
    /// retry (`run_roster_pass`).
    pub(in crate::mux) replay_failed_reads: std::sync::atomic::AtomicU32,
    /// The replay is done, and the projection reconcile it owes waits for a
    /// pass whose fold reached the journal head (`run_roster_pass`).
    pub(in crate::mux) reconcile_pending: AtomicBool,
    /// Direct reports' echoes not in the journal yet (`ReportEchoes`).
    pub(in crate::mux) report_echoes: Mutex<ReportEchoes>,
    /// Held across each echo append, so echoes reach the journal in the
    /// order their reports committed (`write_report_echo`). Never taken
    /// under the hook projector's lock: the append runs the projector.
    pub(in crate::mux) echo_appends: Mutex<()>,
    /// Test seam (`agent_roster_restore::REPLAY_GATE_FOR_TEST`).
    #[cfg(test)]
    pub(in crate::mux) replay_gate: Mutex<Option<(SyncSender<()>, Receiver<()>)>>,
    /// Test seam: runs once at the replay's reconcile, after its check that
    /// the roster folded every agent record and before its first write.
    #[cfg(test)]
    pub(in crate::mux) reconcile_seam: Mutex<Option<Box<dyn FnOnce() + Send>>>,
    /// The rebuild of a stale roster from the whole journal
    /// (`agent_roster_rebuild.rs`); only the owner takes it, a slice after
    /// each pass.
    pub(in crate::mux) rebuild: Mutex<Option<agent_roster_rebuild::AgentRosterRebuild>>,
    /// A rebuild is under way: the owner takes its slices.
    pub(in crate::mux) rebuilding: AtomicBool,
    /// The live roster may hold state the current reducer would not have
    /// folded, until a rebuild replaces it; a rebuild that gave up leaves it
    /// set. The projection reconcile waits for it.
    pub(in crate::mux) stale: AtomicBool,
    /// The reducer version the stale roster was migrated from when the
    /// start could not mark it stale (0: marked, or not stale). Live passes
    /// save the roster at this version, so a stop before the rebuild cannot
    /// leave it passing for the current reducer's fold.
    pub(in crate::mux) unmarked_from: std::sync::atomic::AtomicU32,
    /// Test seam: runs once in a direct agent report, after its projection
    /// commit and before its journal echo.
    #[cfg(test)]
    pub(in crate::mux) report_echo_seam: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}

impl Drop for AgentRosterWorker {
    /// A mux dropped without a shutdown still ends its owner, which may sleep
    /// until the next request.
    fn drop(&mut self) {
        self.control.stop();
    }
}

/// Marks the owner gone when its thread ends, so no caller waits for it.
struct OwnerEnded<'a>(&'a RosterControl);

impl Drop for OwnerEnded<'_> {
    fn drop(&mut self) {
        self.0.lock().running = false;
        self.0.settled.notify_all();
    }
}

/// The owner's loop: take everything recorded, run one pass, mark it done,
/// and sleep until the next request. It holds only a weak mux reference
/// between passes, so the session can drop.
fn run_owner(control: &RosterControl, mux: &Weak<Mux>) {
    let _ended = OwnerEnded(control);
    loop {
        let (pass, ticket) = {
            let mut requests = control.lock();
            while !requests.pending && !requests.stopping {
                let Some(retry_at) = requests.retry_at else {
                    requests = control.wake.wait(requests).unwrap_or_else(PoisonError::into_inner);
                    continue;
                };
                let now = Instant::now();
                if now >= retry_at {
                    requests.retry_at = None;
                    requests.pending = true;
                    break;
                }
                requests = control
                    .wake
                    .wait_timeout(requests, retry_at - now)
                    .unwrap_or_else(PoisonError::into_inner)
                    .0;
            }
            if !requests.pending {
                return;
            }
            requests.pending = false;
            let pass = RosterPass {
                wanted: requests.wanted,
                head: std::mem::take(&mut requests.head),
                retire: std::mem::take(&mut requests.retire),
            };
            (pass, requests.asked)
        };
        let Some(session) = mux.upgrade() else { return };
        // A pass that panics must not end the roster's only owner: every later
        // request would wait for a fold that never comes.
        // A stale roster's rebuild takes a slice after the pass, before the
        // pass counts as done: a caller that waits for a pass sees its
        // progress.
        let left = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let left = session.run_roster_pass(pass);
            session.run_agent_roster_rebuild_slice();
            left
        }))
        .unwrap_or_else(|_| {
            eprintln!("cmux-tui: an agent roster pass panicked; the next request folds again");
            Vec::new()
        });
        drop(session);
        let mut requests = control.lock();
        requests.done = requests.done.max(ticket);
        // A retirement whose journal head could not be read or reached waits
        // for the next pass, ahead of later ones.
        if !left.is_empty() {
            let later = std::mem::replace(&mut requests.retire, left);
            requests.retire.extend(later);
        }
        control.settled.notify_all();
    }
}

impl Mux {
    /// Starts the roster's owner. Work recorded before it starts is done when
    /// it starts.
    pub(in crate::mux) fn start_agent_roster_worker(self: &Arc<Self>) -> anyhow::Result<()> {
        let worker = &self.agent_roster_worker;
        worker.control.lock().running = true;
        let control = Arc::clone(&worker.control);
        let weak = Arc::downgrade(self);
        let spawned = std::thread::Builder::new()
            .name(AGENT_ROSTER_THREAD.into())
            .spawn(move || run_owner(&control, &weak));
        match spawned {
            Ok(thread) => {
                *worker.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread);
                Ok(())
            }
            Err(error) => {
                worker.control.lock().running = false;
                Err(error.into())
            }
        }
    }

    /// Stops the roster's owner after the work recorded before this call: a
    /// closed terminal's retirement is saved, so a restart does not bring its
    /// entry back. Waits at most `STOP_WAIT` for it.
    pub(in crate::mux) fn stop_agent_roster_worker(&self) {
        let worker = &self.agent_roster_worker;
        worker.control.stop();
        let Some(thread) = worker.thread.lock().unwrap_or_else(PoisonError::into_inner).take()
        else {
            return;
        };
        if thread.thread().id() == std::thread::current().id() {
            return;
        }
        if worker.control.wait_until_ended(STOP_WAIT) {
            let _ = thread.join();
        } else {
            eprintln!(
                "cmux-tui: the agent roster worker did not stop within {} s; shutdown goes on \
                 without it",
                STOP_WAIT.as_secs()
            );
        }
    }

    /// Hands the start's unfinished roster replay to the owner and wakes it.
    pub(in crate::mux) fn continue_agent_roster_replay(
        &self,
        replay: agent_roster_restore::AgentRosterReplay,
    ) {
        let worker = &self.agent_roster_worker;
        *worker.replay.lock().unwrap_or_else(PoisonError::into_inner) = Some(replay);
        worker.replaying.store(true, Ordering::Release);
        worker.control.continue_later();
    }

    /// Asks the owner for another pass of the background replay after
    /// `delay`, with no request to wake it: a retry after a failed read.
    pub(in crate::mux) fn retry_agent_roster_replay_after(&self, delay: Duration) {
        self.agent_roster_worker.control.continue_after(delay);
    }

    /// Asks the owner for another pass of the background replay.
    pub(in crate::mux) fn continue_agent_roster_replay_later(&self) {
        self.agent_roster_worker.control.continue_later();
    }

    fn report_echoes(&self) -> MutexGuard<'_, ReportEchoes> {
        self.agent_roster_worker.report_echoes.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// A direct report of `terminal_id` committed (under the hook projector's
    /// lock): its echo is not in the journal until [`Self::report_echo_appended`].
    pub(in crate::mux) fn note_report_echo(&self, terminal_id: &TerminalPublicId) -> u64 {
        let mut echoes = self.report_echoes();
        echoes.numbered += 1;
        let number = echoes.numbered;
        let terminal = echoes.terminals.entry(terminal_id.clone()).or_default();
        terminal.latest = number;
        terminal.appending += 1;
        number
    }

    /// Appends report `number`'s echo, unless a later report of its
    /// terminal was committed since: that one's echo carries the newer state,
    /// and an older echo must not fold after it. Echo appends take turns
    /// (`echo_appends`), so the check holds until the append. A failed one is
    /// kept for the owner to append again; a written one supersedes its
    /// terminal's older failed echoes.
    pub(in crate::mux) fn write_report_echo(&self, number: u64, echo: ReportEcho) {
        let turn =
            self.agent_roster_worker.echo_appends.lock().unwrap_or_else(PoisonError::into_inner);
        let latest = self.report_echoes().terminals.get(&echo.terminal_id).map(|t| t.latest);
        let written = latest != Some(number) || self.append_agent_report_echo(&echo);
        let mut echoes = self.report_echoes();
        let terminal_id = echo.terminal_id.clone();
        if let Some(terminal) = echoes.terminals.get_mut(&terminal_id) {
            terminal.appending = terminal.appending.saturating_sub(1);
        }
        if written {
            echoes
                .failed
                .retain(|failed| failed.echo.terminal_id != terminal_id || failed.number > number);
        } else {
            echoes.failed.push(FailedEcho { number, echo });
        }
        echoes.forget_if_written(&terminal_id);
        let failed = !echoes.failed.is_empty();
        drop(echoes);
        drop(turn);
        if failed {
            self.retry_agent_roster_replay_after(Duration::ZERO);
        } else {
            self.continue_agent_roster_replay_later();
        }
    }

    /// Whether a direct report of `terminal_id` has an echo not in the
    /// journal: the roster still holds the agent's state from before it.
    pub(crate) fn agent_report_echo_unwritten(&self, terminal_id: &TerminalPublicId) -> bool {
        self.report_echoes().terminals.contains_key(terminal_id)
    }

    /// Whether every direct report's echo is in the journal.
    pub(in crate::mux) fn report_echoes_written(&self) -> EchoesWritten {
        let echoes = self.report_echoes();
        if echoes.terminals.values().any(|terminal| terminal.appending > 0) {
            EchoesWritten::Appending
        } else if !echoes.failed.is_empty() {
            EchoesWritten::Failed
        } else {
            EchoesWritten::All
        }
    }

    /// The owner appends the failed echoes again, oldest first, each only
    /// while it is still its terminal's last report, in turn with every other
    /// echo append (`write_report_echo`). One left failed asks for another
    /// pass after the roster's read backoff.
    pub(in crate::mux) fn retry_failed_report_echoes(&self) {
        let turn =
            self.agent_roster_worker.echo_appends.lock().unwrap_or_else(PoisonError::into_inner);
        let failed = std::mem::take(&mut self.report_echoes().failed);
        if failed.is_empty() {
            return;
        }
        let touched =
            failed.iter().map(|failed| failed.echo.terminal_id.clone()).collect::<Vec<_>>();
        let mut left = Vec::new();
        for failed in failed {
            let latest =
                self.report_echoes().terminals.get(&failed.echo.terminal_id).map(|t| t.latest);
            if latest == Some(failed.number) && !self.append_agent_report_echo(&failed.echo) {
                left.push(failed);
            }
        }
        let mut echoes = self.report_echoes();
        echoes.failed = left;
        for terminal_id in touched {
            echoes.forget_if_written(&terminal_id);
        }
        drop(turn);
        if echoes.failed.is_empty() {
            echoes.failed_retries = 0;
            drop(echoes);
            self.continue_agent_roster_replay_later();
            return;
        }
        echoes.failed_retries = echoes.failed_retries.saturating_add(1);
        let delay = agent_roster_rebuild::roster_read_retry_delay(echoes.failed_retries);
        drop(echoes);
        self.retry_agent_roster_replay_after(delay);
    }

    /// The roster state of `terminal_id` now, with no wait for the owner.
    #[cfg(test)]
    pub(crate) fn agent_roster_state_now_for_test(&self, terminal_id: &str) -> Option<String> {
        let host = self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner);
        host.roster.entries.get(terminal_id).map(|entry| entry.state.clone())
    }

    /// Whether the roster may still show states older than the journal: its start's replay
    /// runs in the background, or the projection reconcile that replay owes has not run yet.
    pub(crate) fn agent_roster_settling(&self) -> bool {
        self.agent_roster_replaying()
            || self.agent_roster_worker.reconcile_pending.load(Ordering::Acquire)
    }

    /// Whether the start's roster replay is still running in the background.
    pub(crate) fn agent_roster_replaying(&self) -> bool {
        self.agent_roster_worker.replaying.load(Ordering::Acquire)
    }

    /// Asks the owner for another pass of the roster rebuild.
    pub(in crate::mux) fn continue_agent_roster_rebuild_later(&self) {
        self.agent_roster_worker.control.continue_later();
    }

    /// Asks the owner for another pass of the roster rebuild after `delay`,
    /// with no request to wake it: a retry after a failed read.
    pub(in crate::mux) fn retry_agent_roster_rebuild_after(&self, delay: Duration) {
        self.agent_roster_worker.control.continue_after(delay);
    }

    /// Records roster work for the owner and wakes it: a fold through
    /// `through`, or the retirement of a closed terminal. On a request path:
    /// O(1) in memory, no fold, no journal read, no snapshot write.
    pub(in crate::mux) fn request_roster_work(&self, through: Option<u64>, retire: Option<String>) {
        self.agent_roster_worker.control.record(through, retire);
    }

    /// The highest journal sequence a request asked the roster to fold
    /// through; a pass reads it again after each page, so a request that came
    /// meanwhile is folded in the same pass.
    pub(in crate::mux) fn wanted_roster_sequence(&self) -> u64 {
        self.agent_roster_worker.control.lock().wanted
    }

    /// Fold the journal tail into the roster and save its cursor at the
    /// head, so a start replays at most one maintenance tick of records.
    /// Shutdown does not call it: shutdown waits for the owner only a bounded
    /// time ([`Mux::stop_agent_roster_worker`]).
    ///
    /// Lawrence 2026-10-30: the cursor moved only with agent events, so a
    /// quiet stretch left it 9,821 records behind on a nightly registry and
    /// each start decoded 13 sealed segments (about 300 ms cold) to fold
    /// records that change nothing. The maintenance worker's step: it asks the
    /// owner for a pass through the head and waits for it, so the tick's later
    /// steps (checkpoint, seal) still come after the roster caught up. A
    /// request never waits for it.
    pub(in crate::mux) fn catch_up_agent_roster(&self) {
        self.agent_roster_worker.control.pass_and_wait(true, None);
    }

    /// Waits until the owner finished the roster work recorded before this
    /// call: true when it did, or when no owner runs any more (after a
    /// shutdown nothing is left to wait for).
    #[cfg(test)]
    pub(crate) fn settle_agent_roster_for_test(&self) -> bool {
        let control = &self.agent_roster_worker.control;
        control.pass_and_wait(false, Some(Duration::from_secs(60))) || !control.lock().running
    }
}

// Test-only, in its own module: the crash ratchet counts the parent's
// `#[cfg(test)]` methods as daemon code.
#[cfg(test)]
mod replay_for_test {
    use super::*;

    impl Mux {
        /// Runs `seam` once in the next direct agent report, after its
        /// projection commit and before its journal echo.
        pub(crate) fn hold_agent_report_echo_for_test(&self, seam: Box<dyn FnOnce() + Send>) {
            *self
                .agent_roster_worker
                .report_echo_seam
                .lock()
                .unwrap_or_else(PoisonError::into_inner) = Some(seam);
        }

        /// Fails the next `echoes` journal appends of direct reports' echoes.
        pub(crate) fn fail_agent_report_echoes_for_test(&self, echoes: u32) {
            crate::mux::agent_roster_fold::rebuild_faults::fail_report_echoes(
                &self.session,
                echoes,
            );
        }

        /// Starts a roster replay from zero in this running daemon, as a start
        /// whose snapshot does not restore does: the roster goes back to empty and
        /// the owner replays the journal in the background, `page` records per
        /// page, through `gate` (`agent_roster_restore::REPLAY_GATE_FOR_TEST`).
        #[cfg(test)]
        pub(crate) fn restart_agent_roster_replay_for_test(
            &self,
            page: usize,
            gate: (SyncSender<()>, Receiver<()>),
        ) {
            use agent_roster_restore::{RosterFoldLimits, restore_agent_roster_within};
            assert!(self.settle_agent_roster_for_test());
            let restored = {
                let registry = self.workspace_registry.lock().unwrap();
                registry
                    .put_journal_reducer_state(
                        crate::journal_reducers::AGENT_ROSTER_REDUCER_ID,
                        crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION,
                        0,
                        "",
                    )
                    .unwrap();
                let limits =
                    RosterFoldLimits { page, save_every_pages: 64, stop_after_pages: None };
                restore_agent_roster_within(&registry, limits, Some(Duration::ZERO)).unwrap()
            };
            *self.agent_roster.lock().unwrap_or_else(PoisonError::into_inner) = restored.host;
            *self.agent_roster_worker.replay_gate.lock().unwrap_or_else(PoisonError::into_inner) =
                Some(gate);
            self.continue_agent_roster_replay(restored.replay.expect("a replay from zero"));
        }
    }
}
