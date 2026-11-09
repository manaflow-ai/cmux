//! A prompt to a watched Claude Code chat whose app still runs it, delivered into that app's
//! session (`claude_peers.rs`) instead of refused as `watch.read_only`.
//!
//! With `agents.desktopBridge.enabled`, `prompt_with` hands a watched Claude chat's prompt here.
//! When the conversation's own Claude Code is registered and live, the prompt goes to its inbox
//! as a message with a fresh `uuid`, and is accepted at once. The app runs it as a turn and writes
//! it to the transcript with that uuid; the watch (`watch.rs`) shows that line as this prompt,
//! under this prompt's id, and its answer as the turn's answer. The prompt's call answers when
//! the watch ends that turn, so a person's send and an agent's `--wait` read the answer as from
//! any turn. Nothing is started and nothing is written to the transcript by acpmux.
//!
//! A chat whose app no longer runs it falls through to the refusal: Take Over runs it here.
//! Deliveries are kept in memory (the newest 256 answered ones too, so a resend is not delivered
//! again). After a daemon restart, a delivered line the watch had not shown yet shows only its
//! answer, as any other session's peer message does.

use super::{Hub, PromptOptions, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::sync::watch;

/// Longest a delivered prompt's call waits for the app to end its turn. It is answered then
/// with `answered: false`; the turn still shows when it ends.
const ANSWER_WAIT: Duration = Duration::from_secs(30 * 60);

/// Most deliveries kept; past it the oldest answered ones go. A resend of a prompt id that went
/// still finds its answer while it is kept.
const KEPT: usize = 256;

/// How a delivery ended: the turn the watch showed it as, or why the app's inbox did not take it.
type Outcome = Option<Result<String, String>>;

/// A delivery, by the uuid it was sent with: waiting for its transcript line and turn until
/// `turn` holds its [`Outcome`], then kept (when it went) so a resend is not delivered again.
pub(super) struct Pending {
    pub(super) session_id: String,
    pub(super) prompt_id: String,
    pub(super) text: String,
    order: u64,
    turn: watch::Sender<Outcome>,
}

#[derive(Default)]
struct Deliveries {
    by_uuid: HashMap<String, Pending>,
    next: u64,
}

static PENDING: LazyLock<Mutex<Deliveries>> = LazyLock::new(Default::default);

fn deliveries() -> std::sync::MutexGuard<'static, Deliveries> {
    PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Deliveries {
    /// The delivery of `prompt_id`, claimed under one lock: a new one (`Ok`) to send as `uuid`, or
    /// the one a resend of the same id finds (`Err`), whose turn it answers with.
    fn claim(
        &mut self,
        uuid: String,
        session_id: &str,
        prompt_id: &str,
        text: &str,
    ) -> Result<watch::Receiver<Outcome>, watch::Receiver<Outcome>> {
        if let Some((_, p)) = self.of_prompt(session_id, prompt_id) {
            return Err(p.turn.subscribe());
        }
        let (turn, rx) = watch::channel(None);
        self.next = self.next.saturating_add(1);
        let pending = Pending {
            session_id: session_id.to_owned(),
            prompt_id: prompt_id.to_owned(),
            text: text.to_owned(),
            order: self.next,
            turn,
        };
        self.by_uuid.insert(uuid, pending);
        while self.by_uuid.len() > KEPT {
            let oldest = self
                .by_uuid
                .iter()
                .filter(|(_, p)| p.turn.borrow().is_some())
                .min_by_key(|(_, p)| p.order)
                .map(|(k, _)| k.clone());
            let Some(oldest) = oldest else { break };
            self.by_uuid.remove(&oldest);
        }
        Ok(rx)
    }

    fn of_prompt(&self, session_id: &str, prompt_id: &str) -> Option<(&String, &Pending)> {
        self.by_uuid.iter().find(|(_, p)| p.session_id == session_id && p.prompt_id == prompt_id)
    }
}

/// The delivery a transcript line with `uuid` in `session_id` shows, if acpmux sent it and the
/// watch has not shown it yet.
pub(super) fn delivered(session_id: &str, uuid: &str) -> Option<(String, String)> {
    deliveries()
        .by_uuid
        .get(uuid)
        .filter(|p| p.session_id == session_id && p.turn.borrow().is_none())
        .map(|p| (p.prompt_id.clone(), p.text.clone()))
}

/// The watch ended the turn of `prompt_id`: its call (and any resend's) answers with `turn_id`.
pub(super) fn answered(session_id: &str, prompt_id: &str, turn_id: &str) {
    if let Some((_, p)) = deliveries().of_prompt(session_id, prompt_id) {
        p.turn.send_replace(Some(Ok(turn_id.to_owned())));
    }
}

/// The outcome `rx` gets, once the watch shows its turn or its delivery fails, within [`ANSWER_WAIT`].
async fn turn_of(mut rx: watch::Receiver<Outcome>) -> Outcome {
    let wait = rx.wait_for(Option::is_some);
    tokio::time::timeout(ANSWER_WAIT, wait).await.ok()?.ok()?.clone()
}

/// The text of a prompt's content blocks, when they are all text: an image or a file would not
/// reach the app (its inbox takes text), so such a prompt is refused rather than cut.
fn text_of(blocks: &[Value]) -> Option<String> {
    blocks
        .iter()
        .map(|b| match b.get("type").and_then(Value::as_str) {
            Some("text") => b.get("text").and_then(Value::as_str),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()
        .map(|texts| texts.join("\n\n"))
        .filter(|text| !text.trim().is_empty())
}

impl Hub {
    /// `Some` answer when `session` is a watched Claude chat this prompt was delivered into;
    /// `None` leaves the prompt to the usual path (which refuses it while watched).
    pub(super) async fn bridged_prompt(
        self: &Arc<Self>,
        session: &Arc<Session>,
        blocks: &[Value],
        opts: &mut PromptOptions,
    ) -> Option<Result<Value, RpcError>> {
        let watching = session.meta().watching?;
        if watching.family != "claude" {
            return None;
        }
        let agent_session_id = session.meta().agent_session_id?;
        // Only a chat the bridge listed (`desktop_bridge.rs`) takes prompts; any other watched
        // chat stays read-only, whatever runs its conversation.
        if session.meta().tags.get("bridge").is_none_or(|t| t.value != "claude") {
            return None;
        }
        // A resend of a prompt id that went answers with its turn, whether or not the app still runs.
        if let Some(id) = opts.prompt_id.clone() {
            let kept = deliveries().of_prompt(&session.id, &id).map(|(_, p)| p.turn.subscribe());
            if let Some(rx) = kept {
                return Some(resent(session, &id, rx, opts).await);
            }
        }
        let config = self.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).claude.clone();
        let lookup = (config.clone(), agent_session_id.clone());
        let peer = tokio::task::spawn_blocking(move || {
            // The session's own registry entry must name an entrypoint the setting lists: a tag
            // alone is anyone's to set.
            let listed = crate::claude_peers::listed_entrypoints();
            crate::claude_peers::enabled()
                .then(|| crate::claude_peers::find(&lookup.0, &lookup.1))
                .flatten()
                .filter(|p| p.entrypoint.as_ref().is_some_and(|e| listed.contains(e)))
        })
        .await
        .ok()??;
        let Some(text) = text_of(blocks) else {
            return Some(Err(RpcError::invalid_params(
                "only text reaches a Claude Code session another app runs: send it without attachments, or take the chat over",
            )));
        };
        let prompt_id = opts.prompt_id.clone().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let uuid = uuid::Uuid::now_v7().to_string();
        // Claimed under one lock: two sends of one id never both go.
        let claimed = deliveries().claim(uuid.clone(), &session.id, &prompt_id, &text);
        let rx = match claimed {
            Ok(rx) => rx,
            Err(rx) => return Some(resent(session, &prompt_id, rx, opts).await),
        };
        let sender = opts.agent.clone().unwrap_or_else(|| "person".to_owned());
        let from = crate::claude_peers::from_address(&sender);
        // The chat shows the prompt as sent (`delivered`); the app also reads how to answer.
        let wire = with_reply_hint(&text, opts.agent.as_deref());
        let sent = crate::claude_peers::deliver(&config, &peer, &wire, &uuid, &from).await;
        if let Err(e) = sent {
            // A resend waiting on this delivery fails with it, and a later one delivers again.
            let gone = deliveries().by_uuid.remove(&uuid);
            if let Some(p) = gone {
                p.turn.send_replace(Some(Err(e.clone())));
            }
            return Some(Err(undelivered(&e)));
        }
        self.append(
            session,
            "mux",
            "bridge_delivered",
            json!({"promptId": prompt_id, "uuid": uuid, "pid": peer.pid, "entrypoint": peer.entrypoint}),
        );
        if let Some(f) = opts.on_accepted.take() {
            f(
                json!({"sessionId": session.id, "promptId": prompt_id, "queued": false, "state": "delivered", "bridged": true}),
            );
        }
        Some(answer(&prompt_id, turn_of(rx).await, Some(&peer)))
    }
}

/// `text` as the app reads it: an agent's message ends with how to answer that agent. Claude
/// Code's own messaging cannot reach an `acpmux:` address, and its `acpmux send` from the app's
/// shell is bound to this chat (`desktop_bridge.rs`), so the answer lands in the sender's inbox
/// under the chat's name. The person's prompt goes as typed.
fn with_reply_hint(text: &str, agent: Option<&str>) -> String {
    match agent.map(str::trim).filter(|a| !a.is_empty()) {
        Some(agent) => {
            let quoted = agent.replace('\'', "'\\''");
            format!(
                "{text}\n\n[From {agent}, an acpmux session. Answer it with `acpmux send '{quoted}' '<your reply>'` in your shell; your own messaging tools cannot reach it.]"
            )
        }
        None => text.to_owned(),
    }
}

fn undelivered(e: &str) -> RpcError {
    RpcError::new(-32000, format!("bridge.undelivered: {e}"))
        .with_data(json!({"reason": "bridge.undelivered"}))
}

fn answer(
    prompt_id: &str,
    outcome: Outcome,
    peer: Option<&crate::claude_peers::Peer>,
) -> Result<Value, RpcError> {
    match outcome {
        Some(Err(e)) => Err(undelivered(&e)),
        Some(Ok(turn_id)) => Ok(reply(prompt_id, Some(&turn_id), peer)),
        None => Ok(reply(prompt_id, None, peer)),
    }
}

/// A resend's answer: accepted as a duplicate, then the first delivery's turn.
async fn resent(
    session: &Session,
    prompt_id: &str,
    rx: watch::Receiver<Outcome>,
    opts: &mut PromptOptions,
) -> Result<Value, RpcError> {
    if let Some(f) = opts.on_accepted.take() {
        f(json!({"sessionId": session.id, "promptId": prompt_id, "duplicate": true}));
    }
    let mut answer = answer(prompt_id, turn_of(rx).await, None);
    let meta = answer.as_mut().ok().and_then(|v| v.pointer_mut("/_meta/acpmux"));
    if let Some(meta) = meta.and_then(Value::as_object_mut) {
        meta.insert("duplicate".to_owned(), json!(true));
    }
    answer
}

fn reply(
    prompt_id: &str,
    turn_id: Option<&str>,
    peer: Option<&crate::claude_peers::Peer>,
) -> Value {
    let bridged = peer.map(|p| json!({"pid": p.pid, "entrypoint": p.entrypoint}));
    json!({
        "stopReason": "end_turn",
        "_meta": {"acpmux": {
            "promptId": prompt_id,
            "turnId": turn_id,
            "answered": turn_id.is_some(),
            "bridged": bridged.unwrap_or(json!(true)),
        }},
    })
}

#[cfg(test)]
#[path = "bridge_tests.rs"]
mod tests;
