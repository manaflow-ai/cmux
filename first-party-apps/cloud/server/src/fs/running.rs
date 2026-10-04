//! Running file transfers: the copy runs on its own worker thread, off the
//! op loop. The op answers at once with a transfer id; the worker sends
//! one completion through a channel and wakes the loop, and the loop (the
//! only writer of transfer state) finishes the transfer: it closes the
//! one-shot route, publishes a pull, and queues a
//! `cloud.file.transfer.changed` event. At most [`MAX_TRANSFERS`] run at
//! once; more are refused (retryable), nothing queues.
//! `cloud.file.transfer.cancel` kills the worker's children through the
//! transfer's [`Cancel`]; the loop finishes it like any other end, with
//! state `cancelled`, and removes a pull's partial file.

use super::cancel::Cancel;
use super::key::TransferKey;
use super::transfer::{
    Direction, TRANSFER_CANCELLED, TRANSFER_FAILED, Transfer, TransferError, TransferJob,
};
use crate::api::{CloudError, codes};
use crate::clock::{Clock, SystemClock};
use crate::link::LinkWake;
use crate::ports::listener::Listener;
use serde_json::{Value, json};
use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};

/// Transfers that may run at once.
pub const MAX_TRANSFERS: usize = 4;
/// Every transfer slot is taken: retry when one ends.
pub const TRANSFER_BUSY: &str = "cmux.cloud.transfer_busy";

/// How one transfer ended.
#[derive(Debug, Clone, PartialEq)]
pub struct TransferEvent {
    pub transfer: String,
    pub machine: String,
    pub direction: Direction,
    /// The guest path.
    pub path: String,
    pub local_path: PathBuf,
    /// Bytes copied, or the typed failure.
    pub outcome: Result<u64, CloudError>,
}

/// What the loop keeps of a running transfer until it ends.
pub(crate) struct Running {
    pub(crate) machine: String,
    pub(crate) direction: Direction,
    pub(crate) guest: String,
    /// The user's local path (a pull is published here).
    pub(crate) local: PathBuf,
    /// Where scp writes (a pull's hidden name; a push's own file).
    pub(crate) landing: PathBuf,
    /// The one-shot listener to the guest's SSH port; closed at the end.
    pub(crate) route: Listener,
    /// Shared with the worker: a cancel kills its children.
    pub(crate) cancel: Cancel,
    /// Epoch milliseconds by the transfers' clock (set by `start`).
    pub(crate) started_at: u64,
}

/// Finished transfers `cloud.file.transfer.list` keeps at most.
pub const HISTORY_ENTRIES: usize = 32;
/// Finished transfers older than this (by the injected clock) are not
/// listed. Pruned when the history is read or written; no timer.
pub const HISTORY_MAX_AGE_MS: u64 = 60 * 60 * 1000;

/// One finished transfer in the history.
struct Finished {
    event: TransferEvent,
    started_at: u64,
    ended_at: u64,
}

/// What `cloud.file.transfer.cancel` found.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum CancelAnswer {
    /// It was running: it is being stopped; one `cancelled` event follows.
    Cancelling,
    /// It had already ended: the cancel changes nothing. Its own end event
    /// (`done` or `failed`) goes out after this answer when the loop had not
    /// sent it yet; no `cancelled` event follows.
    Ended,
}

/// The number of a `transfer-<n>` id (ids this server issued).
fn sequence(id: &str) -> u64 {
    id.strip_prefix("transfer-").and_then(|n| n.parse().ok()).unwrap_or(u64::MAX)
}

fn direction(direction: Direction) -> &'static str {
    match direction {
        Direction::Push => "push",
        Direction::Pull => "pull",
    }
}

impl Drop for Transfers {
    /// The server stops with transfers running: each copy is killed and a
    /// pull's hidden landing file is removed, so no partial file stays next
    /// to the user's target. No end event goes out (the channel is gone).
    fn drop(&mut self) {
        // Transfers whose worker already ended are finished first, so a
        // completed pull is published, not removed.
        self.settle();
        for running in self.running.values_mut() {
            running.cancel.cancel();
            running.route.close();
            if running.direction == Direction::Pull {
                let _ = std::fs::remove_file(&running.landing);
            }
        }
    }
}

