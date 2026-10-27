//! Process setup that only the terminal owner (the mux server) needs, and
//! the owner's background work, which a headless owner starts after its
//! first client (`after_first_client`).

mod after_first_client;
mod background_checks;
mod crash_forward;
mod memory_guard;
mod owner_panic;
pub(crate) mod poll_watch_lab;

use std::path::PathBuf;
use std::sync::Arc;

use cmux_threads::ThreadQos;
use cmux_tui_core::Mux;

pub(crate) use after_first_client::FirstClientGate;
#[cfg(test)]
pub(crate) use after_first_client::THREAD_NAME as FIRST_CLIENT_THREAD;

/// Debug builds only: the owner's hang log test trigger, once its mux
/// exists (tests/owner_panic.rs).
#[cfg(debug_assertions)]
pub(crate) fn hang_for_test(headless: bool) {
    if headless {
        owner_panic::hang_for_test();
    }
}

/// The QoS of the owner's main thread: it serves requests a person waits
/// on, so UserInitiated (Chromium's kDefault in the `cmux_threads::qos`
/// table), below the UserInteractive echo threads.
const MAIN_THREAD_QOS: ThreadQos = ThreadQos::UserInitiated;

/// Lists the calling thread as `main` in the thread registry at
/// [`MAIN_THREAD_QOS`] and sets its QoS, so `cmux_threads::snapshot` (and
/// `server.threads` on it, p02-threads task 203) shows it.
/// Returns false, and changes nothing, when the thread is listed already.
///
/// Call it once the main thread has started the owner's workers: a macOS
/// thread starts at its creator's class, and those workers (journal
/// maintenance, history search) run at their own lower classes, not at the
/// main thread's. The deferred work it starts later ([`OwnerBackground`])
/// declares its own QoS ([`OwnerWorkPlan::start`]).
pub(crate) fn register_main_thread() -> bool {
    cmux_threads::register_current("main", MAIN_THREAD_QOS)
}

/// Validate the owner's storage flags and raise its open-file soft limit.
///
/// The owner holds descriptors for every terminal, and the default soft
/// limit (256 on macOS) stopped it at about 60 terminals. Terminal hosts and
/// the programs in terminals get the original limit back at spawn.
///
/// The headless owner also records every panic (`owner_panic`, cx-urd.59)
/// from here on. Its checks (sending earlier panics, the memory guard, the
/// network checks) are returned to start with the rest of the background work.
pub(crate) fn prepare(args: &crate::Args) -> anyhow::Result<Option<OwnerChecks>> {
    let checks = args.headless.then(|| {
        owner_panic::install(&args.session);
        #[cfg(all(tokio_unstable, feature = "cmux-stability"))]
        poll_watch_lab::install(&args.session);
        OwnerChecks { panic_log: owner_panic::log_path(&args.session) }
    });
    if args.ephemeral && args.state.is_some() {
        anyhow::bail!("--ephemeral and --state are mutually exclusive");
    }
    #[cfg(unix)]
    if let Err(error) = cmux_tui_core::raise_open_file_limit(cmux_tui_core::OPEN_FILE_LIMIT_CEILING)
    {
        crate::client_log::stderr_log!(
            "startup",
            "{}: cannot raise the open-file limit: {error}",
            crate::cli::BIN
        );
    }
    Ok(checks)
}

/// The headless owner's own checks: sends the panics and memory alerts not
/// sent yet (`crash_forward`, tester rollout #7), then runs the memory guard
/// (#9), which sends its alerts as they happen, and fetches the signed
/// invite-wave flags and the daily update answer (`background_checks`).
pub(crate) struct OwnerChecks {
    panic_log: Option<PathBuf>,
}

impl OwnerChecks {
    fn start(self) {
        let logs = self
            .panic_log
            .iter()
            .flat_map(|log| [log.clone(), memory_guard::memory_log_path(log)])
            .collect();
        let forwarder = crash_forward::start(logs);
        memory_guard::spawn(self.panic_log, forwarder);
        background_checks::spawn();
    }
}

/// What the owner's deferred background work needs to start.
///
/// Work a client can wait on starts with the owner instead: the unplaced
/// terminal reaper (`identify` advertises `terminal-reaper-active-v1` while
/// it runs, and the app's tab close reads it at connect) and the Chief
/// brains (a Chief create waits for the supervisor's answer).
pub(crate) struct OwnerWorkPlan {
    /// The headless owner's checks (`prepare`).
    pub(crate) checks: Option<OwnerChecks>,
    /// The bound control socket the journal plugin connects to.
    pub(crate) journal_socket: PathBuf,
    /// A headless owner also starts the apps with an `always` server.
    pub(crate) headless: bool,
}

