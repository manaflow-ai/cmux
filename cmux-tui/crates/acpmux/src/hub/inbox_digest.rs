//! Part of `Hub` (declared in `digest.rs`, fan-in like it). `acpmux session inbox NAME --digest`
//! (`_acpmux/inbox_digest {sessionId, dryRun?}`): a one-shot drain of a busy chat's inbox.
//!
//! A coordinator that 30 lanes report to had 285 agent messages queued, and each one it read
//! cost it a turn (2026-10-29). The drain takes the agent messages waiting in the chat's queue
//! (the ones `digest.rs` counts as another agent's) out of it and puts ONE prompt in their
//! place, rendered by [`render`]:
//!
//! - The person's own prompts are never touched: they stay where they are, ahead of it.
//! - Each original leaves the queue with a `dequeued` record naming the digest
//!   (`digestPromptId`, `digestTurnId`); its full text stays in the log under its own promptId,
//!   in its `queued` record. Its waiting `session/prompt` answers with the digest's answer
//!   (`digest.rs` `Joined`). The digest's own `queued` record is logged first, so a restart
//!   runs the digest and never the originals again (`lost_start.rs`).
//! - When the chat's turn runs and its agent steers, the digest goes into that turn as ONE
//!   steer (its queue entry is marked as a steer, as Send now marks one, `queue.rs`
//!   `steer_queued`); otherwise it waits at the head of the agent messages in the queue, still
//!   behind the person's prompts, and runs as its own turn: no later agent message joins it.
//! - `dryRun` returns the digest it would make and changes nothing.
//!
//! What stays queued: a message with anything but text (an image, an uploaded file, hidden
//! context), a slash command, a sub-session family message (each is checked again in its own
//! turn), one sent now or steering now, a Web one, and an earlier digest.
//!
//! The digest's provenance (hub-set, never a client's): `{kind: "inbox_digest", digestId,
//! parts: [{promptId, from, fromName, class, receivedAt, bytes, duplicateOf?}], counts: {block,
//! question, result, fyi}}`. A message's class is the one its queue entry holds
//! (`prompt_class.rs`), a result when it has none.
//!
//! Only the unix socket asks for a drain, from the person or from the chat's own agent
//! (`server/agent_messages.rs`): never Web, and never another session's agent.

use super::super::queue::{PromptRun, QueuedPrompt};
use super::super::*;
use super::{DIGEST_MAX_BYTES, Joined};
use crate::prompt_class::PromptClass as Class;
use std::sync::atomic::Ordering;

/// The provenance kind of an inbox digest.
pub const KIND: &str = "inbox_digest";
/// The sender a digest goes under, as another agent's message (`digest.rs`).
pub(crate) const SENDER: &str = "inbox digest";
/// A part past the budget shows this many characters of its text.
const CUT_CHARS: usize = 400;
/// An FYI's line, at most, in characters.
const FYI_CHARS: usize = 160;

/// Whether a prompt's provenance is an inbox digest's.
pub(crate) fn is_digest(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(KIND)
}

/// One message of a digest, as the renderer reads it.
#[derive(Clone, Debug)]
pub(crate) struct Part {
    pub prompt_id: String,
    /// Its sender's address: a session id or `acp:<id>`; a sender that only named itself has
    /// its name here.
    pub from: String,
    pub from_name: String,
    pub class: Class,
    pub received_at: u64,
    pub text: String,
}

/// A digest: the prompt's text and its provenance.
pub(crate) struct Rendered {
    pub text: String,
    pub provenance: Value,
}

