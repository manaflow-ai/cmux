//! `conversation-import`: history from another store, appended once
//! (plans/cmux-next/home-state-ownership.md section 7). The one time the owner
//! keeps a message's own author and time: the Chief home's first launch moves
//! each build's old Chief history into its owner. The owner still assigns
//! every seq and the rev, and refuses what would put history out of order:
//! imported times must not go backward, must not pass the newest message the
//! conversation holds, and must not be in the future. A message whose key
//! (author and client id, or its id) the conversation already holds is
//! skipped, so a retry imports nothing twice. Only a trusted local user
//! connection may import (server/conversations.rs); the remote relay never
//! forwards the command.

use cmux_conversation::{Part, Summary};
use serde::{Deserialize, Serialize};

use super::ConversationStore;

/// One message to import, as the store it comes from had it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct ImportedMessage {
    /// Kept when given and not yet used anywhere; else the owner makes one.
    #[serde(default)]
    pub id: Option<String>,
    pub client_msg_id: String,
    pub author: String,
    pub parts: Vec<Part>,
    /// RFC 3339 UTC with milliseconds (`2026-10-06T03:06:01.998Z`), the
    /// owner's own format.
    pub created_at: String,
}

/// What an import did.
#[derive(Debug, Clone)]
pub(crate) struct ImportOutcome {
    pub summary: Summary,
    /// The seqs the imported messages got, in order.
    pub imported: Vec<u64>,
    /// Messages the conversation already held.
    pub skipped: usize,
}

/// The owner's time format: `YYYY-MM-DDTHH:MM:SS.mmmZ`.
#[allow(dead_code)]
fn valid_time(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 24
        && bytes.iter().enumerate().all(|(index, byte)| match index {
            4 | 7 => *byte == b'-',
            10 => *byte == b'T',
            13 | 16 => *byte == b':',
            19 => *byte == b'.',
            23 => *byte == b'Z',
            _ => byte.is_ascii_digit(),
        })
}

