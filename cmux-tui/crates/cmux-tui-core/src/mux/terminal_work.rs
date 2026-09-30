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
//! owner ends every host whose terminal id the registry does not know.
//!
//! The reaper uses the same pool to end several due terminals at once.

use super::*;

/// Upper bound on concurrent terminal starts and reaps. A start is mostly
/// process creation and a host handshake, so a few workers overlap them
/// without starving the rest of the machine.
pub(crate) const MAX_TERMINAL_WORKERS: usize = 8;

/// Jobs queued beyond the running ones. A caller whose job does not fit
/// runs it inline, as before this pool existed.
const MAX_QUEUED_TERMINAL_JOBS: usize = 1024;

type TerminalJob = Box<dyn FnOnce() + Send>;

#[derive(Default)]
struct TerminalWorkState {
    queue: VecDeque<TerminalJob>,
    workers: usize,
}

/// A bounded pool of short-lived worker threads. Workers start on demand
/// and exit when the queue is empty, so an idle owner holds none and a
/// dropped owner never joins a worker that holds its last reference.
#[derive(Default)]
pub(crate) struct TerminalWorkPool {
    state: Arc<Mutex<TerminalWorkState>>,
}

impl TerminalWorkPool {
    /// Queue `job`. Returns it when the queue is full or no worker thread
    /// could start, so the caller can run it inline.
    pub(crate) fn try_submit(&self, job: TerminalJob) -> Result<(), TerminalJob> {
        let spawn = {
            let mut state = self.state.lock().unwrap();
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
        let started = std::thread::Builder::new()
            .name("mux-terminal-work".into())
            .spawn(move || Self::work(&state));
        if started.is_ok() {
            return Ok(());
        }
        let mut state = self.state.lock().unwrap();
        state.workers -= 1;
        if state.workers > 0 {
            // A running worker drains the queue, including this job.
            return Ok(());
        }
        Err(state.queue.pop_back().expect("the job just queued is still queued"))
    }

    fn work(state: &Mutex<TerminalWorkState>) {
        loop {
            let job = {
                let mut state = state.lock().unwrap();
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
            if std::panic::catch_unwind(std::panic::AssertUnwindSafe(job)).is_err() {
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
            results[index] = Some(result);
        }
        results.into_iter().map(|result| result.expect("every terminal job reports")).collect()
    }
}

/// A host launched for a creation that has not committed yet.
#[cfg(unix)]
pub(crate) struct PrelaunchedTerminal {
    /// Spawn options before the surface identity environment, which the
    /// registry records as the launch spec.
    launch_opts: SurfaceOptions,
    host: crate::surface::PrelaunchedHost,
}

#[cfg(unix)]
impl PrelaunchedTerminal {
    pub(crate) fn launch_opts(&self) -> &SurfaceOptions {
        &self.launch_opts
    }

    pub(crate) fn into_host(self) -> crate::surface::PrelaunchedHost {
        self.host
    }
}

impl Mux {
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
    pub(crate) fn prelaunch_tab_terminal(
        self: &Arc<Self>,
        pane: Option<PaneId>,
        cwd: Option<String>,
        env: Vec<(String, String)>,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<String>> {
        #[cfg(unix)]
        {
            if !self.uses_terminal_host_runtime() {
                return Ok(None);
            }
            let target = {
                let state = self.state.lock().unwrap();
                match pane {
                    Some(pane) => state.panes.contains_key(&pane).then_some(pane),
                    None => state.active_pane(),
                }
            };
            let Some(target) = target else { return Ok(None) };
            let cwd = cwd.or_else(|| self.pane_cwd(target));
            let (launch_opts, cell_pixels) = self.terminal_spawn_options(cwd, None, size, &env);
            if launch_opts.terminal_host_root.is_none() {
                return Ok(None);
            }
            let workspace_key = self.workspace_key_for_pane(target);
            let terminal_id = TerminalId::random()?;
            let mut host = Surface::prelaunch_hosted(
                self.next_id(),
                launch_opts.clone(),
                Arc::downgrade(self),
                terminal_id,
                cell_pixels,
            )?;
            debug_assert!(host.terminal_id() == terminal_id);
            // The deprecated recovery mirror syncs a file twice; do it here,
            // in parallel, instead of under the creation lock. A tab that
            // lands in another workspace rewrites it there.
            if let Some(workspace_key) = workspace_key.as_deref() {
                let _ = host.persist_workspace(workspace_key);
            }
            let terminal_hex = terminal_id.to_hex();
            self.prelaunched_terminals
                .lock()
                .unwrap()
                .insert(terminal_hex.clone(), PrelaunchedTerminal { launch_opts, host });
            Ok(Some(terminal_hex))
        }
        #[cfg(not(unix))]
        {
            let _ = (pane, cwd, env, size);
            Ok(None)
        }
    }

    /// The prelaunched host reserved under `terminal_hex`, for the creation
    /// that reserves the same id.
    #[cfg(unix)]
    pub(crate) fn take_prelaunched_terminal(
        &self,
        terminal_hex: &str,
    ) -> Option<PrelaunchedTerminal> {
        self.prelaunched_terminals.lock().unwrap().remove(terminal_hex)
    }

    /// End the prelaunched host under `terminal_hex` unless its creation
    /// adopted it.
    pub(crate) fn discard_prelaunched_terminal(&self, terminal_hex: &str) {
        #[cfg(unix)]
        {
            // Drop outside the lock: dropping kills and waits the host.
            let unclaimed = self.prelaunched_terminals.lock().unwrap().remove(terminal_hex);
            drop(unclaimed);
        }
        #[cfg(not(unix))]
        let _ = terminal_hex;
    }

    /// Whether new terminals run in durable host processes (tests may use
    /// in-process surfaces).
    #[cfg(unix)]
    fn uses_terminal_host_runtime(&self) -> bool {
        #[cfg(test)]
        return !self.test_surface_runtime;
        #[cfg(not(test))]
        true
    }

    /// Spawn options and cell size for a new terminal: the owner's options
    /// with `cwd`, `command` and `env` applied, sized to the latest client.
    pub(super) fn terminal_spawn_options(
        &self,
        cwd: Option<String>,
        command: Option<Vec<String>>,
        size: Option<(u16, u16)>,
        env: &[(String, String)],
    ) -> (SurfaceOptions, (u16, u16)) {
        let mut opts = self.surface_options.lock().unwrap().clone();
        if cwd.is_some() {
            opts.cwd = cwd;
        }
        if command.is_some() {
            opts.command = command;
        }
        opts.extra_env.extend(env.iter().cloned());
        // Spawn at the latest client-owned size: starting at the default
        // 80x24 and resizing a frame later makes shells emit artifacts
        // (e.g. zsh's reverse-video %% partial-line marker).
        let (cols, rows) = self.resolve_client_size(size, (opts.cols, opts.rows));
        opts.cols = cols;
        opts.rows = rows;
        let cell_pixels = {
            let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let cell_pixels = self.cell_pixel_creation_size();
            drop(cell_pixel_lifecycle);
            cell_pixels
        };
        (opts, cell_pixels)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminal_work_pool_runs_every_job_and_keeps_input_order() {
        let pool = TerminalWorkPool::default();
        let jobs: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..50usize)
            .map(|index| {
                Box::new(move || {
                    std::thread::sleep(Duration::from_millis((50 - index as u64) % 7));
                    index * 2
                }) as Box<dyn FnOnce() -> usize + Send>
            })
            .collect();
        let results = pool.run_all(jobs).into_iter().map(Result::unwrap).collect::<Vec<_>>();
        assert_eq!(results, (0..50).map(|index| index * 2).collect::<Vec<_>>());
    }

    #[test]
    fn terminal_work_pool_survives_panicking_jobs() {
        let pool = TerminalWorkPool::default();
        let panicking: Vec<Box<dyn FnOnce() -> usize + Send>> = (0..2 * MAX_TERMINAL_WORKERS)
            .map(|_| Box::new(|| panic!("job failed")) as Box<dyn FnOnce() -> usize + Send>)
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
        let pool = TerminalWorkPool::default();
        let running = Arc::new(AtomicUsize::new(0));
        let peak = Arc::new(AtomicUsize::new(0));
        let jobs: Vec<Box<dyn FnOnce() + Send>> = (0..40)
            .map(|_| {
                let running = running.clone();
                let peak = peak.clone();
                Box::new(move || {
                    let now = running.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(now, Ordering::SeqCst);
                    std::thread::sleep(Duration::from_millis(5));
                    running.fetch_sub(1, Ordering::SeqCst);
                }) as Box<dyn FnOnce() + Send>
            })
            .collect();
        pool.run_all(jobs);
        let peak = peak.load(Ordering::SeqCst);
        assert!(peak <= MAX_TERMINAL_WORKERS, "peak {peak} workers");
        assert!(peak > 1, "jobs did not overlap");
    }
}
