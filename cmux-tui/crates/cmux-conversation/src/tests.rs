use std::collections::HashMap;

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
