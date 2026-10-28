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

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, SyncSender, TrySendError};
use std::sync::{Arc, PoisonError, Weak};
use std::time::Duration;

use cmux_threads::checked;
use cmux_threads::work::{Lane, Priority, Shutdown};
use serde_json::{Value, json};

use super::Mux;
use super::mux_work::Answer;
use crate::resource::TerminalPublicId;
use crate::shell_history::{FinishedCommand, MAX_QUEUED_COMMANDS};
use crate::state::command_history_store::{
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
    Delete(CommandDeletion, DeletionAnswer),
}

/// The answer of a delete: the deleted row count, or the worker stopped.
pub(crate) type DeletionAnswer = Answer<anyhow::Result<u64>>;

/// The worker's bounded queue and the client deletes queued on it that are
/// not answered yet. While one is, no pass runs at utility: the client
/// waits on its answer, not on the registry lock, so `LockBoost` cannot
/// raise the pass it waits behind.
#[derive(Clone)]
pub(crate) struct CommandHistoryQueue {
    sender: SyncSender<CommandHistoryMessage>,
    deletes_waiting: Arc<AtomicUsize>,
}

impl CommandHistoryQueue {
    fn new(sender: SyncSender<CommandHistoryMessage>) -> Self {
        Self { sender, deletes_waiting: Arc::default() }
    }

    /// A client delete, counted as waiting until `done` has its answer.
    fn delete(
        &self,
        deletion: CommandDeletion,
        done: impl FnOnce(anyhow::Result<u64>) + Send + 'static,
    ) -> CommandHistoryMessage {
        let waiting = DeleteWaiting::new(&self.deletes_waiting);
        let answer = DeletionAnswer::new(
            move |deleted| {
                done(deleted);
                drop(waiting);
            },
            worker_stopped,
        );
        CommandHistoryMessage::Delete(deletion, answer)
    }
}

/// One unanswered client delete in [`CommandHistoryQueue::deletes_waiting`].
struct DeleteWaiting(Arc<AtomicUsize>);

impl DeleteWaiting {
    fn new(count: &Arc<AtomicUsize>) -> Self {
        count.fetch_add(1, Ordering::AcqRel);
        Self(Arc::clone(count))
    }
}

impl Drop for DeleteWaiting {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

fn worker_stopped() -> anyhow::Result<u64> {
    Err(anyhow::anyhow!("terminal command history worker stopped"))
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
    #[track_caller]
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
        if let Some(queue) = self.command_history_queue() {
            // A full queue wakes the worker anyway.
            let _ = queue.sender.try_send(CommandHistoryMessage::Wake);
        }
        Ok(json!({ "enabled": enabled, "retention_days": retention_days }))
    }

    /// `list-terminal-commands`.
    #[track_caller]
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

    /// `delete-terminal-commands`: queued for the worker, which runs it after
    /// every command queued before it and sends `done` the deleted row
    /// count. Never waits: a full queue hands the send to the System lane.
    pub(crate) fn delete_terminal_commands_then(
        self: &Arc<Self>,
        deletion: CommandDeletion,
        done: impl FnOnce(anyhow::Result<u64>) + Send + 'static,
    ) {
        let Some(queue) = self.command_history_queue() else {
            done(Err(anyhow::anyhow!("terminal command history worker not started")));
            return;
        };
        let sender = queue.sender.clone();
        let message = match sender.try_send(queue.delete(deletion, done)) {
            Ok(()) => return,
            Err(TrySendError::Disconnected(_)) => {
                // Dropping the message answers that the worker stopped.
                self.forget_command_history_worker();
                return;
            }
            Err(TrySendError::Full(message)) => message,
        };
        // A refused item drops the message, which answers that the worker
        // stopped; a send to a stopped worker does the same.
        let _ =
            self.post_mux_work(Priority::UserVisible, Lane::System, Shutdown::SkipOnShutdown, {
                move |_| drop(sender.send(message))
            });
    }

