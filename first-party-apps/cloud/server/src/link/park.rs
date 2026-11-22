//! Ops that need a link never block the serve loop. When an op (a connect,
//! a port forward, a browser route, a file transfer) needs a link that is
//! still connecting, the link's `connect` parks it: the op answers nothing
//! yet, and the loop runs it again (same request, same key) when that link
//! generation is up or ended. Its result line then goes out before the
//! link line of the same change. Only the loop thread runs, parks and
//! re-runs ops; nothing here waits.
//!
//! An op whose machine does not run yet (a new machine binding, a paused one
//! starting) parks the same way until it runs: it runs again when the
//! projection shows the machine running (a team `cloud.machine.upsert`, or
//! another op's answer), or when its next read is due ([`read_delay`]). Each
//! read is one `connect_info` of that machine, never a list; after
//! [`MAX_READS`] it answers the machine-starting error. A machine whose
//! state the host pushes (`cloud.machine.state`, crate::api::events) wakes
//! its op on the push; its reads are only a fallback, every
//! [`PUSHED_READ_DELAY`], at most [`MAX_PUSHED_READS`].
//!
//! A paused machine's start that fails (`cloud.machine.start`, which Resume
//! and the app's Reconnect run, or the start inside a connect) parks the same way when the
//! refusal is transient (a 503 or 502): the op runs again after its backoff
//! wait, until it succeeds or the waits reach the bound; a final refusal (a
//! 404) answers at once and is never retried. The rule and its bound are
//! crate::ops::start_retry.

use super::ops::{LINK_UNAVAILABLE, link_failure_for, starting};
use crate::api::{CloudError, ControlPlane, Request};
use crate::clock::Timer;
use crate::ops::Server;
use crate::ops::start_retry::{self, Tries};
use cmux_cloud_wire::CloudMachineStatus;
use serde_json::Value;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// The internal answer of a parked op. It never reaches the host.
pub(crate) const LINK_WAIT: &str = "cmux.cloud.internal.link_wait";

/// The internal answer of an op parked until its machine runs. It never
/// reaches the host.
pub(crate) const MACHINE_WAIT: &str = "cmux.cloud.internal.machine_wait";

/// Reads of a starting machine before its op gives up: about 95 s of
/// pauses, inside the app's 120 s bound on a connect
/// (`CloudAppLinks.connectTimeout`), so the answer reaches it.
pub(crate) const MAX_READS: u32 = 45;

/// The fallback read of a pushed machine: the push wakes the op first.
pub(crate) const PUSHED_READ_DELAY: Duration = Duration::from_secs(10);

/// Fallback reads of a pushed machine before its op gives up: about 90 s,
/// the same bound as [`MAX_READS`].
pub(crate) const MAX_PUSHED_READS: u32 = 9;

/// The wait before read `attempt` (from 1): 1 s for the first 20 reads, then
/// 3 s; [`PUSHED_READ_DELAY`] for a machine whose state is pushed.
pub(crate) fn read_delay(attempt: u32, pushed: bool) -> Duration {
    if pushed {
        return PUSHED_READ_DELAY;
    }
    Duration::from_secs(if attempt <= 20 { 1 } else { 3 })
}

/// Ops the loop keeps parked at most; more answer `link_unavailable`
/// (retryable) instead of queueing.
const MAX_PARKED: usize = 64;

/// An op waiting for link `generation` of `machine`, or for `machine` to
/// run.
pub(crate) struct Parked {
    id: Value,
    request: Request,
    machine: String,
    wait: Wait,
}

enum Wait {
    Link {
        generation: u64,
    },
    /// Read `attempt` is due when `due` is set (by `_timer`; dropping the
    /// op cancels it).
    Running {
        attempt: u32,
        due: Arc<AtomicBool>,
        _timer: Timer,
    },
    /// A start that failed transiently runs again when `due` is set (by
    /// `_timer`, after its backoff wait; dropping the op cancels it).
    Start {
        tries: Tries,
        due: Arc<AtomicBool>,
        _timer: Timer,
    },
}

