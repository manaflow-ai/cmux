//! The daemon's terminal command history worker
//! (`terminal-command-history-v1`, plans/cmux-next/history.md section 6).
//!
//! One long-lived thread per daemon is the only writer of command rows: it
//! stores the commands PTY readers queue (they never wait for the
//! registry), runs client deletes in queue order, so a command queued before
//! a delete is stored first and then deleted with the rest, and expires old
//! rows. Between messages it waits for one deadline: the time the oldest
//! row expires, or a retry of a WAL checkpoint that a reader blocked. No
//! polling. It starts with a persistent daemon (and expires what aged out
//! while the daemon was down) or on first use.
//!
//! The rows belong to the workspace registry (`command_history_store`);
//! list requests read it directly, and set-terminal-command-history writes
//! only the retention value there before waking the worker.

use std::sync::atomic::Ordering;
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, PoisonError, Weak};
use std::time::Duration;

use serde_json::{Value, json};

use super::Mux;
use crate::resource::TerminalPublicId;
use crate::shell_history::{FinishedCommand, MAX_QUEUED_COMMANDS};
use crate::workspace_registry::command_history_store::{
    CommandDeletion, CommandExpiry, CommandHistoryPage, CommandHistoryRow,
};
use crate::workspace_registry::unix_epoch_ms;

/// Commands stored in one registry transaction.
const MAX_COMMANDS_PER_WRITE: usize = 64;
/// Wait before retrying a failed pass or a checkpoint a reader blocked.
const RETRY_MS: u64 = 60_000;

pub(crate) enum CommandHistoryMessage {
    Append(TerminalPublicId, FinishedCommand),
    /// The retention changed: expire and compute the deadline again.
    Wake,
    /// A client delete; the worker answers with the deleted row count.
    Delete(CommandDeletion, SyncSender<anyhow::Result<u64>>),
}

impl Mux {
    /// Whether this daemon records finished shell commands (in memory, off
    /// at start; a global switch that any trusted local client sets: a gap
    /// recorded in plans/cmux-next/COORDINATION.md).
    pub(crate) fn terminal_command_history_enabled(&self) -> bool {
        self.terminal_command_history.load(Ordering::Acquire)
    }

    /// `set-terminal-command-history`: the switch, and the retention when
    /// given (stored at once; lists hide what it expires, and the worker
    /// deletes those rows).
    pub(crate) fn set_terminal_command_history(
        self: &Arc<Self>,
        enabled: bool,
        retention_days: Option<u32>,
    ) -> anyhow::Result<Value> {
        let retention_days = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            if let Some(days) = retention_days {
                registry.set_terminal_command_retention_days(days)?;
            }
            registry.terminal_command_retention_days()?
        };
        self.terminal_command_history.store(enabled, Ordering::Release);
        if let Some(sender) = self.command_history_sender() {
            // A full queue wakes the worker anyway.
            let _ = sender.try_send(CommandHistoryMessage::Wake);
        }
        Ok(json!({ "enabled": enabled, "retention_days": retention_days }))
    }

    /// `list-terminal-commands`.
    pub(crate) fn list_terminal_commands(
        &self,
        after_id: Option<u64>,
        limit: usize,
    ) -> anyhow::Result<Value> {
        let now = unix_epoch_ms()?;
        let page = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .list_terminal_commands(after_id, limit, now)?;
        Ok(command_history_page_json(&page))
    }

    /// `delete-terminal-commands`, run by the worker after every command
    /// queued before it.
    pub(crate) fn delete_terminal_commands(
        self: &Arc<Self>,
        deletion: CommandDeletion,
    ) -> anyhow::Result<Value> {
        let (reply, answer) = std::sync::mpsc::sync_channel(1);
        let sender = self
            .command_history_sender()
            .ok_or_else(|| anyhow::anyhow!("terminal command history worker not started"))?;
        if sender.send(CommandHistoryMessage::Delete(deletion, reply)).is_err() {
            self.forget_command_history_worker();
            anyhow::bail!("terminal command history worker stopped");
        }
        let deleted = answer
            .recv()
            .map_err(|_| anyhow::anyhow!("terminal command history worker stopped"))??;
        Ok(json!({ "deleted": deleted }))
    }

    /// Queues finished shell commands of `terminal` for the worker. The
    /// caller (a PTY reader) never waits for the registry. The queue is
    /// bounded: when it is full, records drop and a diagnostic counts it.
    pub(crate) fn append_shell_commands(
        self: &Arc<Self>,
        terminal: TerminalPublicId,
        commands: Vec<FinishedCommand>,
    ) {
        if !self.terminal_command_history_enabled() {
            return;
        }
        let Some(sender) = self.command_history_sender() else {
            self.report_internal_diagnostic("terminal command history worker not started");
            return;
        };
        for command in commands {
            match sender.try_send(CommandHistoryMessage::Append(terminal.clone(), command)) {
                Ok(()) => {}
                Err(TrySendError::Full(_)) => self.report_internal_diagnostic(
                    "terminal command history queue full; record dropped",
                ),
                Err(TrySendError::Disconnected(_)) => {
                    self.forget_command_history_worker();
                    self.report_internal_diagnostic(
                        "terminal command history worker stopped; record dropped",
                    );
                    return;
                }
            }
        }
    }

    /// Starts the worker for a persistent registry (daemon start), so rows
    /// that expired while the daemon was down are deleted now.
    pub(super) fn start_command_history_for_persistent_registry(self: &Arc<Self>) {
        let persistent = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .session_journal_database_path()
            .is_some();
        if persistent && self.command_history_sender().is_none() {
            self.report_internal_diagnostic("terminal command history worker not started");
        }
    }

    fn forget_command_history_worker(&self) {
        *self.command_history_worker.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }

    fn command_history_sender(self: &Arc<Self>) -> Option<SyncSender<CommandHistoryMessage>> {
        let mut slot = self.command_history_worker.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sender) = slot.as_ref() {
            return Some(sender.clone());
        }
        let (sender, receiver) =
            std::sync::mpsc::sync_channel::<CommandHistoryMessage>(MAX_QUEUED_COMMANDS);
        let mux = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("terminal-command-history".into())
            .spawn(move || Worker { mux, checkpoint_pending: false }.run(receiver))
            .ok()?;
        *slot = Some(sender.clone());
        Some(sender)
    }
}

