//! The person before automation across connections
//! (plans/cmux-next/chrome-parity/p05-ipc.md section 3.4, task p05-ipc-143).
//!
//! A connection is classified once its hello window closes
//! (connection_qos.rs): the verified app's connections are the person's,
//! the CLI, MCP, hooks, agents, scripts, page relays and remote devices are
//! automation. That class decides, for each request, who goes first where
//! connections compete:
//!
//! - **Pool workers** (sequenced_pool.rs). A connection's control sequence
//!   carries its [`RequestClass`]. A worker takes a ready person sequence
//!   before an automation one, and after [`PERSON_STREAK_BOUND`] person
//!   tasks taken while automation waited it takes one automation task, so
//!   automation keeps a bounded share. Automation holds at most the
//!   priority's worker count; while it holds any worker, a person sequence
//!   that finds every worker busy starts one more
//!   ([`PERSON_HEADROOM_WORKERS`]), so a person request never waits behind
//!   an automation storm for a worker. This is Chromium's thread group:
//!   `TaskPriority::USER_BLOCKING` work runs before `BEST_EFFORT` work,
//!   which runs on at most `max_best_effort_tasks` workers so foreground
//!   work always finds one (base/task/thread_pool/thread_group.cc
//!   `CanRunPolicy`, base/task/thread_pool/priority_queue.cc).
//! - **Worker permits** (worker_admission.rs). Resource stream and wait
//!   permits and clear-history workers are taken without waiting, so person
//!   first means a share automation cannot take: automation holds at most
//!   [`automation_capacity`] of a server cap, the person all of it.
//! - **The registry lock.** The workspace registry, its connection and the
//!   mux state lock admit a waiting frontend caller first with a starvation
//!   bound (priority_gate.rs), keyed on the request's cause, which the
//!   person's requests carry as `frontend`.
//!
//! The pool and the permits order by class under the default-off daemon
//! feature [`FEATURE`] (schemas/features/features.d/daemonPersonFirst.json);
//! with it off every request is the person's, as before. Scheduling only:
//! authorization reads the request origin (server/origin_gate.rs).

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};

use super::connection_scheduler::connection_qos::{ConnectionClass, ConnectionClassCell};

/// The registry name of the feature that orders requests by class.
pub(crate) const FEATURE: &str = "daemonPersonFirst";

/// Whether connections registered from now on order their requests by
/// class; one per client registry.
#[derive(Debug, Default)]
pub(crate) struct PersonFirstGate(AtomicBool);

impl PersonFirstGate {
    /// From `CMUX_ENABLE_FEATURES` and `CMUX_DISABLE_FEATURES` (disable
    /// wins); the registry default is off on every channel.
    pub(crate) fn from_env() -> Self {
        Self(AtomicBool::new(cmux_features::listed_in_env(FEATURE)))
    }

    pub(crate) fn enabled(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }

    #[cfg(test)]
    pub(crate) fn set_for_test(&self, enabled: bool) {
        self.0.store(enabled, Ordering::Relaxed);
    }
}

/// While automation waits, a pool priority takes at most this many person
/// tasks in a row before one automation task.
pub(crate) const PERSON_STREAK_BOUND: usize = 4;

/// The workers a pool priority may start past its count for person work
/// while automation holds some of its workers.
pub(crate) const PERSON_HEADROOM_WORKERS: usize = 1;

/// One server permit in this many is the person's alone
/// ([`person_reserve`]).
const PERSON_RESERVE_DIVISOR: usize = 8;

/// Whom a request serves, for scheduling across connections.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub(crate) enum RequestClass {
    /// The verified app's connections, and work no connection owns.
    #[default]
    Person,
    /// The CLI, MCP, hooks, agents, scripts, page relays and remote devices.
    Automation,
}

