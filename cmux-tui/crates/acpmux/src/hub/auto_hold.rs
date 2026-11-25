//! What Auto mode (`crate::auto_session`) asks of a chat that only the hub can answer or do:
//! whether it has work, its Auto record, its queue's prompts in full, and the freeze of a chat
//! another holder runs.
//!
//! A chat that is not this machine's to run is frozen with the mark [`AUTO_AWAY`], the way a chat
//! that moved to another daemon is (`transfer_out.rs`): no prompt starts a turn, and the queue
//! and the draft do not change. The mark names no move, so no move watch settles it.

use super::*;
use crate::auto_session::record::AutoRecord;

/// The `moving` mark of an Auto chat this machine may not run now: another holder runs it, its
/// process tree is stopped, or its Cloud copy is being brought in.
pub(crate) const AUTO_AWAY: &str = "auto-away";

/// The sender's name of a prompt the holder loop gives a chat from its Cloud inbox.
pub(crate) const AUTO_CLIENT: &str = "auto-session";

/// The unlogged row change that says a chat's `autoSession` changed.
const ROW_KIND: &str = "auto_session";

/// The log record of a Cloud inbox message this machine took: `{n, promptId, text}`.
const AUTO_INBOX: &str = "auto_inbox";

/// What a change to a frozen Auto chat's queue or draft gets (a prompt is sent to the Cloud
/// instead, `Hub::auto_away_prompt`).
pub(super) fn away_error(session: &Session) -> RpcError {
    RpcError::new(
        -32000,
        "auto.away: this chat is not running on this machine now; it changes where it runs",
    )
    .with_data(json!({"reason": "auto.away", "sessionId": session.id, "retryable": true}))
}

impl Hub {
    /// `needsRun` for `session`: a turn running, a prompt queued, or a background task at work
    /// (`idle.rs` `at_work`). Reads the chat's process records, so call it off the async workers.
    pub(crate) fn auto_needs_run(&self, session: &Session) -> bool {
        self.at_work(session).is_some()
    }

    /// Changes each time a continuation of a cut turn stops waiting for `session`
    /// (`auto_resume.rs`). One waits from a turn's end until the hub has settled whether the
    /// turn is continued, and the chat is at work for that long ([`Self::auto_needs_run`]);
    /// its end is no log record. Whoever read "at work" reads again when this changes. Take it
    /// before the read, so what is let go right after the read still changes it.
    pub(crate) fn auto_work_settles(&self, session: &Session) -> tokio::sync::watch::Receiver<u64> {
        session.auto_resume.released()
    }

    /// The chat's Auto record.
    pub(crate) fn auto_record(&self, session: &Session) -> Option<AutoRecord> {
        session.read_meta(|m| m.auto_session.clone())
    }

    /// Replaces the chat's Auto record with what `change` makes of it, read and written as one
    /// step: the holder loop and a request never undo each other's change. A change is saved
    /// and goes out as the row's change notice; the same record again does nothing.
    pub(crate) fn update_auto_record(
        &self,
        session: &Session,
        change: impl FnOnce(Option<AutoRecord>) -> Option<AutoRecord>,
    ) {
        {
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let record = change(meta.auto_session.clone());
            if meta.auto_session == record {
                return;
            }
            meta.auto_session = record;
        }
        self.save_meta(session);
        self.row_notice(session, ROW_KIND);
    }

    /// Freezes the chat (`away`) or frees it. Only Auto's own mark is set or cleared: a chat a
    /// move froze keeps its move's mark.
    pub(crate) fn auto_hold(&self, session: &Session, away: bool) {
        let mut moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
        match (moving.as_deref(), away) {
            (None, true) => *moving = Some(AUTO_AWAY.to_owned()),
            (Some(AUTO_AWAY), false) => {
                *moving = None;
                drop(moving);
                // Its queued prompts run again, as after a move that did not happen
                // (`transfer_out.rs` `end_move`).
                session.queue_moved.notify_waiters();
            }
            _ => {}
        }
    }

    /// The holder loop accepted the chat's import: it is this machine's now. Frees it and
    /// runs its restored queue, the continuation first, once (`queue.rs` `resume_queues`).
    pub(crate) fn auto_activate(self: &Arc<Self>, session: &Arc<Session>) {
        {
            let mut moving = session.moving.lock().unwrap_or_else(|e| e.into_inner());
            if moving.as_deref() == Some(AUTO_AWAY) {
                *moving = None;
            }
        }
        let (hub, followed) = (self.clone(), session.clone());
        // Owned by the hub's scope: its close ends a follow still running (check-spawn-owner).
        self.scope.spawn_named("auto-activate-follow", async move {
            hub.follow_policy(&followed).await;
            followed.queue_moved.notify_waiters();
        });
        self.resume_queues();
    }

