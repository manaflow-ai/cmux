//! Parallel terminal starts and reaps.
//!
//! Creating a terminal commits its topology under the creation lock, and a
//! host launch (process spawn, bootstrap, PTY launch, first snapshot) is
//! most of its cost. [`Mux::prelaunch_tab_terminal`] launches the host for a
//! `new-tab` on the shared [`TerminalWorkPool`] before the creation
//! transaction, under a fresh terminal id; the transaction then reserves
//! that id in the registry exactly as before (every commit still syncs) and
//! adopts the running host instead of launching one while it holds the lock.
//! The host's recovery-record workspace key is written there too, so that
//! synced write also leaves the lock.
//!
//! A prelaunched host has no registry row until its creation commits. That
//! is safe: a protocol v4 host starts its child only after activation, which
//! follows the durable topology commit; a live owner exact-kills an
//! unclaimed host when its [`PrelaunchedTerminal`] drops; and a restarted
//! owner ends every such host: its record names no workspace, so it is not
//! recovered (`orphan_hosts::recoverable`, cx-0tgl LC).
//!
//! The reaper uses the same pool to end several due terminals at once.
//!
//! The pool also owns the owner's one read loop ([`read_loop`]): every
//! daemon-local PTY terminal's output is read there, not on a thread of its
//! own.

use super::*;
use crate::supervised::{self, Fatal, ShutdownBehavior};
use std::sync::PoisonError;

#[cfg(unix)]
pub(crate) mod read_loop;
#[cfg(unix)]
mod read_poller;
#[cfg(any(unix, windows))]
mod standby_host;

/// Upper bound on concurrent terminal starts and reaps. A start is mostly
/// process creation and a host handshake, so a few workers overlap them
/// without starving the rest of the machine.
pub(crate) const MAX_TERMINAL_WORKERS: usize = 8;

/// Jobs queued beyond the running ones. A caller whose job does not fit
/// runs it inline, as before this pool existed.
const MAX_QUEUED_TERMINAL_JOBS: usize = 1024;

/// The workers' class: a person waits on a terminal start (a new tab,
/// split or workspace).
const TERMINAL_WORK_QOS: cmux_threads::ThreadQos = cmux_threads::ThreadQos::UserInitiated;

/// How long one job may run before the release hang watch reports it:
/// Chrome's default unit-of-work deadline (`kDefaultHangWatchTime`,
/// base/threading/hang_watcher.cc). A job is a host launch, a reap or a
/// creation's launch and commits; each commit's request is watched again at
/// its own class deadline (server/request_hang_watch.rs).
const TERMINAL_JOB_HANG_DEADLINE: Duration = cmux_hang_watch::DEFAULT_DEADLINE;

type TerminalJob = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct TerminalWorkState {
    queue: VecDeque<TerminalJob>,
    workers: usize,
}

/// A bounded pool of short-lived worker threads. Workers start on demand
/// and exit when the queue is empty, so an idle owner holds none and a
/// dropped owner never joins a worker that holds its last reference.
pub(crate) struct TerminalWorkPool {
    state: Arc<Mutex<TerminalWorkState>>,
    /// The read loop of the owner's daemon-local PTY terminals.
    #[cfg(unix)]
    reads: read_loop::TerminalReads,
    /// The host process started ahead of the next new tab (R81, cap one).
    #[cfg(any(unix, windows))]
    standby: Arc<standby_host::StandbyHostSlot>,
}

impl TerminalWorkPool {
    /// The owner's pool. Its standby slot is a consumer in `memory`, the
    /// owner's registry (`Mux::memory`).
    #[cfg_attr(not(any(unix, windows)), allow(unused_variables))]
    pub(crate) fn new(memory: &Arc<crate::memory::DaemonMemory>) -> Self {
        Self {
            state: Arc::default(),
            #[cfg(unix)]
            reads: read_loop::TerminalReads::new(),
            #[cfg(any(unix, windows))]
            standby: standby_host::StandbyHostSlot::new(memory.clone()),
        }
    }

