//! Terminal-creating requests run off the connection's dispatcher.
//!
//! A terminal create waits for its host to launch, which can take a large
//! fraction of a second. Run inline, a burst of creates on one connection
//! held every later request on that connection behind them and started the
//! hosts one at a time. Now the dispatcher hands each create to the owner's
//! bounded terminal work pool and moves on, so later requests on the
//! connection are answered meanwhile. A `new-tab` launches its host on the
//! pool in parallel with the other creates (`Mux::prelaunch_tab_terminal`).
//!
//! Creates of one connection still commit, and reply, in request order:
//! each create commits only after every earlier create of its connection
//! committed, so the tabs of a pane land in the order they were requested.
//! Other requests may be answered before an earlier create's reply.
//!
//! Splits are the exception that keeps the order (SPLIT BURST): a split
//! (`split`, `new-pane`) starts once every earlier create of its connection
//! that still runs is a split that has joined its creation group (`Mux::run_in_creation_group`). A burst of
//! Cmd-D splits on one connection then commits as one group, in request
//! order (the group runs its members in the order they joined), with one
//! projection write. Each create's reply still waits for the reply of the
//! create before it, so the replies and the receipts' revisions keep the
//! request order.

use super::*;
use crate::panic_free::RecoverPoison;
use std::collections::BTreeSet;
use std::sync::Condvar;

/// The creates of one connection, in request order.
#[derive(Default)]
pub(super) struct ConnectionCreations {
    state: Mutex<CreationQueue>,
    /// Signalled when [`CreationQueue::next_reply`] moves.
    replied: Condvar,
}

#[derive(Default)]
struct CreationQueue {
    slots: VecDeque<Arc<CreationSlot>>,
    /// The request-order number of the next slot submitted.
    next_seq: u64,
    /// Started slots that have not finished.
    running: usize,
    /// Started slots that hold the next start back: not a split, or a split
    /// that has not joined its creation group.
    running_unjoined: usize,
    /// The slot whose reply may go out now; later slots wait for it.
    next_reply: u64,
    /// Slots after `next_reply` that already ended.
    ended_early: BTreeSet<u64>,
}

struct CreationSlot {
    /// Its place in the connection's request order.
    seq: u64,
    /// A split: it may start beside earlier splits that joined their group.
    groupable: bool,
    request: Mutex<Option<PendingSurfaceRequest>>,
    /// `None` until the slot's launch step finished; then the terminal id of
    /// its prelaunched host, if it has one.
    launched: Mutex<Option<Option<String>>>,
    /// Debug timing marks of this create (`CMUX_TUI_DEBUG_SPANS`).
    trace: Mutex<Option<crate::debug_spans::Trace>>,
    /// The caller-minted terminal id whose input queue this creation owns, with its generation:
    /// creating from submit to commit (`terminal-input-while-creating-v1`, `mux::creating_input`).
    creating_terminal: Option<(String, u64)>,
}

impl Command {
    /// Commands that create a terminal and wait for its host to launch.
    pub(super) fn creates_terminal(&self) -> bool {
        matches!(
            self,
            Self::NewTab { .. }
                | Self::NewPane { .. }
                | Self::NewPaneRight { .. }
                | Self::Split { .. }
                | Self::NewScreen(_)
                | Self::NewWorkspace { .. }
                | Self::CreateTerminal { .. }
        )
    }
}

/// What a create can launch before its commit: the host of a `new-tab`,
/// under the terminal id the caller chose (`terminal-placement-env-v1`, as
/// the app always does) or a fresh one.
struct PrelaunchRequest {
    pane: Option<PaneId>,
    terminal_id: Option<crate::terminal_host::TerminalId>,
    cwd: Option<String>,
    /// The argv `shell_args` resolves to; the create adopts this host, so
    /// it must run the same program.
    argv: Option<Vec<String>>,
    env: Vec<(String, String)>,
    size: Option<(u16, u16)>,
}

