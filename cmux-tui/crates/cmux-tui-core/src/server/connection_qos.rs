//! A connection's client class and the class its threads rest at
//! (p02-threads task 224).
//!
//! Chromium sets a child process's priority from what it is, never from
//! what it says: the browser classes each renderer by its role and
//! visibility (content/browser/renderer_host/render_process_host_impl.cc
//! `UpdateProcessPriority`) and a utility process runs at kUtility
//! (base/threading/platform_thread_apple.mm `ThreadTypeToQoSClass`). A daemon
//! connection gets its class the same way, once what it is becomes known:
//!
//! - when its hello window closes (its first line that is not `identify` or
//!   `client-hello`), because no later line can change its origin
//!   (request_origin.rs);
//! - after every `set-client-info` and `client.metadata.update`, because
//!   `remote: true` makes it a remote device's lane.
//!
//! The verified app's connection ([`ConnectionClass::Person`]) keeps its
//! reader and request threads at user-initiated. The CLI, MCP, hooks,
//! agents, scripts, page relays and remote devices
//! ([`ConnectionClass::Automation`]) rest at utility. The class follows the
//! derived origin, as the request cause does (`RequestOrigin::event_cause`):
//! a `set-client-info` `kind` is a label and never raises a connection.
//!
//! A connection thread reads its class at one point of its loop
//! ([`RestingClass::follow`]): the reader before each line it routes, the
//! dispatcher before each request it runs. The class is entered as a
//! [`WorkQos`], so a thread resting at utility is raised while it waits for
//! or holds a ranked lock (`cmux_tui_platform::qos::LockBoost`), and a
//! request's own class (`crate::request_qos`) nests inside it. The
//! connection's writer stays at the echo class: producers that wait on its
//! queue (backpressured streams) must not wait behind a utility thread.
//!
//! Threads follow the class only under the default-off daemon feature
//! `daemonRequestQos` (crate::request_qos); the class itself is always
//! recorded.

use std::sync::Arc;
use std::sync::atomic::{AtomicU8, Ordering};

use cmux_threads::ThreadQos;
use cmux_tui_platform::qos::WorkQos;

use crate::request_origin::RequestOrigin;
use crate::request_qos::RequestQos;
use crate::server::ClientTransport;
use crate::thread_qos::ThreadType;

/// Who a connection serves, which sets the class its threads rest at.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub(in crate::server) enum ConnectionClass {
    /// Not known yet: its hello window is open and no `set-client-info`
    /// came. Its threads keep the class they started at.
    #[default]
    Unclassified = 0,
    /// The verified app's connection: the person waits on it.
    Person = 1,
    /// The CLI, MCP, hooks, agents, scripts, page relays and remote devices.
    Automation = 2,
}

impl ConnectionClass {
    /// The class of a connection over `transport` whose origin derives to
    /// `origin`; `remote_device` is `set-client-info remote: true`.
    pub(in crate::server) fn of(
        transport: ClientTransport,
        remote_device: bool,
        origin: RequestOrigin,
    ) -> Self {
        if remote_device || matches!(transport, ClientTransport::Remote) {
            return Self::Automation;
        }
        match origin {
            RequestOrigin::User => Self::Person,
            RequestOrigin::Page | RequestOrigin::Agent | RequestOrigin::App => Self::Automation,
        }
    }

    /// The class a connection thread in `role` rests at.
    pub(in crate::server) const fn qos(self, role: ConnectionThread) -> ThreadQos {
        match (self, role) {
            (Self::Unclassified, ConnectionThread::Reader) => {
                crate::server::line_connection::CONNECTION_READER_QOS
            }
            (Self::Unclassified, ConnectionThread::Request) => super::REQUEST_THREAD_QOS,
            (Self::Person, _) => ThreadType::Interactive.qos(),
            (Self::Automation, _) => ThreadType::Utility.qos(),
        }
    }

    const fn from_u8(raw: u8) -> Self {
        match raw {
            1 => Self::Person,
            2 => Self::Automation,
            _ => Self::Unclassified,
        }
    }
}

/// What a connection thread does for its connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::server) enum ConnectionThread {
    /// Reads and routes its lines (mux-conn, mux-remote-conn, mux-ws-conn).
    Reader,
    /// Runs its queued requests (mux-control-dispatch, mux-surface-control).
    Request,
}

/// One connection's class, shared by its registry record (which sets it)
/// and its threads (which follow it). Advisory: a thread that reads an old
/// value takes the new one at its next follow point.
#[derive(Debug, Default)]
pub(in crate::server) struct ConnectionClassCell(AtomicU8);

impl ConnectionClassCell {
    pub(in crate::server) fn get(&self) -> ConnectionClass {
        ConnectionClass::from_u8(self.0.load(Ordering::Relaxed))
    }

    pub(in crate::server) fn set(&self, class: ConnectionClass) {
        self.0.store(class as u8, Ordering::Relaxed);
    }
}

/// The class one connection thread rests at, followed from its connection's
/// [`ConnectionClassCell`]. Not `Send`: it lives on the thread it changes.
pub(in crate::server) struct RestingClass {
    cell: Arc<ConnectionClassCell>,
    role: ConnectionThread,
    enabled: bool,
    applied: ConnectionClass,
    /// Dropped before the next class is entered: scopes nest.
    scope: Option<WorkQos>,
}

impl RestingClass {
    pub(in crate::server) fn new(
        cell: Arc<ConnectionClassCell>,
        role: ConnectionThread,
        gate: RequestQos,
    ) -> Self {
        Self {
            cell,
            role,
            enabled: gate.enabled(),
            applied: ConnectionClass::Unclassified,
            scope: None,
        }
    }

    /// Runs this thread at its connection's class when that changed since
    /// the last call: one relaxed load otherwise. Call it outside every
    /// request and lock scope. The thread's registry row asks for the class
    /// (`desired`) and shows it as `effective` once applied; a class the
    /// process could not take back is not entered (`WorkQos::enter`).
    pub(in crate::server) fn follow(&mut self) {
        if !self.enabled {
            return;
        }
        let class = self.cell.get();
        if class == self.applied {
            return;
        }
        self.applied = class;
        self.scope = None;
        if class == ConnectionClass::Unclassified {
            return;
        }
        let qos = class.qos(self.role);
        if let Some(slot) = cmux_threads::current_slot() {
            slot.request(qos);
        }
        self.scope = Some(WorkQos::enter(qos));
    }

    /// The class this thread last followed.
    #[cfg(test)]
    pub(in crate::server) fn applied(&self) -> ConnectionClass {
        self.applied
    }
}

/// A reader's class: the connection is classified once its hello window
/// closes, then the reader follows it before each line it routes.
pub(in crate::server) struct ReaderClass {
    resting: RestingClass,
    classified_at_hello: bool,
}

impl ReaderClass {
    pub(in crate::server) fn new(cell: Arc<ConnectionClassCell>, gate: RequestQos) -> Self {
        Self {
            resting: RestingClass::new(cell, ConnectionThread::Reader, gate),
            classified_at_hello: false,
        }
    }

    /// Before routing a line: classifies `client` the first time this is
    /// called with its hello window closed, then follows the class.
    pub(in crate::server) fn before_line(
        &mut self,
        mux: &crate::Mux,
        client: u64,
        hello_closed: bool,
    ) {
        if hello_closed && !self.classified_at_hello {
            self.classified_at_hello = true;
            mux.control_clients.classify_connection(client);
        }
        self.resting.follow();
    }
}

#[cfg(test)]
#[path = "connection_qos_tests.rs"]
mod tests;
