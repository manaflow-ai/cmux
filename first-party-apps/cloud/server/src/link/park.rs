//! Ops that need a link never block the serve loop. When an op (a connect,
//! a port forward, a browser route, a file transfer) needs a link that is
//! still connecting, the link's `connect` parks it: the op answers nothing
//! yet, and the loop runs it again (same request, same key) when that link
//! generation is up or ended. Its result line then goes out before the
//! link line of the same change. Only the loop thread runs, parks and
//! re-runs ops; nothing here waits.

use super::ops::{LINK_UNAVAILABLE, link_failure};
use crate::api::{CloudError, ControlPlane, Request};
use crate::ops::Server;
use serde_json::Value;

/// The internal answer of a parked op. It never reaches the host.
pub(crate) const LINK_WAIT: &str = "cmux.cloud.internal.link_wait";

/// Ops the loop keeps parked at most; more answer `link_unavailable`
/// (retryable) instead of queueing.
const MAX_PARKED: usize = 64;

/// An op waiting for link `generation` of `machine`.
pub(crate) struct Parked {
    id: Value,
    request: Request,
    machine: String,
    generation: u64,
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
        let outcome = self.handle(request);
        self.park_or_answer(id, request, outcome)
    }

    fn park_or_answer(
        &mut self,
        id: &Value,
        request: &Request,
        outcome: Result<Value, CloudError>,
    ) -> Option<Result<Value, CloudError>> {
        let parked = self.attach_mut().parked.take();
        match (outcome, parked) {
            (Err(error), Some((machine, generation))) if error.code == LINK_WAIT => {
                let attach = self.attach_mut();
                if attach.parked_ops.len() >= MAX_PARKED {
                    return Some(Err(CloudError {
                        retryable: true,
                        ..CloudError::new(LINK_UNAVAILABLE, "too many ops wait for their links")
                    }));
                }
                attach.parked_ops.push(Parked {
                    id: id.clone(),
                    request: request.clone(),
                    machine,
                    generation,
                });
                None
            }
            (Err(error), _) if error.code == LINK_WAIT => Some(Err(CloudError {
                retryable: true,
                ..CloudError::new(LINK_UNAVAILABLE, "the link is connecting")
            })),
            (outcome, _) => Some(outcome),
        }
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
        for mut op in parked {
            let supervisor = &self.attach().supervisor;
            if let Some(newer) = supervisor.connecting(&op.machine)
                && newer != op.generation
            {
                op.generation = newer;
            }
            match self.attach().supervisor.outcome(&op.machine, op.generation) {
                None => self.attach_mut().parked_ops.push(op),
                Some(Ok(_)) => {
                    // The link is up: run the op again; it finds the carrier.
                    let outcome = self.handle(&op.request);
                    if let Some(answer) = self.park_or_answer(&op.id, &op.request, outcome) {
                        settled.push((op.id, answer));
                    }
                }
                Some(Err(failure)) => settled.push((op.id, Err(link_failure(failure)))),
            }
        }
        settled
    }
}
