//! Permalink resolve on the local conversation owner (`conversation-tree-v1`):
//! a link `<scheme>://conversation/<id>[/message/<id>]` names one
//! conversation and maybe one message. Resolve returns what every UI needs to
//! open it: the conversation, the message, its thread root and its path in
//! the thread tree (root first), so the Messages Home and the Channels page
//! open the same message from the same link.

use cmux_conversation::{ConversationLink, Message, Reject, Summary, summary};
use rusqlite::Connection;
use serde::Serialize;

use super::{ConversationStore, load_head, load_message_by_id, load_message_by_seq, rejected};

/// Most parent steps a path follows. A tree deeper than this gives a path
/// that starts below the root (`truncated`); the UI still opens the message.
pub(crate) const MAX_PATH: usize = 256;

/// `conversation-link-resolve` data.
#[derive(Debug, Clone, Serialize)]
pub(crate) struct ResolvedLink {
    /// The canonical link.
    pub url: String,
    pub conversation: Summary,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<Message>,
    /// The top root of the message's thread; absent for a message that is
    /// not in a thread (and for a conversation link).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thread_root: Option<String>,
    /// Message ids from the thread root down to the message (both
    /// included), following `reply_to` parents. `[message]` for a message
    /// not in a thread; empty for a conversation link.
    pub path: Vec<String>,
    /// The path stops below the root (deeper than MAX_PATH).
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
}

impl ConversationStore {
    /// The conversation and message `link` names. An unknown conversation is
    /// `unknown_conversation`; an unknown message, or one of another
    /// conversation, is `unknown_message`.
    pub(crate) fn resolve_link(&mut self, link: &ConversationLink) -> anyhow::Result<ResolvedLink> {
        let transaction = self.connection.transaction()?;
        let head = load_head(&transaction, &link.conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        let last = load_message_by_seq(&transaction, &head.id, head.last_seq)?;
        let conversation = summary(&head, last.as_ref());
        let Some(message_id) = &link.message else {
            return Ok(ResolvedLink {
                url: link.url(),
                conversation,
                message: None,
                thread_root: None,
                path: Vec::new(),
                truncated: false,
            });
        };
        let message = load_message_by_id(&transaction, message_id)?
            .filter(|message| message.conversation == head.id)
            .ok_or_else(|| rejected(Reject::UnknownMessage))?;
        let (path, truncated) = thread_path(&transaction, &message)?;
        Ok(ResolvedLink {
            url: link.url(),
            conversation,
            thread_root: message.thread_root.clone(),
            message: Some(message),
            path,
            truncated,
        })
    }
}

/// The ids from `message`'s thread root down to `message`: each step goes to
/// the `reply_to` parent while that parent is in the same thread, then to
/// the root. A message not in a thread is its own path.
fn thread_path(connection: &Connection, message: &Message) -> anyhow::Result<(Vec<String>, bool)> {
    let mut path = vec![message.id.clone()];
    let Some(root) = message.thread_root.as_deref() else { return Ok((path, false)) };
    let mut current = message.clone();
    let mut truncated = false;
    loop {
        if path.len() >= MAX_PATH {
            truncated = true;
            break;
        }
        let parent = current
            .reply_to
            .as_ref()
            .map(|reply_to| reply_to.message_id.as_str())
            .filter(|parent| *parent != root && !path.iter().any(|id| id == parent));
        let Some(parent) = parent else {
            path.push(root.to_owned());
            break;
        };
        match load_message_by_id(connection, parent)? {
            Some(next)
                if next.conversation == message.conversation
                    && next.thread_root.as_deref() == Some(root) =>
            {
                path.push(next.id.clone());
                current = next;
            }
            // A parent outside the thread (a reply written before nesting):
            // the root is the next step.
            _ => {
                path.push(root.to_owned());
                break;
            }
        }
    }
    path.reverse();
    Ok((path, truncated))
}
