use std::collections::HashMap;

use serde_json::json;

use super::*;

const ALICE: &str = "user_local";
const MUX: &str = "agent_mux";
const EVE: &str = "user_eve";
const NOW: &str = "2026-10-01T12:00:00.000Z";

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
        };
        self.run(actor, key, op).unwrap().message.unwrap()
    }
}

#[test]
fn conversation_create_validates_participants_and_title() {
    let head = new_head();
    assert_eq!(head.rev, 1);
    assert_eq!(head.last_seq, 0);
    let create_with = |actor: &str, title: &str, participants: &[Participant]| {
        create(&CreateRequest { id: "conv_X", actor, title, participants, now: NOW })
    };
    assert_eq!(create_with(EVE, "t", &[human(ALICE)]), Err(Reject::NotParticipant));
    assert_eq!(create_with(ALICE, "", &[human(ALICE)]), Err(Reject::InvalidTitle));
    assert_eq!(create_with(ALICE, &"x".repeat(201), &[human(ALICE)]), Err(Reject::InvalidTitle));
    assert!(create_with(ALICE, &"é".repeat(200), &[human(ALICE)]).is_ok());
    assert_eq!(create_with(ALICE, "t", &[]), Err(Reject::InvalidParticipant));
    assert_eq!(
        create_with(ALICE, "t", &[human(ALICE), human(ALICE)]),
        Err(Reject::DuplicateParticipant)
    );
    // A human must use `user_`, an agent `agent_`.
    let mut wrong_kind = human(MUX);
    wrong_kind.agent_class = None;
    assert_eq!(
        create_with(ALICE, "t", &[human(ALICE), wrong_kind]),
        Err(Reject::InvalidParticipant)
    );
    assert_eq!(create_with("bob", "t", &[human("bob")]), Err(Reject::InvalidParticipant));
}

#[test]
fn conversation_send_assigns_dense_seq_and_requires_matching_client_msg_id() {
    let mut host = Host::new();
    let first = host.send(ALICE, "c1", "hi");
    let second = host.send(MUX, "c2", "hello");
    assert_eq!((first.seq, second.seq), (1, 2));
    assert_eq!(host.head.last_seq, 2);
    assert_eq!(host.head.rev, 3);
    let mismatched =
        Op::MessageSend { client_msg_id: "c3".to_string(), parts: vec![text("x")], reply_to: None };
    assert_eq!(host.run(ALICE, "other", mismatched).unwrap_err(), Reject::InvalidClientMsgId);
    let outsider =
        Op::MessageSend { client_msg_id: "c4".to_string(), parts: vec![text("x")], reply_to: None };
    assert_eq!(host.run(EVE, "c4", outsider).unwrap_err(), Reject::NotParticipant);
    assert_eq!(host.head.rev, 3);
}

#[test]
fn conversation_parts_are_bounded() {
    let mut host = Host::new();
    let send = |parts: Vec<Part>| Op::MessageSend {
        client_msg_id: "k".to_string(),
        parts,
        reply_to: None,
    };
    for parts in [
        vec![],
        vec![text("x"); 17],
        vec![text("")],
        vec![text(&"a".repeat(MAX_TEXT_BYTES)), text("b")],
        vec![Part::Text {
            text: "héllo".to_string(),
            runs: Some(vec![TextRun { start: 3, length: 3, mention: None, link: None }]),
        }],
        vec![Part::Text {
            text: "hi".to_string(),
            runs: Some(vec![TextRun {
                start: 0,
                length: 2,
                mention: Some("nobody".to_string()),
                link: None,
            }]),
        }],
        vec![Part::Work {
            session: String::new(),
            host: None,
            status: WorkStatus::Running,
            preview: None,
        }],
    ] {
        assert_eq!(host.run(ALICE, "k", send(parts)).unwrap_err(), Reject::InvalidParts);
    }
    assert!(host.run(ALICE, "k", send(vec![text("x"); 16])).is_ok());
    let edge = vec![Part::Text {
        text: "@mux 👋".to_string(),
        runs: Some(vec![
            TextRun { start: 0, length: 4, mention: Some(MUX.to_string()), link: None },
            TextRun { start: 5, length: 2, mention: None, link: None },
        ]),
    }];
    let mut op = send(edge);
    if let Op::MessageSend { client_msg_id, .. } = &mut op {
        *client_msg_id = "k2".to_string();
    }
    assert!(host.run(ALICE, "k2", op).is_ok());
}