impl PrelaunchRequest {
    fn of(command: &Command, frontend_shell: bool) -> Option<Self> {
        // A pane creation adopts the spare only with the new pane's size
        // (`split_kind::PanePrelaunch`).
        let pane_prelaunch = match command {
            Command::Split(params) => params.prelaunch(),
            Command::NewPaneRight(params) => params.prelaunch(),
            Command::NewPane { pane, cols, rows, cwd, env, terminal_id, shell_args, .. } => {
                optional_surface_size(*cols, *rows).map(|size| split_kind::PanePrelaunch {
                    pane: *pane,
                    terminal_id: terminal_id.as_ref(),
                    cwd: cwd.as_ref(),
                    env: env.as_ref(),
                    shell_args: shell_args.as_ref(),
                    size,
                })
            }
            _ => None,
        };
        if let Some(prelaunch) = pane_prelaunch {
            return Self::build(
                Some(prelaunch.pane),
                prelaunch.terminal_id,
                prelaunch.cwd,
                prelaunch.env,
                prelaunch.shell_args,
                Some(prelaunch.size),
                frontend_shell,
            );
        }
        let Command::NewTab { pane, cwd, env, cols, rows, terminal_id, shell_args, .. } = command
        else {
            return None;
        };
        Self::build(
            *pane,
            terminal_id.as_ref(),
            cwd.as_ref(),
            env.as_ref(),
            shell_args.as_ref(),
            optional_surface_size(*cols, *rows),
            frontend_shell,
        )
    }

    fn build(
        pane: Option<PaneId>,
        terminal_id: Option<&String>,
        cwd: Option<&String>,
        env: Option<&BTreeMap<String, String>>,
        shell_args: Option<&Vec<String>>,
        size: Option<(u16, u16)>,
        frontend_shell: bool,
    ) -> Option<Self> {
        // An invalid caller id is reported by the create itself.
        let terminal_id = match terminal_id {
            Some(hex) => Some(crate::terminal_host::TerminalId::from_hex(hex)?),
            None => None,
        };
        // An invalid environment is reported by the create itself.
        let mut env =
            env.map(crate::mux::validate_terminal_env).transpose().ok()?.unwrap_or_default();
        let argv = shell_argv(&env, shell_args.cloned(), frontend_shell);
        // The create adopts this host only with the same launch: mark it as
        // `placement_spawn_options` does.
        crate::login_shell::mark(&mut env, argv.as_deref());
        Some(Self { pane, terminal_id, cwd: cwd.cloned(), argv, env, size })
    }

    fn launch(self, mux: &Arc<Mux>) -> Option<String> {
        // A failed prelaunch falls back to the create's own launch, which
        // reports the failure through the usual creation error path.
        mux.prelaunch_tab_terminal(
            self.pane,
            self.terminal_id,
            self.cwd,
            self.argv,
            self.env,
            self.size,
        )
        .ok()
        .flatten()
    }
}