struct Done {
    id: String,
    result: Result<u64, TransferError>,
}

pub(crate) struct Transfers {
    running: BTreeMap<String, Running>,
    sender: Sender<Done>,
    receiver: Receiver<Done>,
    wake: Option<LinkWake>,
    next: u64,
    events: Vec<TransferEvent>,
    /// Finished transfers, oldest end first (at most [`HISTORY_ENTRIES`]).
    history: VecDeque<Finished>,
    clock: Arc<dyn Clock>,
}

impl Transfers {
    pub(crate) fn new() -> Self {
        let (sender, receiver) = channel();
        Self {
            running: BTreeMap::new(),
            sender,
            receiver,
            wake: None,
            next: 0,
            events: Vec::new(),
            history: VecDeque::new(),
            clock: Arc::new(SystemClock),
        }
    }

    /// The time source of `started_at`, `ended_at` and the history bound.
    pub(crate) fn set_clock(&mut self, clock: Arc<dyn Clock>) {
        self.clock = clock;
    }

    /// `cloud.file.transfer.list`: running transfers (oldest start first),
    /// then finished ones (newest end first). Reads only; prunes old entries.
    pub(crate) fn list(&mut self) -> Vec<Value> {
        self.settle();
        self.prune();
        let mut running: Vec<(u64, &String, &Running)> =
            self.running.iter().map(|(id, r)| (sequence(id), id, r)).collect();
        running.sort_by_key(|(n, _, _)| *n);
        let mut out: Vec<Value> = running
            .into_iter()
            .map(|(_, id, r)| {
                json!({ "transfer": id, "machine": r.machine, "direction": direction(r.direction),
                    "state": "running", "started_at": r.started_at })
            })
            .collect();
        for done in self.history.iter().rev() {
            let mut entry = json!({ "transfer": done.event.transfer,
                "machine": done.event.machine, "direction": direction(done.event.direction),
                "started_at": done.started_at, "ended_at": done.ended_at });
            match &done.event.outcome {
                Ok(_) => entry["state"] = json!("done"),
                Err(e) if e.code == TRANSFER_CANCELLED => entry["state"] = json!("cancelled"),
                Err(e) => {
                    // Code and retryable only: the message can hold local
                    // paths and scp output, and this read is on MCP.
                    entry["state"] = json!("failed");
                    entry["error"] = json!({ "code": e.code, "retryable": e.retryable });
                }
            }
            out.push(entry);
        }
        out
    }

    /// Drops finished entries older than [`HISTORY_MAX_AGE_MS`].
    fn prune(&mut self) {
        let now = self.clock.now_unix_ms();
        self.history.retain(|f| now.saturating_sub(f.ended_at) <= HISTORY_MAX_AGE_MS);
    }

    /// Wakes the serve loop after each completion.
    pub(crate) fn set_wake(&mut self, wake: LinkWake) {
        self.wake = Some(wake);
    }

    pub(crate) fn full(&self) -> bool {
        self.running.len() >= MAX_TRANSFERS
    }

    /// Starts the copy on a worker thread and returns its id. The worker
    /// owns the job and the key (dropped, and so wiped, when it ends) and
    /// sends exactly one completion.
    pub(crate) fn start(
        &mut self,
        transfer: Arc<dyn Transfer>,
        job: TransferJob,
        key: TransferKey,
        running: Running,
    ) -> Result<String, CloudError> {
        if self.full() {
            return Err(CloudError {
                retryable: true,
                ..CloudError::new(
                    TRANSFER_BUSY,
                    "Other file transfers are running: try again when one ends",
                )
            });
        }
        self.next += 1;
        let id = format!("transfer-{}", self.next);
        let done = self.sender.clone();
        let wake = self.wake.clone();
        let worker_id = id.clone();
        let cancel = running.cancel.clone();
        let spawned =
            std::thread::Builder::new().name("cmux-cloud-transfer".into()).spawn(move || {
                let result = transfer.run(&job, &key, &cancel);
                drop(key);
                // A closed channel means the server is gone: nothing waits.
                if done.send(Done { id: worker_id, result }).is_ok()
                    && let Some(wake) = wake
                {
                    wake();
                }
            });
        if let Err(e) = spawned {
            let mut running = running;
            running.route.close();
            if running.direction == Direction::Pull {
                let _ = std::fs::remove_file(&running.landing);
            }
            return Err(CloudError::new(TRANSFER_FAILED, format!("no transfer thread: {e}")));
        }
        let mut running = running;
        running.started_at = self.clock.now_unix_ms();
        self.running.insert(id.clone(), running);
        Ok(id)
    }

