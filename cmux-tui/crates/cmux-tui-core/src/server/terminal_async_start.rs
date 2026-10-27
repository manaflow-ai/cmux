//! `terminal-async-start-v1` (p05-ipc-130, plans/cmux-next/chrome-parity/p05-ipc.md 3.6):
//! a `create-terminal` that sets `async_start` and names its own
//! `terminal_id`, `origin` and `mutation_id` replies once admitted, with
//! `starting: true`, instead of after its host launched.
//!
//! Admission runs before the reply (`Mux::admit_terminal_create`): the
//! replay and fingerprint check of the mutation, the
//! `expected_generation`/`expected_revision` CAS and the reservation of the
//! registry row. A refusal is the error reply; a retry of a create that
//! started replies as a synchronous retry does. Only the launch (host
//! start, topology, projection, activation) runs after the reply, on the
//! terminal work pool, and the requesting connection then gets
//! `terminal-started` with the placement the synchronous reply would have
//! carried, or `terminal-start-failed` with the create's `mutation_id`, so
//! the client rolls back exactly the intent it admitted.
//!
//! Chrome starts a renderer the same way: `RenderProcessHostImpl::Init`
//! returns at once, messages to the process queue on its channel until it
//! runs, and the launch reports later through `ChildProcessLauncher::Client`
//! (`OnProcessLaunched` / `OnProcessLaunchFailed`,
//! content/browser/child_process_launcher.h).
//!
//! Ordering. The handler cannot start the launch itself: a fast launch
//! could send its event before the reply. It leaves a [`TerminalStart`] in
//! the [`StartsAfterReply`] scope that the creation commit
//! (server/terminal_create.rs) holds around the request; the commit queues
//! it once the reply is queued, so the event always follows the reply. The
//! starts of one connection run in request order, and a later create of the
//! connection that is not admitted this way commits only after them, so the
//! tabs of a pane still land in request order. A request outside that
//! scope (another transport, a batch) creates synchronously.
//!
//! Input sent to the terminal id while it starts is queued
//! (`terminal-input-while-creating-v1`) and written once it runs, or given
//! back when the start fails. An `attach-surface` of the same connection
//! whose `expected_terminal_id` is the starting terminal's id waits for the
//! start and then attaches, so its first READY comes once the host is up.

use std::cell::RefCell;
use std::marker::PhantomData;

use super::*;
use crate::event_cause::EventCause;
use crate::terminal_host::TerminalId;
use crate::workspace_registry::TerminalLifecycle;

/// `terminal-async-start-v1`; advertised while the daemon feature
/// `terminalAsyncStart` is on.
pub(super) const TERMINAL_ASYNC_START_CAPABILITY: &str = "terminal-async-start-v1";

/// The work a create left for after its reply.
type StartWork = Box<dyn FnOnce() -> anyhow::Result<Value> + Send>;

/// Whether a `create-terminal` of `client` that asks for `async_start` is
/// admitted before its start: the feature, a local connection, the
/// client's own canonical `terminal_id` (the id the reply and the events
/// name, which input and attach may already address) and its own
/// `mutation_id` (the id `terminal-start-failed` rolls back by).
pub(super) fn eligible(
    mux: &Mux,
    client: u64,
    terminal_id: Option<&str>,
    mutation_id: Option<&str>,
) -> bool {
    let canonical = terminal_id
        .is_some_and(|id| TerminalId::from_hex(id).is_some_and(|parsed| parsed.to_hex() == id));
    canonical
        && mutation_id.is_some()
        && mux.terminal_async_start_enabled()
        && !mux.is_remote_client(client)
}

impl Command {
    /// The terminal id of a create that [`eligible`] admits before its
    /// start (the creation queue lets it pass the connection's starts).
    pub(super) fn async_start_terminal(&self, mux: &Mux, client: u64) -> Option<&str> {
        let Self::CreateTerminal {
            async_start: true, detached: false, terminal_id, mutation, ..
        } = self
        else {
            return None;
        };
        let terminal_id = terminal_id.as_deref();
        eligible(mux, client, terminal_id, mutation.mutation_id.as_deref())
            .then_some(terminal_id)
            .flatten()
    }

    /// The terminal id an `attach-surface` names by `expected_terminal_id`
    /// alone: one a start of this connection may own.
    pub(super) fn attach_terminal_id(&self) -> Option<&str> {
        match self {
            Self::AttachSurface(params) if params.surface.is_none() => {
                params.expected_terminal_id.as_deref()
            }
            _ => None,
        }
    }
}

