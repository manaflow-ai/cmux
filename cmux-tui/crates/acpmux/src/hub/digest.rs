//! Part of `Hub`; see `hub/mod.rs`. Fan-in: other agents' messages to a busy chat go in
//! together, and the person's own prompts go first.
//!
//! A chat many agents write to (a coordinator) got one turn per queued message, each waiting for
//! the one before: 121 messages were 121 turns, with the person's own message behind them all
//! (2026-10-20). Two rules fix that. Neither drops, shortens, rewrites or reorders an agent's
//! words:
//!
//! - The person goes first: a prompt of the person's (`PromptRun::agent` is `None`) joins the
//!   queue ahead of every agent message waiting (`queue.rs` `enqueue`), behind the person's own
//!   earlier prompts and a prompt sent now.
//! - Agents go in together: when an agent message's turn starts, the agent messages waiting
//!   right behind it under the same rules join that turn (`take_joined`), each as it was sent,
//!   oldest first, under a line naming its sender (`digest_blocks`), up to
//!   [`DIGEST_MAX_BYTES`] of text; the rest goes in together as the next turn. A joined prompt
//!   leaves the queue with a `dequeued` record naming the turn (`joinedTurnId`), and its
//!   `session/prompt` answers with that turn's answer (`joined_reply`).
//!
//! Delivery inside a turn stays the steer's (`steer_end.rs`): an agent that steers reads a
//! message at its next tool boundary. What waits here is what could not steer: an agent that
//! does not steer, a steer its turn ended before reading, a `--no-steer` send, a send that waits
//! for its reply.
//!
//! Another agent's message is one with an agent's provenance (`prompt_provenance.rs`:
//! `agent_message`, `subsession_message`), one from a connection that proved it runs in an
//! acpmux session (`acpmux send` from an agent), or one that names its sender in
//! `_meta.acpmux.fromAgent` (`acpmux send --from`). Naming yourself an agent only puts you
//! later, so it needs no proof. Every other prompt is the person's, as before.

use super::*;
use std::sync::atomic::Ordering;

/// Text one turn of agent messages takes at most (the first message always goes in whole).
pub(super) const DIGEST_MAX_BYTES: usize = 128 * 1024;

/// Longest sender name in `_meta.acpmux.fromAgent`, in characters.
pub const MAX_FROM_AGENT_CHARS: usize = 64;

/// What a joined prompt's wait gets (`queue.rs` `QueuedPrompt::joined`): the turn it joined and,
/// once that turn ends, its answer.
#[derive(Debug)]
pub(super) struct Joined {
    pub(super) prompt_id: String,
    pub(super) turn_id: String,
    pub(super) answer: tokio::sync::watch::Receiver<Option<Answer>>,
}

/// One message in a turn of agent messages.
pub(super) struct Part {
    pub(super) prompt_id: String,
    pub(super) sender: String,
    pub(super) run: Arc<PromptRun>,
}

/// The sender of a prompt that is another agent's message, `None` for the person's. `declared`:
/// `_meta.acpmux.fromAgent`, or the name of the session a connection proved it runs in.
pub(super) fn agent_sender(provenance: Option<&Value>, declared: Option<&str>) -> Option<String> {
    if let Some(name) = declared {
        return Some(name.to_owned());
    }
    let p = provenance?;
    let kind = p.get("kind").and_then(Value::as_str);
    if !matches!(kind, Some("agent_message" | super::subsessions::PROVENANCE_KIND)) {
        return None;
    }
    let field = |k: &str| p.get(k).and_then(Value::as_str).filter(|v| !v.trim().is_empty());
    Some(field("fromName").or_else(|| field("from")).unwrap_or("another agent").to_owned())
}

/// `_meta.acpmux.fromAgent` of a `session/prompt`: `None` when absent or null.
pub fn declared_sender(params: &Value) -> Result<Option<String>, RpcError> {
    match params.pointer("/_meta/acpmux/fromAgent") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(name))
            if !name.trim().is_empty()
                && name.chars().count() <= MAX_FROM_AGENT_CHARS
                && !name.chars().any(|c| c.is_control()) =>
        {
            Ok(Some(name.trim().to_owned()))
        }
        Some(_) => Err(RpcError::invalid_params(format!(
            "fromAgent must be one line of 1 to {MAX_FROM_AGENT_CHARS} characters"
        ))
        .with_data(json!({"reason": "from_agent.value_refused"}))),
    }
}

