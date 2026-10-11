use serde_json::json;

use super::*;

const ALICE: &str = "user_local";

/// An in-memory host: the head plus every message by seq.
struct Host {
    head: ConversationHead,
    messages: Vec<Message>,
    next_id: u64,
    now: &'static str,
}

impl Host {
    fn new() -> Self {
        Self { head: new_head(), messages: Vec::new(), next_id: 1, now: NOW }
    }

    fn find(&self, id: &str) -> Option<&Message> {
        self.messages.iter().find(|message| message.id == id)
    }

    fn run(&mut self, actor: &str, key: &str, op: Op) -> Result<Commit, Reject> {
        let new_message_id = format!("msg_{:026}", self.next_id);
        let target = op.target_message_id().and_then(|id| self.find(id));
        let reply_target = op.reply_to().and_then(|reply| self.find(&reply.message_id));
        let request = OpRequest {
            actor,
            idempotency_key: key,
            op: &op,
            now: self.now,
            new_message_id: &new_message_id,
            target,
            reply_target,
            thread_target: op.thread_root().and_then(|root| self.find(root)),
            last_message: self.messages.last(),
        };
        let commit = apply(&self.head, &request)?;
        if op.is_send() {
            self.next_id += 1;
        }
        self.head = commit.head.clone();
        if let Some(message) = &commit.message {
            match self.messages.iter_mut().find(|stored| stored.id == message.id) {
                Some(stored) => *stored = message.clone(),
                None => self.messages.push(message.clone()),
            }
        }
        Ok(commit)
    }

    fn send(&mut self, actor: &str, key: &str, body: &str) -> Message {
        let op = Op::MessageSend {
            client_msg_id: key.to_string(),
            parts: vec![text(body)],
            reply_to: None,
            thread_root: None,
        };
        self.run(actor, key, op).unwrap().message.unwrap()
    }
}

#[test]
fn conversation_wire_shapes_match_the_contract() {
    let op: Op = serde_json::from_value(json!({
        "kind": "reaction.add", "message_id": "msg_1", "part_index": 0,
        "reaction": {"tapback": "love"}
    }))
    .unwrap();
    assert_eq!(
        op,
        Op::ReactionAdd {
            message_id: "msg_1".to_string(),
            part_index: 0,
            reaction: ReactionKind::Tapback(Tapback::Love),
        }
    );
    let op: Op = serde_json::from_value(json!({
        "kind": "message.send", "client_msg_id": "c1",
        "parts": [{"type": "text", "text": "hi"},
                  {"type": "work", "session": "s1", "status": "running"}]
    }))
    .unwrap();
    assert!(op.is_send());
    let change = Change::ReadCursor { participant: ALICE.to_string(), seq: 3 };
    assert_eq!(
        serde_json::to_value(change).unwrap(),
        json!({"kind": "read-cursor", "participant": ALICE, "seq": 3})
    );
    let mut host = Host::new();
    let message = host.send(ALICE, "c1", "hi");
    let value = serde_json::to_value(Change::MessageUpdated { message }).unwrap();
    assert_eq!(value["kind"], "message-updated");
    assert_eq!(value["message"]["parts"], json!([{"type": "text", "text": "hi"}]));
    assert_eq!(value["message"]["reactions"], json!([]));
    assert!(value["message"].get("edited_at").is_none());
    let codes = Reject::ALL.iter().map(|reject| reject.code()).collect::<Vec<_>>();
    for code in [
        "not_participant",
        "not_author",
        "unknown_message",
        "invalid_parts",
        "idempotency_conflict",
        "cursor_regression",
        "unknown_conversation",
    ] {
        assert!(codes.contains(&code), "{code}");
    }
}

const NOW: &str = "2026-10-01T12:00:00.000Z";

fn text(value: &str) -> Part {
    Part::Text { text: value.to_string(), runs: None }
}

fn new_head() -> ConversationHead {
    create(&CreateRequest {
        id: "conv_TEST",
        actor: ALICE,
        title: "mux",
        participants: &[human(ALICE), agent(MUX)],
        now: NOW,
    })
    .unwrap()
}

const MUX: &str = "agent_mux";

fn human(id: &str) -> Participant {
    Participant {
        id: id.to_string(),
        kind: ParticipantKind::Human,
        display_name: "Alice".to_string(),
        agent_class: None,
        acp_session: None,
        person: None,
    }
}

fn agent(id: &str) -> Participant {
    Participant {
        id: id.to_string(),
        kind: ParticipantKind::Agent,
        display_name: "mux".to_string(),
        agent_class: Some(AgentClass::Mux),
        acp_session: Some("mux".to_string()),
        person: None,
    }
}
