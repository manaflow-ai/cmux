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

use anyhow::Context;
use cmux_conversation::{Message, Part, ParticipantKind, Reject, Summary, summary, valid_token};
use rusqlite::{TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

use super::{
    ConversationStore, load_head, load_message_by_seq, new_id, rejected, write_head, write_message,
};

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
    pub(crate) fn import(
        &mut self,
        conversation: &str,
        messages: &[ImportedMessage],
    ) -> anyhow::Result<ImportOutcome> {
        let now_ms = crate::workspace_registry::unix_epoch_ms()?;
        let now = cmux_conversation::format_rfc3339_millis(now_ms);
        let transaction =
            self.connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut head = load_head(&transaction, conversation)?
            .ok_or_else(|| rejected(Reject::UnknownConversation))?;
        let mut previous: Option<&str> = None;
        for message in messages {
            if head.participant(&message.author).is_none() {
                return Err(rejected(Reject::NotParticipant));
            }
            anyhow::ensure!(
                valid_token(&message.client_msg_id),
                "bad request: client_msg_id must be 1-128 printable ASCII characters"
            );
            anyhow::ensure!(
                !message.parts.is_empty(),
                "bad request: an imported message needs parts"
            );
            anyhow::ensure!(
                valid_time(&message.created_at),
                "bad request: created_at must be YYYY-MM-DDTHH:MM:SS.mmmZ"
            );
            anyhow::ensure!(
                message.created_at <= now,
                "bad request: import_out_of_order: created_at is in the future"
            );
            if let Some(previous) = previous {
                anyhow::ensure!(
                    previous <= message.created_at.as_str(),
                    "bad request: import_out_of_order: created_at goes backward"
                );
            }
            previous = Some(&message.created_at);
        }
        let mut held_keys = HashSet::new();
        let mut held_ids = HashSet::new();
        {
            let mut statement =
                transaction.prepare("SELECT message_json FROM message WHERE conversation = ?1")?;
            for row in statement.query_map(params![conversation], |row| row.get::<_, String>(0))? {
                let held: Message =
                    serde_json::from_str(&row?).context("conversation message is corrupt")?;
                held_keys.insert((held.author.clone(), held.client_msg_id.clone()));
                held_ids.insert(held.id);
            }
        }
        let mut fresh = Vec::new();
        let mut skipped = 0;
        for message in messages {
            let id_taken = match &message.id {
                Some(id) => {
                    held_ids.contains(id)
                        || transaction
                            .query_row("SELECT 1 FROM message WHERE id = ?1", params![id], |_| {
                                Ok(())
                            })
                            .is_ok()
                }
                None => false,
            };
            if held_keys.contains(&(message.author.clone(), message.client_msg_id.clone()))
                || id_taken
            {
                skipped += 1;
            } else {
                fresh.push(message);
            }
        }
        if let (Some(first), Some(last)) =
            (fresh.first(), load_message_by_seq(&transaction, conversation, head.last_seq)?)
        {
            anyhow::ensure!(
                first.created_at >= last.created_at,
                "bad request: import_out_of_order: the conversation already holds newer messages"
            );
        }
        let mut imported = Vec::with_capacity(fresh.len());
        for message in &fresh {
            head.last_seq += 1;
            let id = match &message.id {
                Some(id) => id.clone(),
                None => new_id("msg_", now_ms)?,
            };
            let human =
                head.participant(&message.author).is_some_and(|p| p.kind == ParticipantKind::Human);
            // The loop guard counts what the TS core counts: text or question messages are turns,
            // work cards and attachments are not (home-core import corpus, cx-weuj).
            if message.parts.iter().any(Part::counts_as_turn) {
                if human {
                    head.agent_text_streak = 0;
                } else {
                    head.agent_text_streak = head.agent_text_streak.saturating_add(1);
                    head.last_agent_text_at = Some(message.created_at.clone());
                }
            }
            write_message(
                &transaction,
                &Message {
                    id,
                    conversation: conversation.to_string(),
                    seq: head.last_seq,
                    client_msg_id: message.client_msg_id.clone(),
                    author: message.author.clone(),
                    parts: message.parts.clone(),
                    reply_to: None,
                    answers: Vec::new(),
                    answers_pending: Vec::new(),
                    created_at: message.created_at.clone(),
                    edited_at: None,
                    retracted_at: None,
                    reactions: Vec::new(),
                    origin: None,
                },
            )?;
            if message.created_at > head.updated_at {
                head.updated_at = message.created_at.clone();
            }
            imported.push(head.last_seq);
        }
        if !imported.is_empty() {
            head.rev += 1;
            write_head(&transaction, &head)?;
        }
        let last = load_message_by_seq(&transaction, conversation, head.last_seq)?;
        transaction.commit()?;
        Ok(ImportOutcome { summary: summary(&head, last.as_ref()), imported, skipped })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_conversation::Participant;

    /// The shared corpus case (home-core conversation-import-cases.json): the TypeScript core
    /// decides which imported messages are agent turns, and the local import must agree.
    #[test]
    fn an_imported_agent_work_card_is_not_an_agent_turn_as_the_corpus_says() {
        let corpus: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../backend/packages/home-core/conformance/conversation-import-cases.json"
        ))
        .unwrap();
        let case = corpus["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["name"] == "import: an imported agent work card is not an agent turn")
            .expect("the shared import case");
        let people: Vec<Participant> = serde_json::from_value(serde_json::json!([
            {"id":"user_me","kind":"human","display_name":"Me"},
            {"id":"agent_chief","kind":"agent","display_name":"Chief","agent_class":"mux"}
        ]))
        .unwrap();
        let messages: Vec<ImportedMessage> = case["params"]["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| ImportedMessage {
                id: None,
                client_msg_id: m["client_msg_id"].as_str().unwrap().to_string(),
                author: m["author"].as_str().unwrap().to_string(),
                parts: serde_json::from_value(m["parts"].clone()).unwrap(),
                created_at: cmux_conversation::format_rfc3339_millis(
                    cmux_conversation::parse_rfc3339_millis(m["created_at"].as_str().unwrap())
                        .unwrap(),
                ),
            })
            .collect();
        let mut store = ConversationStore::open(None).unwrap();
        let id = store.create("home-chief", "user_me", "Chief", &people).unwrap().summary.id;
        store.import(&id, &messages).unwrap();
        let head = load_head(&store.connection, &id).unwrap().unwrap();
        assert_eq!(
            u64::from(head.agent_text_streak),
            case["expect"]["head"]["agent_text_streak"].as_u64().unwrap()
        );
    }
}
