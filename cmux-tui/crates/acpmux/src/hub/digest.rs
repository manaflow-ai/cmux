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
//!   [`DIGEST_MAX_BYTES`] of text; the rest goes in together as the next turn. A slash command
//!   (`/compact`) runs only as a turn's first words, so it goes in alone and ends the run, and so
//!   does a sub-session family message: its own turn checks it again (`subsession_guard.rs`
//!   `family_dispatch_check`), which a joined one would skip. A joined prompt
//!   leaves the queue with a `dequeued` record naming the turn (`joinedTurnId`), and its
//!   `session/prompt` answers with that turn's answer (`joined_reply`). When that turn fails,
//!   the joined messages go back to the head of the queue, held, once (`requeue_joined`):
//!   none is lost to a turn the agent may never have read. A reply in place to any of them
//!   finds it in that turn's provenance (`withdraw.rs` `app_reply_fits`).
//!
//! A failed turn holds the prompts behind it (`queue.rs` `pause_queue`): the person's wait for
//! the person to resume them, since they were written for a turn that went well. Agent messages
//! do not depend on that turn and nobody watches them, so they never wait for a person: the
//! chat's next completed turn releases them (`release_held_agent_messages`), and so does the
//! `autoResumeDelaysMs` wait (`retry_held_agent_messages`), whichever comes first; another agent's
//! next message waits behind them to go in with them rather than overtake them. Each hold of the
//! same message waits the next wait, the last one again once they are used up, so a chat that
//! keeps failing is not sent the same messages over and over. coord-deputy held 121 after one
//! "agent process closed" (2026-10-21): a chat whose agent died completes no turn, so they waited
//! until someone pressed resume.
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

use super::queue::{Answer, PromptRun, QueuedPrompt};
use super::*;
use std::sync::atomic::Ordering;

/// Text one turn of agent messages takes at most (the first message always goes in whole).
pub(super) const DIGEST_MAX_BYTES: usize = 128 * 1024;

/// Longest sender name in `_meta.acpmux.fromAgent`, in characters.
pub const MAX_FROM_AGENT_CHARS: usize = 64;