/// The admission reply: the `TerminalPlacement` shape with no placement
/// yet, `lifecycle: "launching"` and `starting: true`.
pub(super) struct AdmittedReply<'a> {
    pub(super) terminal_id: &'a str,
    pub(super) key: &'a str,
    pub(super) workspace: WorkspaceId,
    pub(super) terminal_revision: u64,
    /// A retry of a create whose start has not reported.
    pub(super) replayed: bool,
    pub(super) identity: &'a (String, String),
}

impl AdmittedReply<'_> {
    pub(super) fn json(&self) -> Value {
        json!({
            "surface": null,
            "terminal_id": self.terminal_id,
            "terminal_incarnation": null,
            "pane": null,
            "screen": null,
            "workspace": self.workspace,
            "key": self.key,
            "lifecycle": TerminalLifecycle::Launching,
            "exit": null,
            "already_exited": false,
            "terminal_revision": self.terminal_revision,
            "replayed": self.replayed,
            "registry_id": self.identity.0,
            "generation": self.identity.1,
            "starting": true,
        })
    }
}

/// One admitted create whose terminal has not started yet.
pub(super) struct TerminalStart {
    mux: Arc<Mux>,
    /// The host terminal id (32 hex) the reply named.
    terminal_id: String,
    mutation_id: String,
    key: String,
    /// The request's cause, kept for the start's thread.
    cause: EventCause,
    /// This start's input queue (`Mux::begin_creating_input`), ended once.
    creating_input: Option<u64>,
    work: Option<StartWork>,
}

impl TerminalStart {
    pub(super) fn new(
        mux: &Arc<Mux>,
        terminal_id: String,
        mutation_id: String,
        key: String,
        work: StartWork,
    ) -> Self {
        let creating_input = mux.begin_creating_input(&terminal_id);
        Self {
            mux: mux.clone(),
            terminal_id,
            mutation_id,
            key,
            cause: EventCause::current(),
            creating_input,
            work: Some(work),
        }
    }

    /// The host terminal id the reply named.
    pub(super) fn terminal_id(&self) -> &str {
        &self.terminal_id
    }

    /// Start the terminal, end its input queue and tell the connection.
    pub(super) fn run(mut self, writer: &MessageWriter) {
        let Some(work) = self.work.take() else { return };
        let _cause = self.mux.request_qos().enter(self.cause);
        let result = work();
        self.end_creating_input(result.as_ref().err().map(|_| "failed"));
        let _ = writer.send_control(&self.outcome_event(result));
    }

    /// Run the start on this thread and return what a synchronous create
    /// replies: the request could not leave it for after its reply.
    pub(super) fn run_inline(mut self) -> anyhow::Result<Value> {
        let work = self.work.take().expect("an unrun start has its work");
        let result = work();
        self.end_creating_input(result.as_ref().err().map(|_| "failed"));
        result
    }

    fn outcome_event(&self, result: anyhow::Result<Value>) -> Value {
        match result {
            Ok(placement) => json!({
                "event": "terminal-started",
                "terminal_id": self.terminal_id,
                "mutation_id": self.mutation_id,
                "result": placement,
            }),
            Err(error) => json!({
                "event": "terminal-start-failed",
                "terminal_id": self.terminal_id,
                "mutation_id": self.mutation_id,
                "key": self.key,
                "error": error.to_string(),
                "error_code": response_error_code(&error),
            }),
        }
    }

    fn end_creating_input(&mut self, failure: Option<&str>) {
        if let Some(generation) = self.creating_input.take() {
            self.mux.finish_creating_input(&self.terminal_id, generation, failure);
        }
    }
}

impl Drop for TerminalStart {
    /// A start dropped unrun (its request unwound) gives queued input back.
    fn drop(&mut self) {
        self.end_creating_input(Some("cancelled"));
    }
}

thread_local! {
    /// The starts the request running on this thread left for after its
    /// reply; `None` outside a [`StartsAfterReply`] scope.
    static AFTER_REPLY: RefCell<Option<Vec<TerminalStart>>> = const { RefCell::new(None) };
}

/// The scope of one request whose reply is queued before its starts run.
/// Not `Send`: it is this thread's.
pub(super) struct StartsAfterReply {
    _thread: PhantomData<*const ()>,
}