impl RequestClass {
    /// The class of a request on a connection of class `class`. A
    /// connection not classed yet is the person's: it is classed before
    /// its first request runs (`ReaderClass::before_line`), so only a
    /// connection no registry record holds stays unclassified.
    pub(in crate::server) const fn of_connection(class: ConnectionClass) -> Self {
        match class {
            ConnectionClass::Automation => Self::Automation,
            ConnectionClass::Person | ConnectionClass::Unclassified => Self::Person,
        }
    }

    /// The class of a request on the connection of `cell`: its connection's
    /// class with [`FEATURE`] on, the person's with it off.
    pub(in crate::server) fn of_cell(cell: &ConnectionClassCell) -> Self {
        if cell.person_first() { Self::of_connection(cell.get()) } else { Self::Person }
    }
}

/// The permits of a server cap of `capacity` only the person may take: one
/// in [`PERSON_RESERVE_DIVISOR`], rounded up, and none of a cap of one.
pub(crate) const fn person_reserve(capacity: usize) -> usize {
    if capacity < 2 { 0 } else { capacity.div_ceil(PERSON_RESERVE_DIVISOR) }
}

/// The most of a server cap of `capacity` automation may hold.
pub(crate) const fn automation_capacity(capacity: usize) -> usize {
    capacity - person_reserve(capacity)
}

/// Whether `class` may take one more of a server cap of `capacity` that has
/// `active` taken, `automation_active` of them by automation.
pub(crate) const fn admits(
    class: RequestClass,
    capacity: usize,
    active: usize,
    automation_active: usize,
) -> bool {
    if active >= capacity {
        return false;
    }
    match class {
        RequestClass::Person => true,
        RequestClass::Automation => automation_active < automation_capacity(capacity),
    }
}

/// One pool priority's ready sequences by class, with the starvation bound.
#[derive(Debug, Default)]
pub(crate) struct ClassedReady {
    person: VecDeque<u64>,
    automation: VecDeque<u64>,
    /// Person sequences taken in a row while automation waited.
    streak: usize,
}

impl ClassedReady {
    pub(crate) fn push_back(&mut self, class: RequestClass, id: u64) {
        self.queue(class).push_back(id);
    }

    /// Takes sequence `id` out (it waits in `class`'s queue); false when it
    /// is not there.
    pub(crate) fn remove(&mut self, class: RequestClass, id: u64) -> bool {
        let queue = self.queue(class);
        match queue.iter().rposition(|queued| *queued == id) {
            Some(position) => {
                queue.remove(position);
                true
            }
            None => false,
        }
    }

    /// The next sequence to run and its class: a person sequence unless
    /// [`PERSON_STREAK_BOUND`] of them ran in a row while automation waited,
    /// and an automation one only while `automation_may_run`.
    pub(crate) fn pop(&mut self, automation_may_run: bool) -> Option<(u64, RequestClass)> {
        let automation_waits = automation_may_run && !self.automation.is_empty();
        if (!automation_waits || self.streak < PERSON_STREAK_BOUND)
            && let Some(id) = self.person.pop_front()
        {
            self.streak = if automation_waits { self.streak + 1 } else { 0 };
            return Some((id, RequestClass::Person));
        }
        if !automation_may_run {
            return None;
        }
        let id = self.automation.pop_front()?;
        self.streak = 0;
        Some((id, RequestClass::Automation))
    }

    /// Ready sequences a worker may take now: every person one, and the
    /// automation ones up to `automation_room` more running.
    pub(crate) fn runnable(&self, automation_room: usize) -> usize {
        self.person.len() + self.automation.len().min(automation_room)
    }

    pub(crate) fn has_person(&self) -> bool {
        !self.person.is_empty()
    }

    pub(crate) fn has_automation(&self) -> bool {
        !self.automation.is_empty()
    }

    pub(crate) fn clear(&mut self) {
        self.person.clear();
        self.automation.clear();
        self.streak = 0;
    }

    fn queue(&mut self, class: RequestClass) -> &mut VecDeque<u64> {
        match class {
            RequestClass::Person => &mut self.person,
            RequestClass::Automation => &mut self.automation,
        }
    }
}

#[cfg(test)]
#[path = "request_priority_class_tests.rs"]
mod tests;
