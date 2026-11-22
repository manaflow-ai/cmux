//! Launch snapshots and shell command history: the launch snapshot path and subscription, command history settings, and the shell command feed.

use super::*;

impl Mux {
    /// The launch snapshot file (`launch-snapshot-v1`) while its writer runs.
    pub fn launch_snapshot_path(&self) -> Option<std::path::PathBuf> {
        self.launch_snapshot_path.lock().unwrap().clone()
    }

    pub(crate) fn set_launch_snapshot_path(&self, path: Option<std::path::PathBuf>) {
        *self.launch_snapshot_path.lock().unwrap() = path;
    }

    /// Events that can change the launch snapshot.
    pub(crate) fn subscribe_launch_snapshot(&self) -> MuxEventReceiver {
        self.subscribers.subscribe_launch_snapshot()
    }

    /// Whether this daemon records finished shell commands (in memory, off
    /// at start; a global switch that any trusted local client sets: a gap
    /// recorded in plans/cmux-next/COORDINATION.md).
    pub(crate) fn terminal_command_history_enabled(&self) -> bool {
        self.terminal_command_history.load(Ordering::Acquire)
    }

    pub(crate) fn set_terminal_command_history(&self, enabled: bool) {
        self.terminal_command_history.store(enabled, Ordering::Release);
    }

    /// Queues finished shell commands of `terminal` for the journal
    /// (`shell.command.finished`). One long-lived worker per daemon appends
    /// them in order; the caller (a PTY reader) never waits for the journal
    /// writer. The queue is bounded: when it is full, records drop and a
    /// diagnostic counts it.
    pub(crate) fn append_shell_commands(
        self: &Arc<Self>,
        terminal: TerminalPublicId,
        commands: Vec<crate::shell_history::FinishedCommand>,
    ) {
        if !self.terminal_command_history_enabled() {
            return;
        }
        let Some(sender) = self.shell_command_sender() else {
            self.report_internal_diagnostic("shell command journal worker not started");
            return;
        };
        for command in commands {
            if sender.try_send((terminal.clone(), command)).is_err() {
                self.report_internal_diagnostic("shell command journal queue full; record dropped");
            }
        }
    }

    /// The journal worker's queue, started on first use.
    pub(super) fn shell_command_sender(
        self: &Arc<Self>,
    ) -> Option<SyncSender<(TerminalPublicId, crate::shell_history::FinishedCommand)>> {
        let mut slot = self.shell_command_journal.lock().unwrap();
        if let Some(sender) = slot.as_ref() {
            return Some(sender.clone());
        }
        let (sender, receiver) = std::sync::mpsc::sync_channel::<(
            TerminalPublicId,
            crate::shell_history::FinishedCommand,
        )>(crate::shell_history::MAX_QUEUED_COMMANDS);
        let mux = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("shell-command-journal".into())
            .spawn(move || {
                while let Ok((terminal, command)) = receiver.recv() {
                    let Some(mux) = mux.upgrade() else { return };
                    let ingress =
                        crate::shell_history::command_journal_ingress(&terminal, &command);
                    let key = format!("shell-command-{}", crate::workspace_registry::new_uuid_v4());
                    if let Err(error) = mux.append_journal_ingress(&ingress, "shell-command", &key)
                    {
                        eprintln!(
                            "cmux-tui: journaling a shell command for {terminal} failed: {error}"
                        );
                    }
                }
            })
            .ok()?;
        *slot = Some(sender.clone());
        Some(sender)
    }
}
