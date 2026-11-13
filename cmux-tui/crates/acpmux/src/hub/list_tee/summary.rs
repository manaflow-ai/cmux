//! The local row and its optional peer form share one bounded conversion.
use super::super::{Hub, Session};
use acpmux_book::index::{ForkOf, RowKey, Summary};
use serde_json::{Map, Value};
use std::io;

const TEXT_CHARS: usize = 160;
/// Applies to each summary list, including names, URLs, warnings and tag ids.
const LIST_ITEMS: usize = 8;
const EXTRA_KEYS: &[&str] = &[
    "name",
    "shortName",
    "indicator",
    "titleSource",
    "lastPrompt",
    "model",
    "cwd",
    "family",
    "agentSessionId",
    "startedBy",
    "createdMs",
    "preview",
    "subagentsRunning",
    "subagentNames",
    "commandsRunning",
    "pullRequests",
    "usageWarnings",
    "lastMessage",
    "lane",
    "turn",
    "tags",
    "effort",
    "createdAt",
    "inputSince",
    "lastTurn",
    "pendingPermissions",
    "waitingOn",
    "seenSeq",
    "gitBranch",
    "pullRequest",
    "forkSeq",
    "queued",
    "waitsForSlot",
    "turnCount",
    "retry",
    "retryDeciding",
    "lifecycleReceipt",
    "stale",
    "watching",
    "loopEpisode",
    "coldArchive",
    "waitingPrompt",
    "since",
    "stuckError",
    "stuckSince",
];

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn json(value: &impl serde::Serialize) -> io::Result<Box<serde_json::value::RawValue>> {
    serde_json::value::to_raw_value(value).map_err(io::Error::other)
}

fn cut(text: &mut String, chars: usize) {
    if text.chars().count() > chars {
        *text = text.chars().take(chars.saturating_sub(1)).collect();
        text.push('…');
    }
}

fn cut_values(value: &mut Value) {
    match value {
        Value::String(text) => cut(text, TEXT_CHARS),
        Value::Array(values) => {
            values.truncate(LIST_ITEMS);
            for value in values {
                cut_values(value);
            }
        }
        Value::Object(values) => {
            for value in values.values_mut() {
                cut_values(value);
            }
        }
        _ => {}
    }
}

fn retain(value: Option<&mut Value>, keys: &[&str]) {
    if let Some(Value::Object(values)) = value {
        values.retain(|key, _| keys.contains(&key.as_str()));
    }
}