#[test]
fn conversation_reply_to_must_name_an_existing_part() {
    let mut host = Host::new();
    let first = host.send(ALICE, "c1", "question");
    let reply = |message_id: &str, part_index: u32, key: &str| Op::MessageSend {
        client_msg_id: key.to_string(),
        parts: vec![text("answer")],
        reply_to: Some(PartRef { message_id: message_id.to_string(), part_index }),
    };
    assert_eq!(
        host.run(MUX, "c2", reply("msg_nope", 0, "c2")).unwrap_err(),
        Reject::UnknownMessage
    );
    assert_eq!(
        host.run(MUX, "c2", reply(&first.id, 1, "c2")).unwrap_err(),
        Reject::InvalidPartIndex
    );
    let sent = host.run(MUX, "c2", reply(&first.id, 0, "c2")).unwrap().message.unwrap();
    assert_eq!(sent.reply_to.unwrap().message_id, first.id);
}

#[test]
fn conversation_edit_and_retract_are_author_only() {
    let mut host = Host::new();
    let message = host.send(ALICE, "c1", "draft");
    let edit =
        |id: &str| Op::MessageEdit { message_id: id.to_string(), parts: vec![text("final")] };
    assert_eq!(host.run(MUX, "e1", edit(&message.id)).unwrap_err(), Reject::NotAuthor);
    assert_eq!(host.run(ALICE, "e1", edit("msg_missing")).unwrap_err(), Reject::UnknownMessage);
    let commit = host.run(ALICE, "e1", edit(&message.id)).unwrap();
    let Change::MessageUpdated { message: edited } = commit.change else { panic!("edit change") };
    assert_eq!(edited.parts, vec![text("final")]);
    assert_eq!(edited.edited_at.as_deref(), Some(NOW));
    let retract = Op::MessageRetract { message_id: message.id.clone() };
    assert_eq!(host.run(MUX, "r1", retract.clone()).unwrap_err(), Reject::NotAuthor);
    let retracted = host.run(ALICE, "r1", retract.clone()).unwrap().message.unwrap();
    assert!(retracted.parts.is_empty());
    assert_eq!(retracted.retracted_at.as_deref(), Some(NOW));
    assert_eq!(host.run(ALICE, "r2", retract).unwrap_err(), Reject::Retracted);
    assert_eq!(host.run(ALICE, "e2", edit(&message.id)).unwrap_err(), Reject::Retracted);
}

#[test]
fn conversation_concurrent_reactions_from_two_authors_both_survive() {
    let mut host = Host::new();
    let message = host.send(ALICE, "c1", "ship it?");
    let love = ReactionKind::Tapback(Tapback::Love);
    let add = |reaction: ReactionKind| Op::ReactionAdd {
        message_id: message.id.clone(),
        part_index: 0,
        reaction,
    };
    host.run(ALICE, "a1", add(love.clone())).unwrap();
    host.run(MUX, "a2", add(love.clone())).unwrap();
    assert_eq!(host.run(MUX, "a3", add(love.clone())).unwrap_err(), Reject::DuplicateReaction);
    host.run(MUX, "a4", add(ReactionKind::Emoji("🎉".to_string()))).unwrap();
    let stored = host.find(&message.id).unwrap();
    assert_eq!(stored.reactions.len(), 3);
    let remove =
        Op::ReactionRemove { message_id: message.id.clone(), part_index: 0, reaction: love };
    host.run(ALICE, "d1", remove.clone()).unwrap();
    assert_eq!(host.run(ALICE, "d2", remove).unwrap_err(), Reject::UnknownReaction);
    let stored = host.find(&message.id).unwrap();
    let authors =
        stored.reactions.iter().map(|reaction| reaction.author.as_str()).collect::<Vec<_>>();
    assert_eq!(authors, vec![MUX, MUX]);
    assert_eq!(
        host.run(ALICE, "a5", add(ReactionKind::Emoji(String::new()))).unwrap_err(),
        Reject::InvalidReaction
    );
    let out_of_range = Op::ReactionAdd {
        message_id: message.id.clone(),
        part_index: 1,
        reaction: ReactionKind::Tapback(Tapback::Like),
    };
    assert_eq!(host.run(ALICE, "a6", out_of_range).unwrap_err(), Reject::InvalidPartIndex);
}

#[test]
fn conversation_message_changes_keep_the_list_order() {
    let mut host = Host::new();
    let message = host.send(ALICE, "c1", "hi");
    host.now = "2026-10-01T13:00:00.000Z";
    let love = ReactionKind::Tapback(Tapback::Love);
    let id = message.id;
    for (key, op) in [
        ("a1", Op::ReactionAdd { message_id: id.clone(), part_index: 0, reaction: love.clone() }),
        ("e1", Op::MessageEdit { message_id: id.clone(), parts: vec![text("edited")] }),
        (
            "d1",
            Op::ReactionRemove { message_id: id.clone(), part_index: 0, reaction: love.clone() },
        ),
        ("a2", Op::ReactionAdd { message_id: id.clone(), part_index: 0, reaction: love.clone() }),
        ("r1", Op::MessageRetract { message_id: id.clone() }),
    ] {
        host.run(ALICE, key, op).unwrap();
        assert_eq!(host.head.updated_at, NOW, "{key} must not reorder the list");
    }
    let remove = Op::ReactionRemove { message_id: id, part_index: 0, reaction: love };
    assert_eq!(host.run(ALICE, "d2", remove).unwrap_err(), Reject::Retracted);
    host.run(ALICE, "t1", Op::TitleSet { title: "renamed".to_string() }).unwrap();
    assert_eq!(host.head.updated_at, "2026-10-01T13:00:00.000Z");
}