    /// `cloud.file.transfer.cancel`: stops a running transfer (its children
    /// are killed now; its one `cancelled` event comes when its worker has
    /// returned, so a pull's partial file is removed after the copy is
    /// dead). A transfer that already ended answers [`CancelAnswer::Ended`]
    /// and changes nothing. Never blocks.
    pub(crate) fn cancel(&mut self, id: &str) -> Result<CancelAnswer, CloudError> {
        // A worker that already ended is finished first: its real outcome
        // (a published pull, a done push) stands.
        self.settle();
        if let Some(running) = self.running.get_mut(id) {
            running.cancel.cancel();
            // The one-shot route closes now: scp's own ssh child loses its
            // connection at once, so the worker returns without waiting for
            // ssh's keepalive timeout. Closing again at the end is a no-op.
            running.route.close();
            return Ok(CancelAnswer::Cancelling);
        }
        let issued = id
            .strip_prefix("transfer-")
            .and_then(|n| n.parse::<u64>().ok())
            .is_some_and(|n| n >= 1 && n <= self.next && id == format!("transfer-{n}"));
        if issued {
            Ok(CancelAnswer::Ended)
        } else {
            Err(CloudError::new(
                codes::NOT_FOUND,
                format!("{id} is not a transfer of this cmux Cloud app server"),
            ))
        }
    }

    /// Finishes every transfer whose worker has ended. Never blocks.
    pub(crate) fn settle(&mut self) {
        while let Ok(done) = self.receiver.try_recv() {
            self.finish(done);
        }
    }

    /// Blocks until every running transfer has ended (embedders and tests;
    /// the serve loop never calls it).
    pub(crate) fn wait_all(&mut self) {
        self.settle();
        while !self.running.is_empty() {
            // The struct holds a sender, so this never disconnects; each
            // worker sends exactly one completion.
            match self.receiver.recv() {
                Ok(done) => self.finish(done),
                Err(_) => break,
            }
        }
    }

    pub(crate) fn take_events(&mut self) -> Vec<TransferEvent> {
        self.settle();
        std::mem::take(&mut self.events)
    }

    fn finish(&mut self, done: Done) {
        let Some(mut running) = self.running.remove(&done.id) else { return };
        running.route.close();
        // A cancel wins over the copy's own end, except for a push whose
        // copy had already finished: its bytes are on the machine.
        let cancelled = running.cancel.is_cancelled()
            && !(running.direction == Direction::Push && done.result.is_ok());
        let outcome = if cancelled {
            Err(CloudError::new(TRANSFER_CANCELLED, "The transfer was cancelled"))
        } else {
            // A pull is published with a hard link, which never overwrites
            // and never follows a symlink put at the target meanwhile.
            done.result
                .and_then(|bytes| match running.direction {
                    Direction::Push => Ok(bytes),
                    Direction::Pull => std::fs::hard_link(&running.landing, &running.local)
                        .map(|()| bytes)
                        .map_err(|e| TransferError {
                            message: format!("{}: {e}", running.local.display()),
                            retryable: false,
                        }),
                })
                .map_err(|e| CloudError {
                    retryable: e.retryable,
                    ..CloudError::new(TRANSFER_FAILED, e.message)
                })
        };
        // The worker has returned, so its copy is dead: a failed or
        // cancelled pull leaves nothing, and a retry can run.
        if running.direction == Direction::Pull {
            let _ = std::fs::remove_file(&running.landing);
        }
        let event = TransferEvent {
            transfer: done.id,
            machine: running.machine,
            direction: running.direction,
            path: running.guest,
            local_path: running.local,
            outcome,
        };
        self.history.push_back(Finished {
            event: event.clone(),
            started_at: running.started_at,
            ended_at: self.clock.now_unix_ms(),
        });
        while self.history.len() > HISTORY_ENTRIES {
            self.history.pop_front();
        }
        self.prune();
        self.events.push(event);
    }
}
