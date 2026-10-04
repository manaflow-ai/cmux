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
                | Self::NewScreen { .. }
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
        let Command::NewTab { pane, cwd, env, cols, rows, terminal_id, shell_args, .. } = command
        else {
            return None;
        };
        // An invalid caller id is reported by the create itself.
        let terminal_id = match terminal_id {
            Some(hex) => Some(crate::terminal_host::TerminalId::from_hex(hex)?),
            None => None,
        };
        // An invalid environment is reported by the create itself.
        let env = env
            .as_ref()
            .map(crate::mux::validate_terminal_env)
            .transpose()
            .ok()?
            .unwrap_or_default();
        Some(Self {
            pane: *pane,
            terminal_id,
            cwd: cwd.clone(),
            argv: shell_argv(&env, shell_args.clone(), frontend_shell),
            env,
            size: optional_surface_size(*cols, *rows),
        })
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
        let slot = Arc::new(CreationSlot {
            request: Mutex::new(Some(pending)),
            launched: Mutex::new(None),
        });
        self.begin_creation();
        self.creations.state.lock().unwrap().slots.push_back(slot.clone());
        let scheduler = self.clone();
        let job_mux = mux.clone();
        let job_writer = writer.clone();
        let job: Box<dyn FnOnce() + Send> = Box::new(move || {
            let launched = prelaunch.and_then(|prelaunch| prelaunch.launch(&job_mux));
            *slot.launched.lock().unwrap() = Some(launched);
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
                let mut queue = self.creations.state.lock().unwrap();
                if queue.committing {
                    return;
                }
                let Some(head) = queue.slots.front() else { return };
                if head.launched.lock().unwrap().is_none() {
                    return;
                }
                queue.committing = true;
                queue.slots.pop_front().expect("the head slot is present")
            };
            let keep_open = self.commit_creation(mux, client, &slot, writer);
            self.creations.state.lock().unwrap().committing = false;
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
        let launched = slot.launched.lock().unwrap().take().flatten();
        let pending = slot.request.lock().unwrap().take();
        let keep_open = match pending {
            // A closed connection drops its queued requests unexecuted.
            Some(_) if self.cancelled.is_cancelled() => true,
            Some(mut pending) => {
                if let (Some(terminal_hex), Command::NewTab { terminal_id, .. }) =
                    (launched.as_ref(), &mut pending.request.cmd)
                {
                    *terminal_id = Some(terminal_hex.clone());
                }
                run_pending_request(self, mux, client, pending, writer)
            }
            None => true,
        };
        if let Some(terminal_hex) = launched {
            mux.discard_prelaunched_terminal(&terminal_hex);
        }
        keep_open
    }

    fn begin_creation(&self) {
        self.state.lock().unwrap().active_creations += 1;
    }

    fn finish_creation(&self) {
        let mut state = self.state.lock().unwrap();
        state.active_creations -= 1;
        self.changed.notify_all();
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
