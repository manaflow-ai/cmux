//! A session request the daemon forwards to a live agent (`Hub::forward_as`: `session/set_mode`,
//! `session/set_config_option`, `session/set_model`, and a fork's `session/fork`) as a
//! `cmux_bounded` machine. Its one waiting
//! state declares its bound and what ends it, so an agent that stays alive and never answers ends
//! the request with a named error instead of holding its caller, and the session's
//! `harness_use` read lock (which a fork's cancel writes), forever.
//!
//! The bound is the agent's start budget (`agentStartTimeoutMs`, 90 s by default): an agent that
//! has not answered a settings switch in the time it is given to start is not going to.

use cmux_bounded::{BoundedMachine, Wait};
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Phase {
    /// Written to the agent; its answer has not come.
    Asked { bound: Duration },
    /// The agent answered (a result or an error).
    Answered,
    /// The bound passed with no answer: the caller gets [`no_answer`].
    GaveUp,
}

#[derive(Debug)]
pub(crate) enum Event {
    Answered,
    GaveUp,
}

#[derive(Debug)]
pub(crate) struct ForwardWait(Phase);

impl ForwardWait {
    pub(crate) fn asked(bound: Duration) -> Self {
        Self(Phase::Asked { bound })
    }
}

impl BoundedMachine for ForwardWait {
    type State = Phase;
    type Event = Event;
    const NAME: &'static str = "acpmux.forward";

    fn wait(state: &Phase) -> Wait<Event> {
        match state {
            Phase::Asked { bound } => Wait::bounded(
                *bound,
                Event::GaveUp,
                "the agent answers a forwarded session request",
            ),
            Phase::Answered | Phase::GaveUp => Wait::Settled,
        }
    }

    fn step(&mut self, event: Event) {
        self.0 = match (&self.0, event) {
            (Phase::Asked { .. }, Event::Answered) => Phase::Answered,
            (Phase::Asked { .. }, Event::GaveUp) => Phase::GaveUp,
            (done @ (Phase::Answered | Phase::GaveUp), _) => done.clone(),
        };
    }

    fn state(&self) -> &Phase {
        &self.0
    }
}

/// The error a request the agent never answered ends with.
pub(crate) fn no_answer(m: &str, bound: Duration) -> crate::rpc::RpcError {
    crate::rpc::RpcError::internal(format!(
        "the agent did not answer {m} within {} s (agentStartTimeoutMs); the request was cancelled",
        bound.as_secs()
    ))
}

#[cfg(test)]
#[path = "forward_wait_tests.rs"]
mod tests;
