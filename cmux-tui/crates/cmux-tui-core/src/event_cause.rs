//! Why a mux event happened, for scheduling only (plans/cmux-next/
//! chrome-parity/p06-scheduler.md, "Cause per envelope, not per variant").
//!
//! The request dispatcher enters an [`EventCauseScope`] derived from the
//! request's [`crate::request_origin::RequestOrigin`]; `Mux::emit` stamps the
//! current cause on the subscriber envelope. An emit outside every scope (PTY
//! output, an OSC title or status, hooks, reaps) is [`EventCause::Program`].
//! Work handed to another thread (the terminal work pool, the connection
//! dispatcher) captures the cause when it is queued and enters it where it
//! runs. This is Chromium's `base::ScopedSetTaskPriorityForCurrentThread`
//! (base/task/scoped_set_task_priority_for_current_thread.h): a scoped
//! thread-local the posting side reads, not a parameter on every call.
//!
//! The cause never decides what a caller may do: authorization reads the
//! request origin itself (server/origin_gate.rs, server/app_trust.rs).

use std::cell::Cell;

/// Echoed in `set-client-info`: the connection's `subscribe` events carry
/// `cause` (spec/events.md "Event cause"). Without it the lines are as
/// before, so strict decoders of the event schema never see the field.
pub(crate) const CAPABILITY: &str = "event-cause-v1";

/// Who set off an event, ordered by scheduling priority, lowest first. When
/// a subscriber coalesces two events into one it keeps the higher cause.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub(crate) enum EventCause {
    /// A request from an agent, a script, the CLI or a page.
    Automation,
    /// The daemon or a program on its own: terminal output, titles, hooks.
    #[default]
    Program,
    /// A request from the verified app, made for the person using it.
    Frontend,
}

thread_local! {
    static CURRENT: Cell<Option<EventCause>> = const { Cell::new(None) };
}

impl EventCause {
    /// The cause in force on this thread; [`Self::Program`] outside a scope.
    pub(crate) fn current() -> Self {
        CURRENT.with(Cell::get).unwrap_or_default()
    }

    /// The cause of two coalesced events: the higher one.
    pub(crate) fn merge(self, other: Self) -> Self {
        self.max(other)
    }

    /// `self` narrowed by a request's own claim: it may only lower the cause.
    pub(crate) fn narrowed_by(self, claim: Self) -> Self {
        self.min(claim)
    }

    /// The wire name (spec/events.md "Event cause"). `program` is never
    /// sent: a missing field means it.
    pub(crate) const fn wire_name(self) -> &'static str {
        match self {
            Self::Automation => "automation",
            Self::Program => "program",
            Self::Frontend => "frontend",
        }
    }
}

/// Makes `cause` this thread's cause until dropped, then restores the outer
/// one. Scopes nest; it is not `Send`, so it ends on the thread it began.
#[must_use = "the cause is in force only while the scope lives"]
pub(crate) struct EventCauseScope {
    previous: Option<EventCause>,
    _not_send: std::marker::PhantomData<*const ()>,
}

impl EventCauseScope {
    pub(crate) fn enter(cause: EventCause) -> Self {
        let previous = CURRENT.with(|current| current.replace(Some(cause)));
        Self { previous, _not_send: std::marker::PhantomData }
    }
}

impl Drop for EventCauseScope {
    fn drop(&mut self) {
        CURRENT.with(|current| current.set(self.previous));
    }
}
