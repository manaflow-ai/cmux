//! Claude Code's live model list: `claude -p` in stream-json mode, the SDK's
//! `initialize` control request, then `list_models`. The `initialize` reply
//! also lists models; it is the answer when `list_models` is refused (an older
//! Claude Code). The probe runs with no session file, no MCP servers and no
//! hooks, so it touches nothing of the user's.
//!
//! Row mapping after MonoCode's claudeCatalog.ts (modelFromListRow,
//! settingsFromListRow, claudeLaunchId). Portions adapted from MonoCode,
//! Copyright (c) 2026 Nick, MIT License (see THIRD_PARTY_LICENSES.md).

use super::{LiveModel, Probe, text};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

const INIT_ID: &str = "acpmux-models-init";
const LIST_ID: &str = "acpmux-models-list";

/// The flags after the harness's own argv.
pub(super) fn args() -> Vec<String> {
    [
        "-p",
        "--input-format",
        "stream-json",
        "--output-format",
        "stream-json",
        "--verbose",
        "--no-session-persistence",
        "--strict-mcp-config",
        "--mcp-config",
        r#"{"mcpServers":{}}"#,
        "--settings",
        r#"{"disableAllHooks":true}"#,
    ]
    .map(str::to_owned)
    .to_vec()
}

fn control_request(id: &str, subtype: &str) -> Value {
    json!({"type": "control_request", "request_id": id, "request": {"subtype": subtype}})
}

/// A control response to `id`: `Ok(payload)` or `Err(message)`.
fn control_response(v: &Value, id: &str) -> Option<Result<Value, String>> {
    if text(v, "type") != Some("control_response") {
        return None;
    }
    let inner = v.get("response")?;
    if text(inner, "request_id").or_else(|| text(v, "request_id")) != Some(id) {
        return None;
    }
    Some(match text(inner, "subtype") {
        Some("error") => Err(text(inner, "error").unwrap_or("control request failed").to_owned()),
        _ => Ok(inner.get("response").cloned().unwrap_or(Value::Null)),
    })
}

pub(super) async fn list(child: &mut Probe) -> Result<Vec<LiveModel>> {
    child.send(&control_request(INIT_ID, "initialize")).await?;
    let mut from_init = Vec::new();
    loop {
        let v = child.next().await?;
        if let Some(reply) = control_response(&v, INIT_ID) {
            let payload = reply.map_err(|e| anyhow!("Claude Code refused initialize: {e}"))?;
            from_init = parse(&payload);
            child.send(&control_request(LIST_ID, "list_models")).await?;
        } else if let Some(reply) = control_response(&v, LIST_ID) {
            let listed = reply.map(|payload| parse(&payload)).unwrap_or_default();
            let models = if listed.is_empty() { from_init } else { listed };
            return if models.is_empty() {
                Err(anyhow!("Claude Code listed no models"))
            } else {
                Ok(models)
            };
        }
    }
}

/// The models in a `list_models` or `initialize` payload (`{models: [...]}`
/// or the array itself), without disabled rows, the "default" choice and
/// update notices, each id once.
pub fn parse(payload: &Value) -> Vec<LiveModel> {
    let rows = payload.as_array().or_else(|| payload.get("models").and_then(Value::as_array));
    let mut out: Vec<LiveModel> = Vec::new();
    for row in rows.into_iter().flatten() {
        if let Some(model) = row_model(row)
            && !out.iter().any(|m| m.id == model.id)
        {
            out.push(model);
        }
    }
    out
}

/// `opus[1m]` -> (`opus`, true).
fn split_context(value: &str) -> (&str, bool) {
    let value = value.trim();
    match value.strip_suffix("[1m]").or_else(|| value.strip_suffix("[1M]")) {
        Some(id) if !id.trim().is_empty() => (id.trim(), true),
        _ => (value, false),
    }
}

/// The `--model` id: a family alias (`opus`) stays bare; a versioned value
/// (`opus-5-5`) takes the `claude-` prefix, or the resolved model's id.
fn launch_id(value: &str, resolved: &str) -> String {
    let id = if value.is_empty() { resolved } else { value };
    if id.is_empty() || id.starts_with("claude-") || !id.chars().any(|c| c.is_ascii_digit()) {
        return id.to_owned();
    }
    if resolved.starts_with("claude-") { resolved.to_owned() } else { format!("claude-{id}") }
}

fn row_model(row: &Value) -> Option<LiveModel> {
    if row.get("disabled").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let value = text(row, "value")?;
    if value == "default" || value.starts_with("cc-update-required") {
        return None;
    }
    let (value_id, wide) = split_context(value);
    let (resolved_id, resolved_wide) = split_context(text(row, "resolvedModel").unwrap_or(""));
    let mut id = launch_id(value_id, resolved_id);
    if id.is_empty() {
        return None;
    }
    let wide = wide || resolved_wide;
    if wide {
        id.push_str("[1m]");
    }
    let mut name = name(row, &id);
    if wide && !name.contains("1M") {
        name.push_str(" · 1M context");
    }
    let mut efforts: Vec<String> = row
        .get("supportedEffortLevels")
        .and_then(Value::as_array)
        .map(|levels| levels.iter().filter_map(Value::as_str).map(str::trim))
        .into_iter()
        .flatten()
        .filter(|level| !level.is_empty())
        .map(str::to_owned)
        .collect();
    if efforts.is_empty() && row.get("supportsEffort").and_then(Value::as_bool) == Some(true) {
        efforts = ["low", "medium", "high", "max"].map(str::to_owned).to_vec();
    }
    Some(LiveModel {
        id,
        name,
        efforts,
        default_effort: None,
        fast: row.get("supportsFastMode").and_then(Value::as_bool),
        is_default: false,
    })
}

/// The display name, else the description's first part (`Opus 5.5 · ...`),
/// else the id. A description that extends the name (`Opus` -> `Opus 5.5`)
/// is the better name.
fn name(row: &Value, id: &str) -> String {
    let display = text(row, "displayName").unwrap_or("");
    let head =
        text(row, "description").and_then(|d| d.split('·').next()).map(str::trim).unwrap_or("");
    let extends = !display.is_empty()
        && head.len() > display.len()
        && head.to_lowercase().starts_with(&display.to_lowercase());
    let picked = if extends || display.is_empty() { head } else { display };
    if picked.is_empty() { id.to_owned() } else { picked.to_owned() }
}
