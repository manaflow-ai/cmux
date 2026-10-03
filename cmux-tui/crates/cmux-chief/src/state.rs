//! The brain host's durable state (`$MUX_HOME/state/host.json`). Same JSON
//! as `mux/host/src/state.ts`, so either host takes over the other's state.
//! Every entry is a durable to-do whose effect an owner dedupes (acpmux by
//! promptId, the conversation owner by idempotency key).

use std::collections::BTreeMap;

use cmux_conversation::{Op, WorkStatus};
use serde::{Deserialize, Serialize};

/// Most answered prompt ids kept.
pub const MAX_ANSWERED: usize = 2_000;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HostState {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_conversation: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mux_session_id: Option<String>,
    /// The seq of the last turn end the host settled.
    #[serde(default)]
    pub acpmux_seq: u64,
    /// Reply-key epoch, set when the core resets to a log whose turn seqs
    /// may repeat keys already used (`rules::turn_key`; the rule is in
    /// `Core::acpmux_connected`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acpmux_epoch: Option<u64>,
    /// The mux log's identity: the `at` of its seq 1 event, once known.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub acpmux_log: Option<u64>,
    /// Prompts sent (or to send) whose turn has not ended.
    #[serde(default)]
    pub prompts: BTreeMap<String, OutstandingPrompt>,
    /// Prompt ids whose turn ended, newest last.
    #[serde(default)]
    pub answered: Vec<String>,
    /// Conversation ops not yet confirmed by the owner, in order.
    #[serde(default)]
    pub outbox: Vec<OutboxEntry>,
    /// Child agents: acpmux session id -> its work card.
    #[serde(default)]
    pub children: BTreeMap<String, ChildRecord>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct OutstandingPrompt {
    pub conversation: String,
    pub text: String,
    /// The human message it answers (inbox prompts only).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub seq: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutboxEntry {
    pub conversation: String,
    /// snake_case in host.json (the conversation owner's field name).
    #[serde(rename = "idempotency_key")]
    pub idempotency_key: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub rate_retried: bool,
    /// Not sent before this time (ms since the epoch).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub not_before: Option<u64>,
    pub op: Op,
    /// A work-card op: its message id comes from `children[child].message_id`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub child: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChildRecord {
    pub conversation: String,
    pub name: String,
    pub status: WorkStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message_id: Option<String>,
    pub edits: u64,
}

impl HostState {
    pub fn is_answered(&self, prompt_id: &str) -> bool {
        self.answered.iter().any(|id| id == prompt_id)
    }

    /// The prompt's turn ended: it leaves the outstanding set for good.
    pub fn mark_answered(&mut self, prompt_id: &str) {
        self.prompts.remove(prompt_id);
        if self.is_answered(prompt_id) {
            return;
        }
        self.answered.push(prompt_id.to_owned());
        if self.answered.len() > MAX_ANSWERED {
            let extra = self.answered.len() - MAX_ANSWERED;
            self.answered.drain(..extra);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_typescript_host_json() {
        let json = r#"{"defaultConversation":"conv_1","muxSessionId":"s1","acpmuxSeq":7,
            "prompts":{"msg_1":{"conversation":"conv_1","text":"t","seq":3}},"answered":["a"],
            "outbox":[{"conversation":"conv_1","idempotency_key":"turn:s1:2","rateRetried":true,
              "notBefore":10,"op":{"kind":"message.send","client_msg_id":"turn:s1:2","parts":[{"type":"text","text":"hi"}]}}],
            "children":{"s2":{"conversation":"conv_1","name":"w","status":"running","messageId":"msg_9","edits":1}}}"#;
        let state: HostState = serde_json::from_str(json).unwrap();
        assert_eq!(state.acpmux_seq, 7);
        assert!(state.outbox[0].rate_retried);
        assert_eq!(state.children["s2"].message_id.as_deref(), Some("msg_9"));
        let back: HostState =
            serde_json::from_value(serde_json::to_value(&state).unwrap()).unwrap();
        assert_eq!(back, state);
    }

    #[test]
    fn answered_is_bounded_and_removes_the_prompt() {
        let mut state = HostState::default();
        state.prompts.insert(
            "p".into(),
            OutstandingPrompt { conversation: "c".into(), text: "t".into(), seq: None },
        );
        state.mark_answered("p");
        assert!(state.prompts.is_empty() && state.is_answered("p"));
        for i in 0..MAX_ANSWERED + 5 {
            state.mark_answered(&format!("x{i}"));
        }
        assert_eq!(state.answered.len(), MAX_ANSWERED);
        assert!(!state.is_answered("p"));
    }
}
