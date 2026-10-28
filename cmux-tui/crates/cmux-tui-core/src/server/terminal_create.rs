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

use super::*;
use crate::panic_free::RecoverPoison;

/// The creates of one connection, in request order.
#[derive(Default)]
pub(super) struct ConnectionCreations {
    state: Mutex<CreationQueue>,
}

#[derive(Default)]
struct CreationQueue {
    slots: VecDeque<Arc<CreationSlot>>,
    /// A thread is committing the head slot.
    committing: bool,
}

struct CreationSlot {
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
        let Command::NewTab(params) = command else {
            return None;
        };
        Self::build(
            params.pane,
            params.terminal_id.as_ref(),
            params.cwd.as_ref(),
            params.env.as_ref(),
            params.shell_args.as_ref(),
            optional_surface_size(params.cols, params.rows),
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
        // From the line's arrival, as a resource create's trace
        // (connection_frame.rs): the time it waited in this connection's
        // queue counts, and `dequeued` marks where that wait ended.
        let trace =
            crate::debug_spans::Trace::start(label, pending.arrival.arrived).and_then(|trace| {
                crate::debug_spans::install(Some(trace));
                crate::debug_spans::mark("dequeued");
                crate::debug_spans::take()
            });
        // The pool job is the request's: its launch, and the commits it
        // runs (each under its own request's cause), keep the cause the
        // dispatcher captured.
        let cause = pending.cause;
        let creating_terminal = pending.request.cmd.created_terminal_id().and_then(|terminal_id| {
            mux.begin_creating_input(&terminal_id).map(|generation| (terminal_id, generation))
        });
        let slot = Arc::new(CreationSlot {
            request: Mutex::new(Some(pending)),
            launched: Mutex::new(None),
            trace: Mutex::new(None),
            creating_terminal,
        });
        self.begin_creation();
        self.creations.state.lock().recover_poison().slots.push_back(slot.clone());
        let scheduler = self.clone();
        let job_mux = mux.clone();
        let job_writer = writer.clone();
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            let _cause = job_mux.request_qos().enter(cause);
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
    /// finished, in request order. Only one thread commits at a time; a
    /// launch that finishes while another thread commits leaves its slot to
    /// that thread.
    fn commit_ready_creations(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        writer: &MessageWriter,
    ) {
        loop {
            let slot = {
                let mut queue = self.creations.state.lock().recover_poison();
                if queue.committing {
                    return;
                }
                let Some(head) = queue.slots.front() else { return };
                if head.launched.lock().recover_poison().is_none() {
                    return;
                }
                let Some(slot) = queue.slots.pop_front() else { return };
                queue.committing = true;
                slot
            };
            let keep_open = self.commit_creation(mux, client, &slot, writer);
            self.creations.state.lock().recover_poison().committing = false;
            self.finish_creation();
            if !keep_open {
                self.close();
            }
        }
    }

    fn commit_creation(
        &self,
        mux: &Arc<Mux>,
        client: u64,
        slot: &CreationSlot,
        writer: &MessageWriter,
    ) -> bool {
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
        let keep_open = match pending {
            // A closed connection drops its queued requests unexecuted.
            Some(_) if cancelled => true,
            Some(mut pending) => {
                if let Some(terminal_hex) = launched.as_ref() {
                    match &mut pending.request.cmd {
                        Command::NewTab(params) => {
                            params.terminal_id = Some(terminal_hex.clone());
                        }
                        Command::NewPane { terminal_id, .. } => {
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
        // Input queued for the new terminal goes to it now, before any later input, or back to
        // its senders when the create failed or was dropped.
        if let Some((terminal_id, generation)) = &slot.creating_terminal {
            mux.finish_creating_input(terminal_id, *generation, cancelled.then_some("cancelled"));
        }
        crate::debug_spans::mark("reply.queued");
        crate::debug_spans::finish(crate::debug_spans::take());
        if let Some(terminal_hex) = launched {
            mux.discard_prelaunched_terminal(&terminal_hex);
        }
        keep_open
    }

    fn begin_creation(&self) {
        self.state.lock().recover_poison().active_creations += 1;
    }

    fn finish_creation(&self) {
        let mut state = self.state.lock().recover_poison();
        state.active_creations -= 1;
        let hooks = state.take_settled_hooks();
        self.changed.notify_all();
        drop(state);
        for hook in hooks {
            hook();
        }
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
