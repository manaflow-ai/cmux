//! Deploy on first use for the `foundry` harness (`crate::foundry`): once a turn started and before
//! its agent does, a model with no deployment deploys and the turn waits until Azure serves it.
//! That wait is one tool call, so the live line reads "Connecting" and, while Azure creates the
//! deployment, "Deploying model". It ends when the model itself starts, which is when "Thinking"
//! begins. A failed deploy fails the turn (no agent call, so no DeploymentNotFound after).

use std::collections::{HashMap, HashSet};
use std::sync::{Mutex, OnceLock};

use serde_json::{Value, json};

use super::{Hub, Session};
use crate::foundry;
use crate::no_panic::{JsonExt, LockExt};

const CONNECTING: &str = "Connecting";
const DEPLOYING: &str = "Deploying model";

/// One daemon: the open wait per session, and the models already deployed this process.
struct Gate {
    lines: HashMap<String, String>,
    deployed: HashSet<String>,
}

fn gate() -> &'static Mutex<Gate> {
    static GATE: OnceLock<Mutex<Gate>> = OnceLock::new();
    GATE.get_or_init(|| Mutex::new(Gate { lines: HashMap::new(), deployed: HashSet::new() }))
}

impl Hub {
    /// `Ok` when the model is already up or this deploy finished; `Err` with Azure's words when
    /// deploy failed (quota, deprecating, …).
    pub(crate) async fn foundry_deploy(&self, s: &Session) -> Result<(), String> {
        let meta = s.meta();
        if meta.harness != foundry::HARNESS_ID {
            return Ok(());
        }
        let model = super::model_options::current_model(&meta);
        // `azure/gpt-5` is the picker id; the deployment Azure created is the name after the slash.
        let Some(model) = model.as_deref().map(foundry_deployment) else {
            return Ok(());
        };
        let cfg = self.config.read().await;
        let account = cfg.profile(foundry::HARNESS_ID).and_then(|p| foundry::account_of(&p.env));
        drop(cfg);
        let Some(account) = account else { return Ok(()) };
        // Up before the agent: the line stays "Connecting" until the model itself starts
        // (`foundry_line_end` from the first thought, reply or call).
        self.foundry_line_open(s, CONNECTING);
        // Keyed by account so a region switch deploys again on first use.
        let key = format!("{account}/{model}");
        if gate().lock_or_recover().deployed.contains(&key) {
            return Ok(());
        }
        if !foundry::deployed(&account, model).await {
            self.foundry_line_title(s, DEPLOYING);
            if let Err(e) = foundry::deploy(&account, model).await {
                self.foundry_line_end(s, Some(&e));
                return Err(e);
            }
            self.foundry_line_title(s, CONNECTING);
        }
        gate().lock_or_recover().deployed.insert(key);
        Ok(())
    }

    /// The Foundry wait's one call. The pane reads a `tool_call` whose message is a
    /// `session/update`; a record filed as `session/update` never becomes the live line.
    fn foundry_line_open(&self, s: &Session, title: &str) {
        self.foundry_line_end(s, None);
        let id = format!("foundry-line-{}", uuid::Uuid::now_v7());
        gate().lock_or_recover().lines.insert(s.id.clone(), id.clone());
        self.foundry_line_send(s, &id, "tool_call", "in_progress", Some(title), "");
    }

    fn foundry_line_title(&self, s: &Session, title: &str) {
        if title.is_empty() {
            return;
        }
        let Some(id) = gate().lock_or_recover().lines.get(&s.id).cloned() else {
            return;
        };
        self.foundry_line_send(s, &id, "tool_call_update", "in_progress", Some(title), "");
    }

    /// Closes the wait, once. `None` completes it; `Some(text)` fails it with that text.
    pub(super) fn foundry_line_end(&self, s: &Session, failure: Option<&str>) {
        let Some(id) = gate().lock_or_recover().lines.remove(&s.id) else {
            return;
        };
        let (status, text) = match failure {
            Some(text) => ("failed", text),
            None => ("completed", ""),
        };
        self.foundry_line_send(s, &id, "tool_call_update", status, None, text);
    }

    fn foundry_line_send(
        &self,
        s: &Session,
        id: &str,
        kind: &str,
        status: &str,
        title: Option<&str>,
        text: &str,
    ) {
        self.append(s, "in", kind, foundry_status_msg(&s.id, id, kind, status, title, text));
    }
}

/// The Azure deployment a picker id names. The provider prefix (`azure/gpt-5` is `gpt-5`) is
/// dropped. A bare deployment name is kept.
fn foundry_deployment(model: &str) -> &str {
    model.split_once('/').map(|(_, rest)| rest).unwrap_or(model)
}

/// The record the live line reads: `kind` is the update (`tool_call` / `tool_call_update`) and
/// `msg.method` is `session/update`.
fn foundry_status_msg(
    session: &str,
    id: &str,
    kind: &str,
    status: &str,
    title: Option<&str>,
    text: &str,
) -> Value {
    let mut update = json!({
        "sessionUpdate": kind,
        "toolCallId": id,
        "kind": "other",
        "status": status,
    });
    if let Some(title) = title.filter(|title| !title.is_empty()) {
        update.set("title", json!(title));
    }
    if !text.is_empty() {
        update.set(
            "content",
            json!([{"type": "content", "content": {"type": "text", "text": text}}]),
        );
    }
    json!({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {"sessionId": session, "update": update},
    })
}

#[cfg(test)]
mod tests {
    use super::foundry_status_msg;

    #[test]
    fn the_wait_is_a_tool_call_the_live_line_reads() {
        let msg = foundry_status_msg(
            "s",
            "foundry-line-1",
            "tool_call",
            "in_progress",
            Some("Connecting"),
            "",
        );
        assert_eq!(msg["method"], "session/update");
        let update = &msg["params"]["update"];
        assert_eq!(update["sessionUpdate"], "tool_call");
        assert_eq!(update["title"], "Connecting");
        assert_eq!(update["status"], "in_progress");
        assert!(update.get("content").is_none());
    }

    #[test]
    fn the_deployment_is_the_model_past_its_provider_prefix() {
        assert_eq!(super::foundry_deployment("azure/gpt-5-mini"), "gpt-5-mini");
        assert_eq!(super::foundry_deployment("byo/gpt-5"), "gpt-5");
        assert_eq!(super::foundry_deployment("gpt-4o"), "gpt-4o");
    }
}
