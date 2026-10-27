//! `terminal-async-start-v1` (p05-ipc-130, plans/cmux-next/chrome-parity/p05-ipc.md 3.6):
//! a `create-terminal` that sets `async_start` and names its `terminal_id`
//! replies once admitted, with `starting: true`, instead of after its host
//! launched. The start (reservation, launch, topology, projection) then runs
//! on the terminal work pool, and the requesting connection gets
//! `terminal-started` with the placement the reply would have carried, or
//! `terminal-start-failed` with the create's `mutation_id`, so the client
//! rolls back exactly the intent it admitted.
//!
//! Chrome starts a renderer the same way: `RenderProcessHostImpl::Init`
//! returns at once, messages to the process queue on its channel until it
//! runs, and the launch reports later through `ChildProcessLauncher::Client`
//! (`OnProcessLaunched` / `OnProcessLaunchFailed`,
//! content/browser/child_process_launcher.h).
//!
//! Ordering. The handler cannot start the work itself: a fast start could
//! send its event before the reply. It leaves a [`TerminalStart`] in the
//! [`StartsAfterReply`] scope that the creation commit (server/terminal_create.rs)
//! holds around the request; the commit submits it once the reply is queued
//! on the connection's writer, so the event always follows the reply. The
//! starts of one connection run in request order. A later create of the same
//! connection without `async_start` does not wait for them, so it may commit
//! first. A request outside that scope (another transport, a batch) creates
//! synchronously, as without the feature.
//!
//! Input sent to the terminal id while it starts is queued
//! (`terminal-input-while-creating-v1`) and written once it runs, or given
//! back when the start fails.

use std::cell::RefCell;
use std::marker::PhantomData;

use super::*;
use crate::event_cause::EventCause;
use crate::workspace_registry::TerminalLifecycle;

/// `terminal-async-start-v1`; advertised while the daemon feature
/// `terminalAsyncStart` is on.
pub(super) const TERMINAL_ASYNC_START_CAPABILITY: &str = "terminal-async-start-v1";

/// The work a create left for after its reply.
type StartWork = Box<dyn FnOnce() -> anyhow::Result<Value> + Send>;

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

    /// The admission reply: the `TerminalPlacement` shape with no placement
    /// yet, `lifecycle: "launching"` and `starting: true`.
    pub(super) fn admitted_reply(
        &self,
        workspace: WorkspaceId,
        (registry_id, generation): (String, String),
    ) -> anyhow::Result<Value> {
        Ok(json!({
            "surface": null,
            "terminal_id": self.terminal_id,
            "terminal_incarnation": null,
            "pane": null,
            "screen": null,
            "workspace": workspace,
            "key": self.key,
            "lifecycle": TerminalLifecycle::Launching,
            "exit": null,
            "already_exited": false,
            "terminal_revision": self.mux.terminal_registry_revision()?,
            "replayed": false,
            "registry_id": registry_id,
            "generation": generation,
            "starting": true,
        }))
    }

    /// Start the terminal, end its input queue and tell the connection.
    fn run(mut self, writer: &MessageWriter) {
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
/// terminal work pool, one at a time.
#[derive(Default)]
pub(super) struct ConnectionStarts {
    queue: VecDeque<TerminalStart>,
    /// A pool job is draining `queue`.
    running: bool,
}

impl ConnectionStarts {
    /// Queue `starts`; true when the caller must start a drain.
    pub(super) fn push(&mut self, starts: Vec<TerminalStart>) -> bool {
        self.queue.extend(starts);
        if self.running || self.queue.is_empty() {
            return false;
        }
        self.running = true;
        true
    }

    /// The next start, or `None` with the drain ended.
    pub(super) fn next(&mut self) -> Option<TerminalStart> {
        let start = self.queue.pop_front();
        if start.is_none() {
            self.running = false;
        }
        start
    }
}

/// Run one start on the drain's thread.
pub(super) fn run_start(start: TerminalStart, writer: &MessageWriter) {
    start.run(writer);
}
