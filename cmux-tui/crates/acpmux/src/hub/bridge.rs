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
//! Deliveries waiting for their line are kept in memory; after a daemon restart the line still
//! shows, as the app's own peer message is not shown, only its answer.

use super::{Hub, PromptOptions, Session};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;
use tokio::sync::oneshot;

/// Longest a delivered prompt's call waits for the app to end its turn. It is answered then
/// with `answered: false`; the turn still shows when it ends.
const ANSWER_WAIT: Duration = Duration::from_secs(30 * 60);

/// A delivery the watch has not shown yet, by the uuid it was sent with.
pub(super) struct Pending {
    pub(super) session_id: String,
    pub(super) prompt_id: String,
    pub(super) text: String,
    done: Option<oneshot::Sender<String>>,
}

static PENDING: LazyLock<Mutex<HashMap<String, Pending>>> = LazyLock::new(Default::default);

fn pending() -> std::sync::MutexGuard<'static, HashMap<String, Pending>> {
    PENDING.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The delivery a transcript line with `uuid` in `session_id` shows, if acpmux sent it.
pub(super) fn delivered(session_id: &str, uuid: &str) -> Option<(String, String)> {
    pending()
        .get(uuid)
        .filter(|p| p.session_id == session_id)
        .map(|p| (p.prompt_id.clone(), p.text.clone()))
}

/// The watch ended the turn of `prompt_id`: its call answers with `turn_id`.
pub(super) fn answered(session_id: &str, prompt_id: &str, turn_id: &str) {
    let mut map = pending();
    let Some(uuid) = map
        .iter()
        .find(|(_, p)| p.session_id == session_id && p.prompt_id == prompt_id)
        .map(|(k, _)| k.clone())
    else {
        return;
    };
    if let Some(mut p) = map.remove(&uuid)
        && let Some(done) = p.done.take()
    {
        let _ = done.send(turn_id.to_owned());
    }
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
        // The same prompt id again (a resend) is not delivered twice.
        if pending().values().any(|p| p.session_id == session.id && p.prompt_id == prompt_id) {
            if let Some(f) = opts.on_accepted.take() {
                f(json!({"sessionId": session.id, "promptId": prompt_id, "duplicate": true}));
            }
            return Some(Ok(reply(&prompt_id, None, &peer)));
        }
        let uuid = uuid::Uuid::now_v7().to_string();
        let (tx, rx) = oneshot::channel();
        pending().insert(
            uuid.clone(),
            Pending {
                session_id: session.id.clone(),
                prompt_id: prompt_id.clone(),
                text: text.clone(),
                done: Some(tx),
            },
        );
        let sender = opts.agent.clone().unwrap_or_else(|| "person".to_owned());
        let from = crate::claude_peers::from_address(&sender);
        let (target, msg_uuid) = (peer.clone(), uuid.clone());
        let sent = tokio::task::spawn_blocking(move || {
            crate::claude_peers::deliver(&config, &target, &text, &msg_uuid, &from)
        })
        .await
        .unwrap_or_else(|e| Err(e.to_string()));
        if let Err(e) = sent {
            pending().remove(&uuid);
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
        let turn_id = tokio::time::timeout(ANSWER_WAIT, rx).await.ok().and_then(Result::ok);
        if turn_id.is_none() {
            pending().remove(&uuid);
        }
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