impl ConnectionSurfaceScheduler {
    /// Start `pending` (a create, see [`Command::creates_terminal`]) on the
    /// terminal work pool. Returns false when the connection must close.
    pub(super) fn submit_creation(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        pending: PendingSurfaceRequest,
        writer: &MessageWriter,
    ) -> bool {
        let prelaunch = PrelaunchRequest::of(&pending.request.cmd, frontend_shell(mux, client));
        let label = match (&pending.request.cmd, prelaunch.is_some()) {
            (Command::NewTab { .. }, true) => "new-tab",
            (_, true) => "pane-create",
            _ => "create",
        };
        let trace = crate::debug_spans::Trace::start(label, Instant::now());
        let creating_terminal = pending.request.cmd.created_terminal_id().and_then(|terminal_id| {
            mux.begin_creating_input(&terminal_id).map(|generation| (terminal_id, generation))
        });
        let groupable = matches!(pending.request.cmd, Command::Split(_) | Command::NewPane { .. });
        let mut queue = self.creations.state.lock().recover_poison();
        let seq = queue.next_seq;
        queue.next_seq += 1;
        let slot = Arc::new(CreationSlot {
            seq,
            groupable,
            request: Mutex::new(Some(pending)),
            launched: Mutex::new(None),
            trace: Mutex::new(None),
            creating_terminal,
        });
        queue.slots.push_back(slot.clone());
        drop(queue);
        self.begin_creation();
        let scheduler = self.clone();
        let job_mux = mux.clone();
        let job_writer = writer.clone();
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            crate::debug_spans::install(trace);
            crate::debug_spans::mark("job.start");
            let launched = prelaunch.and_then(|prelaunch| prelaunch.launch(&job_mux));
            crate::debug_spans::mark("prelaunch.done");
            let trace = crate::debug_spans::take();
            *slot.trace.lock().recover_poison() = trace;
            *slot.launched.lock().recover_poison() = Some(launched);
            scheduler.commit_ready_creations(&job_mux, client, &job_writer);
        });
        if let Err(job) = mux.submit_terminal_work(job) {
            // The pool is saturated: create inline, as before the pool.
            job();
        }
        writer.is_open()
    }

    /// Commit every create at the head of the queue whose launch step
    /// finished, in request order. A create starts when no earlier create
    /// runs, or when it is a split and every earlier create that runs is a
    /// split that joined its creation group; this thread commits it.
    fn commit_ready_creations(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        writer: &MessageWriter,
    ) {
        // A create that panics ends its slot, and the loop goes on to the
        // creates waiting behind it: nobody else would start them. The
        // first panic goes on to the caller (the terminal pool reports it)
        // once the loop has nothing more to start.
        if let Some(panic) = self.commit_ready_creations_catching(mux, client, writer) {
            std::panic::resume_unwind(panic);
        }
    }

    fn commit_ready_creations_catching(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        writer: &MessageWriter,
    ) -> Option<Box<dyn std::any::Any + Send>> {
        let mut panicked = None;
        loop {
            let slot = {
                let mut queue = self.creations.state.lock().recover_poison();
                let Some(head) = queue.slots.front() else { return panicked };
                let may_start =
                    queue.running == 0 || (head.groupable && queue.running_unjoined == 0);
                if !may_start || head.launched.lock().recover_poison().is_none() {
                    return panicked;
                }
                let Some(slot) = queue.slots.pop_front() else { return panicked };
                queue.running += 1;
                queue.running_unjoined += 1;
                slot
            };
            let joined = Arc::new(AtomicBool::new(false));
            // Ends the slot also when the create panics (the pool catches
            // it): later creates of the connection wait for this one.
            let end = SlotEnd { scheduler: self, slot: &slot, joined: &joined };
            let committed = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                if slot.groupable {
                    crate::mux::with_group_join_notice(
                        self.join_notice(mux, client, writer, joined.clone()),
                        || self.commit_creation(mux, client, &slot, writer),
                    )
                } else {
                    self.commit_creation(mux, client, &slot, writer)
                }
            }));
            drop(end);
            let keep_open = match committed {
                Ok(keep_open) => keep_open,
                Err(panic) => {
                    eprintln!("cmux-tui: a terminal create of client {client} panicked");
                    panicked.get_or_insert(panic);
                    true
                }
            };
            if !keep_open {
                self.close();
            }
        }
    }

    /// Run when a create joins its creation group: the next split of the
    /// connection may start now, on the terminal work pool (this thread is
    /// inside the create). With a full pool it starts when this create ends.
    fn join_notice(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        writer: &MessageWriter,
        joined: Arc<AtomicBool>,
    ) -> Box<dyn FnOnce()> {
        let (scheduler, mux, writer) = (self.clone(), mux.clone(), writer.clone());
        Box::new(move || {
            joined.store(true, Ordering::Release);
            let start_next = {
                let mut queue = scheduler.creations.state.lock().recover_poison();
                queue.running_unjoined -= 1;
                queue.running_unjoined == 0
                    && queue.slots.front().is_some_and(|head| head.groupable)
            };
            if start_next {
                let job_mux = mux.clone();
                let job: Box<dyn FnOnce() + Send> = Box::new(move || {
                    scheduler.commit_ready_creations(&job_mux, client, &writer);
                });
                // A full pool: the create that joined starts the next one
                // when it ends.
                let _ = mux.submit_terminal_work(job);
            }
        })
    }

    /// Creates of the connection whose launch step finished and that wait
    /// to start.
    #[cfg(test)]
    pub(super) fn launched_creations_waiting_for_test(&self) -> usize {
        let queue = self.creations.state.lock().recover_poison();
        queue.slots.iter().filter(|slot| slot.launched.lock().recover_poison().is_some()).count()
    }

    /// Wake the creates that wait to reply: the connection closed.
    pub(super) fn wake_reply_waiters(&self) {
        let _queue = self.creations.state.lock().recover_poison();
        self.creations.replied.notify_all();
    }

    /// A started create ended: release its hold on later starts and let
    /// the next create's reply go out.
    fn finish_slot(&self, slot: &CreationSlot, joined: bool) {
        let mut guard = self.creations.state.lock().recover_poison();
        let queue = &mut *guard;
        queue.running -= 1;
        if !joined {
            queue.running_unjoined -= 1;
        }
        queue.ended_early.insert(slot.seq);
        while queue.ended_early.remove(&queue.next_reply) {
            queue.next_reply += 1;
        }
        drop(guard);
        self.creations.replied.notify_all();
    }

    /// `writer`, with the replies of `slot` held until every earlier
    /// create of the connection replied.
    fn ordered_reply_writer(
        self: &Arc<Self>,
        slot: &CreationSlot,
        writer: &MessageWriter,
    ) -> MessageWriter {
        let mut ordered = writer.clone();
        ordered.sink = Arc::new(OrderedReplySink {
            inner: writer.sink.clone(),
            scheduler: self.clone(),
            seq: slot.seq,
        });
        ordered
    }

    fn commit_creation(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        slot: &CreationSlot,
        writer: &MessageWriter,
    ) -> bool {
        let writer = &self.ordered_reply_writer(slot, writer);
        let launched = slot.launched.lock().recover_poison().take().flatten();
        let pending = slot.request.lock().recover_poison().take();
        let trace = slot.trace.lock().recover_poison().take();
        crate::debug_spans::install(trace);
        crate::debug_spans::mark("commit.start");
        // The terminal id the app minted (or the prelaunch chose) names the
        // trace, so app marks join it, and owes the first-output marks
        // (`debug_spans::FOLLOW_MARKS`): its reader starts in this commit.
        let created_terminal = slot.creating_terminal.as_ref().map(|(terminal_id, _)| terminal_id);
        if let Some(terminal_id) = launched.as_ref().or(created_terminal) {
            crate::debug_spans::follow(terminal_id);
        }
        let cancelled = self.cancelled.is_cancelled();
        // Runs after the create, also when it panics.
        let cleanup = CreateCleanup { mux, slot, launched: launched.clone(), cancelled };
        let keep_open = match pending {
            // A closed connection drops its queued requests unexecuted.
            Some(_) if cancelled => true,
            Some(mut pending) => {
                if let Some(terminal_hex) = launched.as_ref() {
                    match &mut pending.request.cmd {
                        Command::NewTab { terminal_id, .. }
                        | Command::NewPane { terminal_id, .. } => {
                            *terminal_id = Some(terminal_hex.clone());
                        }
                        Command::Split(params) => params.set_terminal_id(terminal_hex.clone()),
                        Command::NewPaneRight(params) => {
                            params.set_terminal_id(terminal_hex.clone());
                        }
                        _ => {}
                    }
                }
                run_pending_request(self, mux, client, pending, writer)
            }
            None => true,
        };
        drop(cleanup);
        keep_open
    }

    fn begin_creation(&self) {
        self.state.lock().recover_poison().active_creations += 1;
    }

    fn finish_creation(&self) {
        let mut state = self.state.lock().recover_poison();
        state.active_creations -= 1;
        self.changed.notify_all();
    }
}