/// A flag set by a timer of `clock` after `delay`; the timer wakes the loop.
fn due_after<C: ControlPlane>(server: &mut Server<C>, delay: Duration) -> (Arc<AtomicBool>, Timer) {
    let due = Arc::new(AtomicBool::new(false));
    let attach = server.attach_mut();
    let (fired, wake) = (Arc::clone(&due), attach.wake.clone());
    let timer = attach.wait_clock.after(
        delay,
        Box::new(move || {
            fired.store(true, Ordering::Release);
            if let Some(wake) = wake {
                wake();
            }
        }),
    );
    (due, timer)
}

/// The machine of `request` when it is a start (`cloud.machine.start` or an
/// alias such as `vm.resume`).
fn start_machine(request: &Request) -> Option<String> {
    if crate::ops::canonical_name(&request.op) != Some("cloud.machine.start") {
        return None;
    }
    request.args["machine"].as_str().map(str::to_owned)
}

impl<C: ControlPlane> Server<C> {
    /// The serve loop's form of [`Server::handle`]. `None`: the op is
    /// parked and its answer comes later from [`Server::take_settled`].
    pub(crate) fn handle_from_loop(
        &mut self,
        request: &Request,
        id: &Value,
    ) -> Option<Result<Value, CloudError>> {
        self.attach_mut().park_link_waits = true;
        let outcome = self.run_once(request);
        self.park_or_answer(id, request, outcome, 0, Tries::default())
    }

    /// One run of a loop op, with no note left from an earlier one.
    fn run_once(&mut self, request: &Request) -> Result<Value, CloudError> {
        self.attach_mut().start_failed = None;
        self.handle(request)
    }

    /// `reads`: the reads of a starting machine this op already made;
    /// `tries`: the transient start failures it already waited out.
    fn park_or_answer(
        &mut self,
        id: &Value,
        request: &Request,
        outcome: Result<Value, CloudError>,
        reads: u32,
        tries: Tries,
    ) -> Option<Result<Value, CloudError>> {
        let parked = self.attach_mut().parked.take();
        let parked_machine = self.attach_mut().parked_machine.take();
        // A start that failed: the op's own (`cloud.machine.start`) or the
        // one inside its connect. Bad args never reached the backend.
        let start_failed = self.attach_mut().start_failed.take().or_else(|| {
            outcome
                .as_ref()
                .err()
                .filter(|e| e.code != crate::api::codes::INVALID_ARGS)
                .and_then(|_| start_machine(request))
        });
        let outcome = match (outcome, start_failed) {
            (Err(error), Some(machine)) if start_retry::transient(&error) => {
                let Some((tries, wait)) = start_retry::next(tries) else {
                    return Some(Err(start_retry::stopped(&machine, error, tries)));
                };
                if self.attach().parked_ops.len() >= MAX_PARKED {
                    return Some(Err(start_retry::stopped(&machine, error, tries)));
                }
                let (due, timer) = due_after(self, wait);
                self.attach_mut().parked_ops.push(Parked {
                    id: id.clone(),
                    request: request.clone(),
                    machine,
                    wait: Wait::Start { tries, due, _timer: timer },
                });
                return None;
            }
            (Err(error), Some(machine)) => {
                Err(start_retry::refused(&machine, error, self.projection()))
            }
            (outcome, _) => outcome,
        };
        let full = self.attach().parked_ops.len() >= MAX_PARKED;
        let too_many = || {
            Some(Err(CloudError {
                retryable: true,
                ..CloudError::new(LINK_UNAVAILABLE, "too many ops wait for their links")
            }))
        };
        match (outcome, parked) {
            (Err(error), Some((machine, generation))) if error.code == LINK_WAIT => {
                if full {
                    return too_many();
                }
                self.attach_mut().parked_ops.push(Parked {
                    id: id.clone(),
                    request: request.clone(),
                    machine,
                    wait: Wait::Link { generation },
                });
                None
            }
            (Err(error), _) if error.code == MACHINE_WAIT => {
                let pushed =
                    parked_machine.as_deref().is_some_and(|m| self.projection().is_pushed(m));
                let max = if pushed { MAX_PUSHED_READS } else { MAX_READS };
                let Some(machine) = parked_machine.filter(|_| reads < max) else {
                    return Some(Err(starting()));
                };
                if full {
                    return too_many();
                }
                let attempt = reads + 1;
                let (due, timer) = due_after(self, read_delay(attempt, pushed));
                self.attach_mut().parked_ops.push(Parked {
                    id: id.clone(),
                    request: request.clone(),
                    machine,
                    wait: Wait::Running { attempt, due, _timer: timer },
                });
                None
            }
            (Err(error), _) if error.code == crate::fs::jobs::FILE_WAIT => {
                // A file op: its worker answers later (take_settled).
                self.edge_parts().0.file_jobs.start(id.clone()).err().map(Err)
            }
            (Err(error), _) if error.code == LINK_WAIT => Some(Err(CloudError {
                retryable: true,
                ..CloudError::new(LINK_UNAVAILABLE, "the link is connecting")
            })),
            (outcome, _) => Some(outcome),
        }
    }

