//! The thread that starts workers on Linux, where a thread starts at its creator's nice value.

use std::io;
use std::sync::Arc;
use std::sync::mpsc::Sender;

use super::delayed::{self, DelayShared};
use super::{LaneShared, WorkConfig, WorkerClass};
use crate::qos::{LiveQos, ThreadQos};

/// Whether a thread the calling thread starts can run at `qos`. On Linux a new thread starts at its
/// creator's nice value, and an unprivileged thread cannot lower it.
pub(super) fn can_start_at(qos: ThreadQos) -> bool {
    match crate::qos::current() {
        LiveQos::Nice(nice) => nice <= qos.linux_nice(),
        _ => true,
    }
}

/// A thread the launcher starts.
pub(super) enum Launch {
    /// One worker of `lane`, counted live and idle already.
    Worker { lane: Arc<LaneShared>, class: WorkerClass },
    /// The `<label>-delay` service thread of the delayed items (`work_delayed.rs`).
    Delay { shared: Arc<DelayShared>, config: Arc<WorkConfig> },
}

impl Launch {
    /// Starts the thread on the calling thread.
    pub(super) fn start(self) {
        match self {
            Launch::Worker { lane, class } => lane.spawn_worker(class),
            Launch::Delay { shared, config } => delayed::start_thread(&shared, &config),
        }
    }
}

/// The thread that starts the threads a thread above their nice value may not start (see
/// [`can_start_at`]). It keeps the nice value of the thread that built the [`Work`], waits for
/// requests with no timeout, and exits once every lane and the delayed items are gone.
pub(super) struct Launcher {
    pub(super) requests: Sender<Launch>,
}

impl Launcher {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    pub(super) fn start(config: &WorkConfig) -> io::Result<Option<Launcher>> {
        let (requests, inbox) = std::sync::mpsc::channel::<Launch>();
        config.spawner.spawn(
            format!("{}-launch", config.label),
            ThreadQos::UserInitiated,
            Box::new(move || {
                for launch in inbox {
                    launch.start();
                }
            }),
        )?;
        Ok(Some(Launcher { requests }))
    }

    /// macOS sets a thread's QoS class absolutely, so any thread may start any worker.
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    pub(super) fn start(_config: &WorkConfig) -> io::Result<Option<Launcher>> {
        Ok(None)
    }
}