    /// [`Self::delete_terminal_commands_then`] for a caller that waits for
    /// the count (history_ops/commands.rs). The wait is a checked `recv`:
    /// a request thread that reaches it is reported by the blocking detector.
    #[track_caller]
    pub(crate) fn delete_terminal_commands(
        self: &Arc<Self>,
        deletion: CommandDeletion,
    ) -> anyhow::Result<Value> {
        let (reply, answer) = std::sync::mpsc::sync_channel(1);
        self.delete_terminal_commands_then(deletion, move |deleted| {
            let _ = reply.send(deleted);
        });
        let deleted = checked::sync::recv(&answer).unwrap_or_else(|_| worker_stopped())?;
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
        let Some(queue) = self.command_history_queue() else {
            self.report_internal_diagnostic("terminal command history worker not started");
            return;
        };
        for command in commands {
            match queue.sender.try_send(CommandHistoryMessage::Append(terminal.clone(), command)) {
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

    /// Daemon start with a persistent registry: deletes the rows that expired
    /// while the daemon was down, then starts the worker only when a row will
    /// expire later. The pass runs here, on the constructing thread: a worker
    /// that upgraded its `Weak<Mux>` at start could keep a Mux (and its
    /// registry lock) alive after its creator dropped it to reopen the session.
    #[track_caller]
    pub(super) fn start_command_history_for_persistent_registry(self: &Arc<Self>) {
        let mut registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        if registry.session_journal_database_path().is_none() {
            return;
        }
        let Ok(now) = unix_epoch_ms() else { return };
        let retry = now.saturating_add(RETRY_MS);
        let (mut next, deleted) = match registry.expire_terminal_commands(now) {
            Ok(expiry) => (expiry.next_ms, expiry.deleted > 0),
            Err(error) => {
                eprintln!("cmux-tui: terminal command history pass failed: {error}");
                (Some(retry), false)
            }
        };
        let checkpoint_pending =
            deleted && !matches!(registry.checkpoint_terminal_command_deletes(), Ok(true));
        drop(registry);
        if checkpoint_pending {
            next = Some(next.map_or(retry, |next| next.min(retry)));
        }
        if next.is_some() && self.spawn_command_history_worker(next, checkpoint_pending).is_none() {
            self.report_internal_diagnostic("terminal command history worker not started");
        }
    }

    fn forget_command_history_worker(&self) {
        *self.command_history_worker.lock().unwrap_or_else(PoisonError::into_inner) = None;
    }

    fn command_history_queue(self: &Arc<Self>) -> Option<CommandHistoryQueue> {
        self.spawn_command_history_worker(None, false)
    }

    /// The worker's queue; starts the worker (with its first `deadline`) when
    /// none runs. The worker does no pass until a message or its deadline.
    fn spawn_command_history_worker(
        self: &Arc<Self>,
        deadline: Option<u64>,
        checkpoint_pending: bool,
    ) -> Option<CommandHistoryQueue> {
        let mut slot = self.command_history_worker.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(queue) = slot.as_ref() {
            return Some(queue.clone());
        }
        let (sender, receiver) =
            std::sync::mpsc::sync_channel::<CommandHistoryMessage>(MAX_QUEUED_COMMANDS);
        let queue = CommandHistoryQueue::new(sender);
        let worker = Worker {
            mux: Arc::downgrade(self),
            checkpoint_pending,
            deletes_waiting: Arc::clone(&queue.deletes_waiting),
        };
        // An upkeep thread (p04-input-084): a pass runs at utility unless a
        // client waits for a delete (`Worker::pass`).
        cmux_threads::spawn(
            "terminal-command-history",
            crate::request_qos::UPKEEP_THREAD_QOS,
            move || worker.run(receiver, deadline),
        )
        .ok()?;
        *slot = Some(queue.clone());
        Some(queue)
    }
}

struct Worker {
    mux: Weak<Mux>,
    /// Rows were deleted but a reader blocked the WAL checkpoint.
    checkpoint_pending: bool,
    /// [`CommandHistoryQueue::deletes_waiting`].
    deletes_waiting: Arc<AtomicUsize>,
}

impl Worker {
    #[track_caller]
    fn run(mut self, receiver: Receiver<CommandHistoryMessage>, mut deadline: Option<u64>) {
        loop {
            let message = match deadline {
                None => checked::sync::recv(&receiver).map_err(|_| RecvTimeoutError::Disconnected),
                Some(deadline) => {
                    let now = unix_epoch_ms().unwrap_or(deadline);
                    checked::sync::recv_timeout(
                        &receiver,
                        Duration::from_millis(deadline.saturating_sub(now)),
                    )
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
                    if !batch.is_empty() {
                        self.history_changed();
                    }
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
    #[track_caller]
    fn delete(&mut self, deletes: Vec<(CommandDeletion, DeletionAnswer)>) -> Option<u64> {
        let mux = self.mux.upgrade()?;
        let mut deleted_any = false;
        for (deletion, reply) in deletes {
            let result = mux
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .delete_terminal_commands(&deletion);
            if matches!(&result, Ok(deleted) if *deleted > 0) {
                self.checkpoint_pending = true;
                deleted_any = true;
            }
            reply.send(result);
        }
        drop(mux);
        if deleted_any {
            self.history_changed();
        }
        self.pass(|registry, now| registry.expire_terminal_commands(now))
    }

    /// Command rows changed: an open History page re-reads (the merged
    /// history lists these rows, cx-hnmbt.12).
    fn history_changed(&self) {
        if let Some(mux) = self.mux.upgrade() {
            mux.history.changed(&mux, &[cmux_history::HistoryKind::Command]);
        }
    }

    /// One store or expiry pass, then the WAL checkpoint when rows went.
    /// Returns the next deadline.
    #[track_caller]
    fn pass(
        &mut self,
        work: impl FnOnce(
            &mut crate::workspace_registry::WorkspaceRegistry,
            u64,
        ) -> anyhow::Result<CommandExpiry>,
    ) -> Option<u64> {
        let mux = self.mux.upgrade()?;
        let now = unix_epoch_ms().ok()?;
        // Utility with `daemonRequestQos` on, raised by the registry lock
        // while a request waits for it; at the declared class while a client
        // waits for a delete queued behind this pass.
        let client_waits = self.deletes_waiting.load(Ordering::Acquire) > 0;
        let _pass = (!client_waits).then(|| mux.request_qos().enter_upkeep_pass()).flatten();
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

#[cfg(test)]
#[path = "command_history_tests.rs"]
mod tests;
