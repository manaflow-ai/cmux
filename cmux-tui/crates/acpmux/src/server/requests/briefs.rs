//! Briefs (`hub/dispatch.rs`): steer, list and report one. `dispatch` is in `requests.rs`.

use super::*;

pub(super) async fn steer(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let id = params
        .get("briefId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("briefId is required"))?;
    let row = hub.briefs.get(id).ok_or_else(|| RpcError::not_found(format!("no brief {id:?}")))?;
    let idempotency = params
        .get("idempotencyKey")
        .or_else(|| params.get("idempotency_key"))
        .and_then(Value::as_str);
    if idempotency.is_some_and(|key| row.get("lastSteerKey").and_then(Value::as_str) == Some(key)) {
        return Ok(
            json!({"brief":row,"event":crate::hub::dispatch::event("steer", &row),"replayed":true}),
        );
    }
    if let Some(host) = row.get("host").and_then(Value::as_str).filter(|host| *host != "local")
        && let Some(peer) = hub.peer_by_name(host)
    {
        let mut forwarded = params.clone();
        crate::server::remote_guard::mark_forwarded(
            conn.origin,
            conn.auth,
            &params,
            &mut forwarded,
        );
        let result = peer.request(method::MUX_STEER, forwarded).await.map_err(|e| {
            RpcError::internal(format!(
                "steer to {host} failed: {e}; recovery: reconnect the peer and retry"
            ))
        })?;
        if let Some(remote) = result.get("brief").cloned() {
            hub.briefs.put(remote);
        }
        return Ok(result);
    }
    let sid = row
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::not_found("brief has no session"))?;
    let text = params
        .get("text")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("steer text is required"))?;
    let mut p = json!({"sessionId":sid,"text":text,"steer":true,"_meta":{"acpmux":{"briefId":id,"steer":true}}});
    if let Some(via) = params.pointer("/_meta/acpmux/via").cloned() {
        p["_meta"]["acpmux"]["via"] = via;
    }
    Box::pin(super::handle_request(hub, conn, method::SESSION_PROMPT, p)).await?;
    let row = hub
        .briefs
        .update(id, |r| {
            r["status"] = json!("running");
            if let Some(key) = idempotency {
                r["lastSteerKey"] = json!(key);
            }
        })
        .unwrap_or(row);
    Ok(json!({"brief":row,"event":crate::hub::dispatch::event("steer", &row)}))
}

pub(super) async fn list(hub: &Arc<Hub>, params: Value) -> Result<Value, RpcError> {
    let status = params.get("status").and_then(Value::as_str);
    let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
    let mut rows = hub.briefs.list(status, limit);
    for peer in hub.connected_peers() {
        let Ok(remote) = peer.request(method::MUX_BRIEFS, json!({"limit": 500})).await else {
            continue;
        };
        for row in remote.get("briefs").and_then(Value::as_array).into_iter().flatten() {
            let Some(id) = row.get("briefId").and_then(Value::as_str) else { continue };
            if let Some(local) = rows
                .iter_mut()
                .find(|candidate| candidate.get("briefId").and_then(Value::as_str) == Some(id))
            {
                *local = row.clone();
            } else if status
                .is_none_or(|want| row.get("status").and_then(Value::as_str) == Some(want))
            {
                rows.push(row.clone());
            }
            hub.briefs.put(row.clone());
        }
    }
    if let Some(want) = status {
        rows.retain(|row| row.get("status").and_then(Value::as_str) == Some(want));
    }
    Ok(json!({"briefs":rows.into_iter().take(limit.clamp(1, 500)).collect::<Vec<_>>() }))
}

pub(super) async fn report(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let id = params
        .get("briefId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("briefId is required"))?;
    let row = hub.briefs.get(id).ok_or_else(|| RpcError::not_found(format!("no brief {id:?}")))?;
    let key = params
        .get("idempotencyKey")
        .or_else(|| params.get("idempotency_key"))
        .and_then(Value::as_str);
    if key.is_some_and(|key| row.get("lastReportKey").and_then(Value::as_str) == Some(key)) {
        return Ok(
            json!({"brief":row,"event":crate::hub::dispatch::event("report", &row),"replayed":true}),
        );
    }
    if let Some(host) = row.get("host").and_then(Value::as_str).filter(|host| *host != "local")
        && let Some(peer) = hub.peer_by_name(host)
    {
        let mut forwarded = params.clone();
        crate::server::remote_guard::mark_forwarded(
            conn.origin,
            conn.auth,
            &params,
            &mut forwarded,
        );
        let result = peer.request(method::MUX_REPORT, forwarded).await.map_err(|e| {
            RpcError::internal(format!(
                "report to {host} failed: {e}; recovery: reconnect the peer and retry"
            ))
        })?;
        if let Some(remote) = result.get("brief").cloned() {
            hub.briefs.put(remote);
        }
        return Ok(result);
    }
    let summary = params
        .get("summary")
        .or_else(|| params.get("details"))
        .cloned()
        .ok_or_else(|| RpcError::invalid_params("summary is required"))?;
    let status = params.get("status").and_then(Value::as_str).unwrap_or("reported");
    if !["reported", "merged", "running"].contains(&status) {
        return Err(RpcError::invalid_params("status must be running, reported or merged"));
    }
    let row = hub
        .briefs
        .update(id, |r| {
            r["status"] = json!(status);
            r["report"] = summary.clone();
            r["reportedAt"] = json!(crate::store::now_ms());
            if let Some(key) = key {
                r["lastReportKey"] = json!(key);
            }
            r["reportedBy"] =
                json!(conn.caller().map(|id| hub.session_name(id)).unwrap_or_else(|| conn.label()));
        })
        .ok_or_else(|| RpcError::not_found(format!("no brief {id:?}")))?;
    Ok(json!({"brief":row,"event":crate::hub::dispatch::event("report", &row)}))
}