impl StartsAfterReply {
    pub(super) fn enter() -> Self {
        AFTER_REPLY.with(|starts| *starts.borrow_mut() = Some(Vec::new()));
        Self { _thread: PhantomData }
    }

    /// The starts left in the scope, which ends.
    pub(super) fn take(self) -> Vec<TerminalStart> {
        AFTER_REPLY.with(|starts| starts.borrow_mut().take()).unwrap_or_default()
    }
}

impl Drop for StartsAfterReply {
    fn drop(&mut self) {
        // After `take` this is already `None`; on unwind it drops the
        // starts, which give their queued input back.
        let left = AFTER_REPLY.with(|starts| starts.borrow_mut().take());
        drop(left);
    }
}

/// Whether the request on this thread may leave a start for after its reply.
pub(super) fn can_defer() -> bool {
    AFTER_REPLY.with(|starts| starts.borrow().is_some())
}

/// Leave `start` for after the reply, or give it back outside a scope.
pub(super) fn defer(start: TerminalStart) -> Result<(), TerminalStart> {
    AFTER_REPLY.with(|starts| match starts.borrow_mut().as_mut() {
        Some(starts) => {
            starts.push(start);
            Ok(())
        }
        None => Err(start),
    })
}

/// The starts one connection admitted, run in request order on the
/// terminal work pool, one at a time, and the attaches waiting for them.
#[derive(Default)]
pub(super) struct ConnectionStarts {
    queue: VecDeque<TerminalStart>,
    /// A pool job is draining `queue`.
    running: bool,
    /// The terminal ids being admitted, queued or starting, with the
    /// attaches that wait for them.
    starting: HashMap<String, Vec<PendingSurfaceRequest>>,
}

impl ConnectionStarts {
    /// A create admitting `terminal_id` runs: an attach of it waits from now.
    pub(super) fn expect(&mut self, terminal_id: &str) {
        self.starting.entry(terminal_id.to_string()).or_default();
    }

    /// Queue `starts`; the attaches of an expected id that got no start
    /// (the create replied after its start, or failed) come back to run.
    /// The bool is true when the caller must start a drain.
    pub(super) fn push(
        &mut self,
        expected: Option<&str>,
        starts: Vec<TerminalStart>,
    ) -> (bool, Vec<PendingSurfaceRequest>) {
        let unstarted = expected
            .filter(|id| !starts.iter().any(|start| start.terminal_id == *id))
            .and_then(|id| self.starting.remove(id))
            .unwrap_or_default();
        for start in &starts {
            self.starting.entry(start.terminal_id.clone()).or_default();
        }
        self.queue.extend(starts);
        if self.running || self.queue.is_empty() {
            return (false, unstarted);
        }
        self.running = true;
        (true, unstarted)
    }

    /// The next start, or `None` with the drain ended.
    pub(super) fn next(&mut self) -> Option<TerminalStart> {
        let start = self.queue.pop_front();
        if start.is_none() {
            self.running = false;
        }
        start
    }

    /// The connection has starts that have not reported: a create that is
    /// not admitted before its start waits for them.
    pub(super) fn pending(&self) -> bool {
        self.running || !self.queue.is_empty()
    }

    /// Hold `pending`, an attach of a terminal this connection is starting,
    /// until that start reports; otherwise give it back.
    pub(super) fn park_attach(
        &mut self,
        pending: PendingSurfaceRequest,
    ) -> Option<PendingSurfaceRequest> {
        let waiters =
            pending.request.cmd.attach_terminal_id().and_then(|id| self.starting.get_mut(id));
        match waiters {
            Some(waiters) => {
                waiters.push(pending);
                None
            }
            None => Some(pending),
        }
    }

    /// The attaches that waited for `terminal_id`, which no longer starts.
    pub(super) fn started(&mut self, terminal_id: &str) -> Vec<PendingSurfaceRequest> {
        self.starting.remove(terminal_id).unwrap_or_default()
    }
}

/// The live surface of `terminal_id`, a host terminal id (32 hex), for an
/// `attach-surface` that names it by `expected_terminal_id` while the
/// feature is on.
pub(super) fn attach_by_host_id(
    mux: &Mux,
    terminal_id: Option<&str>,
) -> Option<Arc<crate::Surface>> {
    if !mux.terminal_async_start_enabled() {
        return None;
    }
    let terminal_id = TerminalId::from_hex(terminal_id?)?.to_hex();
    let surface = mux.resolve_terminal(&terminal_id).ok()??.surface?;
    mux.surface(surface)
}