    /// A pool whose registry no system source feeds.
    #[cfg(test)]
    pub(crate) fn for_test() -> Self {
        Self::new(&Arc::new(crate::memory::DaemonMemory::without_system_source()))
    }

    /// Queue `job`. Returns it when the queue is full or no worker thread
    /// could start, so the caller can run it inline.
    pub(crate) fn try_submit(&self, job: TerminalJob) -> Result<(), TerminalJob> {
        let spawn = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            if state.queue.len() >= MAX_QUEUED_TERMINAL_JOBS {
                return Err(job);
            }
            state.queue.push_back(job);
            if state.workers < MAX_TERMINAL_WORKERS {
                state.workers += 1;
                true
            } else {
                false
            }
        };
        if !spawn {
            return Ok(());
        }
        let state = self.state.clone();
        let started = supervised::spawn_at(
            "mux-terminal-work",
            TERMINAL_WORK_QOS,
            Fatal,
            ShutdownBehavior::Continue,
            move || {
                Self::work(&state);
            },
        );
        if started.is_ok() {
            return Ok(());
        }
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.workers -= 1;
        if state.workers > 0 {
            // A running worker drains the queue, including this job.
            return Ok(());
        }
        // No worker is left, so the queue still holds the job just queued.
        match state.queue.pop_back() {
            Some(job) => Err(job),
            None => Ok(()),
        }
    }

    fn work(state: &Mutex<TerminalWorkState>) {
        let _hang_watch = cmux_hang_watch::register_thread(
            cmux_hang_watch::ThreadKind::Pool,
            "mux-terminal-work",
        );
        loop {
            let job = {
                let mut state = state.lock().unwrap_or_else(PoisonError::into_inner);
                match state.queue.pop_front() {
                    Some(job) => job,
                    None => {
                        state.workers -= 1;
                        return;
                    }
                }
            };
            // A panicking job must not take its worker slot with it: the
            // slot count would never drop and later jobs would queue forever.
            let watched = cmux_hang_watch::watch(TERMINAL_JOB_HANG_DEADLINE);
            let finished = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
            drop(watched);
            if finished.is_err() {
                eprintln!("cmux-tui: a terminal work job panicked");
            }
        }
    }

    /// Run every job on the pool, or inline when it is full, and return
    /// their results in input order once all finished. A job that panicked
    /// reports `Err` with its payload instead of losing its result.
    pub(crate) fn run_all<T: Send + 'static>(
        &self,
        jobs: Vec<Box<dyn FnOnce() -> T + Send>>,
    ) -> Vec<std::thread::Result<T>> {
        let (sender, receiver) = std::sync::mpsc::channel();
        let count = jobs.len();
        for (index, job) in jobs.into_iter().enumerate() {
            let sender = sender.clone();
            let queued = self.try_submit(Box::new(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(job));
                let _ = sender.send((index, result));
            }));
            if let Err(inline) = queued {
                inline();
            }
        }
        drop(sender);
        let mut results: Vec<Option<std::thread::Result<T>>> = (0..count).map(|_| None).collect();
        for (index, result) in receiver.iter().take(count) {
            if let Some(slot) = results.get_mut(index) {
                *slot = Some(result);
            }
        }
        // Every job sends its result (a panic included) before its sender
        // drops; a missing one reports like a panicked job.
        results
            .into_iter()
            .map(|result| {
                result.unwrap_or_else(|| Err(Box::new("cmux-tui: a terminal job did not report")))
            })
            .collect()
    }
}

/// A host launched for a creation that has not committed yet.
#[cfg(any(unix, windows))]
pub(crate) struct PrelaunchedTerminal {
    /// Spawn options before the surface identity environment, which the
    /// registry records as the launch spec.
    launch_opts: SurfaceOptions,
    host: crate::surface::PrelaunchedHost,
}

#[cfg(any(unix, windows))]
impl PrelaunchedTerminal {
    pub(crate) fn launch_opts(&self) -> &SurfaceOptions {
        &self.launch_opts
    }

    pub(crate) fn into_host(self) -> crate::surface::PrelaunchedHost {
        self.host
    }
}