#[test]
fn conversation_read_cursor_is_monotonic_and_bounded() {
    let mut host = Host::new();
    host.send(ALICE, "c1", "one");
    host.send(ALICE, "c2", "two");
    let set = |seq| Op::ReadCursorSet { seq };
    assert_eq!(host.run(MUX, "r0", set(3)).unwrap_err(), Reject::CursorOutOfRange);
    let commit = host.run(MUX, "r1", set(2)).unwrap();
    assert_eq!(commit.change, Change::ReadCursor { participant: MUX.to_string(), seq: 2 });
    assert_eq!(host.head.read_cursors.get(MUX), Some(&2));
    assert_eq!(host.run(MUX, "r2", set(1)).unwrap_err(), Reject::CursorRegression);
    assert_eq!(host.run(EVE, "r3", set(1)).unwrap_err(), Reject::NotParticipant);
}

#[test]
fn conversation_participants_and_title_emit_a_summary() {
    let mut host = Host::new();
    let last = host.send(ALICE, "c1", "hi");
    let commit = host.run(ALICE, "p1", Op::ParticipantsAdd { participant: human(EVE) }).unwrap();
    let Change::Conversation { conversation } = commit.change else { panic!("summary change") };
    assert_eq!(conversation.participants.len(), 3);
    assert_eq!(conversation.owner, OWNER_LOCAL);
    assert_eq!(conversation.last_message.unwrap().id, last.id);
    assert_eq!(
        host.run(ALICE, "p2", Op::ParticipantsAdd { participant: human(EVE) }).unwrap_err(),
        Reject::DuplicateParticipant
    );
    assert_eq!(
        host.run(EVE, "t1", Op::TitleSet { title: String::new() }).unwrap_err(),
        Reject::InvalidTitle
    );
    host.run(EVE, "t2", Op::TitleSet { title: "Team".to_string() }).unwrap();
    assert_eq!(host.head.title, "Team");
    assert!(check_typing(&host.head, EVE).is_ok());
    assert_eq!(check_typing(&host.head, "user_zed"), Err(Reject::NotParticipant));
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

#[test]
fn conversation_ids_and_timestamps_are_fixed_width() {
    assert_eq!(format_rfc3339_millis(0), "1970-01-01T00:00:00.000Z");
    assert_eq!(format_rfc3339_millis(951_782_400_123), "2000-02-29T00:00:00.123Z");
    assert_eq!(format_rfc3339_millis(1_790_000_000_999), "2026-09-21T14:13:20.999Z");
    let id = encode_id("conv_", 1_790_000_000_999, [0xFF; 10]);
    assert_eq!(id.len(), 5 + 26);
    assert!(id.ends_with("ZZZZZZZZZZZZZZZZ"));
    assert!(encode_id("msg_", 1, [0; 10]) < encode_id("msg_", 2, [0; 10]));
}

/// xorshift64*: a deterministic generator for the op-sequence test.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_F491_4F6C_DD1D)
    }

    fn below(&mut self, bound: u64) -> u64 {
        self.next() % bound
    }
}

fn random_op(rng: &mut Rng, host: &Host, key: &str) -> Op {
    let message_id = if host.messages.is_empty() || rng.below(8) == 0 {
        "msg_unknown".to_string()
    } else {
        host.messages[rng.below(host.messages.len() as u64) as usize].id.clone()
    };
    let reaction = match rng.below(3) {
        0 => ReactionKind::Tapback(Tapback::Love),
        1 => ReactionKind::Tapback(Tapback::Laugh),
        _ => ReactionKind::Emoji("🎉".to_string()),
    };
    let part_index = rng.below(2) as u32;
    match rng.below(9) {
        0..=2 => Op::MessageSend {
            client_msg_id: key.to_string(),
            parts: vec![text("x"); 1 + rng.below(2) as usize],
            reply_to: None,
        },
        3 => Op::MessageEdit { message_id, parts: vec![text("edited")] },
        4 => Op::MessageRetract { message_id },
        5 => Op::ReactionAdd { message_id, part_index, reaction },
        6 => Op::ReactionRemove { message_id, part_index, reaction },
        7 => Op::ReadCursorSet { seq: rng.below(host.head.last_seq + 2) },
        _ => Op::TitleSet { title: format!("title {}", rng.below(100)) },
    }
}

