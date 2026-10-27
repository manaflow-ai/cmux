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
//! The person's connections ([`ConnectionClass::Person`]) rest at the echo
//! class on the reader (it reads the person's keys) and at user-initiated on
//! the dispatcher. They are the verified app's connection and the app's
//! other connections without a hello (`terminal_attach`, `journal_read`,
//! `agent_session_attach`, ...): the same process, by the kernel's peer
//! fact fixed at accept (`ConnectionOrigin::peer_key`), as a verified app
//! connection, as `origin.confirmation.issue` pairs a page relay with its
//! app. The CLI, MCP, hooks, agents, scripts, page relays and remote devices
//! ([`ConnectionClass::Automation`]) rest at utility. A connection not
//! classed yet rests at user-initiated. A `set-client-info` `kind` is a
//! label and never raises a connection. The class is for scheduling only:
//! authorization reads the request origin (server/origin_gate.rs).
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
    /// came. Its threads rest at user-initiated.
    #[default]
    Unclassified = 0,
    /// The verified app's connections: the person waits on them.
    Person = 1,
    /// The CLI, MCP, hooks, agents, scripts, page relays and remote devices.
    Automation = 2,
}

impl ConnectionClass {
    /// The class's name in `server-threads` (server/server_stats.rs).
    pub(in crate::server) const fn as_str(self) -> &'static str {
        match self {
            Self::Unclassified => "unclassified",
            Self::Person => "person",
            Self::Automation => "automation",
        }
    }

    /// The class of a connection over `transport` whose origin derives to
    /// `origin`; `remote_device` is `set-client-info remote: true`, and
    /// `app_process` says its peer is the process of a verified app
    /// connection (`ClientRegistryState::classify`).
    pub(in crate::server) fn of(
        transport: ClientTransport,
        remote_device: bool,
        origin: RequestOrigin,
        app_process: bool,
    ) -> Self {
        if remote_device || matches!(transport, ClientTransport::Remote) {
            return Self::Automation;
        }
        match origin {
            RequestOrigin::User => Self::Person,
            RequestOrigin::Agent if app_process => Self::Person,
            RequestOrigin::Page | RequestOrigin::Agent | RequestOrigin::App => Self::Automation,
        }
    }

    /// The class a connection thread in `role` rests at. A request's own
    /// class nests inside it: the person's reader runs a request at
    /// user-initiated and goes back to the echo class for its next read.
    pub(in crate::server) const fn qos(self, role: ConnectionThread) -> ThreadQos {
        match (self, role) {
            (Self::Person, ConnectionThread::Reader) => crate::echo_thread::ECHO_PATH_QOS,
            (Self::Unclassified | Self::Person, _) => ThreadType::Interactive.qos(),
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
pub(in crate::server) struct ConnectionClassCell {
    class: AtomicU8,
    /// The connection's client id; `None` for a cell no registry record
    /// holds.
    client: Option<u64>,
}

impl ConnectionClassCell {
    /// The cell of connection `client`'s registry record.
    pub(in crate::server) fn of_client(client: u64) -> Self {
        Self { class: AtomicU8::default(), client: Some(client) }
    }

    pub(in crate::server) fn get(&self) -> ConnectionClass {
        ConnectionClass::from_u8(self.class.load(Ordering::Relaxed))
    }

    pub(in crate::server) fn set(&self, class: ConnectionClass) {
        self.class.store(class as u8, Ordering::Relaxed);
    }
}

/// The class one connection thread rests at, followed from its connection's
/// [`ConnectionClassCell`]. Not `Send`: it lives on the thread it changes.
pub(in crate::server) struct RestingClass {
    cell: Arc<ConnectionClassCell>,
    role: ConnectionThread,
    enabled: bool,
    /// `None` before the first follow.
    applied: Option<ConnectionClass>,
    /// The thread's registry row names the connection (first follow).
    named: bool,
    /// Dropped before the next class is entered: scopes nest.
    scope: Option<WorkQos>,
}

impl RestingClass {
    pub(in crate::server) fn new(
        cell: Arc<ConnectionClassCell>,
        role: ConnectionThread,
        gate: RequestQos,
    ) -> Self {
        Self { cell, role, enabled: gate.enabled(), applied: None, named: false, scope: None }
    }

    /// Runs this thread at its connection's class when that changed since
    /// the last call: one relaxed load otherwise. Call it outside every
    /// request and lock scope. The thread's registry row asks for the class
    /// (`desired`) and shows it as `effective` once applied; a class the
    /// process could not take back is not entered (`WorkQos::enter`). The
    /// first call, feature on or off, names the connection on the row
    /// (`server-threads` `connection`), so the QoS audit can tell the
    /// person's connection threads from automation's.
    pub(in crate::server) fn follow(&mut self) {
        if !self.named {
            self.named = true;
            if let (Some(client), Some(slot)) = (self.cell.client, cmux_threads::current_slot()) {
                slot.work_for(client);
            }
        }
        if !self.enabled {
            return;
        }
        let class = self.cell.get();
        if self.applied == Some(class) {
            return;
        }
        self.applied = Some(class);
        self.scope = None;
        let qos = class.qos(self.role);
        if let Some(slot) = cmux_threads::current_slot() {
            slot.request(qos);
        }
        self.scope = Some(WorkQos::enter(qos));
    }

    /// The class this thread last followed; `None` with the feature off.
    #[cfg(test)]
    pub(in crate::server) fn applied(&self) -> Option<ConnectionClass> {
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
    /// Made on the reader thread before its first read, which it then waits
    /// for at the class of a connection not classed yet.
    pub(in crate::server) fn new(cell: Arc<ConnectionClassCell>, gate: RequestQos) -> Self {
        let mut resting = RestingClass::new(cell, ConnectionThread::Reader, gate);
        resting.follow();
        Self { resting, classified_at_hello: false }
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
