//! Parallel terminal starts and reaps.
//!
//! A host launch (process spawn, bootstrap, PTY launch, first snapshot) is
//! most of a terminal create's cost. The shared [`TerminalWorkPool`] runs
//! those launches off the request path: `tab_launch` starts the host of a
//! new tab when its request arrives and adopts it after the creation's
//! accept commit. The reaper uses the same pool to end several due terminals
//! at once.

use super::*;

#[cfg(unix)]
mod standby_host;

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
    /// The host process started ahead of the next new tab (R81, cap one).
    #[cfg(unix)]
    standby: Arc<standby_host::StandbyHostSlot>,
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

    /// The spare host process, when one is ready (R81).
    #[cfg(unix)]
    pub(crate) fn take_standby(&self) -> Option<crate::terminal_host_runtime::StandbyTerminalHost> {
        self.standby.take()
    }

    /// Start the next spare host in the background.
    #[cfg(unix)]
    pub(crate) fn refill_standby(&self) {
        self.standby.refill(self);
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

impl Mux {
    /// Queue `job` on the terminal work pool. Returns it when the pool is
    /// saturated, so the caller runs it inline.
    pub(crate) fn submit_terminal_work(
        &self,
        job: Box<dyn FnOnce() + Send>,
    ) -> Result<(), Box<dyn FnOnce() + Send>> {
        self.terminal_work.try_submit(job)
    }

    /// Whether new terminals run in durable host processes (tests may use
    /// in-process surfaces).
    #[cfg(unix)]
    pub(super) fn uses_terminal_host_runtime(&self) -> bool {
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
        let mut opts = self.surface_options.lock().unwrap().clone();
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
        // After the merge: a caller PATH (the app's login-shell PATH) may
        // replace the daemon PATH, but the `claude` shim directory stays first
        // on it, so `claude` still starts with the session's agent hooks.
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
            let cell_pixel_lifecycle = self.cell_pixel_lifecycle.lock().unwrap();
            let cell_pixels = self.cell_pixel_creation_size();
            drop(cell_pixel_lifecycle);
            cell_pixels
        };
        (opts, cell_pixels)
    }
}

/// Hosts that outlive their owner exist only on Unix; elsewhere every
/// create launches its terminal itself.
#[cfg(not(unix))]
impl Mux {
    pub(crate) fn begin_tab_launch(
        self: &Arc<Self>,
        _pane: Option<PaneId>,
        _terminal_id: Option<TerminalId>,
        _cwd: Option<String>,
        _command: Option<Vec<String>>,
        _env: Vec<(String, String)>,
        _size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<String>> {
        Ok(None)
    }

    pub(crate) fn discard_pending_launch(&self, _terminal_hex: &str) {}

    pub(crate) fn wait_for_launched_surface(&self, surface: Arc<Surface>) -> Arc<Surface> {
        surface
    }

    pub(crate) fn kept_terminal_input_len(&self, _terminal_hex: &str) -> usize {
        0
    }

    pub(crate) fn take_kept_terminal_input(&self, _terminal_hex: &str) -> Option<Vec<u8>> {
        None
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
        fn failing_job() -> usize {
            panic!("job failed")
        }
        let pool = TerminalWorkPool::default();
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