    /// Drops the parked op of op line `id`; `false` when none waits.
    pub(crate) fn cancel_parked(&mut self, id: &Value) -> bool {
        let parked = &mut self.attach_mut().parked_ops;
        let before = parked.len();
        parked.retain(|op| &op.id != id);
        parked.len() != before
    }

    /// Answers of parked ops whose link is now up or ended, in the order
    /// they came. Applies the link process events first (the one drain).
    /// A link that was replaced by a newer connecting generation (a
    /// link-details respawn) is followed, not failed.
    pub(crate) fn take_settled(&mut self) -> Vec<(Value, Result<Value, CloudError>)> {
        let attach = self.attach_mut();
        attach.drain_link_events();
        let parked = std::mem::take(&mut attach.parked_ops);
        let mut settled = Vec::new();
        // File ops whose worker ended: their result, and the key's ledger row.
        for (id, key, outcome) in self.edge_parts().0.file_jobs.take_done() {
            self.settle_key(key.as_deref(), &outcome);
            settled.push((id, outcome));
        }
        for mut op in parked {
            if let Wait::Running { attempt, due, .. } = &op.wait {
                let (reads, due) = (*attempt, due.load(Ordering::Acquire));
                let runs = self
                    .projection()
                    .get(&op.machine)
                    .is_some_and(|m| m.record.status == CloudMachineStatus::Running);
                if !runs && !due {
                    self.attach_mut().parked_ops.push(op);
                    continue;
                }
                // It runs, or the next read is due: run the op again with a
                // fresh read of the machine's link facts.
                self.attach_mut().infos.forget(&op.machine);
                let outcome = self.run_once(&op.request);
                if let Some(answer) =
                    self.park_or_answer(&op.id, &op.request, outcome, reads, Tries::default())
                {
                    settled.push((op.id, answer));
                }
                continue;
            }
            if let Wait::Start { tries, due, .. } = &op.wait {
                if !due.load(Ordering::Acquire) {
                    self.attach_mut().parked_ops.push(op);
                    continue;
                }
                // The backoff wait passed: the same request again (the
                // same key for the op's own start), with fresh link facts.
                let tries = *tries;
                self.attach_mut().infos.forget(&op.machine);
                let outcome = self.run_once(&op.request);
                if let Some(answer) = self.park_or_answer(&op.id, &op.request, outcome, 0, tries) {
                    settled.push((op.id, answer));
                }
                continue;
            }
            let Wait::Link { generation } = &mut op.wait else { continue };
            let supervisor = &self.attach().supervisor;
            if let Some(newer) = supervisor.connecting(&op.machine)
                && newer != *generation
            {
                *generation = newer;
            }
            match self.attach().supervisor.outcome(&op.machine, *generation) {
                None => self.attach_mut().parked_ops.push(op),
                Some(Ok(_)) => {
                    // The link is up: run the op again; it finds the carrier.
                    let outcome = self.run_once(&op.request);
                    if let Some(answer) =
                        self.park_or_answer(&op.id, &op.request, outcome, 0, Tries::default())
                    {
                        settled.push((op.id, answer));
                    }
                }
                Some(Err(failure)) => {
                    settled.push((op.id, Err(link_failure_for(&op.machine, failure))));
                }
            }
        }
        settled
    }
}