    /// What the holder loop does once it accepted the import of chat `id` (`effects.rs`): for a
    /// caller that drives the importer itself, as the machine-side tests do. An import alone
    /// leaves the chat frozen until this.
    pub fn auto_accept_import(self: &Arc<Self>, id: &str) {
        if let Some(session) = self.auto_session(id) {
            self.auto_activate(&session);
        }
    }

    /// Frees every chat Auto froze at startup: no holder loop runs to say which are this
    /// machine's (`auto_session/laptop.rs`).
    pub(crate) fn auto_release_all(&self) {
        for session in self.sessions() {
            self.auto_hold(&session, false);
        }
    }

    /// Whether Auto froze the chat.
    pub(crate) fn auto_held(&self, session: &Session) -> bool {
        session.moving().as_deref() == Some(AUTO_AWAY)
    }

    /// What a prompt to a frozen Auto chat answers: the holder loop sends it to the chat's
    /// Cloud inbox, or says why the chat waits. None for any other chat.
    pub(super) async fn auto_away_prompt(
        &self,
        session: &Arc<Session>,
        blocks: &[Value],
        client: &str,
        prompt_id: Option<&str>,
    ) -> Option<Result<Value, RpcError>> {
        if !self.auto_held(session) {
            return None;
        }
        // A message the holder loop took from the Cloud inbox never goes back to it: it stays
        // owed in the chat's log until the chat may run here (`auto_inbox_owed`).
        if client == AUTO_CLIENT {
            return Some(Err(away_error(session)));
        }
        let holder = self.auto_holder.get()?;
        Some(holder.send_while_away(&session.id, blocks, prompt_id).await)
    }

    /// The chat with exactly this id, if this daemon has it.
    pub(crate) fn auto_session(&self, id: &str) -> Option<Arc<Session>> {
        self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(id).cloned()
    }

    /// Makes what the chat's log holds durable. Blocking: it syncs the log.
    pub(crate) fn auto_flush(&self, session: &Session) -> anyhow::Result<()> {
        self.store.flush_session(&session.id)
    }

    /// The chat's log records after `after`, as an export writes them (`transfer.rs`), each
    /// with its seq and its size as JSON: at most `count` of them and `bytes` in all, and
    /// always one. Blocking: it reads the log.
    pub(crate) fn auto_events(
        &self,
        session: &Session,
        after: u64,
        count: usize,
        bytes: usize,
    ) -> anyhow::Result<Vec<(u64, Value)>> {
        let mut records: Vec<(u64, Value)> = Vec::new();
        let mut total = 0usize;
        let mut failed = None;
        self.scan_events(&session.id, after, &mut |record| {
            let seq = record.seq;
            let (value, size) = match serde_json::to_value(&record)
                .and_then(|value| serde_json::to_vec(&value).map(|text| (value, text.len())))
            {
                Ok(sized) => sized,
                Err(error) => {
                    failed = Some(anyhow::Error::from(error));
                    return false;
                }
            };
            // A record too large for one append goes as a note of its size: the log's order
            // and numbering stay whole, and the folder's snapshot holds what it wrote.
            let (value, size) = if size > bytes {
                let note = json!({
                    "seq": seq, "at": record.at, "dir": record.dir, "kind": record.kind,
                    "msg": {"autoSessionOmitted": true, "bytes": size},
                });
                (note, 256)
            } else {
                (value, size)
            };
            if !records.is_empty() && total.saturating_add(size) > bytes {
                return false;
            }
            total = total.saturating_add(size);
            records.push((seq, value));
            records.len() < count
        })?;
        match failed {
            Some(error) => Err(error),
            None => Ok(records),
        }
    }

    /// Whether the chat's log or its prompt ledger holds prompt `prompt_id`. Blocking.
    pub(crate) fn auto_took_prompt(&self, session: &Session, prompt_id: &str) -> bool {
        self.knows_prompt(session, prompt_id, true)
    }

    /// Writes a Cloud inbox message into the chat's own log before it is acked, so a daemon
    /// that stops between the ack and the prompt's own record still has it (`auto_inbox`).
    pub(crate) fn auto_log_inbox(&self, session: &Session, n: u64, prompt_id: &str, text: &str) {
        self.append(
            session,
            "mux",
            AUTO_INBOX,
            json!({"n": n, "promptId": prompt_id, "text": text}),
        );
    }

