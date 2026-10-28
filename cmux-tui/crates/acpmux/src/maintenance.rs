//! acpmux's periodic upkeep on one [`MaintenanceClock`].
//!
//! The model catalog refresh (`catalog/`), the agent CLI health check
//! (`hub/health_view.rs`) and the upload age-cap sweep
//! (`hub/file_uploads.rs`) register here instead of each running its own
//! tokio interval. They then share the clock's 5-minute wall-clock grid and
//! its 30 s kernel leeway: an idle daemon wakes at most once per boundary for
//! all of them, and not at all between (cmux_wake's maintenance module).
//! Chrome shares delayed wakes the same way (base/task/delay_policy.h,
//! base/message_pump.cc `AdjustDelayedRunTime`).
//!
//! The clock runs its jobs on its own thread; these jobs are async. The
//! adapter is one tokio task: a clock job only sends its slot to the task,
//! and the task starts the job's future, unless the job's last run is still
//! going. A run never overlaps the one before, as with the tokio interval
//! and `MissedTickBehavior::Delay` these jobs used.
//!
//! The catalog refresh and the health check ask servers, so installs must
//! not all ask at the same instant. Each job sits on the grid shifted by this
//! install's phase ([`install_phase`], a random number kept in the acpmux
//! home): installs spread across the period, and one install's jobs still
//! share their wakes. A job started at once ([`Start::Now`]) first runs on
//! the grid at least half a period later, so a daemon that starts just
//! before a boundary does not fetch twice.
//!
//! Energy Saver: [`Maintenance::energy`] is this process's mode. The control
//! channel's `_acpmux/energy` (`energy_control.rs`) flips it, and the clock
//! runs each job registered `skippable_in_saver` at 4 times its period.

use std::collections::BTreeMap;
use std::future::Future;
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};

use futures::future::BoxFuture;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use cmux_wake::MaintenanceClock;

use crate::supervised::{Fatal, ShutdownBehavior, Supervisor};
pub use cmux_wake::{EnergyMode, JobSpec, Placement, RegisterError};

/// The file in the acpmux home that keeps [`install_phase`].
pub const PHASE_FILE: &str = "maintenance-phase";

type AsyncJob = Box<dyn FnMut() -> BoxFuture<'static, ()> + Send>;

/// When a job's first run starts.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Start {
    /// At once, then on the grid.
    Now,
    /// At the next multiple of its period.
    OnGrid,
}

/// Why a job was not registered.
#[derive(Debug, thiserror::Error)]
pub enum MaintenanceError {
    /// [`Maintenance::start`] has not run (or the clock did not start).
    #[error("the maintenance clock has not started")]
    NotStarted,
    #[error(transparent)]
    Clock(#[from] RegisterError),
}

/// Energy Saver and the periodic upkeep of one daemon. Holds no thread until
/// [`Maintenance::start`]: a hub built in a test has a mode and no clock.
pub struct Maintenance {
    energy: Arc<EnergyMode>,
    running: OnceLock<Running>,
}

struct Running {
    clock: MaintenanceClock,
    /// This install's grid phase ([`install_phase`]).
    phase: u64,
    adapter: mpsc::UnboundedSender<Message>,
    next_slot: AtomicUsize,
}

/// What the adapter task hears.
enum Message {
    Add {
        slot: usize,
        spec: JobSpec,
        job: AsyncJob,
    },
    /// The clock refused the job after it was added.
    Remove(usize),
    /// The clock says the job in `slot` is due.
    Due(usize),
    /// The registered jobs' names, in registration order.
    Jobs(oneshot::Sender<Vec<&'static str>>),
}

impl Default for Maintenance {
    fn default() -> Self {
        Self { energy: EnergyMode::new(false), running: OnceLock::new() }
    }
}

impl Maintenance {
    /// This process's Energy Saver mode.
    pub fn energy(&self) -> &Arc<EnergyMode> {
        &self.energy
    }

    /// Starts the clock thread and the adapter task, once, with every job on
    /// the grid shifted by `phase` ([`install_phase`]); call in the daemon's
    /// runtime. A second call does nothing. The adapter holds every registered
    /// job: it runs under `supervisor` as Fatal.
    pub fn start(&self, phase: u64, supervisor: &Supervisor) -> std::io::Result<()> {
        if self.running.get().is_some() {
            return Ok(());
        }
        let clock = MaintenanceClock::start(&self.energy)?;
        let (adapter, inbox) = mpsc::unbounded_channel();
        let jobs = adapt(inbox);
        crate::supervised::task(
            supervisor,
            "maintenance.adapter",
            Fatal,
            ShutdownBehavior::Skip,
            jobs,
        );
        // A racing start loses its clock here; its adapter ends with its sender.
        let _ = self.running.set(Running { clock, phase, adapter, next_slot: AtomicUsize::new(0) });
        Ok(())
    }

