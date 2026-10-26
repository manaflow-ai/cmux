//! A request's cause and QoS class, entered together (p06-scheduler-035).
//!
//! Every place that runs a request on a thread enters a [`CauseScope`]: the
//! connection reader, the dispatcher and its workers, an `origin` claim that
//! narrows the cause, and the threads that run automation outside a frame
//! (app and script routers, script jobs, agent starts, creation jobs). The
//! thread then runs at the class of the cause it is in
//! ([`EventCause::request_qos`]); a lowered thread is raised before it waits
//! for a lock and while it holds one (`crate::lock_rank`).
//!
//! The classes are behind the default-off daemon feature
//! [`FEATURE`] (schemas/features/features.d/daemonRequestQos.json). With it
//! off a scope enters only the cause, as before.

use std::sync::atomic::{AtomicBool, Ordering};

use cmux_tui_platform::qos::WorkQos;

use crate::event_cause::{EventCause, EventCauseScope};

/// The registry name of the feature that turns request classes on.
pub(crate) const FEATURE: &str = "daemonRequestQos";

/// Whether requests run at their cause's class; one per mux, read with
/// one relaxed load per request.
#[derive(Debug, Default)]
pub(crate) struct RequestQosGate(AtomicBool);

impl RequestQosGate {
    /// From `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` (disable
    /// wins), the lists `cmux_features::Snapshot::from_env` reads; the
    /// registry default is off on every channel.
    pub(crate) fn from_env() -> Self {
        let list = |name: &str| std::env::var(name).ok();
        Self::from_lists(
            list(cmux_features::ENABLE_ENV).as_deref(),
            list(cmux_features::DISABLE_ENV).as_deref(),
        )
    }

    fn from_lists(enable: Option<&str>, disable: Option<&str>) -> Self {
        let names = |list: Option<&str>| {
            list.is_some_and(|list| list.split(',').any(|name| name.trim() == FEATURE))
        };
        Self(AtomicBool::new(names(enable) && !names(disable)))
    }

    pub(crate) fn snapshot(&self) -> RequestQos {
        RequestQos { enabled: self.0.load(Ordering::Relaxed) }
    }

    #[cfg(test)]
    pub(crate) fn set_for_test(&self, enabled: bool) {
        self.0.store(enabled, Ordering::Relaxed);
    }
}

/// The gate's value, carried to a thread that runs a request later.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct RequestQos {
    enabled: bool,
}

impl RequestQos {
    /// Makes `cause` this thread's cause and, with the feature on, its class
    /// ([`EventCause::request_qos`]) until the scope drops.
    pub(crate) fn enter(self, cause: EventCause) -> CauseScope {
        let cause_scope = EventCauseScope::enter(cause);
        let class = if self.enabled { cause.request_qos() } else { None };
        #[cfg(test)]
        if let Some(class) = class {
            tests::note_entered(class);
        }
        CauseScope { _qos: class.map(WorkQos::enter), _cause: cause_scope }
    }
}

/// A request's cause and class on this thread. The class drops first, then
/// the cause.
#[must_use = "the cause and class hold only while the scope lives"]
pub(crate) struct CauseScope {
    _qos: Option<WorkQos>,
    _cause: EventCauseScope,
}

#[cfg(test)]
#[path = "request_qos_tests.rs"]
pub(crate) mod tests;