impl Mux {
    /// The read loop every daemon-local PTY terminal of this owner reads on.
    #[cfg(unix)]
    pub(crate) fn terminal_reads(&self) -> &read_loop::TerminalReads {
        &self.terminal_work.reads
    }

    /// Queue `job` on the terminal work pool. Returns it when the pool is
    /// saturated, so the caller runs it inline.
    pub(crate) fn submit_terminal_work(
        &self,
        job: Box<dyn FnOnce() + Send>,
    ) -> Result<(), Box<dyn FnOnce() + Send>> {
        self.terminal_work.try_submit(job)
    }

    /// Launch the host of a `new-tab` into `pane` (the active pane when
    /// `None`) before its creation transaction. Returns the terminal id the
    /// create must reserve (`new-tab` `terminal_id`) so that it adopts this
    /// host, or `None` when this owner does not host terminals or has no
    /// such pane; the create then launches its host itself.
    ///
    /// The caller must finish with [`Mux::discard_prelaunched_terminal`],
    /// which ends the host when the create did not adopt it.
    #[track_caller]
    pub(crate) fn prelaunch_tab_terminal(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        terminal_id: Option<TerminalId>,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        env: Vec<(String, String)>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<String>> {
        #[cfg(any(unix, windows))]
        {
            // Holder terminals start in their create: no host process to launch ahead.
            if !self.uses_terminal_host_runtime() || holder_model() {
                return Ok(None);
            }
            let target = {
                let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
                match pane {
                    Some(pane) => state.panes.contains_key(&pane).then_some(pane),
                    None => state.active_pane(),
                }
            };
            let Some(target) = target else { return Ok(None) };
            crate::debug_spans::mark("prelaunch.target");
            let cwd = self.new_terminal_cwd(cwd, Some(target), None);
            let (launch_opts, cell_pixels) = self.terminal_spawn_options(cwd, command, size, &env);
            if launch_opts.terminal_host_root.is_none() {
                return Ok(None);
            }
            let workspace_key = self.workspace_key_for_pane(target);
            let terminal_id = match terminal_id {
                // A retry of a keyed create names a terminal that exists: the
                // create replays its first result, so nothing may launch a
                // second host (or rewrite the record) under that id.
                Some(terminal_id)
                    if self
                        .workspace_registry
                        .lock()
                        .unwrap_or_else(PoisonError::into_inner)
                        .terminal_record(&terminal_id.to_hex())?
                        .is_some() =>
                {
                    return Ok(None);
                }
                Some(terminal_id) => terminal_id,
                None => TerminalId::random()?,
            };
            // The spare host process, when one is ready (R81); the next one
            // starts in the background after this launch.
            let standby = self.terminal_work.standby.take();
            let used_spare = standby.is_some();
            crate::debug_spans::mark(if used_spare { "spare.taken" } else { "spare.none" });
            let launch = |standby| {
                Surface::prelaunch_hosted(
                    self.next_id(),
                    launch_opts.clone(),
                    Arc::downgrade(self),
                    terminal_id,
                    (cell_pixels, workspace_key.as_deref().unwrap_or_default()),
                    standby,
                )
            };
            let mut launched = launch(standby);
            // A spare that died after its liveness check fails before
            // bootstrap: launch on a fresh process, so the tab never fails
            // or slows down because of the spare.
            if launched.is_err() && used_spare {
                launched = launch(None);
            }
            crate::debug_spans::mark("host.launched");
            self.terminal_work.standby.refill(&self.terminal_work);
            let mut host = launched?;
            debug_assert!(host.terminal_id() == terminal_id);
            // The deprecated recovery mirror syncs a file twice; do it here,
            // in parallel, instead of under the creation lock. A tab that
            // lands in another workspace rewrites it there.
            if let Some(workspace_key) = workspace_key.as_deref() {
                let _ = host.persist_workspace(workspace_key);
                crate::debug_spans::mark("host.workspace_persisted");
            }
            let terminal_hex = terminal_id.to_hex();
            self.prelaunched_terminals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .insert(terminal_hex.clone(), PrelaunchedTerminal { launch_opts, host });
            Ok(Some(terminal_hex))
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = (pane, terminal_id, cwd, env, size);
            Ok(None)
        }
    }

    /// The prelaunched host reserved under `terminal_hex`, for the creation
    /// that reserves the same id.
    #[cfg(any(unix, windows))]
    pub(crate) fn take_prelaunched_terminal(
        &self,
        terminal_hex: &str,
    ) -> Option<PrelaunchedTerminal> {
        self.prelaunched_terminals
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(terminal_hex)
    }

    /// End the prelaunched host under `terminal_hex` unless its creation
    /// adopted it.
    pub(crate) fn discard_prelaunched_terminal(&self, terminal_hex: &str) {
        #[cfg(any(unix, windows))]
        {
            // Drop outside the lock: dropping kills and waits the host.
            let unclaimed = self
                .prelaunched_terminals
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .remove(terminal_hex);
            drop(unclaimed);
        }
        #[cfg(not(any(unix, windows)))]
        let _ = terminal_hex;
    }

    /// Whether new terminals run in durable host processes (tests may use
    /// in-process surfaces).
    #[cfg(any(unix, windows))]
    fn uses_terminal_host_runtime(&self) -> bool {
        #[cfg(test)]
        return !self.test_surface_runtime;
        #[cfg(not(test))]
        true
    }

    /// Spawn options and cell size for a new terminal: the owner's options
    /// with `cwd`, `command` and `env` applied, sized to the latest client.
    /// Every terminal spawn that takes a caller `env` comes through here.
    pub(super) fn terminal_spawn_options(
        &self,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        env: &[(String, String)],
    ) -> (SurfaceOptions, (u16, u16)) {
        let mut opts = self.surface_options.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        if command.is_some() {
            opts.command = command;
        }
        // The daemon owns some keys (its socket, the terminal identity, the
        // hook helper...): a caller value for one of them is dropped, so the
        // daemon value always wins. The warning names the key, never the value.
        let dropped = crate::daemon_env::merge_caller_env(&mut opts.extra_env, env);
        crate::daemon_env::warn_dropped(&dropped);
        // After the merge: a caller PATH (the app's login-shell PATH, an
        // agent's PATH) may replace the daemon PATH, but the app's bundled
        // `cmux` stays first on it, so a command that runs plain `cmux` gets
        // the app's CLI, not an older one the caller lists first.
        crate::daemon_env::keep_bundled_cli_first(&mut opts.extra_env, opts.bundled_cli.as_deref());
        // The `claude` shim directory stays first on it, so `claude` still
        // starts with the session's agent hooks.
        crate::daemon_env::keep_shim_first_on_path(
            &mut opts.extra_env,
            opts.claude_shim_dir.as_deref(),
        );
        // Spawn at the latest client-owned size: starting at the default
        // 80x24 and resizing a frame later makes shells emit artifacts
        // (e.g. zsh's reverse-video %% partial-line marker).
        let (cols, rows) = self.resolve_client_size(size, (opts.cols, opts.rows));
        opts.cols = cols;
        opts.rows = rows;
        let cell_pixels = {
            let cell_pixel_lifecycle =
                self.cell_pixel_lifecycle.lock().unwrap_or_else(PoisonError::into_inner);
            let cell_pixels = self.cell_pixel_creation_size();
            drop(cell_pixel_lifecycle);
            cell_pixels
        };
        (opts, cell_pixels)
    }
}

/// New terminals run on the holder (`holder_runtime`), not on host processes.
fn holder_model() -> bool {
    #[cfg(unix)]
    {
        crate::holder_runtime::enabled()
    }
    #[cfg(not(unix))]
    {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[cfg(any(unix, windows))]
    #[test]
    fn the_owner_pools_spare_is_a_consumer_in_the_mux_memory() {
        let mux = Mux::new_for_test("terminal-work-memory", SurfaceOptions::default());
        let names: Vec<_> =
            mux.memory.registry().report().into_iter().map(|line| line.name).collect();
        assert_eq!(names, ["terminal.standby-host"], "one registry per owner, from the root");
    }

    #[test]
    fn terminal_work_pool_runs_every_job_and_keeps_input_order() {
        let pool = TerminalWorkPool::for_test();
        let jobs: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..50usize)
            .map(|index| {
                Box::new(move || {
                    crate::request_path::sleep(Duration::from_millis((50 - index as u64) % 7));
                    index * 2
                }) as Box<dyn FnOnce() -> usize + Send>
            })
            .collect();
        let results = pool.run_all(jobs).into_iter().map(Result::unwrap).collect::<Vec<_>>();
        assert_eq!(results, (0..50).map(|index| index * 2).collect::<Vec<_>>());
    }

    #[test]
    fn terminal_work_pool_survives_panicking_jobs() {
        fn failing_job() -> usize {
            panic!("job failed")
        }
        let pool = TerminalWorkPool::for_test();
        let panicking: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..2 * MAX_TERMINAL_WORKERS)
            .map(|_| Box::new(failing_job) as Box<dyn FnOnce() -> usize + Send>)
            .collect();
        assert!(pool.run_all(panicking).iter().all(Result::is_err));
        for _ in 0..2 * MAX_TERMINAL_WORKERS {
            let queued = pool.try_submit(Box::new(|| panic!("raw job failed")));
            assert!(queued.is_ok());
        }
        // Every worker slot came back, so later jobs still run.
        let jobs: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..MAX_TERMINAL_WORKERS)
            .map(|index| Box::new(move || index) as Box<dyn FnOnce() -> usize + Send>)
            .collect();
        let results = pool.run_all(jobs).into_iter().map(Result::unwrap).collect::<Vec<_>>();
        assert_eq!(results, (0..MAX_TERMINAL_WORKERS).collect::<Vec<_>>());
        assert_eq!(pool.state.lock().unwrap().queue.len(), 0);
    }

    #[test]
    fn terminal_work_pool_bounds_concurrent_workers() {
        let pool = TerminalWorkPool::for_test();
        let running = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let jobs: Vec<Box<dyn FnOnce() + Send>> = (0..40)
            .map(|_| {
                let running = running.clone();
                let peak = peak.clone();
                Box::new(move || {
                    let now = running.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(now, Ordering::SeqCst);
                    crate::request_path::sleep(Duration::from_millis(5));
                    running.fetch_sub(1, Ordering::SeqCst);
                }) as Box<dyn FnOnce() + Send>
            })
            .collect();
        pool.run_all(jobs);
        let peak = peak.load(Ordering::SeqCst);
        assert!(peak <= MAX_TERMINAL_WORKERS, "peak {peak} workers");
        assert!(peak > 1, "jobs did not overlap");
    }

    /// A worker registers with the process's hang watch and watches each
    /// job: a job past its 10 s deadline (on the watch's test clock) is a
    /// hang of the `mux-terminal-work` thread.
    #[test]
    fn terminal_work_job_past_its_deadline_is_a_hang_of_its_worker() {
        const THREAD: &str = "mux-terminal-work";
        let harness = crate::hang_watch_test_support::Harness::get();
        let _serial = harness.serial();
        // The pool starts its workers after the watch runs, so they register.
        let pool = TerminalWorkPool::for_test();
        let before = harness.hangs_of(THREAD).len();
        let (reported, hangs) = std::sync::mpsc::channel();
        let queued = pool.try_submit(Box::new(move || {
            harness.advance(TERMINAL_JOB_HANG_DEADLINE + Duration::from_secs(1));
            let _ = reported.send(harness.wait_for(THREAD, before + 1));
        }));
        assert!(queued.is_ok(), "the job is queued");
        let hangs = hangs.recv().expect("the job reports its hang");
        let hang = hangs.last().expect("a hang of the worker");
        assert_eq!(hang.kind, cmux_hang_watch::ThreadKind::Pool);
        assert_eq!(hang.deadline_ms, 10_000);
    }
}