/// The started background work that the owner stops at shutdown, each
/// handle at its own step of the shutdown order.
#[derive(Default)]
pub(crate) struct OwnerWork {
    pub(crate) idle_terminal_reaper: Option<cmux_tui_core::IdleTerminalReaper>,
    #[cfg(unix)]
    pub(crate) machine_usage_poller: Option<crate::coderouter_usage::UsagePoller>,
}

impl OwnerWorkPlan {
    /// Starts the work on the calling (owner) thread. Each piece starts its
    /// own registered threads at a declared QoS: the checks, the poller
    /// (Background) and the idle reaper (Utility) below the owner; the
    /// journal plugin and apps supervisors at UserInitiated, because a Linux
    /// child process keeps its spawning thread's nice value.
    pub(crate) fn start(self, mux: &Arc<Mux>) -> OwnerWork {
        if let Some(checks) = self.checks {
            checks.start();
        }
        mux.start_journal_plugin(self.journal_socket);
        let mut work = OwnerWork::default();
        // Cloud VMs carry coderouter identity in their model-plane env; every
        // other host resolves no source and gets no poller.
        #[cfg(unix)]
        {
            work.machine_usage_poller = crate::coderouter_usage::start_poller(Arc::downgrade(mux));
        }
        // Closes terminals whose idle-close policy (`set-terminal-idle-policy`)
        // has elapsed with no attached view. It reads every policy when it
        // starts, so a policy set before then is not missed.
        let idle_reaper = cmux_tui_core::start_idle_terminal_reaper(
            Arc::downgrade(mux),
            cmux_tui_core::IDLE_CLOSE_REAP_INTERVAL,
        );
        work.idle_terminal_reaper = match idle_reaper {
            Ok(reaper) => Some(reaper),
            Err(error) => {
                crate::client_log::stderr_log!(
                    "startup",
                    "{}: idle terminal reaper unavailable: {error}",
                    crate::cli::BIN
                );
                None
            }
        };
        // Apps with an `always` server start off this path; an `apps-*`
        // command starts the supervisor itself when it comes first.
        #[cfg(unix)]
        if self.headless {
            cmux_tui_core::server::start_apps_when_ready(mux);
        }
        work
    }
}

/// The owner's background work: waiting for the first client, or started.
/// The default holds nothing and has started nothing.
#[derive(Default)]
pub(crate) struct OwnerBackground {
    held: Option<Held>,
    work: OwnerWork,
}

/// Work held until its gate marks it due, with the mux it starts on.
struct Held {
    plan: OwnerWorkPlan,
    gate: FirstClientGate,
    mux: Arc<Mux>,
}

impl OwnerBackground {
    /// Starts `plan` now: an interactive owner is its own first client.
    pub(crate) fn now(mux: &Arc<Mux>, plan: OwnerWorkPlan) -> Self {
        Self { held: None, work: plan.start(mux) }
    }

    /// Holds `plan` until `gate` marks it due (`take_due`, `start_due`). With
    /// no gate (its thread could not start) the work starts now.
    pub(crate) fn after_first_client(
        mux: &Arc<Mux>,
        plan: OwnerWorkPlan,
        gate: std::io::Result<FirstClientGate>,
    ) -> Self {
        match gate {
            Ok(gate) => Self {
                held: Some(Held { plan, gate, mux: Arc::clone(mux) }),
                work: OwnerWork::default(),
            },
            Err(error) => {
                crate::client_log::warn("startup", &format!("first-client gate: {error}"));
                Self::now(mux, plan)
            }
        }
    }

    /// True once, when the gate marked the held work due.
    pub(crate) fn take_due(&self) -> bool {
        self.held.as_ref().is_some_and(|held| held.gate.take_due())
    }

    /// Starts the held work on the calling (owner) thread; call it after
    /// `take_due` returned true.
    pub(crate) fn start_due(&mut self) {
        if let Some(Held { plan, gate, mux }) = self.held.take() {
            gate.stop();
            self.work = plan.start(&mux);
        }
    }

    /// The owner is stopping: a gate still waiting ends and its work never
    /// starts. Returns the started work for the shutdown steps.
    pub(crate) fn into_work(mut self) -> OwnerWork {
        if let Some(held) = self.held.take() {
            held.gate.stop();
        }
        self.work
    }
}

/// Serializes the tests that read thread rows by name (`main`, the gate,
/// the deferred work's threads): one test's threads would be another's.
#[cfg(test)]
pub(crate) fn lock_thread_rows() -> std::sync::MutexGuard<'static, ()> {
    static ROWS: std::sync::Mutex<()> = std::sync::Mutex::new(());
    ROWS.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}
