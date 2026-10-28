//! The cancelable channel and worker that carry machine updates to the app.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::Receiver;
use std::thread::JoinHandle;

use super::MachineUpdate;

/// A cancelable stream of provider-owned presentation snapshots.
pub struct MachineUpdateStream {
    /// `Some` until `into_parts` hands the parts out or `Drop` stops them.
    parts: Option<MachineUpdateStreamParts>,
    stop: Arc<AtomicBool>,
}

struct MachineUpdateStreamParts {
    receiver: Receiver<MachineUpdate>,
    worker: JoinHandle<()>,
}

impl MachineUpdateStream {
    pub fn new(
        receiver: Receiver<MachineUpdate>,
        stop: Arc<AtomicBool>,
        worker: JoinHandle<()>,
    ) -> Self {
        Self { parts: Some(MachineUpdateStreamParts { receiver, worker }), stop }
    }

    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: `parts` is set by `new` and taken only here (which consumes self) \
                  and in Drop (which runs after), so it is present"
    )]
    pub(crate) fn into_parts(
        mut self,
    ) -> (Receiver<MachineUpdate>, Arc<AtomicBool>, JoinHandle<()>) {
        let MachineUpdateStreamParts { receiver, worker } =
            self.parts.take().expect("machine update stream parts are present");
        (receiver, self.stop.clone(), worker)
    }

    pub(crate) fn stop_handle(&self) -> Arc<AtomicBool> {
        self.stop.clone()
    }
}

impl Drop for MachineUpdateStream {
    fn drop(&mut self) {
        if let Some(MachineUpdateStreamParts { receiver, worker }) = self.parts.take() {
            self.stop.store(true, Ordering::Release);
            // Drop the receiver before joining so a worker blocked on a full
            // bounded channel observes cancellation instead of deadlocking.
            drop(receiver);
            let _ = crate::blocking::thread::join(worker);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::machine::{MachineCapabilities, MachineSnapshot, MachineUiState};

    #[test]
    fn dropping_update_stream_cancels_and_joins_a_blocked_worker() {
        let update = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        sender.send(MachineUpdate::Ui(Box::new(update.clone()))).unwrap();
        let stop = Arc::new(AtomicBool::new(false));
        let exited = Arc::new(AtomicBool::new(false));
        let worker_exited = exited.clone();
        let worker = std::thread::spawn(move || {
            // This blocks until MachineUpdateStream drops its receiver.
            let _ = sender.send(MachineUpdate::Ui(Box::new(update)));
            worker_exited.store(true, Ordering::Release);
        });
        let stream = MachineUpdateStream::new(receiver, stop.clone(), worker);

        drop(stream);

        assert!(stop.load(Ordering::Acquire));
        assert!(exited.load(Ordering::Acquire));
    }

    #[test]
    fn update_stream_into_parts_hands_out_a_running_worker() {
        let update = MachineUiState::new(MachineSnapshot {
            machines: Vec::new(),
            active: None,
            capabilities: MachineCapabilities::default(),
        });
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let stop = Arc::new(AtomicBool::new(false));
        let worker = std::thread::spawn(move || {
            sender.send(MachineUpdate::Ui(Box::new(update))).unwrap();
        });
        let stream = MachineUpdateStream::new(receiver, stop.clone(), worker);

        let (receiver, parts_stop, worker) = stream.into_parts();

        assert!(!stop.load(Ordering::Acquire), "into_parts must not stop the worker");
        assert!(Arc::ptr_eq(&stop, &parts_stop));
        assert!(matches!(receiver.recv(), Ok(MachineUpdate::Ui(_))));
        worker.join().unwrap();
    }
}