/// The digest `digest_id` of `parts`, in order: blocks and questions, results grouped by
/// sender, then FYIs, one line each. Identical texts from one sender fold to the newest copy,
/// marked "(×N)". Each part is headed by its sender and promptId. Blocks, questions and results
/// keep their whole text while the texts so far fit in [`DIGEST_MAX_BYTES`]; past that a part
/// shows its first [`CUT_CHARS`] characters and where its full text is.
pub(crate) fn render(digest_id: &str, parts: &[Part]) -> Rendered {
    // Oldest first; a stable sort keeps the queue's order between equal times.
    let mut order: Vec<&Part> = parts.iter().collect();
    order.sort_by_key(|p| p.received_at);
    // Each sender's text once: its newest copy, and how many came.
    let key = |p: &Part| (p.from.clone(), p.from_name.clone(), p.text.clone());
    let mut newest: HashMap<(String, String, String), (&Part, usize)> = HashMap::new();
    for &p in &order {
        let entry = newest.entry(key(p)).or_insert((p, 0));
        *entry = (p, entry.1.saturating_add(1));
    }
    // The copy a folded part went into, `None` for one that is kept.
    let folded_into = |p: &Part| {
        newest.get(&key(p)).map(|(kept, _)| *kept).filter(|kept| !std::ptr::eq(*kept, p))
    };
    let times = |p: &Part| match newest.get(&key(p)) {
        Some((_, n)) if *n > 1 => format!(" (×{n})"),
        _ => String::new(),
    };
    let kept: Vec<&Part> = order.iter().copied().filter(|&p| folded_into(p).is_none()).collect();
    let of = |class: Class| kept.iter().copied().filter(move |p| p.class == class);
    let count = |class: Class| parts.iter().filter(|p| p.class == class).count();

    let mut text = header(parts.len(), &Class::ALL.map(count), kept.len() < parts.len());
    let mut used = 0usize;
    let mut body = |text: &mut String, part: &Part| {
        let cut: String = part.text.chars().take(CUT_CHARS).collect();
        let fits = used.saturating_add(part.text.len()) <= DIGEST_MAX_BYTES;
        if fits || cut.len() == part.text.len() {
            used = used.saturating_add(part.text.len());
            text.push_str(&part.text);
        } else {
            text.push_str(&format!("{cut}…\n[full text: promptId {}]", part.prompt_id));
        }
    };
    let asks: Vec<&Part> = of(Class::Block).chain(of(Class::Question)).collect();
    if !asks.is_empty() {
        text.push_str("\n\n## Blocks and questions");
        for part in asks {
            let (class, name, id) = (part.class.as_str(), &part.from_name, &part.prompt_id);
            text.push_str(&format!("\n\n[{class}] from {name}, promptId {id}{}\n", times(part)));
            body(&mut text, part);
        }
    }
    // Senders in the order of their oldest result, folded ones included.
    let mut senders: Vec<(&str, &str)> = Vec::new();
    for part in order.iter().filter(|p| p.class == Class::Result) {
        let sender = (part.from.as_str(), part.from_name.as_str());
        if !senders.contains(&sender) {
            senders.push(sender);
        }
    }
    if !senders.is_empty() {
        text.push_str("\n\n## Results");
        for (from, name) in senders {
            text.push_str(&format!("\n\n### from {name}"));
            for part in of(Class::Result).filter(|p| p.from == from && p.from_name == name) {
                let id = &part.prompt_id;
                text.push_str(&format!("\n\n[result] promptId {id}{}\n", times(part)));
                body(&mut text, part);
            }
        }
    }
    let fyis: Vec<&Part> = of(Class::Fyi).collect();
    if !fyis.is_empty() {
        text.push_str("\n\n## FYIs\n");
        for part in fyis {
            let (name, id, line) = (&part.from_name, &part.prompt_id, one_line(&part.text));
            text.push_str(&format!("\n- {name} (promptId {id}){}: {line}", times(part)));
        }
    }

    let described: Vec<Value> = order
        .iter()
        .map(|&part| {
            let mut v = json!({"promptId": part.prompt_id, "from": part.from, "fromName": part.from_name, "class": part.class.as_str(), "receivedAt": part.received_at, "bytes": part.text.len()});
            if let Some(kept) = folded_into(part) {
                crate::no_panic::JsonExt::set(&mut v, "duplicateOf", json!(kept.prompt_id));
            }
            v
        })
        .collect();
    let counts: serde_json::Map<String, Value> =
        Class::ALL.iter().map(|&c| (c.as_str().to_owned(), json!(count(c)))).collect();
    let provenance =
        json!({"kind": KIND, "digestId": digest_id, "parts": described, "counts": counts});
    Rendered { text, provenance }
}