/// The blocks of one turn of agent messages, `parts` oldest first: a line saying what follows,
/// then each message under a line naming its sender, its blocks as sent.
pub(super) fn digest_blocks(parts: &[Part]) -> Vec<Value> {
    let total = parts.len();
    let mut blocks = Vec::new();
    for (i, part) in parts.iter().enumerate() {
        let mut line = String::new();
        if i == 0 {
            line.push_str(&format!(
                "{total} messages from other agents arrived while you were busy. Each follows \
                 as it was sent, oldest first.\n\n"
            ));
        } else {
            line.push_str("\n\n");
        }
        line.push_str(&format!("[agent message {} of {total}] from {}\n", i + 1, part.sender));
        blocks.push(json!({"type": "text", "text": line}));
        blocks.extend(part.run.blocks.iter().cloned());
    }
    blocks
}

/// The provenance a turn of agent messages records on its `user_message`: who sent each one,
/// with its own provenance, so a client can show them as other agents' words.
pub(super) fn digest_provenance(parts: &[Part]) -> Value {
    let messages: Vec<Value> = parts
        .iter()
        .map(|part| {
            let mut m = json!({"promptId": part.prompt_id, "from": part.sender});
            if let Some(p) = &part.run.provenance {
                m["provenance"] = p.clone();
            }
            m
        })
        .collect();
    json!({"kind": DIGEST_KIND, "messages": messages})
}

/// The provenance kind of a turn of agent messages (`digest_provenance`).
pub const DIGEST_KIND: &str = "agent_digest";

/// What a joined prompt's `session/prompt` answers: the answer of the turn it joined, under its
/// own prompt id, naming that turn.
pub(super) async fn joined_reply(joined: &Joined, prompt_id: &str) -> Answer {
    let mut answer = joined.answer.clone();
    let answer = match answer.wait_for(Option::is_some).await {
        Ok(answer) => answer.clone().expect("waited for an answer"),
        Err(_) => Err(RpcError::internal("the turn this prompt joined was dropped")),
    };
    answer.map(|mut v| {
        merge_mux_meta(
            &mut v,
            json!({"promptId": prompt_id, "turnId": joined.turn_id, "joinedPromptId": joined.prompt_id}),
        );
        v
    })
}

impl Hub {
    /// The name of session `id` as the sender of a message: its id when it has no name or is gone.
    pub fn session_name(&self, id: &str) -> String {
        let name = self.resolve(id).ok().filter(|s| s.id == id).map(|s| s.meta().name);
        name.filter(|n| !n.trim().is_empty()).unwrap_or_else(|| id.to_owned())
    }

