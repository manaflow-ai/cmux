//! File jobs (coordinator MUST-FIX 2026-10-04): in the serve loop each
//! `cloud.fs.*` op runs its daemon work on its own worker, so a slow op
//! never holds the loop or another op. At most [`MAX_FILE_OPS`] run; one
//! more answers `file_ops_busy` (retryable) at once, as does a second op
//! with the key of one that still runs. The op's result line goes out when
//! its worker ends (the worker wakes the loop). When the host's input ends
//! (the client went away), every running job is cancelled: its dial child
//! is ended through the job's [`Cancel`]. Direct callers (tests, the fs
//! provider) run the work inline.

use super::link_files::Daemon;
use super::{Cancel, FILE_OPS_BUSY, MAX_FILE_OPS};
use crate::api::{CloudError, ControlPlane};
use crate::link::LinkWake;
use crate::ops::Server;
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::mpsc::{Receiver, Sender, channel};

/// The daemon work of one file op.
pub(crate) type Work = Box<dyn FnOnce(&Daemon) -> Result<Value, CloudError> + Send>;

/// The internal answer of an op handed to a worker. It never reaches the
/// host: the serve loop starts the job instead (crate::link::park).
pub(crate) const FILE_WAIT: &str = "cmux.cloud.internal.file_wait";

struct Pending {
    daemon: Daemon,
    key: Option<String>,
    work: Work,
}

struct Running {
    op_id: Value,
    key: Option<String>,
    cancel: Cancel,
}

/// One ended job: the op line id, its idempotency key and its answer.
pub(crate) type Done = (Value, Option<String>, Result<Value, CloudError>);

pub(crate) struct FileJobs {
    pending: Option<Pending>,
    running: BTreeMap<u64, Running>,
    next: u64,
    sender: Sender<(u64, Result<Value, CloudError>)>,
    receiver: Receiver<(u64, Result<Value, CloudError>)>,
    wake: Option<LinkWake>,
}

impl Default for FileJobs {
    fn default() -> Self {
        let (sender, receiver) = channel();
        Self { pending: None, running: BTreeMap::new(), next: 0, sender, receiver, wake: None }
    }
}

fn busy(message: &str) -> CloudError {
    CloudError { retryable: true, ..CloudError::new(FILE_OPS_BUSY, message.to_owned()) }
}

impl FileJobs {
    /// Wakes the serve loop when a job ends.
    pub(crate) fn set_wake(&mut self, wake: LinkWake) {
        self.wake = Some(wake);
    }

    /// Runs `op_id`'s pending work on a worker. `Err`: no worker (the op
    /// answers that error).
    pub(crate) fn start(&mut self, op_id: Value) -> Result<(), CloudError> {
        let Some(Pending { daemon, key, work }) = self.pending.take() else {
            return Err(CloudError::new(FILE_WAIT, "no pending file op"));
        };
        self.next += 1;
        let job = self.next;
        let cancel = daemon.cancel.clone();
        let done = self.sender.clone();
        let wake = self.wake.clone();
        std::thread::Builder::new()
            .name("cmux-cloud-file-op".into())
            .spawn(move || {
                let result = work(&daemon);
                // A closed channel means the server is gone: nothing waits.
                if done.send((job, result)).is_ok()
                    && let Some(wake) = wake
                {
                    wake();
                }
            })
            .map_err(|e| busy(&format!("no worker for the file op: {e}")))?;
        self.running.insert(job, Running { op_id, key, cancel });
        Ok(())
    }

    /// Jobs whose worker ended, in the order they ended. Never blocks.
    pub(crate) fn take_done(&mut self) -> Vec<Done> {
        let mut done = Vec::new();
        while let Ok((job, result)) = self.receiver.try_recv() {
            if let Some(running) = self.running.remove(&job) {
                done.push((running.op_id, running.key, result));
            }
        }
        done
    }

    /// Cancels every running job (the client went away).
    pub(crate) fn cancel_all(&mut self) {
        for running in self.running.values() {
            running.cancel.cancel();
        }
    }
}

impl Drop for FileJobs {
    fn drop(&mut self) {
        self.cancel_all();
    }
}

/// Runs `work` for one file op: on a worker in the serve loop (the op
/// answers later), inline for direct callers.
pub(crate) fn submit<C: ControlPlane>(
    server: &mut Server<C>,
    daemon: Daemon,
    key: Option<&str>,
    work: Work,
) -> Result<Value, CloudError> {
    if !server.attach().park_link_waits {
        return work(&daemon);
    }
    let jobs = &mut server.edge_parts().0.file_jobs;
    if jobs.running.len() >= MAX_FILE_OPS {
        return Err(busy("Other file ops are running: try again when one ends"));
    }
    if key.is_some() && jobs.running.values().any(|r| r.key.as_deref() == key) {
        return Err(busy("The same file op is still running"));
    }
    jobs.pending = Some(Pending { daemon, key: key.map(str::to_owned), work });
    Err(CloudError::new(FILE_WAIT, "the file op runs on a worker"))
}
