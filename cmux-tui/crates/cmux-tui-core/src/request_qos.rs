//! A request's cause and QoS class, entered together.
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
        Self(AtomicBool::new(cmux_features::listed_in_env(FEATURE)))
    }

    #[cfg(test)]
    fn from_lists(enable: Option<&str>, disable: Option<&str>) -> Self {
        Self(AtomicBool::new(cmux_features::listed(FEATURE, enable, disable)))
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
    /// Whether the feature is on: requests and connection threads
    /// (server/connection_qos.rs) change class.
    pub(crate) const fn enabled(self) -> bool {
        self.enabled
    }

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

    /// With the feature on, runs this thread at `class` until the scope
    /// drops, as a request of that class: a daemon thread's work that no
    /// request waits on (the journal writer between receipts).
    pub(crate) fn enter_class(self, class: cmux_threads::ThreadQos) -> Option<WorkQos> {
        #[cfg(test)]
        if self.enabled {
            tests::note_entered(class);
        }
        self.enabled.then(|| WorkQos::enter(class))
    }

    /// One pass of a daemon upkeep thread (output store writer, journal
    /// retention and maintenance) at [`UPKEEP_PASS_QOS`], with the feature
    /// on. The thread is declared at [`UPKEEP_THREAD_QOS`] and lowered per
    /// pass as a [`WorkQos`], so a ranked lock the pass holds (a terminal
    /// slot a PTY reader waits for, the workspace registry a request waits
    /// for) raises it to `LOCK_HOLDER_QOS` until it is released
    /// (`crate::lock_rank`), as it raises a thread declared utility.
    pub(crate) fn enter_upkeep_pass(self) -> Option<WorkQos> {
        self.enter_class(UPKEEP_PASS_QOS)
    }

    /// Starts one-shot thread `name` to finish the request running on the
    /// calling thread (an agent call, a Chief query, a URL open: its reply
    /// waits on the thread). It starts at [`REQUEST_HELPER_QOS`], the
    /// dispatcher's class, never at the class it would inherit (the echo
    /// class of a person's reader), and with the feature on runs at the
    /// class of the request's cause, as Chromium posts a task with the
    /// priority of the work it serves (base/task/task_traits.h). It runs
    /// under the process's supervisor with the
    /// platform's default stack.
    pub(crate) fn spawn_helper<F, T>(
        self,
        name: &str,
        f: F,
    ) -> std::io::Result<crate::supervised::SupervisedThread<T>>
    where
        F: FnOnce() -> T + Send + 'static,
        T: Send + 'static,
    {
        let class = if self.enabled { EventCause::current().request_qos() } else { None };
        let body = move || {
            let _class = class.map(WorkQos::enter);
            f()
        };
        crate::supervised::spawn_at(
            name,
            REQUEST_HELPER_QOS,
            crate::supervised::Fatal,
            crate::supervised::ShutdownBehavior::Continue,
            body,
        )
    }
}

/// The class a request's one-shot helper thread starts at
/// ([`RequestQos::spawn_helper`]): the request dispatcher's.
pub(crate) const REQUEST_HELPER_QOS: cmux_threads::ThreadQos =
    crate::thread_qos::ThreadType::Interactive.qos();

/// The class a daemon upkeep thread is started at
/// ([`RequestQos::enter_upkeep_pass`]).
pub(crate) const UPKEEP_THREAD_QOS: cmux_threads::ThreadQos = cmux_threads::ThreadQos::Default;

/// The class of one upkeep pass with the feature on.
pub(crate) const UPKEEP_PASS_QOS: cmux_threads::ThreadQos = cmux_threads::ThreadQos::Utility;

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