    /// With the turn lock held and the turn of the agent message `prompt_id` started: takes the
    /// agent messages waiting right behind it under the same rules out of the queue, oldest
    /// first, to go in with it. Held prompts wait where they are; anything else (the person's
    /// prompt, one sent now, one under other rules) ends the run. Each joined prompt's wait
    /// answers with `answer` once the turn ends.
    pub(super) fn take_joined(
        &self,
        session: &Arc<Session>,
        head: &PromptRun,
        prompt_id: &str,
        turn_id: &str,
        answer: &tokio::sync::watch::Sender<Option<Answer>>,
    ) -> Vec<Part> {
        if head.agent.is_none() {
            return Vec::new();
        }
        let mut bytes = prompt_text(&head.blocks).len();
        let taken: Vec<QueuedPrompt> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            let mut taken = Vec::new();
            let mut i = 0;
            while i < queue.len() {
                let q = &queue[i];
                if q.held {
                    i += 1;
                    continue;
                }
                let joins = q.run.agent.is_some()
                    && !q.steer
                    && !q.sent_now
                    && q.run.control == head.control
                    && q.run.trust_gate == head.trust_gate;
                let size = prompt_text(&q.run.blocks).len();
                if !joins || bytes + size > DIGEST_MAX_BYTES {
                    break;
                }
                bytes += size;
                let q = queue.remove(i);
                session.queued.fetch_sub(1, Ordering::SeqCst);
                let _ = q.joined.set(Joined {
                    prompt_id: prompt_id.to_owned(),
                    turn_id: turn_id.to_owned(),
                    answer: answer.subscribe(),
                });
                taken.push(q);
            }
            taken
        };
        if taken.is_empty() {
            return Vec::new();
        }
        session.queue_moved.notify_waiters();
        taken
            .into_iter()
            .map(|q| {
                self.append(
                    session,
                    "mux",
                    "dequeued",
                    json!({"promptId": q.prompt_id, "turnId": q.turn_id, "queued": session.queued(), "joinedPromptId": prompt_id, "joinedTurnId": turn_id}),
                );
                // A stored permit: the waiting task answers from `joined` (`queue_slot`).
                q.withdraw.notify_one();
                let sender = q.run.agent.clone().unwrap_or_default();
                Part { prompt_id: q.prompt_id, sender, run: q.run }
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(text: &str, agent: Option<&str>, provenance: Option<Value>) -> Arc<PromptRun> {
        Arc::new(PromptRun {
            blocks: vec![json!({"type": "text", "text": text})],
            control: Control::default(),
            trust_gate: false,
            provenance,
            agent: agent.map(str::to_owned),
        })
    }

    #[test]
    fn agent_messages_and_named_senders_are_agents_and_everything_else_is_the_person() {
        let message = json!({"kind": "agent_message", "from": "acp:s1", "fromName": "lane-a", "to": "acp:s2", "msgId": "m", "threadId": "t"});
        assert_eq!(agent_sender(Some(&message), None).as_deref(), Some("lane-a"));
        let sub = json!({"kind": "subsession_message", "from": "s1", "to": "s2"});
        assert_eq!(agent_sender(Some(&sub), None).as_deref(), Some("s1"));
        assert_eq!(agent_sender(None, Some("coord-deputy")).as_deref(), Some("coord-deputy"));
        assert_eq!(agent_sender(None, None), None, "a plain prompt is the person's");
        let resume = json!({"kind": "auto_resume", "promptId": "p", "attempt": 1, "turnId": "t"});
        assert_eq!(agent_sender(Some(&resume), None), None, "a continuation is the person's");
        let offer =
            json!({"kind": "offer_result", "offerId": "o", "childSessionId": "c", "title": "t"});
        assert_eq!(agent_sender(Some(&offer), None), None);
    }

    #[test]
    fn from_agent_is_one_short_line() {
        let named = |v: Value| declared_sender(&json!({"_meta": {"acpmux": {"fromAgent": v}}}));
        assert_eq!(named(json!(" lane-a ")).unwrap().as_deref(), Some("lane-a"));
        assert_eq!(named(Value::Null).unwrap(), None);
        assert!(named(json!("")).is_err());
        assert!(named(json!("two\nlines")).is_err());
        assert!(named(json!("x".repeat(65))).is_err());
        assert!(named(json!(7)).is_err());
        assert_eq!(declared_sender(&json!({})).unwrap(), None);
    }

    #[test]
    fn a_digest_keeps_every_message_whole_and_in_order_under_its_sender() {
        let parts = vec![
            Part {
                prompt_id: "p1".into(),
                sender: "lane-a".into(),
                run: run("first\nline two", Some("lane-a"), None),
            },
            Part {
                prompt_id: "p2".into(),
                sender: "lane-b".into(),
                run: run("second", Some("lane-b"), None),
            },
            Part {
                prompt_id: "p3".into(),
                sender: "lane-a".into(),
                run: run("third", Some("lane-a"), None),
            },
        ];
        let text = prompt_text(&digest_blocks(&parts));
        let at = |s: &str| text.find(s).unwrap_or_else(|| panic!("{s:?} missing from {text}"));
        assert!(text.starts_with("3 messages from other agents arrived while you were busy."));
        assert!(at("[agent message 1 of 3] from lane-a") < at("first\nline two"));
        assert!(at("first\nline two") < at("[agent message 2 of 3] from lane-b"));
        assert!(at("[agent message 2 of 3] from lane-b") < at("second"));
        assert!(at("second") < at("[agent message 3 of 3] from lane-a"));
        assert!(at("[agent message 3 of 3] from lane-a") < at("third"));
        let provenance = digest_provenance(&parts);
        assert_eq!(provenance["kind"], DIGEST_KIND);
        let senders: Vec<&str> = provenance["messages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|m| m["from"].as_str().unwrap())
            .collect();
        assert_eq!(senders, ["lane-a", "lane-b", "lane-a"]);
    }
}