    /// The inbox messages the chat's log holds (`auto_inbox`): `(prompt id, text)`, oldest
    /// first. Blocking: it reads the log.
    pub(crate) fn auto_inbox_logged(&self, session: &Session) -> Vec<(String, String)> {
        let mut logged: Vec<(String, String)> = Vec::new();
        let _ = self.store.scan_kinds(&session.id, &[AUTO_INBOX], &mut |record| {
            let field = |name: &str| record.msg.get(name).and_then(Value::as_str);
            if let (Some(id), Some(text)) = (field("promptId"), field("text"))
                && !logged.iter().any(|(known, _)| known == id)
            {
                logged.push((id.to_owned(), text.to_owned()));
            }
            true
        });
        logged
    }

    /// The logged inbox messages that no prompt of the chat ran or queued. Blocking.
    pub(crate) fn auto_inbox_owed(&self, session: &Session) -> Vec<(String, String)> {
        let mut owed = self.auto_inbox_logged(session);
        owed.retain(|(id, _)| !self.auto_took_prompt(session, id));
        owed
    }

    /// Every process of the chat: its agent, what runs under it, and whatever was started
    /// with the chat's id in its environment, which a tool's shell keeps after it detaches
    /// into its own session (`agent/command.rs` sets it on the agent).
    #[cfg(unix)]
    pub(crate) async fn auto_processes(
        &self,
        session: &Session,
    ) -> Vec<crate::agent_host::tree::Started> {
        use crate::agent_host::tree;
        let child = session.child.lock().await.clone();
        let mut found = match &child {
            Some(child) => child.harness_processes().await,
            None => Vec::new(),
        };
        let agent = child.as_ref().and_then(|child| child.pid);
        let id = session.id.clone();
        let marked = tokio::task::spawn_blocking(move || {
            let mut marked = tree::marked("ACPMUX_SESSION_ID", &id);
            if let Some(agent) = agent {
                let spared = tree::spared_now();
                marked.extend(
                    tree::all().into_iter().filter(|p| p.pid == agent && !spared.contains(&p.pid)),
                );
            }
            marked
        })
        .await
        .unwrap_or_default();
        for process in marked {
            if !found.iter().any(|known| known.pid == process.pid) {
                found.push(process);
            }
        }
        found
    }

    /// Sends `signal` to the chat's whole process tree, detached tool shells included. It
    /// looks again after each pass, so a process started meanwhile is reached too. Answers how
    /// many processes it signalled.
    #[cfg(unix)]
    pub(crate) async fn auto_signal_tree(&self, session: &Session, signal: i32) -> usize {
        use crate::agent_host::tree;
        let mut reached: Vec<tree::Started> = Vec::new();
        // A stop or a kill leaves nothing able to fork, so a second pass finds nothing new;
        // the bound is for a tree that keeps forking under a continue.
        for _pass in 0..4 {
            let fresh: Vec<tree::Started> = self
                .auto_processes(session)
                .await
                .into_iter()
                .filter(|p| !reached.contains(p))
                .collect();
            if fresh.is_empty() {
                break;
            }
            let batch = fresh.clone();
            let _ = tokio::task::spawn_blocking(move || tree::signal_still_running(&batch, signal))
                .await;
            reached.extend(fresh);
        }
        reached.len()
    }

    /// Kills the chat's whole process tree and ends the hub's hold on its agent. The chat's
    /// transcript and folder stay, and it stays resumable.
    #[cfg(unix)]
    pub(crate) async fn auto_kill_tree(&self, session: &Arc<Session>) -> usize {
        // First, so a stopped process dies at once instead of waiting out a polite end.
        let killed = self.auto_signal_tree(session, libc::SIGKILL).await;
        self.detach_child(session).await;
        killed + self.auto_signal_tree(session, libc::SIGKILL).await
    }

    #[cfg(not(unix))]
    pub(crate) async fn auto_signal_tree(&self, _session: &Session, _signal: i32) -> usize {
        0
    }

    #[cfg(not(unix))]
    pub(crate) async fn auto_kill_tree(&self, session: &Arc<Session>) -> usize {
        self.detach_child(session).await;
        0
    }

    /// The chat's queued prompts, each with its id and its whole text (a snapshot's `queue`).
    pub(crate) fn auto_queue(&self, session: &Session) -> Vec<(String, String)> {
        session
            .queue()
            .into_iter()
            .map(|queued| {
                let text = queued
                    .run
                    .blocks
                    .iter()
                    .filter_map(|block| block.get("text").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join("\n");
                (queued.prompt_id, text)
            })
            .collect()
    }
}