/// The digest's first line: how many messages, of which classes (`counts` in [`Class::ALL`]'s
/// order).
fn header(total: usize, counts: &[usize; 4], folded: bool) -> String {
    let names =
        [("block", "blocks"), ("question", "questions"), ("result", "results"), ("FYI", "FYIs")];
    let classes: Vec<String> = counts
        .iter()
        .zip(names)
        .filter(|(n, _)| **n > 0)
        .map(|(n, (one, many))| format!("{n} {}", if *n == 1 { one } else { many }))
        .collect();
    let messages = if total == 1 { "message" } else { "messages" };
    let mut text = format!(
        "[inbox digest] {total} {messages} from other agents waited for you; here they are in one \
         prompt ({}). Each part names its sender and promptId: the full original stays in this \
         chat's log under that promptId.",
        classes.join(", ")
    );
    if folded {
        text.push_str(
            " Identical messages from one sender are folded into the newest, marked (×N).",
        );
    }
    text
}

/// An FYI's line: its first non-empty line, at most [`FYI_CHARS`] characters, "…" when cut.
fn one_line(text: &str) -> String {
    let mut lines = text.lines().map(str::trim).filter(|l| !l.is_empty());
    let first = lines.next().unwrap_or_default();
    let line: String = first.chars().take(FYI_CHARS).collect();
    if line.len() < first.len() || lines.next().is_some() { format!("{line}…") } else { line }
}

/// Whether a waiting prompt goes into a digest: another agent's text message that may go in
/// with others (module docs).
pub(in crate::hub) fn digestible(q: &QueuedPrompt) -> bool {
    let run = &q.run;
    run.agent.is_some()
        && !is_digest(run.provenance.as_ref())
        && !q.steer
        && !q.sent_now
        && run.control != Control::Web
        && !run.trust_gate
        && !run.blocks.is_empty()
        && run.blocks.iter().all(|b| {
            b.get("type").and_then(Value::as_str) == Some("text")
                && !crate::prompt_context::is_context(b)
        })
        && super::super::forum::slash_command(&run.blocks).is_none()
        && !crate::prompt_uploads::any(&run.blocks)
        && !super::super::subsession_guard::is_family_prompt(run.provenance.as_ref())
}

/// The originals that the inbox digests among `waiting` (`queued` records a restart restores)
/// hold, by prompt id: each one's turn id and its digest's prompt and turn ids.
pub(in crate::hub) fn digested_originals(
    waiting: &[crate::store::EventRecord],
) -> HashMap<String, (String, String, String)> {
    let mut originals = HashMap::new();
    let field = |v: &Value, k: &str| v.get(k).and_then(Value::as_str).unwrap_or("").to_owned();
    let turns: HashMap<String, String> =
        waiting.iter().map(|e| (field(&e.msg, "promptId"), field(&e.msg, "turnId"))).collect();
    for e in waiting {
        let provenance = e.msg.pointer("/_meta/provenance");
        if !is_digest(provenance) {
            continue;
        }
        let (digest_id, digest_turn) = (field(&e.msg, "promptId"), field(&e.msg, "turnId"));
        let parts = provenance.and_then(|p| p.get("parts")).and_then(Value::as_array);
        for part in parts.into_iter().flatten() {
            let id = field(part, "promptId");
            if let Some(turn) = turns.get(&id) {
                originals.insert(id, (turn.clone(), digest_id.clone(), digest_turn.clone()));
            }
        }
    }
    originals
}

/// The renderer's part of a waiting prompt.
fn part_of(q: &QueuedPrompt) -> Part {
    let name = q.run.agent.clone().unwrap_or_default();
    // A sender that only named itself has no address: its name is its address here.
    let from = q.run.provenance.as_ref().and_then(|p| p.get("from")).and_then(Value::as_str);
    let from = from.filter(|f| *f != crate::prompt_provenance::NAMED_SENDER);
    Part {
        prompt_id: q.prompt_id.clone(),
        from: from.map_or_else(|| name.clone(), str::to_owned),
        from_name: name,
        class: q.run.class.unwrap_or(Class::Result),
        received_at: q.queued_at,
        text: prompt_text(&q.run.blocks),
    }
}