impl ConversationStore {
    /// Appends `messages` to `conversation` in one transaction with their own
    /// authors and times. One rev for the whole import.
    pub(crate) fn import(&mut self, conversation: &str, messages: &[ImportedMessage]) -> anyhow::Result<ImportOutcome> {
        let _ = (conversation, messages, &self.connection);
        anyhow::bail!("conversation-import is not built yet")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_conversation::{Op, Participant, Reject};

    fn participants() -> Vec<Participant> {
        serde_json::from_value(serde_json::json!([
            {"id":"user_local","kind":"human","display_name":"Me"},
            {"id":"agent_mux","kind":"agent","display_name":"Chief","agent_class":"mux","acp_session":"mux"}
        ]))
        .unwrap()
    }

    fn message(id: &str, author: &str, key: &str, text: &str, at: &str) -> ImportedMessage {
        ImportedMessage {
            id: Some(id.to_string()),
            client_msg_id: key.to_string(),
            author: author.to_string(),
            parts: vec![Part::Text { text: text.to_string(), runs: None }],
            created_at: at.to_string(),
        }
    }

    fn history() -> Vec<ImportedMessage> {
        vec![
            message("msg_b1", "user_local", "cmk_1", "hi", "2026-10-06T03:06:01.998Z"),
            message("msg_b2", "agent_mux", "turn:optchat:0:x", "Hello.", "2026-10-06T03:06:04.622Z"),
            message("msg_c1", "user_local", "cmk_3", "What are my agents doing?", "2026-10-06T04:55:30.495Z"),
        ]
    }

    fn store_with_chief() -> (ConversationStore, String) {
        let mut store = ConversationStore::open(None).unwrap();
        let id = store.create("home-chief", "user_local", "Chief", &participants()).unwrap().summary.id;
        (store, id)
    }

    #[test]
    fn an_import_keeps_authors_times_and_ids_and_the_owner_assigns_seqs() {
        let (mut store, id) = store_with_chief();
        let outcome = store.import(&id, &history()).unwrap();
        assert_eq!(outcome.imported, vec![1, 2, 3]);
        assert_eq!(outcome.skipped, 0);
        assert_eq!(outcome.summary.last_seq, 3);
        assert_eq!(outcome.summary.rev, 2, "one rev for the whole import");
        let (_, messages) = store.snapshot(&id, 10).unwrap();
        let shown: Vec<_> = messages.iter().map(|m| (m.seq, m.id.as_str(), m.author.as_str(), m.created_at.as_str())).collect();
        assert_eq!(shown, vec![
            (1, "msg_b1", "user_local", "2026-10-06T03:06:01.998Z"),
            (2, "msg_b2", "agent_mux", "2026-10-06T03:06:04.622Z"),
            (3, "msg_c1", "user_local", "2026-10-06T04:55:30.495Z"),
        ]);
    }

    #[test]
    fn a_retry_imports_nothing_twice() {
        let (mut store, id) = store_with_chief();
        store.import(&id, &history()).unwrap();
        let again = store.import(&id, &history()).unwrap();
        assert!(again.imported.is_empty());
        assert_eq!(again.skipped, 3);
        assert_eq!(again.summary.rev, 2, "a replay commits nothing");
        let mut more = history();
        more.push(message("msg_d1", "user_local", "cmk_4", "later", "2026-10-06T05:00:00.000Z"));
        let next = store.import(&id, &more).unwrap();
        assert_eq!((next.imported, next.skipped), (vec![4], 3));
    }

    #[test]
    fn history_older_than_what_the_conversation_holds_is_refused() {
        let (mut store, id) = store_with_chief();
        let op = Op::MessageSend {
            client_msg_id: "now-1".into(),
            parts: vec![Part::Text { text: "typed now".into(), runs: None }],
            reply_to: None,
        };
        store.apply_op(&id, "now-1", "user_local", &op).unwrap();
        let error = store.import(&id, &history()).unwrap_err().to_string();
        assert!(error.contains("import_out_of_order"), "{error}");
        assert_eq!(store.snapshot(&id, 10).unwrap().0.last_seq, 1, "nothing was written");
    }

    #[test]
    fn times_that_go_backward_or_into_the_future_and_strangers_are_refused() {
        let (mut store, id) = store_with_chief();
        let mut backward = history();
        backward.swap(0, 1);
        assert!(store.import(&id, &backward).unwrap_err().to_string().contains("goes backward"));
        let future = vec![message("msg_f", "user_local", "cmk_f", "x", "2999-01-01T00:00:00.000Z")];
        assert!(store.import(&id, &future).unwrap_err().to_string().contains("future"));
        let stranger = vec![message("msg_s", "agent_other", "cmk_s", "x", "2026-10-06T03:00:00.000Z")];
        let error = store.import(&id, &stranger).unwrap_err();
        assert_eq!(error.downcast_ref::<super::super::ConversationRejected>().map(|r| r.0), Some(Reject::NotParticipant));
        let bad_time = vec![message("msg_t", "user_local", "cmk_t", "x", "2026-10-06T03:00:00Z")];
        assert!(store.import(&id, &bad_time).is_err());
        assert_eq!(store.snapshot(&id, 10).unwrap().0.last_seq, 0);
    }

    #[test]
    fn an_imported_history_survives_a_reopen() {
        let directory = std::env::temp_dir().join(format!("cmux-import-{}", crate::workspace_registry::new_uuid_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let id = {
            let mut store = ConversationStore::open(Some(&directory)).unwrap();
            let id = store.create("home-chief", "user_local", "Chief", &participants()).unwrap().summary.id;
            store.import(&id, &history()).unwrap();
            id
        };
        let mut store = ConversationStore::open(Some(&directory)).unwrap();
        let (summary, messages) = store.snapshot(&id, 10).unwrap();
        assert_eq!(summary.last_seq, 3);
        assert_eq!(messages[2].created_at, "2026-10-06T04:55:30.495Z");
        drop(store);
        std::fs::remove_dir_all(&directory).unwrap();
    }
}