struct Worker {
    mux: Weak<Mux>,
    /// Rows were deleted but a reader blocked the WAL checkpoint.
    checkpoint_pending: bool,
}

impl Worker {
    fn run(mut self, receiver: Receiver<CommandHistoryMessage>) {
        let mut deadline = self.pass(|registry, now| registry.expire_terminal_commands(now));
        loop {
            let message = match deadline {
                None => receiver.recv().map_err(|_| RecvTimeoutError::Disconnected),
                Some(deadline) => {
                    let now = unix_epoch_ms().unwrap_or(deadline);
                    receiver.recv_timeout(Duration::from_millis(deadline.saturating_sub(now)))
                }
            };
            deadline = match message {
                Ok(CommandHistoryMessage::Append(terminal, command)) => {
                    // The store also expires old rows, which covers a queued Wake.
                    let mut batch = vec![(terminal.to_string(), command)];
                    let mut deletes = Vec::new();
                    while batch.len() < MAX_COMMANDS_PER_WRITE && deletes.is_empty() {
                        match receiver.try_recv() {
                            Ok(CommandHistoryMessage::Append(terminal, command)) => {
                                batch.push((terminal.to_string(), command));
                            }
                            Ok(CommandHistoryMessage::Wake) => {}
                            Ok(CommandHistoryMessage::Delete(deletion, reply)) => {
                                deletes.push((deletion, reply));
                            }
                            Err(_) => break,
                        }
                    }
                    // Commands queued before recording was turned off are
                    // not stored: the switch is read again here.
                    let recording = self
                        .mux
                        .upgrade()
                        .is_some_and(|mux| mux.terminal_command_history_enabled());
                    if !recording {
                        batch.clear();
                    }
                    let next =
                        self.pass(|registry, now| registry.append_terminal_commands(&batch, now));
                    if deletes.is_empty() { next } else { self.delete(deletes) }
                }
                Ok(CommandHistoryMessage::Delete(deletion, reply)) => {
                    self.delete(vec![(deletion, reply)])
                }
                Ok(CommandHistoryMessage::Wake) | Err(RecvTimeoutError::Timeout) => {
                    self.pass(|registry, now| registry.expire_terminal_commands(now))
                }
                Err(RecvTimeoutError::Disconnected) => return,
            };
        }
    }

    /// Runs client deletes in order, then an expiry pass.
    fn delete(
        &mut self,
        deletes: Vec<(CommandDeletion, SyncSender<anyhow::Result<u64>>)>,
    ) -> Option<u64> {
        let mux = self.mux.upgrade()?;
        for (deletion, reply) in deletes {
            let result = mux
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .delete_terminal_commands(&deletion);
            if matches!(&result, Ok(deleted) if *deleted > 0) {
                self.checkpoint_pending = true;
            }
            let _ = reply.send(result);
        }
        drop(mux);
        self.pass(|registry, now| registry.expire_terminal_commands(now))
    }

    /// One store or expiry pass, then the WAL checkpoint when rows went.
    /// Returns the next deadline.
    fn pass(
        &mut self,
        work: impl FnOnce(
            &mut crate::workspace_registry::WorkspaceRegistry,
            u64,
        ) -> anyhow::Result<CommandExpiry>,
    ) -> Option<u64> {
        let mux = self.mux.upgrade()?;
        let now = unix_epoch_ms().ok()?;
        let mut registry = mux.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        let next = match work(&mut registry, now) {
            Ok(expiry) => {
                self.checkpoint_pending |= expiry.deleted > 0;
                expiry.next_ms
            }
            Err(error) => {
                eprintln!("cmux-tui: terminal command history pass failed: {error}");
                Some(now.saturating_add(RETRY_MS))
            }
        };
        if self.checkpoint_pending {
            match registry.checkpoint_terminal_command_deletes() {
                Ok(true) => self.checkpoint_pending = false,
                Ok(false) => {}
                Err(error) => eprintln!("cmux-tui: terminal command history checkpoint: {error}"),
            }
        }
        if self.checkpoint_pending {
            let retry = now.saturating_add(RETRY_MS);
            return Some(next.map_or(retry, |next| next.min(retry)));
        }
        next
    }
}

fn command_row_json(row: &CommandHistoryRow) -> Value {
    json!({
        "id": row.id.to_string(),
        "terminal_id": row.terminal_id,
        "command": row.command,
        "cwd": row.cwd,
        "exit_code": row.exit_code,
        "started_at_ms": row.started_at_ms.to_string(),
        "duration_ms": row.duration_ms.to_string(),
    })
}

fn command_history_page_json(page: &CommandHistoryPage) -> Value {
    json!({
        "commands": page.commands.iter().map(command_row_json).collect::<Vec<_>>(),
        "truncated": page.truncated,
        "deletions": page.deletions.to_string(),
        "registry_id": page.registry_id,
        "retention_days": page.retention_days,
    })
}
