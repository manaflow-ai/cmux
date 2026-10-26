//! acpmux's periodic upkeep on one [`MaintenanceClock`] (p14-energy-034).
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
//! Energy Saver: [`Maintenance::energy`] is this process's mode. The control
//! channel's `_acpmux/energy` (`energy_control.rs`) flips it, and the clock
//! runs each job registered `skippable_in_saver` at 4 times its period.

use std::collections::BTreeMap;
use std::future::Future;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};

use futures::future::BoxFuture;
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use cmux_wake::MaintenanceClock;
pub use cmux_wake::{EnergyMode, JobSpec, RegisterError};

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

    /// Starts the clock thread and the adapter task, once; call in the
    /// daemon's runtime. A second call does nothing.
    pub fn start(&self) -> std::io::Result<()> {
        if self.running.get().is_some() {
            return Ok(());
        }
        let clock = MaintenanceClock::start(&self.energy)?;
        let (adapter, inbox) = mpsc::unbounded_channel();
        tokio::spawn(adapt(inbox));
        // A racing start loses its clock here; its adapter ends with its sender.
        let _ = self.running.set(Running { clock, adapter, next_slot: AtomicUsize::new(0) });
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
        let registered = running.clock.register(spec, move || {
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
