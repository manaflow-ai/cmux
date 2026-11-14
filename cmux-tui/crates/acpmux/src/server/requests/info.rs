//! The session info request (`_acpmux/info`): one chat's detail, or with `sessionIds` the
//! session list's rows of up to [`MAX_KEYS`] chats by key ([`rows`]).

use super::*;

/// The most keys one `_acpmux/info` with `sessionIds` asks for (the design doc, "asks by key
/// (`_acpmux/info`, at most 100 a request)").
pub(crate) const MAX_KEYS: usize = 100;

/// The most row bytes one reply of [`rows`] holds; it holds one row however large.
pub(crate) const ROWS_REPLY_BYTES: usize = 256 * 1024;

/// `transferBlocked` is the cached durable transfer decision (`hub/transfer_authority.rs`):
/// true while a move away is begun or committed, null until a restored log is read.
pub(super) async fn info(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if params.get("sessionIds").is_some_and(|ids| !ids.is_null()) {
        return rows(hub, conn, params).await;
    }
    let s = hub.resolve_told(session_key(params)?, conn.origin == Origin::Local)?;
    // Never waited for: the next read has it (`hub/usage_view.rs`).
    let later = hub.clone();
    tokio::spawn(async move { later.refresh_usage_stats().await });
    // After a restart the chat logs are read after the ready line; until
    // then the queue, the turn and the status are the session list's. Info
    // waits for this chat's (#22916; read now if the background pass has not
    // reached it, `hub/log_load.rs`), unless a caller that reads only what the
    // session list holds (its id, env, policy, rules, modes) asks with
    // `waitLogs: false`: it answers at once, with `logsLoading`.
    if params.get("waitLogs").and_then(Value::as_bool) != Some(false) {
        hub.session_log(&s).await;
    }
    let mut detail = hub.session_detail(&s);
    if let Some(obj) = detail.as_object_mut() {
        obj.insert("logsLoading".into(), json!(!hub.session_log_loaded(&s)));
        obj.insert("transferBlocked".into(), json!(s.transfer_blocked()));
        obj.insert("ownershipEpoch".into(), json!(s.ownership_epoch()));
    }
    // The session env reaches the unix socket only: no summary or
    // event carries it, so a key added to the allowlist later never
    // reaches another origin by default (session_env.rs).
    if conn.origin == Origin::Local
        && let Some(obj) = detail.as_object_mut()
    {
        obj.insert("sessionEnv".into(), json!(crate::session_env::shown(&s.meta().session_env)));
        // The cmux workspace the chat was recorded for (`workspace_purge.rs`), so the
        // daemon's phone relay can keep an incognito workspace's chats off a phone.
        obj.insert("workspaceId".into(), json!(s.meta().workspace_id));
    }
    // One message carries it whole, its largest fields trimmed if need be: a detail refused
    // as too large is refused again on every read (`hub/reply_fit.rs`).
    crate::hub::reply_fit::fit_reply_object(&mut detail);
    Ok(detail)
}

/// `_acpmux/info` with `sessionIds` and `row: true`: each key's row as `_acpmux/sessions` lists
/// it, made by the same code with the same `withTools` and `usage` (`Hub::rows_by_key`), in the
/// order asked. A key is this daemon's session id, or a peer's (or hub machine's) row key
/// `PEER/ID`, answered from the mirrored row and never sent to the peer. No chat's log is read
/// and no detail is built: a list caller that read the list's keys (agent service v2, row 7b)
/// asks for the rows it prints, [`MAX_KEYS`] a request. The reply is `{rows, missing, rest}`:
/// `missing` the keys that name no row, `rest` the keys past [`ROWS_REPLY_BYTES`] of rows, asked
/// again by the caller.
///
/// Only this machine's socket asks so: a web, device or peer connection keeps the one-chat form
/// its guard scopes (`remote_guard.rs`).
async fn rows(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if conn.origin != Origin::Local {
        return Err(RpcError::invalid_params("sessionIds is read on this machine's socket only"));
    }
    if params.get("sessionId").is_some_and(|id| !id.is_null()) {
        return Err(RpcError::invalid_params("sessionIds and sessionId cannot both be given"));
    }
    if params.get(crate::server::peer_forward::ROW_WILL_DO).and_then(Value::as_bool) != Some(true) {
        return Err(RpcError::invalid_params("sessionIds reads the list's rows: send row: true"));
    }
    let keys: Vec<String> = match params.get("sessionIds") {
        Some(Value::Array(ids)) => ids
            .iter()
            .map(|id| id.as_str().map(str::to_owned))
            .collect::<Option<_>>()
            .ok_or_else(|| RpcError::invalid_params("sessionIds must be strings"))?,
        _ => return Err(RpcError::invalid_params("sessionIds must be an array")),
    };
    if keys.is_empty() || keys.len() > MAX_KEYS {
        return Err(RpcError::invalid_params(format!(
            "sessionIds takes 1 to {MAX_KEYS} keys, not {}",
            keys.len()
        )));
    }
    let tools = match params.get("withTools") {
        None | Some(Value::Null) => false,
        Some(Value::Bool(tools)) => *tools,
        Some(_) => return Err(RpcError::invalid_params("withTools must be a boolean")),
    };
    // One usage read for the request, as `_acpmux/sessions {usage: true}` waits for it.
    if params.get("usage") == Some(&Value::Bool(true)) {
        let read = hub.refresh_usage_stats();
        let _ = tokio::time::timeout(crate::hub::USAGE_READ_WAIT, read).await;
    }
    rows_reply(&keys, hub.rows_by_key(&keys, tools), ROWS_REPLY_BYTES)
}

/// The `{rows, missing, rest}` reply of `keys` whose row texts are `texts` (`None` for a key
/// that names no row): rows in the order asked until `budget` bytes of them, at least one, and
/// every key after the first that would pass it in `rest`. A row text that is not a JSON object
/// is an internal error: a client reads every row as one.
fn rows_reply(
    keys: &[String],
    texts: Vec<Option<Arc<str>>>,
    budget: usize,
) -> Result<Value, RpcError> {
    let mut rows = Vec::new();
    let mut missing = Vec::new();
    let mut rest = Vec::new();
    let mut used = 0_usize;
    for (key, text) in keys.iter().zip(texts) {
        if !rest.is_empty() {
            rest.push(key.clone());
            continue;
        }
        let Some(text) = text else {
            missing.push(key.clone());
            continue;
        };
        if !rows.is_empty() && used.saturating_add(text.len()) > budget {
            rest.push(key.clone());
            continue;
        }
        used = used.saturating_add(text.len());
        match serde_json::from_str::<Value>(&text) {
            Ok(row @ Value::Object(_)) => rows.push(row),
            _ => return Err(RpcError::internal(format!("the list's row for {key} is not a row"))),
        }
    }
    Ok(json!({"rows": rows, "missing": missing, "rest": rest}))
}

#[cfg(test)]
#[path = "info_rows_tests.rs"]
mod tests;
