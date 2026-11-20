//! Codex's live model list: `codex app-server` (JSON-RPC lines without the
//! `jsonrpc` field), `initialize`, `initialized`, then `model/list` page by
//! page. Hidden models are left out and the default model is marked. No
//! account check runs first: a Codex that is not signed in refuses
//! `model/list`, and its message becomes the harness's probe error.
//!
//! Row mapping after MonoCode's codexCatalog.ts (parseModel,
//! parseModelSettings). Portions adapted from MonoCode, Copyright (c) 2026
//! Nick, MIT License (see THIRD_PARTY_LICENSES.md).

use super::{AsyncReadExt, BTreeMap, Cli, LiveModel, Path, Probe, text};
use anyhow::{Result, anyhow};
use serde_json::{Value, json};

/// The most pages one probe reads (a cursor loop must end).
const MAX_PAGES: usize = 20;

pub(super) fn args() -> Vec<String> {
    vec!["app-server".to_owned()]
}

#[derive(Debug, thiserror::Error)]
#[error("codex app-server refused {method}: {message}")]
struct RpcFailure {
    method: String,
    code: Option<i64>,
    message: String,
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
            return Err(RpcFailure {
                method: method.into(),
                code: error["code"].as_i64(),
                message: message.into(),
            }
            .into());
        }
        return Ok(v.get("result").cloned().unwrap_or(Value::Null));
    }
}

/// `initialize` (request 1), then the `initialized` notification.
async fn initialize(child: &mut Probe) -> Result<()> {
    let client = json!({"name": "acpmux", "title": "acpmux", "version": env!("CARGO_PKG_VERSION")});
    request(
        child,
        1,
        "initialize",
        json!({"clientInfo": client, "capabilities": {"experimentalApi": true}}),
    )
    .await?;
    child.send(&json!({"method": "initialized"})).await
}

/// The account's plan usage limits at rest: `account/rateLimits/read`'s result
/// (`{rateLimits, rateLimitsByLimitId?}`), as the app-server answers it.
pub(super) async fn rate_limits(child: &mut Probe) -> Result<Value> {
    initialize(child).await?;
    request(child, 2, "account/rateLimits/read", Value::Null).await
}

pub(super) async fn list(child: &mut Probe) -> Result<Vec<LiveModel>> {
    initialize(child).await?;
    let config = request(child, 2, "config/read", json!({})).await.ok();
    let mut provider =
        config.as_ref().and_then(|v| v.pointer("/config/model_provider")).and_then(Value::as_str);
    let mut rows = Vec::new();
    let mut cursor: Option<String> = None;
    for page in 0..MAX_PAGES {
        let mut params = cursor.as_ref().map_or_else(|| json!({}), |c| json!({"cursor": c}));
        if let Some(provider) = provider {
            params["modelProvider"] = json!(provider);
        }
        let id = 3 + 2 * page as u64;
        let result = match request(child, id, "model/list", params).await {
            Err(e)
                if page == 0
                    && e.downcast_ref::<RpcFailure>().is_some_and(|e| e.code == Some(-32602))
                    && provider.take().is_some() =>
            {
                request(child, id + 1, "model/list", json!({})).await?
            }
            result => result?,
        };
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

/// `debug models` refreshes the configured provider catalog (without `--bundled`).
/// Run with the same executable, profile arguments, and account environment as app-server.
pub(super) async fn provider_models(
    argv: &[String],
    env: &BTreeMap<String, String>,
    cwd: &Path,
) -> Result<Vec<LiveModel>> {
    let args = ["debug".to_owned(), "models".to_owned()];
    let mut cmd = Probe::command(Cli::Codex, argv, env, cwd, &args).await?;
    let mut child = cmd.stdin(std::process::Stdio::null()).spawn()?;
    let mut bytes = Vec::new();
    const LIMIT: u64 = 16 * 1024 * 1024;
    child
        .stdout
        .take()
        .ok_or_else(|| anyhow!("codex has no stdout"))?
        .take(LIMIT + 1)
        .read_to_end(&mut bytes)
        .await?;
    if bytes.len() as u64 > LIMIT || !child.wait().await?.success() {
        return Err(anyhow!("codex catalog refresh unavailable"));
    }
    let response: Value = serde_json::from_slice(&bytes)?;
    let rows = response["models"].as_array().ok_or_else(|| anyhow!("missing provider catalog"))?;
    Ok(parse(rows))
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
    if row.get("hidden").and_then(Value::as_bool) == Some(true)
        || text(row, "visibility").is_some_and(|v| v != "list")
    {
        return None;
    }
    let id = text(row, "model").or_else(|| text(row, "slug")).or_else(|| text(row, "id"))?;
    let name = text(row, "displayName")
        .or_else(|| text(row, "display_name"))
        .or_else(|| text(row, "name"))
        .unwrap_or(id);
    let efforts: Vec<String> = row
        .get("supportedReasoningEfforts")
        .or_else(|| row.get("supported_reasoning_levels"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|e| {
            e.as_str()
                .or_else(|| text(e, "reasoningEffort"))
                .or_else(|| text(e, "effort"))
                .or_else(|| text(e, "id"))
                .map(str::to_owned)
        })
        .collect();
    Some(LiveModel {
        id: id.to_owned(),
        name: display_name(name),
        efforts,
        default_effort: text(row, "defaultReasoningEffort")
            .or_else(|| text(row, "default_reasoning_level"))
            .map(str::to_owned),
        fast: fast(row),
        service_tiers: tiers(row).cloned().unwrap_or_default(),
        is_default: row.get("isDefault").and_then(Value::as_bool) == Some(true),
        upgrade: upgrade(row, id),
    })
}

/// The model Codex's catalog moves this one to: `upgrade` (an id), else `upgradeInfo.model`.
/// gpt-5.6-terra and gpt-5.5 name gpt-6-sol there, so they are legacy; gpt-6.1-sol names none.
fn upgrade(row: &Value, id: &str) -> Option<String> {
    text(row, "upgrade")
        .or_else(|| row.get("upgrade").and_then(|info| text(info, "model")))
        .or_else(|| row.get("upgradeInfo").and_then(|info| text(info, "model")))
        .filter(|to| *to != id)
        .map(str::to_owned)
}

/// Whether a tier faster than the default exists (`serviceTiers`, else
/// `additionalSpeedTiers`); unset when the row names no tiers.
fn fast(row: &Value) -> Option<bool> {
    let tiers = tiers(row)?;
    let id = |t: &Value| t.as_str().map(str::to_owned).or_else(|| text(t, "id").map(str::to_owned));
    Some(tiers.iter().filter_map(id).any(|t| t != "default"))
}

fn tiers(row: &Value) -> Option<&Vec<Value>> {
    ["serviceTiers", "service_tiers", "additionalSpeedTiers", "additional_speed_tiers"]
        .iter()
        .find_map(|key| row.get(*key).and_then(Value::as_array).filter(|t| !t.is_empty()))
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
