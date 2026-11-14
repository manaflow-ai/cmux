//! The local row and its optional peer form share one bounded conversion.
use super::super::{Hub, Session};
use acpmux_book::index::{ForkOf, MAX_TITLE_BYTES, RowKey, Summary};
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

fn cut_title(text: &mut String) {
    cut(text, TEXT_CHARS);
    if text.len() > MAX_TITLE_BYTES {
        let mut end = MAX_TITLE_BYTES.saturating_sub('…'.len_utf8());
        while !text.is_char_boundary(end) {
            end -= 1;
        }
        text.truncate(end);
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

fn selected_extra(row: &Map<String, Value>, state: &str) -> Value {
    let mut values: Map<String, Value> = row
        .iter()
        .filter(|(key, value)| {
            EXTRA_KEYS.contains(&key.as_str())
                && !(matches!(key.as_str(), "stuckError" | "stuckSince") && value.is_null())
        })
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    // Status describes the session; state may instead say stuck or stopping.
    // Ordinary rows need no second copy of the same string on the wire.
    if let Some(status) = row.get("status").and_then(Value::as_str)
        && status != state
    {
        values.insert("status".into(), Value::String(status.to_owned()));
    }
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

fn extra(row: &Map<String, Value>, state: &str) -> Value {
    let mut value = selected_extra(row, state);
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
    cut_title(&mut summary.title);
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
    // v1 keeps this on metadata but does not serialize it in SessionSummary.
    summary.workspace = meta.workspace_id.clone();
    summary.parent =
        super::super::views::activity_parent_id(&meta).map(|id| RowKey::new("local", id));
    summary.fork_of = meta.parent_id.as_ref().map(|id| ForkOf {
        key: RowKey::new("local", id.as_str()),
        seq: meta.fork_seq.unwrap_or(0),
    });
    summary.folder =
        row.get("cwd").and_then(Value::as_str).map(|path| path.trim_end_matches('/').to_owned());
    // Keep the typed archive bit beside the row. The tag remains in `extra` for
    // older readers, but callers must not parse opaque bytes on every parent fold.
    let now = crate::store::now_ms();
    summary.archived = meta
        .tags
        .get("archived")
        .is_some_and(|tag| tag.expires_at.is_none_or(|expires_at| expires_at > now));
    // Apply typed field bounds once, while extra is empty. Subsequent fitting
    // never uses the index's empty-extra fallback.
    summary = summary.prepare()?;
    let local_extra = extra(row, &summary.state);
    let mut local = Form { row: summary, extra: local_extra };

    // Mask before cutting: a text boundary must not leave a partial secret.
    // v1 bounds the scan itself. It recognizes a summary by these three keys.
    // Keep them on the temporary
    // mask input, then convert the result to the same typed Summary shape.
    let mut mask_input =
        selected_extra(row, &local.row.state).as_object().cloned().unwrap_or_default();
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
            cut_title(&mut summary.title);
            summary = summary.prepare()?;
            let peer_extra = extra(&masked, &summary.state);
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

/// Converts one peer table row into the list index's typed summary. The row is
/// supplied from `RemoteRows::live_of_peer`, so fields rewritten by the v1
/// stale marker are not carried into the v2 row. Remote rows never transit to
/// another peer, hence `peer_form` stays empty.
pub(super) fn summary_from_remote(peer: &str, row: &super::super::PeerRow) -> io::Result<Summary> {
    let value = row.value();
    let chat_id =
        row.session_id().ok_or_else(|| invalid("remote summary has no sessionId"))?.to_owned();
    let mut summary = Summary::new(chat_id);
    summary.origin = peer.to_owned();
    summary.title = value
        .get("title")
        .or_else(|| value.get("name"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_owned();
    cut_title(&mut summary.title);
    summary.harness = row.harness().unwrap_or_default().to_owned();
    summary.state = value
        .get("state")
        .and_then(Value::as_str)
        .or_else(|| row.status())
        .unwrap_or("closed")
        .to_owned();
    summary.last_activity = row.updated_ms();
    let count = value.get("unreadTurns").and_then(Value::as_u64).unwrap_or(0);
    let unread = value.get("unread").and_then(Value::as_bool).unwrap_or(false);
    summary.unread = if count == 0 && unread { 1 } else { count.min(u32::MAX as u64) as u32 };
    summary.workspace = value
        .get("workspaceId")
        .or_else(|| value.get("workspace"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    summary.folder =
        value.get("cwd").and_then(Value::as_str).map(|path| path.trim_end_matches('/').to_owned());
    summary.pinned = value.get("pinned").and_then(Value::as_bool).unwrap_or(false);
    let mut opaque = value
        .as_object()
        .map(|row| extra(row, &summary.state))
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    for key in ["stale", "lastSeen", "stuckReason", "stuckSince", "stuckError"] {
        opaque.remove(key);
    }
    summary.extra = json(&Value::Object(opaque))?;
    summary.prepare()
}

#[cfg(test)]
mod tests;