/// The end of one create's commit, on return or on a panic: input queued
/// for the new terminal goes to it now, before any later input, or back to
/// its senders when no live terminal has it (the create failed, was dropped
/// or panicked first); an unused prelaunched host is discarded.
struct CreateCleanup<'a> {
    mux: &'a Arc<Mux>,
    slot: &'a CreationSlot,
    launched: Option<String>,
    cancelled: bool,
}

impl Drop for CreateCleanup<'_> {
    fn drop(&mut self) {
        if let Some((terminal_id, generation)) = &self.slot.creating_terminal {
            // On a panic too: a terminal that is live takes its input, else
            // the input goes back as "failed".
            let failure = self.cancelled.then_some("cancelled");
            self.mux.finish_creating_input(terminal_id, *generation, failure);
        }
        crate::debug_spans::mark("reply.queued");
        crate::debug_spans::finish(crate::debug_spans::take());
        if let Some(terminal_hex) = self.launched.take() {
            self.mux.discard_prelaunched_terminal(&terminal_hex);
        }
    }
}

/// Ends a started create's slot when it drops, on return or on a panic.
struct SlotEnd<'a> {
    scheduler: &'a ConnectionSurfaceScheduler,
    slot: &'a CreationSlot,
    joined: &'a AtomicBool,
}