/// What a joined prompt's wait gets (`queue.rs` `QueuedPrompt::joined`): the turn it joined and,
/// once that turn ends, its answer.
#[derive(Debug, Clone)]
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
    if !matches!(
        kind,
        Some("agent_message" | super::subsessions::PROVENANCE_KIND | super::lane_reports::KIND)
    ) {
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
        Ok(answer) => answer.clone().unwrap_or_else(|| Err(RpcError::internal("no answer"))),
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

    /// After a completed turn: the agent messages a failed turn held run again, in place.
    pub(super) fn release_held_agent_messages(&self, session: &Arc<Session>) {
        let ids: Vec<String> = session
            .queue()
            .iter()
            .filter(|q| q.held && q.run.agent.is_some())
            .map(|q| q.prompt_id.clone())
            .collect();
        if !ids.is_empty() {
            self.resume_held(session, &ids);
        }
    }

    /// After a hold: the agent messages it held go in again by themselves after the
    /// `autoResumeDelaysMs` wait for their hold count (the last wait once those are used up; the
    /// default waits when it is `[]`), or once more while a continuation of the cut turn may
    /// still answer (it releases them). Only these holds: a message released and held again
    /// since waits its own next wait. Also run for the holds a daemon start restored
    /// (`resume_queues`).
    pub(super) fn retry_held_agent_messages(self: &Arc<Self>, session: &Arc<Session>) {
        let held: Vec<(String, usize)> = session
            .queue()
            .iter()
            .filter(|q| q.held && q.run.agent.is_some())
            .map(|q| (q.prompt_id.clone(), q.retries))
            .collect();
        let Some(retries) = held.iter().map(|(_, n)| *n).max() else { return };
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            let delays = hub.config.read().await.auto_resume_delays_ms.clone();
            let delays = delays
                .filter(|d| !d.is_empty())
                .unwrap_or_else(|| super::auto_resume::DEFAULT_DELAYS_MS.to_vec());
            let delay = delays[retries.min(delays.len() - 1)];
            tokio::time::sleep(std::time::Duration::from_millis(delay)).await;
            if session.meta().status == SessionStatus::Closed {
                return;
            }
            // A continuation of the cut turn releases what it held, the person's prompts too:
            // going first would supersede it (`auto_resume.rs`). Wait again instead.
            if hub.continuation_pending(&session) {
                hub.retry_held_agent_messages(&session);
                return;
            }
            let ids: Vec<String> = {
                let mut queue =
                    session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                queue
                    .iter_mut()
                    .filter(|q| {
                        q.held && held.iter().any(|(id, n)| *id == q.prompt_id && *n == q.retries)
                    })
                    .map(|q| {
                        q.retries += 1;
                        q.prompt_id.clone()
                    })
                    .collect()
            };
            if !ids.is_empty() {
                hub.resume_held(&session, &ids);
            }
        });
    }

    /// With the turn lock held and the turn of the agent message `prompt_id` started: takes the
    /// agent messages waiting right behind it under the same rules out of the queue, oldest
    /// first, to go in with it. Held prompts wait where they are; anything else (the person's
    /// prompt, one sent now, one under other rules) ends the run. Each joined prompt's wait
    /// answers with `digest.answer` once the turn ends; a failed turn puts them back
    /// (`requeue_joined`).
    pub(super) fn take_joined(
        &self,
        session: &Arc<Session>,
        head: &PromptRun,
        prompt_id: &str,
        turn_id: &str,
        digest: &DigestTurn,
    ) -> Vec<Part> {
        // A slash command (`/compact`) runs only as a turn's first words: it goes in alone. So does
        // a message with uploaded files: its turn reads and checks them (`prompt_uploads.rs`).
        if head.agent.is_none()
            || super::forum::slash_command(&head.blocks).is_some()
            || crate::prompt_uploads::any(&head.blocks)
        {
            return Vec::new();
        }
        let mut bytes = blocks_bytes(&head.blocks);
        let taken: Vec<QueuedPrompt> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            // A restored prompt whose task has not claimed it yet (`queue_slot`) would hear
            // nothing of the turn it joined, and none would wait for it if that turn put it back.
            let unclaimed = session.restored.lock().unwrap_or_else(|e| e.into_inner()).clone();
            let mut taken = Vec::new();
            let mut i = 0;
            while i < queue.len() {
                let q = &queue[i];
                if q.held {
                    i += 1;
                    continue;
                }
                let joins = q.run.agent.is_some()
                    && super::forum::slash_command(&q.run.blocks).is_none()
                    && !crate::prompt_uploads::any(&q.run.blocks)
                    && !unclaimed.iter().any(|(id, _)| *id == q.prompt_id)
                    && !q.steer
                    && !q.sent_now
                    && q.run.control == head.control
                    && q.run.trust_gate == head.trust_gate
                    && !super::subsession_guard::is_family_prompt(q.run.provenance.as_ref());
                let size = blocks_bytes(&q.run.blocks);
                if !joins || bytes + size > DIGEST_MAX_BYTES {
                    break;
                }
                bytes += size;
                let q = queue.remove(i);
                session.queued.fetch_sub(1, Ordering::SeqCst);
                *q.joined.lock().unwrap_or_else(|e| e.into_inner()) = Some(Joined {
                    prompt_id: prompt_id.to_owned(),
                    turn_id: turn_id.to_owned(),
                    answer: digest.answer.subscribe(),
                });
                taken.push(q);
            }
            taken
        };
        if taken.is_empty() {
            return Vec::new();
        }
        session.queue_moved.notify_waiters();
        let mut left = session.queued() + taken.len() as u64;
        let parts = taken
            .iter()
            .map(|q| {
                left -= 1;
                self.append(
                    session,
                    "mux",
                    "dequeued",
                    json!({"promptId": q.prompt_id, "turnId": q.turn_id, "queued": left, "joinedPromptId": prompt_id, "joinedTurnId": turn_id}),
                );
                // A stored permit: the waiting task answers from `joined` (`queue_slot`).
                q.withdraw.notify_one();
                let sender = q.run.agent.clone().unwrap_or_default();
                Part { prompt_id: q.prompt_id.clone(), sender, run: q.run.clone() }
            })
            .collect();
        *digest.taken.lock().unwrap_or_else(|e| e.into_inner()) = taken;
        parts
    }

    /// After a turn of agent messages failed: the messages that joined it go back to the head of
    /// the queue, held, in order, so none is lost to a turn the agent may never have read. Their
    /// waiting tasks wait again (`queue_slot`); the chat's next completed turn or the retry wait
    /// releases them (`release_held_agent_messages`, `retry_held_agent_messages`). An agent that
    /// read them before failing may read them twice.
    pub(super) fn requeue_joined(self: &Arc<Self>, session: &Arc<Session>, digest: &DigestTurn) {
        let mut taken =
            std::mem::take(&mut *digest.taken.lock().unwrap_or_else(|e| e.into_inner()));
        // Once: a message that fails every turn it is in must not hold the queue again and again.
        taken.retain(|q| !q.requeued);
        if taken.is_empty() || session.meta().status == SessionStatus::Closed {
            return;
        }
        let ids: Vec<String> = taken.iter().map(|q| q.prompt_id.clone()).collect();
        let order: Vec<String> = {
            let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for (i, mut q) in taken.iter().cloned().enumerate() {
                *q.joined.lock().unwrap_or_else(|e| e.into_inner()) = None;
                (q.held, q.steer, q.sent_now, q.restored, q.resume, q.requeued) =
                    (true, false, false, false, false, true);
                queue.insert(i, q);
                session.queued.fetch_add(1, Ordering::SeqCst);
            }
            queue.iter().map(|q| q.prompt_id.clone()).collect()
        };
        let mut position = session.queued() - taken.len() as u64;
        for q in &taken {
            position += 1;
            let text = prompt_text(&q.run.blocks);
            let mut queued = json!({"text": text, "client": q.client, "position": position, "promptId": q.prompt_id, "turnId": q.turn_id, "prompt": q.run.blocks, "control": q.run.control.as_str(), "trustGate": q.run.trust_gate, "requeued": true});
            if let Some(agent) = &q.run.agent {
                queued["fromAgent"] = json!(agent);
            }
            let images = super::prompt_images::keep(&q.run.blocks);
            if !images.is_empty() {
                queued["images"] = Value::Array(images);
            }
            super::session::mark_pasted(&mut queued, &q.run.blocks);
            let queued = crate::prompt_provenance::marked(queued, q.run.provenance.as_ref());
            self.append(session, "mux", "queued", queued);
        }
        self.append(session, "mux", "queue_paused", json!({"held": ids, "requeued": true}));
        self.append(session, "mux", "queue_order", json!({"order": order}));
        session.queue_moved.notify_waiters();
        self.retry_held_agent_messages(session);
    }
}

/// What one prompt's turn hands the agent messages that join it: its answer, and the queue
/// entries they left, which go back if it fails.
pub(super) struct DigestTurn {
    pub(super) answer: tokio::sync::watch::Sender<Option<Answer>>,
    taken: StdMutex<Vec<QueuedPrompt>>,
}

impl Default for DigestTurn {
    fn default() -> Self {
        Self { answer: tokio::sync::watch::channel(None).0, taken: StdMutex::new(Vec::new()) }
    }
}

/// How much of a turn's budget a prompt's blocks take: their text, and an image's data.
fn blocks_bytes(blocks: &[Value]) -> usize {
    blocks
        .iter()
        .map(|b| match b.get("text").and_then(Value::as_str) {
            Some(text) => text.len(),
            None => b.get("data").and_then(Value::as_str).map_or(0, str::len),
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(text: &str, agent: Option<&str>, provenance: Option<Value>) -> Arc<PromptRun> {
        Arc::new(PromptRun {
            blocks: vec![json!({"type": "text", "text": text})],
            display_parts: None,
            control: Control::default(),
            trust_gate: false,
            provenance,
            agent: agent.map(str::to_owned),
            supersede: None,
            full_access_device: None,
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
