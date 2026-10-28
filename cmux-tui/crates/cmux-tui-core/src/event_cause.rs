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

/// Advertised by `identify`: a `cmux.protocol/2` request may carry
/// `priority` ([`RequestPriority`], spec/resource-api-v2.md "Request
/// priority").
pub(crate) const REQUEST_PRIORITY_CAPABILITY: &str = "request-priority-v1";

/// A request envelope's optional `priority` (p02-threads task 224): the
/// caller's own word on whom the request serves. Like an `origin` claim it
/// only narrows the cause the daemon derives from the connection, so a
/// client can run one request as automation and never raise one above its
/// connection. Scheduling only: authorization never reads it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RequestPriority {
    /// The person waits on it: the derived cause stands.
    User,
    /// Automation: it runs at the automation class (UTILITY).
    Automation,
}

impl RequestPriority {
    /// The cause this priority narrows a request's derived cause by.
    pub(crate) const fn event_cause(self) -> EventCause {
        match self {
            Self::User => EventCause::Frontend,
            Self::Automation => EventCause::Automation,
        }
    }
}

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

    /// The class a request with this cause runs at
    /// (`cmux_tui_platform::qos::WorkQos`): verified-app requests at
    /// USER_INITIATED, automation at UTILITY. `None` for program work: its
    /// thread keeps its own class.
    pub(crate) const fn request_qos(self) -> Option<cmux_threads::ThreadQos> {
        match self {
            Self::Frontend => Some(cmux_threads::ThreadQos::UserInitiated),
            Self::Automation => Some(cmux_threads::ThreadQos::Utility),
            Self::Program => None,
        }
    }

    /// The [`cmux_threads::work::Priority`] of a work item that serves a
    /// request with this cause, as Chrome posts a task at the priority of
    /// what it serves (base/task/task_traits.h): the app's requests are
    /// `UserBlocking`, the rest `UserVisible`. Both run at UserInitiated, the
    /// class of the request thread that posts them.
    pub(crate) const fn work_priority(self) -> cmux_threads::work::Priority {
        match self {
            Self::Frontend => cmux_threads::work::Priority::UserBlocking,
            Self::Automation | Self::Program => cmux_threads::work::Priority::UserVisible,
        }
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
