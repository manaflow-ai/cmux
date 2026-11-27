//! Part of `Hub`; see `hub/mod.rs`. No send vanishes (Leo, 2026-11-24: "well clearly we need to
//! have better listeners/scheduling to make sure those messages are recievable";
//! plans/cmux-next/message-delivery-successors.md): a delivery the outbox kept that ends failed
//! (its retries ran out, it expired, the peer or the mesh hub refused it for good) bounces.
//!
//! - Its line goes into `dead-letters.jsonl` beside `outbox.json` (`~/.acpmux/`), which NOW and
//!   the fleet's tooling read: `{ts, deliveryId, target, sender, reason, text}`.
//! - Its sending session here gets a waking notice (`[notice from acpmux, warn] ...`) naming the
//!   target, the reason and the delivery, once (its prompt id is `bounce-<delivery>`).
//!
//! The outbox reports every change into `failed` (`OutboxState::change`) on a channel this
//! module drains ([`Hub::start_bounces`]), so every path that fails a delivery bounces it.

use super::outbox::Delivery;
use super::*;
use cmux_json::JsonSet as _;

/// The file's name beside `outbox.json`.
pub(crate) const FILE: &str = "dead-letters.jsonl";
/// The most of the message's text a dead letter and its bounce carry.
const TEXT_CHARS: usize = 400;
/// The prompt id prefix of a bounce notice.
pub(crate) const PROMPT_PREFIX: &str = "bounce-";

/// The message's text, at most [`TEXT_CHARS`].
fn text_of(d: &Delivery) -> String {
    let text: String = d
        .request
        .get("prompt")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n");
    let mut out: String = text.chars().take(TEXT_CHARS).collect();
    if text.chars().count() > TEXT_CHARS {
        out.push('…');
    }
    out
}

/// The dead letter's line for `d`.
pub(crate) fn line(d: &Delivery) -> Value {
    json!({
        "ts": crate::store::now_ms(),
        "deliveryId": d.id,
        "target": d.target,
        "sender": d.caller,
        "reason": d.error.clone().unwrap_or_else(|| "failed".into()),
        "text": text_of(d),
    })
}

/// Appends `line` to `path`, created private.
fn append(path: &std::path::Path, line: &Value) -> std::io::Result<()> {
    use std::io::Write as _;
    let mut file =
        crate::home_fs::OpenOptions::new().create(true).append(true).mode(0o600).open(path)?;
    let mut bytes = serde_json::to_vec(line).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    file.write_all(&bytes)
}

impl Hub {
    /// Drains the outbox's failures: each one is a dead letter and a bounce to its sender. Once
    /// per hub; a second call does nothing.
    pub fn start_bounces(self: &Arc<Self>) {
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Delivery>();
        if !self.outbox.on_failed(tx) {
            return;
        }
        static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();
        let scope = SCOPE.get_or_init(|| cmux_scope::Scope::new("outbox bounces"));
        let hub = Arc::downgrade(self);
        let _task = scope.spawn_named("outbox bounces", async move {
            while let Some(d) = rx.recv().await {
                let Some(hub) = hub.upgrade() else { return };
                hub.bounce(&d).await;
            }
        });
    }

    /// `d` failed: its dead letter, and the notice to the session that sent it.
    pub(crate) async fn bounce(self: &Arc<Self>, d: &Delivery) {
        let entry = line(d);
        let kept = self.outbox.dead_letters_path();
        let kept_in = kept.as_ref().map_or_else(|| FILE.to_owned(), |p| p.display().to_string());
        if let Some(path) = kept {
            let entry = entry.clone();
            let wrote = tokio::task::spawn_blocking(move || append(&path, &entry)).await;
            if let Ok(Err(e)) | Err(e) = wrote.map_err(std::io::Error::other) {
                tracing::warn!(delivery = %d.id, "a dead letter was not written: {e}");
            }
        }
        tracing::warn!(delivery = %d.id, target = %d.target, reason = %entry["reason"], "bounced");
        let Some(session) = d.caller.as_deref().and_then(|c| self.session_get(c)) else { return };
        let notice = json!({
            "sender": "acpmux",
            "severity": "warn",
            "title": format!("your message to {} was not delivered", d.target),
        });
        let body = format!(
            "[bounce] to {} failed: {}\ndelivery {} (in {kept_in}). Find who holds it now \
             (`acpmux ls`, `acpmux role ls`) and send it again.\n---\n{}",
            d.target,
            entry["reason"].as_str().unwrap_or("failed"),
            d.id,
            entry["text"].as_str().unwrap_or_default(),
        );
        let text = crate::prompt_provenance::notice_text(&notice, &body);
        let mut provenance = crate::prompt_provenance::notice(&notice, &session.id);
        provenance.set("bounceOf", json!(d.id));
        let opts = PromptOptions {
            prompt_id: Some(format!("{PROMPT_PREFIX}{}", d.id)),
            resend: true,
            provenance: Some(provenance),
            agent: Some("acpmux".to_owned()),
            class: Some(crate::prompt_class::PromptClass::Result),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": text})];
        if let Err(e) = self.prompt_with(&session, blocks, "acpmux", true, opts).await
            && e.data.as_ref().is_none_or(|d| d["held"] != true)
        {
            tracing::warn!(session = %session.id, delivery = %d.id, "a bounce: {}", e.message);
        }
    }
}

#[cfg(test)]
#[path = "dead_letters_tests.rs"]
mod tests;
