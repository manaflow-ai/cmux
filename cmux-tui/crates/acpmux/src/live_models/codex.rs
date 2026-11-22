//! Codex's live model list: `codex app-server` (JSON-RPC lines without the
//! `jsonrpc` field), `initialize`, `initialized`, then `model/list` page by
//! page. Hidden models are left out and the default model is marked. No
//! account check runs first: a Codex that is not signed in refuses
//! `model/list`, and its message becomes the harness's probe error.
//!
//! Row mapping after MonoCode's codexCatalog.ts (parseModel,
//! parseModelSettings). Portions adapted from MonoCode, Copyright (c) 2026
//! Nick, MIT License (see THIRD_PARTY_LICENSES.md).

use super::{LiveModel, Probe, text};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

/// The most pages one probe reads (a cursor loop must end).
const MAX_PAGES: usize = 20;

pub(super) fn args() -> Vec<String> {
    vec!["app-server".to_owned()]
}

/// Sends request `id` and returns its result; notifications and other
/// replies in between are skipped.
async fn request(child: &mut Probe, id: u64, method: &str, params: Value) -> Result<Value> {
    child.send(&json!({"id": id, "method": method, "params": params})).await?;
    loop {
        let v = child.next().await?;
        if v.get("id").and_then(Value::as_u64) != Some(id) || v.get("method").is_some() {
            continue;
        }
        if let Some(error) = v.get("error") {
            let message = text(error, "message").unwrap_or("request failed");
            return Err(anyhow!("codex app-server refused {method}: {message}"));
        }
        return Ok(v.get("result").cloned().unwrap_or(Value::Null));
    }
}

pub(super) async fn list(child: &mut Probe) -> Result<Vec<LiveModel>> {
    let client = json!({"name": "acpmux", "title": "acpmux", "version": env!("CARGO_PKG_VERSION")});
    request(
        child,
        1,
        "initialize",
        json!({"clientInfo": client, "capabilities": {"experimentalApi": true}}),
    )
    .await?;
    child.send(&json!({"method": "initialized"})).await?;
    let mut rows = Vec::new();
    let mut cursor: Option<String> = None;
    for page in 0..MAX_PAGES {
        let params = cursor.as_ref().map_or_else(|| json!({}), |c| json!({"cursor": c}));
        let result = request(child, 2 + page as u64, "model/list", params).await?;
        rows.extend(result.get("data").and_then(Value::as_array).cloned().unwrap_or_default());
        cursor = text(&result, "nextCursor").map(str::to_owned);
        if cursor.is_none() {
            break;
        }
    }
    let models = parse(&rows);
    if models.is_empty() {
        return Err(anyhow!("codex app-server listed no models"));
    }
    Ok(models)
}

/// The visible models in `model/list` rows, each id once, the default first.
pub fn parse(rows: &[Value]) -> Vec<LiveModel> {
    let mut out: Vec<LiveModel> = Vec::new();
    for row in rows {
        if let Some(model) = row_model(row)
            && !out.iter().any(|m| m.id == model.id)
        {
            out.push(model);
        }
    }
    if let Some(at) = out.iter().position(|m| m.is_default) {
        out[..=at].rotate_right(1);
    }
    out
}

fn row_model(row: &Value) -> Option<LiveModel> {
    if row.get("hidden").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let id = text(row, "model").or_else(|| text(row, "slug")).or_else(|| text(row, "id"))?;
    let name = text(row, "displayName").or_else(|| text(row, "name")).unwrap_or(id);
    let efforts: Vec<String> = row
        .get("supportedReasoningEfforts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|e| {
            e.as_str()
                .or_else(|| text(e, "reasoningEffort"))
                .or_else(|| text(e, "id"))
                .map(str::to_owned)
        })
        .collect();
    Some(LiveModel {
        id: id.to_owned(),
        name: display_name(name),
        efforts,
        default_effort: text(row, "defaultReasoningEffort").map(str::to_owned),
        fast: fast(row),
        is_default: row.get("isDefault").and_then(Value::as_bool) == Some(true),
    })
}

/// Whether a tier faster than the default exists (`serviceTiers`, else
/// `additionalSpeedTiers`); unset when the row names no tiers.
fn fast(row: &Value) -> Option<bool> {
    let tiers = ["serviceTiers", "additionalSpeedTiers"]
        .iter()
        .find_map(|key| row.get(*key).and_then(Value::as_array).filter(|t| !t.is_empty()))?;
    let id = |t: &Value| t.as_str().map(str::to_owned).or_else(|| text(t, "id").map(str::to_owned));
    Some(tiers.iter().filter_map(id).any(|t| t != "default"))
}

/// `gpt-6-astra` -> `GPT-6-Astra`, as Codex's own picker shows it. Other
/// names stay as the CLI gives them.
fn display_name(name: &str) -> String {
    if !name.get(..3).is_some_and(|p| p.eq_ignore_ascii_case("gpt")) {
        return name.to_owned();
    }
    let mut out = String::with_capacity(name.len());
    let mut upper = true;
    for (i, c) in name.chars().enumerate() {
        out.push(if upper || i < 3 { c.to_ascii_uppercase() } else { c });
        upper = c == '-';
    }
    out
}