impl Drop for SlotEnd<'_> {
    fn drop(&mut self) {
        self.scheduler.finish_slot(self.slot, self.joined.load(Ordering::Acquire));
        self.scheduler.finish_creation();
    }
}

/// A create's replies, held until every earlier create of its connection
/// replied (see the module docs). Everything else goes straight through.
struct OrderedReplySink {
    inner: Arc<dyn MessageSink>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    seq: u64,
}

impl OrderedReplySink {
    /// Wait for this create's turn to reply: every earlier create ended.
    /// An earlier create always ends (also when it panics, see `SlotEnd`),
    /// and it never waits for a later one (a group's earlier member gets
    /// its answer before any later member replies). A closed connection
    /// ends the wait: its reply goes nowhere.
    fn wait_turn(&self) {
        let creations = &self.scheduler.creations;
        let mut queue = creations.state.lock().recover_poison();
        while queue.next_reply < self.seq && !self.scheduler.cancelled.is_cancelled() {
            queue = creations.replied.wait(queue).recover_poison();
        }
    }
}

impl MessageSink for OrderedReplySink {
    fn send_initial(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.inner.send_initial(text, stream)
    }

    fn send_stream(&self, text: Arc<BudgetedText>, stream: &OutboundStream) -> std::io::Result<()> {
        self.inner.send_stream(text, stream)
    }

    fn send_stream_backpressured(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.inner.send_stream_backpressured(text, stream)
    }

    fn send_control(&self, text: Arc<BudgetedText>) -> std::io::Result<()> {
        self.wait_turn();
        self.inner.send_control(text)
    }

    fn send_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.inner.send_terminal(text, stream)
    }

    fn send_ordered_terminal(
        &self,
        text: Arc<BudgetedText>,
        stream: &OutboundStream,
    ) -> std::io::Result<()> {
        self.inner.send_ordered_terminal(text, stream)
    }

    fn set_write_timeout(&self, timeout: Option<Duration>) -> std::io::Result<()> {
        self.inner.set_write_timeout(timeout)
    }

    fn flush_control(&self, timeout: Duration) -> std::io::Result<()> {
        self.inner.flush_control(timeout)
    }

    fn is_open(&self) -> bool {
        self.inner.is_open()
    }

    fn close(&self) {
        self.inner.close();
    }

    fn abort(&self) {
        self.inner.abort();
    }

    fn close_after_control(&self) {
        self.inner.close_after_control();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The prelaunched host runs the program the create commits, so it
    /// resolves `terminal-frontend-shell-integration-v1` the same way.
    #[test]
    fn prelaunch_follows_the_frontend_shell_flag() {
        let command: Command = serde_json::from_value(json!({
            "cmd": "new-tab", "env": {"SHELL": "/opt/frontend/bin/zsh"},
        }))
        .unwrap();
        let frontend = PrelaunchRequest::of(&command, true).unwrap();
        assert_eq!(frontend.argv, Some(vec!["/opt/frontend/bin/zsh".to_string()]));
        assert_eq!(PrelaunchRequest::of(&command, false).unwrap().argv, None);
    }
}