fn selected_extra(row: &Map<String, Value>) -> Value {
    let mut values: Map<String, Value> = row
        .iter()
        .filter(|(key, value)| {
            EXTRA_KEYS.contains(&key.as_str())
                && !(matches!(key.as_str(), "stuckError" | "stuckSince") && value.is_null())
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    retain(values.get_mut("lastMessage"), &["role", "text"]);
    retain(values.get_mut("lane"), &["state", "since", "error", "step", "title", "requiresOpen"]);
    retain(
        values.get_mut("turn"),
        &["startedAt", "prompt", "notice", "activity", "planStep", "stalledSince", "turnId"],
    );
    retain(values.get_mut("lastTurn"), &["status", "endedAt"]);
    retain(values.get_mut("pullRequest"), &["number", "title", "state", "reviewReady", "checks"]);
    retain(values.get_mut("coldArchive"), &["archivedAt", "messages"]);
    retain(
        values.get_mut("tags"),
        &["notifications", "mux.parent", "mux.children", "cmux.chief.participant", "archived"],
    );
    if let Some(Value::Array(warnings)) = values.get_mut("usageWarnings") {
        for warning in warnings {
            retain(Some(warning), &["text"]);
        }
    }
    Value::Object(values)
}

fn extra(row: &Map<String, Value>) -> Value {
    let mut value = selected_extra(row);
    cut_values(&mut value);
    value
}

/// Field names and enum values are preserved. Only display text is eligible
/// for repeated shrinking; structural ids and states must keep their meaning.
fn shrinkable(key: &str) -> bool {
    matches!(
        key,
        "name"
            | "shortName"
            | "title"
            | "text"
            | "lastPrompt"
            | "preview"
            | "prompt"
            | "waitingPrompt"
            | "activity"
            | "planStep"
            | "error"
            | "stuckError"
            | "cwd"
            | "gitBranch"
            | "model"
    )
}

fn longest(value: &mut Value) -> Option<&mut String> {
    match value {
        Value::Object(values) => values
            .iter_mut()
            .filter_map(|(key, value)| {
                if matches!(key.as_str(), "pullRequests" | "subagentNames")
                    && let Value::Array(values) = value
                {
                    return values
                        .iter_mut()
                        .filter_map(|value| match value {
                            Value::String(text) if text.chars().count() > 1 => Some(text),
                            _ => None,
                        })
                        .max_by_key(|text| text.len());
                }
                if shrinkable(key)
                    && let Value::String(text) = value
                {
                    return (text.chars().count() > 1).then_some(text);
                }
                longest(value)
            })
            .max_by_key(|text| text.len()),
        Value::Array(values) => values.iter_mut().filter_map(longest).max_by_key(|text| text.len()),
        _ => None,
    }
}

struct Form {
    row: Summary,
    extra: Value,
}

impl Form {
    fn refresh(&mut self) -> io::Result<()> {
        self.row.extra = json(&self.extra)?;
        Ok(())
    }

    fn shrink(&mut self) -> bool {
        let text = match longest(&mut self.extra) {
            Some(text) if text.len() > self.row.title.len() => text,
            _ => &mut self.row.title,
        };
        let count = text.chars().count();
        if count <= 1 {
            return false;
        }
        cut(text, count / 2);
        true
    }
}

pub(super) fn summary_from_session(hub: &Hub, session: &Session) -> io::Result<Summary> {
    let value = hub.session_list_summary(session);
    let row = value.as_object().ok_or_else(|| invalid("v1 summary is not an object"))?;
    let meta = session.meta();
    let mut summary = Summary::new(session.id.clone());
    summary.title = row.get("title").and_then(Value::as_str).unwrap_or(&meta.name).to_owned();
    cut(&mut summary.title, TEXT_CHARS);
    summary.harness = row
        .get("harness")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("v1 summary has no harness"))?
        .to_owned();
    summary.state = row
        .get("state")
        .or_else(|| row.get("status"))
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("v1 summary has no state"))?
        .to_owned();
    summary.last_activity = row.get("updatedAt").and_then(Value::as_u64).unwrap_or(0);
    let count = row.get("unreadTurns").and_then(Value::as_u64).unwrap_or(0);
    let unread = row.get("unread").and_then(Value::as_bool).unwrap_or(false);
    summary.unread = if count == 0 && unread { 1 } else { count.min(u32::MAX as u64) as u32 };
    summary.workspace = row.get("workspaceId").and_then(Value::as_str).map(str::to_owned);
    summary.parent =
        super::super::views::activity_parent_id(&meta).map(|id| RowKey::new("local", id));
    summary.fork_of = meta.parent_id.as_ref().map(|id| ForkOf {
        key: RowKey::new("local", id.as_str()),
        seq: meta.fork_seq.unwrap_or(0),
    });
    summary.folder =
        row.get("cwd").and_then(Value::as_str).map(|path| path.trim_end_matches('/').to_owned());
    // Apply typed field bounds once, while extra is empty. Subsequent fitting
    // never uses the index's empty-extra fallback.
    summary = summary.prepare()?;
    let mut local = Form { row: summary, extra: extra(row) };

    // Mask before cutting: a text boundary must not leave a partial secret.
    // v1 bounds the scan itself. It recognizes a summary by these three keys.
    // Keep them on the temporary
    // mask input, then convert the result to the same typed Summary shape.
    let mut mask_input = selected_extra(row).as_object().cloned().unwrap_or_default();
    mask_input.insert("sessionId".into(), Value::String(local.row.chat_id.clone()));
    mask_input.insert("harness".into(), Value::String(local.row.harness.clone()));
    mask_input.insert("lastSeq".into(), row.get("lastSeq").cloned().unwrap_or(Value::from(0)));
    mask_input.insert(
        "title".into(),
        Value::String(row.get("title").and_then(Value::as_str).unwrap_or(&meta.name).to_owned()),
    );
    let masked = crate::server::peer_text::masked(&crate::rpc::Message::Response {
        id: Value::from(0),
        result: Some(Value::Object(mask_input)),
        error: None,
    });
    let mut peer = match masked {
        Some(crate::rpc::Message::Response { result: Some(Value::Object(masked)), .. }) => {
            let mut summary = local.row.clone();
            summary.title =
                masked.get("title").and_then(Value::as_str).unwrap_or_default().to_owned();
            cut(&mut summary.title, TEXT_CHARS);
            summary = summary.prepare()?;
            let peer_extra = extra(&masked);
            if summary.title == local.row.title && peer_extra == local.extra {
                None
            } else {
                Some(Form { row: summary, extra: peer_extra })
            }
        }
        _ => None,
    };
    loop {
        local.refresh()?;
        if let Some(peer) = peer.as_mut() {
            peer.refresh()?;
            local.row.peer_form = Some(json(&peer.row)?);
        }
        if local.row.validate().is_ok() {
            return Ok(local.row);
        }
        let shrank_local = local.shrink();
        let shrank_peer = peer.as_mut().is_some_and(Form::shrink);
        if !shrank_local && !shrank_peer {
            return Err(invalid(&format!(
                "summary metadata exceeds 2 KiB after text cuts: local_extra={} peer_form={}",
                local.row.extra.get().len(),
                local.row.peer_form.as_ref().map_or(0, |value| value.get().len()),
            )));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    async fn fixture(secret: bool) -> (std::sync::Arc<Hub>, std::sync::Arc<Session>) {
        let mut config = crate::config::Config::default();
        config.store.mode = crate::config::StoreMode::Memory;
        let store =
            crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
        let mut meta = crate::god_fixture::session_meta(
            "fixture",
            "fixture",
            "/work/project///",
            "native-id",
            400,
            crate::store::now_ms(),
        );
        meta["status"] = Value::from("closed");
        meta["lastPrompt"] = Value::from("p".repeat(100_000));
        meta["preview"] = Value::from("v".repeat(100_000));
        if secret {
            meta["title"] =
                Value::from(format!("token gh{}_{}", "p", "aZ3kQ9mX7pL2vB8nR4tW6yC1dF5gH0jS1234"));
        }
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
        let hub = Hub::new(config, store);
        hub.wait_store().await;
        let session = hub.sessions.lock().unwrap().get("fixture").cloned().unwrap();
        (hub, session)
    }

    #[tokio::test]
    async fn a_long_v1_summary_keeps_required_shapes_without_empty_extra() {
        let (hub, session) = fixture(false).await;
        let row = summary_from_session(&hub, &session).unwrap();
        row.validate().unwrap();
        let extra: Value = serde_json::from_str(row.extra.get()).unwrap();
        assert_eq!(row.folder.as_deref(), Some("/work/project"));
        assert_eq!(extra["cwd"], "/work/project///");
        assert!(extra["lastPrompt"].as_str().unwrap().chars().count() <= TEXT_CHARS);
        assert!(extra["preview"].as_str().unwrap().chars().count() <= TEXT_CHARS);
        assert!(extra.get("forkSeq").is_some());
        assert!(extra.get("spawnedBy").is_none());
        assert!(extra.get("queue").is_none());
        assert!(extra.get("usageStats").is_none());
        assert!(extra.get("tools").is_none());
        assert!(row.peer_form.is_none());
        assert_eq!(row.last_activity, session.meta().updated_at);
    }

    #[tokio::test]
    async fn peer_form_is_a_masked_summary_and_keeps_the_local_secret_local() {
        let (hub, session) = fixture(true).await;
        let row = summary_from_session(&hub, &session).unwrap();
        row.validate().unwrap();
        assert!(row.title.contains("ghp_"));
        let peer: Summary = serde_json::from_str(row.peer_form.as_ref().unwrap().get()).unwrap();
        assert!(!peer.title.contains("ghp_"));
        assert!(peer.title.contains("GitHub"));
        assert_eq!(peer.chat_id, row.chat_id);
        assert!(peer.peer_form.is_none());
    }

    #[tokio::test]
    async fn display_lists_shrink_without_losing_required_keys_or_the_peer_form() {
        let (hub, session) = fixture(true).await;
        hub.edit_test_meta(&session, |meta| {
            meta.pull_requests = (0..LIST_ITEMS)
                .map(|n| format!("https://example.test/{n}/{}", "p".repeat(200)))
                .collect();
        });
        let row = summary_from_session(&hub, &session).unwrap();
        row.validate().unwrap();
        let peer: Summary = serde_json::from_str(row.peer_form.as_ref().unwrap().get()).unwrap();
        for form in [&row, &peer] {
            let extra: Value = serde_json::from_str(form.extra.get()).unwrap();
            let urls = extra["pullRequests"].as_array().unwrap();
            assert_eq!(urls.len(), LIST_ITEMS);
            assert!(urls.iter().all(|url| url.as_str().unwrap().chars().count() <= TEXT_CHARS));
            assert!(urls.iter().any(|url| url.as_str().unwrap().chars().count() < TEXT_CHARS));
            assert!(extra.get("lastPrompt").is_some());
            assert!(extra.get("preview").is_some());
            assert!(extra.get("cwd").is_some());
        }
    }
}
