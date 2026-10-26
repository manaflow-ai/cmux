//! The thread that starts workers on Linux, where a thread starts at its creator's nice value.

use std::io;
use std::sync::Arc;
use std::sync::mpsc::Sender;

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

pub(super) struct Launch {
    pub(super) lane: Arc<LaneShared>,
    pub(super) class: WorkerClass,
}

/// The thread that starts the workers a thread above their nice value may not start (see
/// [`can_start_at`]). It keeps the nice value of the thread that built the [`Work`], waits for
/// requests with no timeout, and exits once every lane is gone.
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
                for Launch { lane, class } in inbox {
                    lane.spawn_worker(class);
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
