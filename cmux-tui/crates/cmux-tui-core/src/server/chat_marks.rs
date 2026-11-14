//! The daemon's acpmux calls for `chat.mark_read` and `chat.pin`
//! (`resource_router/chats.rs`): `_acpmux/markRead {sessionId}` and the pin tag
//! through `_acpmux/tag`. Each opens its own link to this machine's acpmux
//! socket and never starts acpmux; acpmux forwards a peer's chat to that peer.

use std::time::Duration;

use serde_json::{Value, json};

use super::{AcpmuxLink, LinkError};
use crate::mux::chat_index::{PIN_TAG, PINNED};

/// How long a mark waits for acpmux: it answers once the change is on disk.
const MARK_TIMEOUT: Duration = Duration::from_secs(10);

/// Why a chat mark did not happen.
#[derive(Debug)]
pub(crate) enum ChatMarkError {
    /// No acpmux socket, or acpmux did not answer.
    Unavailable(String),
    /// acpmux (or the chat's peer) answered with an error.
    Refused(String),
}

impl crate::mux::Mux {
    /// `_acpmux/markRead {sessionId}`: clears the chat's unread mark and count.
    pub(crate) fn acp_chat_mark_read(&self, chat: &str) -> Result<(), ChatMarkError> {
        self.acp_chat_call("_acpmux/markRead", json!({"sessionId": chat}))
    }

    /// Pins or unpins the chat: acpmux's [`PIN_TAG`] session tag.
    pub(crate) fn acp_chat_pin(&self, chat: &str, pinned: bool) -> Result<(), ChatMarkError> {
        let params = if pinned {
            json!({"sessionId": chat, "set": {PIN_TAG: PINNED}})
        } else {
            json!({"sessionId": chat, "remove": [PIN_TAG]})
        };
        self.acp_chat_call("_acpmux/tag", params)
    }

    fn acp_chat_call(&self, method: &str, params: Value) -> Result<(), ChatMarkError> {
        let socket = self
            .control_clients
            .agent_sessions
            .socket()
            .ok_or_else(|| ChatMarkError::Unavailable("acpmux is not running here".into()))?;
        let link = AcpmuxLink::connect(&socket, |_| {})
            .map_err(|error| ChatMarkError::Unavailable(format!("acpmux: {error}")))?;
        let answer = link.call(method, params, MARK_TIMEOUT);
        link.close();
        match answer {
            Ok(_) => Ok(()),
            Err(LinkError::Rpc(message, _) | LinkError::BadList(message)) => {
                Err(ChatMarkError::Refused(message))
            }
            Err(LinkError::MethodNotFound(message)) => Err(ChatMarkError::Refused(format!(
                "this acpmux does not know {method}: {message}"
            ))),
            Err(LinkError::Closed) => {
                Err(ChatMarkError::Unavailable("acpmux closed the link".into()))
            }
            Err(LinkError::Timeout | LinkError::Busy) => {
                Err(ChatMarkError::Unavailable("acpmux did not answer in time".into()))
            }
        }
    }
}