    /// Runs `job` every `spec.period` on the clock's grid, first at the next
    /// multiple of the period.
    pub fn register<F, Fut>(&self, spec: JobSpec, job: F) -> Result<(), MaintenanceError>
    where
        F: FnMut() -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        self.add(spec, job, Start::OnGrid)
    }

    fn add<F, Fut>(&self, spec: JobSpec, mut job: F, start: Start) -> Result<(), MaintenanceError>
    where
        F: FnMut() -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let running = self.running.get().ok_or(MaintenanceError::NotStarted)?;
        let slot = running.next_slot.fetch_add(1, Ordering::Relaxed);
        let job: AsyncJob = Box::new(move || Box::pin(job()));
        // Added before the clock knows the job, so its first Due finds it.
        running
            .adapter
            .send(Message::Add { slot, spec, job })
            .map_err(|_| RegisterError::Stopped)?;
        let due = running.adapter.clone();
        let placement =
            Placement { phase: running.phase, ran_at_registration: start == Start::Now };
        let registered = running.clock.register_placed(spec, placement, move || {
            let _ = due.send(Message::Due(slot));
        });
        if registered.is_err() {
            let _ = running.adapter.send(Message::Remove(slot));
        } else if start == Start::Now {
            let _ = running.adapter.send(Message::Due(slot));
        }
        Ok(registered?)
    }

    /// [`Maintenance::register`] for a job of `owner` that holds it only
    /// while a run goes: a run after `owner` is gone does nothing. With
    /// [`Start::Now`] the first run starts at once, through the adapter, so a
    /// grid run never overlaps it.
    pub fn register_for<T, F, Fut>(
        &self,
        spec: JobSpec,
        owner: &Arc<T>,
        start: Start,
        mut job: F,
    ) -> Result<(), MaintenanceError>
    where
        T: Send + Sync + 'static,
        F: FnMut(Arc<T>) -> Fut + Send + 'static,
        Fut: Future<Output = ()> + Send + 'static,
    {
        let owner = Arc::downgrade(owner);
        let job = move || {
            let run = owner.upgrade().map(&mut job);
            async move {
                if let Some(run) = run {
                    run.await;
                }
            }
        };
        self.add(spec, job, start)
    }

    /// The registered jobs' names, in registration order; none before
    /// [`Maintenance::start`].
    pub async fn jobs(&self) -> Vec<&'static str> {
        let Some(running) = self.running.get() else { return Vec::new() };
        let (reply, answer) = oneshot::channel();
        if running.adapter.send(Message::Jobs(reply)).is_err() {
            return Vec::new();
        }
        answer.await.unwrap_or_default()
    }
}

/// This install's grid phase: the number kept in `path`, or a new random one
/// written there. A file that cannot be read or written still yields a
/// random phase for this process.
pub fn install_phase(path: &Path) -> u64 {
    if let Some(phase) =
        std::fs::read_to_string(path).ok().and_then(|text| text.trim().parse().ok())
    {
        return phase;
    }
    let mut bytes = [0u8; 8];
    if let Err(e) = getrandom::fill(&mut bytes) {
        tracing::warn!("maintenance: no random phase ({e}); jobs sit on the epoch's grid");
        return 0;
    }
    let phase = u64::from_le_bytes(bytes);
    if let Err(e) = std::fs::write(path, format!("{phase}\n")) {
        tracing::warn!("maintenance: the phase is not kept ({e}); it changes at the next start");
    }
    phase
}

struct Slot {
    spec: JobSpec,
    job: AsyncJob,
    run: Option<JoinHandle<()>>,
}

impl Slot {
    fn start(&mut self) {
        if self.run.as_ref().is_some_and(|run| !run.is_finished()) {
            tracing::debug!(job = self.spec.name, "maintenance: the last run is still going");
            return;
        }
        self.run = Some(tokio::spawn((self.job)()));
    }
}

/// The adapter task: owns every job, starts each when the clock says it is
/// due. Ends when every sender (the [`Running`] and the clock's jobs) is gone.
async fn adapt(mut inbox: mpsc::UnboundedReceiver<Message>) {
    let mut slots: BTreeMap<usize, Slot> = BTreeMap::new();
    while let Some(message) = inbox.recv().await {
        match message {
            Message::Add { slot, spec, job } => {
                slots.insert(slot, Slot { spec, job, run: None });
            }
            Message::Remove(slot) => {
                slots.remove(&slot);
            }
            Message::Due(slot) => {
                if let Some(slot) = slots.get_mut(&slot) {
                    slot.start();
                }
            }
            Message::Jobs(reply) => {
                let _ = reply.send(slots.values().map(|slot| slot.spec.name).collect());
            }
        }
    }
}

#[cfg(test)]
#[path = "maintenance_tests.rs"]
mod tests;
