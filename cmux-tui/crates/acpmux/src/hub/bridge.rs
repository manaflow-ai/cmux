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

/// A delivery, by the uuid it was sent with: waiting for its transcript line and turn until
/// `turn` holds the turn the watch showed it as, then kept so a resend is not delivered again.
pub(super) struct Pending {
    pub(super) session_id: String,
    pub(super) prompt_id: String,
    pub(super) text: String,
    order: u64,
    turn: watch::Sender<Option<String>>,
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
    fn insert(
        &mut self,
        uuid: String,
        session_id: &str,
        prompt_id: &str,
        text: &str,
    ) -> watch::Receiver<Option<String>> {
        let (turn, rx) = watch::channel(None);
        self.next += 1;
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
        rx
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
        p.turn.send_replace(Some(turn_id.to_owned()));
    }
}

/// The turn `rx` names, once the watch shows it, within [`ANSWER_WAIT`].
async fn turn_of(mut rx: watch::Receiver<Option<String>>) -> Option<String> {
    let wait = rx.wait_for(Option::is_some);
    tokio::time::timeout(ANSWER_WAIT, wait).await.ok()?.ok()?.clone()
}

/// The text of a prompt's content blocks; images and other blocks are not carried.
fn text_of(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n\n")
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
        let config = self.harness_homes.lock().unwrap_or_else(|e| e.into_inner()).claude.clone();
        let lookup = (config.clone(), agent_session_id.clone());
        let peer = tokio::task::spawn_blocking(move || {
            crate::claude_peers::enabled()
                .then(|| crate::claude_peers::find(&lookup.0, &lookup.1))
                .flatten()
        })
        .await
        .ok()??;
        let text = text_of(blocks);
        if text.trim().is_empty() {
            return Some(Err(RpcError::invalid_params(
                "only text reaches a Claude Code session another app runs",
            )));
        }
        let prompt_id = opts.prompt_id.clone().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        // The same prompt id again (a resend) is not delivered twice: it answers with the first.
        let resent =
            deliveries().of_prompt(&session.id, &prompt_id).map(|(_, p)| p.turn.subscribe());
        if let Some(rx) = resent {
            if let Some(f) = opts.on_accepted.take() {
                f(json!({"sessionId": session.id, "promptId": prompt_id, "duplicate": true}));
            }
            let turn_id = turn_of(rx).await;
            return Some(Ok(reply(&prompt_id, turn_id.as_deref(), &peer)));
        }
        let uuid = uuid::Uuid::now_v7().to_string();
        let rx = deliveries().insert(uuid.clone(), &session.id, &prompt_id, &text);
        let sender = opts.agent.clone().unwrap_or_else(|| "person".to_owned());
        let from = crate::claude_peers::from_address(&sender);
        let (target, msg_uuid) = (peer.clone(), uuid.clone());
        let sent = tokio::task::spawn_blocking(move || {
            crate::claude_peers::deliver(&config, &target, &text, &msg_uuid, &from)
        })
        .await
        .unwrap_or_else(|e| Err(e.to_string()));
        if let Err(e) = sent {
            deliveries().by_uuid.remove(&uuid);
            return Some(Err(RpcError::new(-32000, format!("bridge.undelivered: {e}"))
                .with_data(json!({"reason": "bridge.undelivered"}))));
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
        let turn_id = turn_of(rx).await;
        Some(Ok(reply(&prompt_id, turn_id.as_deref(), &peer)))
    }
}

fn reply(prompt_id: &str, turn_id: Option<&str>, peer: &crate::claude_peers::Peer) -> Value {
    json!({
        "stopReason": "end_turn",
        "_meta": {"acpmux": {
            "promptId": prompt_id,
            "turnId": turn_id,
            "answered": turn_id.is_some(),
            "bridged": {"pid": peer.pid, "entrypoint": peer.entrypoint},
        }},
    })
}

#[cfg(test)]
#[path = "bridge_tests.rs"]
mod tests;