#[test]
fn conversation_random_op_sequences_keep_the_invariants() {
    for seed in 1..=64_u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let mut host = Host::new();
        let mut authors = HashMap::new();
        for step in 0..400 {
            let actor = [ALICE, MUX, EVE][rng.below(3) as usize];
            let key = format!("k{seed}-{step}");
            let op = random_op(&mut rng, &host, &key);
            let before = host.head.clone();
            let target_author = op.target_message_id().and_then(|id| authors.get(id).cloned());
            match host.run(actor, &key, op.clone()) {
                Ok(commit) => {
                    assert_ne!(actor, EVE, "seed {seed} step {step}: outsider committed");
                    assert_eq!(commit.head.rev, before.rev + 1, "seed {seed}: rev +1 per op");
                    if let Op::MessageSend { .. } = op {
                        let message = commit.message.as_ref().unwrap();
                        assert_eq!(commit.head.last_seq, before.last_seq + 1);
                        assert_eq!(message.seq, commit.head.last_seq);
                        authors.insert(message.id.clone(), actor.to_string());
                    } else {
                        assert_eq!(commit.head.last_seq, before.last_seq);
                    }
                    if let Op::MessageRetract { .. } | Op::MessageEdit { .. } = op {
                        assert_eq!(target_author.as_deref(), Some(actor), "seed {seed}");
                    }
                }
                Err(reject) => {
                    assert_eq!(host.head, before, "seed {seed}: a reject changes nothing");
                    if actor == EVE {
                        assert_eq!(reject, Reject::NotParticipant);
                    }
                }
            }
            for (participant, seq) in &host.head.read_cursors {
                assert!(*seq <= host.head.last_seq, "seed {seed}: cursor past last_seq");
                assert!(
                    *seq >= before.read_cursors.get(participant).copied().unwrap_or(0),
                    "seed {seed}: cursor regressed"
                );
            }
            for (index, message) in host.messages.iter().enumerate() {
                assert_eq!(message.seq, index as u64 + 1, "seed {seed}: seq is dense");
                for (position, reaction) in message.reactions.iter().enumerate() {
                    assert!((reaction.part_index as usize) < message.parts.len());
                    assert!(
                        !message.reactions[..position].iter().any(|earlier| {
                            earlier.author == reaction.author
                                && earlier.part_index == reaction.part_index
                                && earlier.kind == reaction.kind
                        }),
                        "seed {seed}: duplicate reaction"
                    );
                }
            }
        }
    }
}

#[test]
fn conversation_work_cards_do_not_hide_the_agent_text_streak() {
    let mut head = new_head();
    let mut now = 1_790_000_000_000_u64;
    let text = vec![Part::Text { text: "x".to_string(), runs: None }];
    let card = vec![Part::Work {
        session: "child".to_string(),
        host: None,
        status: WorkStatus::Running,
        preview: None,
    }];
    for turn in 0..MAX_AGENT_TURNS {
        for card_index in 0..10 {
            let key = format!("card-{turn}-{card_index}");
            head = send_as(&head, MUX, &key, card.clone(), now).head;
        }
        now += 10_000;
        assert_eq!(check_agent_streak(&head, MUX, &text, now), Ok(()));
        head = send_as(&head, MUX, &format!("text-{turn}"), text.clone(), now).head;
    }
    assert_eq!(head.agent_text_streak as usize, MAX_AGENT_TURNS);
    now += 10_000;
    assert_eq!(check_agent_streak(&head, MUX, &text, now), Err(Reject::AgentBudget));
    assert_eq!(check_agent_streak(&head, MUX, &card, now), Ok(()));
    head = send_as(&head, ALICE, "human", text.clone(), now).head;
    assert_eq!(head.agent_text_streak, 0);
    assert_eq!(check_agent_streak(&head, MUX, &text, now + 1), Ok(()));
    head = send_as(&head, MUX, "reply", text.clone(), now + 1).head;
    assert_eq!(check_agent_streak(&head, MUX, &text, now + 2), Err(Reject::AgentRate));
    assert_eq!(check_agent_streak(&head, MUX, &text, now + 2_001), Ok(()));
}

fn send_as(
    head: &ConversationHead,
    actor: &str,
    key: &str,
    parts: Vec<Part>,
    now_ms: u64,
) -> Commit {
    let op = Op::MessageSend { client_msg_id: key.to_string(), parts, reply_to: None };
    let now = format_rfc3339_millis(now_ms);
    let id = format!("msg_{key}");
    let request = OpRequest {
        actor,
        idempotency_key: key,
        op: &op,
        now: &now,
        new_message_id: &id,
        target: None,
        reply_target: None,
        last_message: None,
    };
    apply(head, &request).unwrap()
}
