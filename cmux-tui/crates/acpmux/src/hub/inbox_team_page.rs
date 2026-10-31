//! Part of `Hub`; see `hub/mod.rs`. A chat's inbox through the team mailbox's methods
//! (`_acpmux/team/inbox`, `/read`, `/ack`), for its own agent while team messaging (Labs
//! `meshRelay.teamMessaging`) is off (`server/team.rs` `chat_inbox`).
//!
//! An agent started before the inbox (#27686) has no `inbox_read` tool: its tools are fixed at
//! its start, and a daemon update does not restart it. Told of its inbox, it reaches for
//! `team_inbox` or `acpmux inbox` (Codex), the team mailbox's, which refused it while team
//! messaging was off. So it saw only the notice's 120-character preview of an order from its
//! owner (three helpers, 2026-10-31). With team messaging off those methods have no mailbox to
//! read, so they read the chat's own inbox instead, in the mailbox's page shape: each message
//! whole as its `body`, under its `messageId` (its prompt id). As in the mailbox, a page marks
//! nothing read (`acpmux inbox` shows each one's first line only); a read marks what it gives
//! read, as `inbox_read` does, and an ack marks one message read.

use super::*;

/// The note a page carries: what these messages are, and the tool that reads them.
const NOTE: &str = "Team messaging is off in Labs: these are this chat's own inbox messages, \
whole. inbox_read reads a thread (its threadId), inbox_reply answers in it.";

impl Hub {
    /// `_acpmux/team/inbox` of the chat's own agent: its inbox's messages, newest first, every
    /// one or only the unread ones. It marks none read.
    pub fn inbox_team_page(&self, session: &Session, unread_only: bool) -> Value {
        let inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
        let messages: Vec<Value> = inbox
            .items
            .iter()
            .rev()
            .filter(|i| !unread_only || !i.read)
            .map(|i| team_message(session, i))
            .collect();
        json!({"messages": messages, "next": null, "inbox": "chat", "sessionId": session.id, "note": NOTE})
    }

    /// `_acpmux/team/read` of the chat's own agent: message `id` whole, marked read; or, for a
    /// thread's id, the thread's messages joined (newest first) as one body.
    pub fn inbox_team_read(&self, session: &Session, id: &str) -> Result<Value, RpcError> {
        let (message, marked) = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(item) = inbox.items.iter_mut().find(|i| i.prompt_id == id) {
                let marked = (!item.read).then(|| (item.thread.clone(), vec![id.to_owned()]));
                item.read = true;
                (team_message(session, item), marked)
            } else if inbox.items.iter().any(|i| i.thread == id) {
                drop(inbox);
                let thread = self.inbox_thread(session, id, true);
                let messages = thread.get("messages").and_then(Value::as_array);
                let body = messages
                    .into_iter()
                    .flatten()
                    .map(|m| {
                        let field = |k: &str| m.get(k).and_then(Value::as_str);
                        format!(
                            "From {}:\n{}",
                            field("from").unwrap_or("?"),
                            field("text").unwrap_or("")
                        )
                    })
                    .collect::<Vec<_>>()
                    .join("\n\n---\n\n");
                let message = json!({"messageId": id, "threadId": id, "kind": "prompt", "body": body,
                    "to": {"sessionId": session.id}, "state": "read"});
                return Ok(json!({"message": message, "thread": thread, "note": NOTE}));
            } else {
                return Err(not_in_inbox(id));
            }
        };
        self.log_read(session, marked.into_iter().collect());
        Ok(json!({"message": message, "note": NOTE}))
    }

    /// `_acpmux/team/ack` of the chat's own agent: message `id` read.
    pub fn inbox_team_ack(&self, session: &Session, id: &str) -> Result<Value, RpcError> {
        let marked = {
            let mut inbox = session.inbox.lock().unwrap_or_else(|e| e.into_inner());
            let Some(item) = inbox.items.iter_mut().find(|i| i.prompt_id == id) else {
                return Err(not_in_inbox(id));
            };
            let marked = (!item.read).then(|| (item.thread.clone(), vec![id.to_owned()]));
            item.read = true;
            marked
        };
        self.log_read(session, marked.into_iter().collect());
        Ok(json!({"messageId": id, "state": "acked", "to": {"sessionId": session.id}}))
    }

    /// The `inbox_read` records of what a read or an ack marked read, one per thread.
    fn log_read(&self, session: &Session, marked: Vec<(String, Vec<String>)>) {
        for (thread, ids) in marked {
            self.append(
                session,
                "mux",
                "inbox_read",
                json!({"threadId": thread, "promptIds": ids}),
            );
        }
    }
}

/// One inbox message in the team mailbox's shape (`mesh::InMessage`).
fn team_message(session: &Session, item: &Item) -> Value {
    json!({
        "messageId": item.prompt_id, "threadId": item.thread, "label": label(&item.thread),
        "kind": "prompt", "class": kind_of(item.class), "body": item.text, "at": item.at,
        "from": {"name": item.from, "sessionId": item.from_session},
        "to": {"sessionId": session.id},
        "state": if item.read { "read" } else { "delivered" },
    })
}

fn not_in_inbox(id: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "inbox.not_found: no message or thread {id} in this chat's inbox"
    ))
    .with_data(json!({"reason": "inbox.not_found"}))
}