impl Hub {
    /// The refusal of a drain from anything but the unix socket.
    pub fn inbox_digest_origin_refused() -> RpcError {
        RpcError::invalid_params(
            "inbox_digest.origin_refused: an inbox digest is made only over the local unix socket",
        )
        .with_data(json!({"reason": "inbox_digest.origin_refused"}))
    }

    /// The refusal of a drain another session's agent asked for.
    pub fn inbox_digest_other_agent() -> RpcError {
        RpcError::invalid_params(
            "inbox_digest.other_agent: only the person or the chat's own agent drains its inbox",
        )
        .with_data(json!({"reason": "inbox_digest.other_agent"}))
    }

    /// `_acpmux/inbox_digest`; see the module docs. `client` names the asking connection.
    pub async fn inbox_digest(
        self: &Arc<Self>,
        session: &Arc<Session>,
        client: &str,
        dry_run: bool,
    ) -> Result<Value, RpcError> {
        self.digest_waiting(session, client, dry_run, false).await
    }

    /// A drain of the agent messages waiting in `session`'s queue, or (`inbox_only`) of a
    /// coordinator's inbox items alone (`coordinator.rs`). An inbox item it cannot take leaves
    /// the inbox, under the same lock, and waits in the ordinary queue.
    pub(in crate::hub) async fn digest_waiting(
        self: &Arc<Self>,
        session: &Arc<Session>,
        client: &str,
        dry_run: bool,
        inbox_only: bool,
    ) -> Result<Value, RpcError> {
        // The queue a restart restored, and a turn adoption recovers, first.
        self.session_log(session).await;
        self.wait_adopted(session).await;
        if session.meta().status == SessionStatus::Closed {
            return Err(super::super::queue::closing_error());
        }
        if session.moving().is_some() {
            return Err(super::super::queue::moving_error());
        }
        if session.meta().watching.is_some() {
            return Err(super::super::watch::read_only());
        }
        // Read before the queue's lock. A turn that ends before the steer reaches it leaves the
        // digest next among the agent messages (`steer_turn`'s fallback, `queue.rs` `enqueue`).
        let steer = session.steering.load(Ordering::SeqCst) && session.turn().is_some();
        let digest_id = format!("inbox-digest-{}", uuid::Uuid::now_v7());
        let turn_id = uuid::Uuid::now_v7().to_string();
        let mut queue = session.queue.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut released = false;
        if inbox_only && !dry_run {
            for q in queue.iter_mut().filter(|q| q.inbox && !digestible(q)) {
                (q.inbox, released) = (false, true);
            }
        }
        let takes = |q: &QueuedPrompt| digestible(q) && (!inbox_only || q.inbox);
        let parts: Vec<Part> = queue.iter().filter(|q| takes(q)).map(part_of).collect();
        if parts.is_empty() {
            drop(queue);
            if released {
                session.queue_moved.notify_waiters();
            }
            return Ok(json!({"sessionId": session.id, "dryRun": dry_run, "digested": 0}));
        }
        let Rendered { text, provenance } = render(&digest_id, &parts);
        if dry_run {
            drop(queue);
            return Ok(
                json!({"sessionId": session.id, "dryRun": true, "digested": parts.len(), "text": text, "provenance": provenance}),
            );
        }
        // A peer's message goes in under a peer's rules, as it came (`queue_edit.rs` `stricter`).
        let peer = queue.iter().any(|q| takes(q) && q.run.control == Control::Peer);
        let control = if peer { Control::Peer } else { Control::Local };
        let (answer, answered) = tokio::sync::watch::channel(None);
        let (taken, rest): (Vec<QueuedPrompt>, Vec<QueuedPrompt>) =
            std::mem::take(&mut *queue).into_iter().partition(|q| takes(q));
        *queue = rest;
        // At the head of the agent messages: behind the person's prompts and a prompt sent now.
        let at = queue
            .iter()
            .position(|q| {
                q.held
                    || (q.run.agent.is_some()
                        && !q.sent_now
                        && !is_digest(q.run.provenance.as_ref()))
            })
            .unwrap_or(queue.len());
        let blocks = vec![json!({"type": "text", "text": text})];
        let run = PromptRun {
            blocks: blocks.clone(),
            display_parts: None,
            control,
            trust_gate: false,
            provenance: Some(provenance.clone()),
            agent: Some(SENDER.to_owned()),
            class: None,
            supersede: None,
            full_access_device: None,
        };
        queue.insert(
            at,
            QueuedPrompt {
                prompt_id: digest_id.clone(),
                turn_id: turn_id.clone(),
                client: client.to_owned(),
                preview: short_text(&text, 200),
                queued_at: now_ms(),
                withdraw: Arc::new(Notify::new()),
                run: Arc::new(run),
                restored: false,
                resume: false,
                steer,
                held: false,
                inbox: false,
                sent_now: false,
                joined: Arc::new(StdMutex::new(None)),
                requeued: false,
                retries: 0,
            },
        );
        // Claimed by the task below (`queue_slot`), as a restored prompt is.
        session
            .restored
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .push((digest_id.clone(), turn_id.clone()));
        session.queued.fetch_add(1, Ordering::SeqCst);
        session.queued.fetch_sub(taken.len() as u64, Ordering::SeqCst);
        for q in &taken {
            *q.joined.lock().unwrap_or_else(|e| e.into_inner()) = Some(Joined {
                prompt_id: digest_id.clone(),
                turn_id: turn_id.clone(),
                answer: answered.clone(),
            });
        }
        let order: Vec<String> = queue.iter().map(|q| q.prompt_id.clone()).collect();
        drop(queue);

        // The digest is logged before the originals leave, so the log never loses them.
        let queued = json!({"text": text, "client": client, "position": at + 1, "promptId": digest_id, "turnId": turn_id, "prompt": blocks, "control": control.as_str(), "trustGate": false, "fromAgent": SENDER});
        let queued = crate::prompt_provenance::marked(queued, Some(&provenance));
        self.append(session, "mux", "queued", queued);
        self.append(session, "mux", "queue_order", json!({"promptId": digest_id, "order": order}));
        let left = session.queued();
        for q in &taken {
            let msg = json!({"promptId": q.prompt_id, "turnId": q.turn_id, "queued": left, "digestPromptId": digest_id, "digestTurnId": turn_id});
            self.append(session, "mux", "dequeued", msg);
            // A stored permit: its waiting task answers from `joined` (`queue_slot`).
            q.withdraw.notify_one();
        }
        session.queue_moved.notify_waiters();

        let (hub, s, who) = (self.clone(), session.clone(), client.to_owned());
        let (id, turn) = (digest_id.clone(), turn_id.clone());
        let opts = PromptOptions {
            prompt_id: Some(digest_id.clone()),
            control,
            provenance: Some(provenance.clone()),
            agent: Some(SENDER.to_owned()),
            ..PromptOptions::default()
        };
        tokio::spawn(async move {
            let result = hub.run_prompt(&s, blocks, &who, false, opts).await;
            // Refused before its turn (as a restored prompt is, `resume_restored`): it leaves the
            // queue, so the prompts behind it still run, and the log says why.
            if let Err(e) = &result
                && hub.remove_queued(&s, &id)
            {
                let msg = json!({"promptId": id, "turnId": turn, "client": who, "error": e.message, "data": e.data});
                hub.append(&s, "mux", "prompt_refused", msg);
            }
            answer.send_replace(Some(result));
        });
        Ok(json!({
            "sessionId": session.id,
            "dryRun": false,
            "digested": taken.len(),
            "promptId": digest_id,
            "turnId": turn_id,
            "delivery": if steer { "steer" } else { "queued" },
            "position": at + 1,
            "text": text,
            "provenance": provenance,
        }))
    }
}

#[cfg(test)]
#[path = "inbox_digest_tests.rs"]
mod tests;
