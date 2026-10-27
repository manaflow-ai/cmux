//! Briefs and tasks (`hub/dispatch.rs`, `hub/tasks.rs`): steer, list and report a brief, give
//! a session on this daemon a task, and list the tasks a chat gave. `dispatch` is in
//! `requests.rs`.

use super::*;
use crate::hub::tasks;

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
    // A task's card not yet delivered is not replayed: the retry sends it again (below).
    if key.is_some_and(|key| row.get("lastReportKey").and_then(Value::as_str) == Some(key))
        && row["result"].get("undelivered").is_none()
    {
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
    let status = params.get("status").and_then(Value::as_str).unwrap_or("reported");
    let ended = tasks::RESULT_STATES.contains(&status);
    if !ended && !["reported", "merged", "running"].contains(&status) {
        return Err(RpcError::invalid_params(
            "status must be running, reported, merged, done, blocked or failed",
        ));
    }
    let by = conn.caller().map(|id| hub.session_name(id)).unwrap_or_else(|| conn.label());
    let result = if ended {
        task_reporter(conn, id, &row)?;
        Some(tasks::result(&params, status, &by)?)
    } else {
        None
    };
    let summary = match &result {
        Some(result) => result["summary"].clone(),
        None => params
            .get("summary")
            .or_else(|| params.get("details"))
            .cloned()
            .ok_or_else(|| RpcError::invalid_params("summary is required"))?,
    };
    // Checked under the ledger's lock: of two calls that say the same, one sends the card. The
    // same call again after its card was not delivered sends it again.
    let mut replayed = false;
    let row = hub
        .briefs
        .update(id, |r| {
            if let Some(result) = &result
                && r["status"] == status
                && tasks::same_result(&r["result"], result)
                && r["result"].get("undelivered").is_none()
            {
                replayed = true;
                return;
            }
            r["status"] = json!(status);
            r["report"] = summary.clone();
            r["reportedAt"] = json!(crate::store::now_ms());
            if let Some(key) = key {
                r["lastReportKey"] = json!(key);
            }
            r["reportedBy"] = json!(by);
            if let Some(result) = &result {
                r["result"] = result.clone();
            }
        })
        .ok_or_else(|| RpcError::not_found(format!("no brief {id:?}")))?;
    let event = crate::hub::dispatch::event("report", &row);
    if replayed {
        return Ok(json!({"brief": row, "event": event, "replayed": true}));
    }
    if result.is_some() {
        hub.send_task_result(&row, conn.caller());
    }
    Ok(json!({"brief": row, "event": event}))
}

/// Refused unless the caller may end task `id` (`row`): its own session, the chat that gave it,
/// or a client that runs in no session (the person at a shell).
fn task_reporter(conn: &Conn, id: &str, row: &Value) -> Result<(), RpcError> {
    let not_yours = |message: String| {
        Err(RpcError::invalid_params(message).with_data(json!({"reason": "task.not_yours"})))
    };
    let Some(caller) = conn.caller() else {
        // The person on this machine (its socket, or the app's pane) may end it; a Web or peer
        // connection proves no session, and its result would read as the lane's.
        if conn.origin.web_class() {
            return not_yours(format!("task {id} is ended on this machine only"));
        }
        return Ok(());
    };
    if [&row["sessionId"], &row["fromSession"]].iter().any(|owner| owner.as_str() == Some(caller)) {
        return Ok(());
    }
    not_yours(format!(
        "task {id} is not this session's: only its own session or the chat that gave it ends it"
    ))
}

/// `_acpmux/task_new`: a brief for session `sessionId` on this daemon, sent to it as the caller's
/// message with the task id first (`hub/tasks.rs`). Returns the task's row at once; the lane's
/// turn runs on.
pub(super) async fn task_new(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    if conn.origin.web_class() {
        return Err(RpcError::invalid_params("a task is given on this machine's daemon only")
            .with_data(json!({"reason": "task.remote_refused"})));
    }
    if hub.briefs.load_failed() {
        return Err(RpcError::internal(
            "brief ledger is unreadable; repair $ACPMUX_HOME/briefs.json before giving a task",
        ));
    }
    let key = session_key(&params)?;
    let target = hub.resolve(key).map_err(|_| {
        RpcError::not_found(format!(
            "no session {key:?} on this daemon; a task for a peer's session is not supported yet"
        ))
    })?;
    let text =
        |k: &str| params.get(k).and_then(Value::as_str).map(str::trim).filter(|t| !t.is_empty());
    let title = text("title")
        .filter(|t| !t.contains('\n'))
        .ok_or_else(|| RpcError::invalid_params("a task has a one-line title"))?;
    let idempotency = text("idempotencyKey");
    let id = loop {
        let id = format!("t-{}", &uuid::Uuid::new_v4().simple().to_string()[..8]);
        if hub.briefs.get(&id).is_none() {
            break id;
        }
    };
    let caller = conn.caller();
    let declared = crate::hub::declared_sender(&params)?;
    if let Some(existing) = hub.briefs.claim(&id, idempotency) {
        return Ok(json!({"task": task_row(hub, &existing), "replayed": true}));
    }
    let from = caller
        .map(|id| hub.session_name(id))
        .or_else(|| declared.clone())
        .unwrap_or_else(|| "the person".to_owned());
    let meta = target.meta();
    let mut record = json!({
        "briefId": id, "kind": "task", "title": title, "brief": text("brief").unwrap_or(title),
        "from": from, "to": meta.name, "target": target.id, "host": "local",
        "stopCondition": text("stopCondition").unwrap_or("the title is done"),
        "status": "running", "sessionId": target.id, "createdAt": crate::store::now_ms(),
        "harness": meta.harness, "model": meta.model_request,
    });
    if let Some(caller) = caller {
        record["fromSession"] = json!(caller);
    }
    if let Some(key) = idempotency {
        record["idempotencyKey"] = json!(key);
    }
    let row = hub.briefs.put(record);
    // The giver's message, as `acpmux send` from it would be (`requests.rs` session/prompt).
    let provenance = match caller {
        Some(caller) if caller != target.id => {
            Some(crate::prompt_provenance::session_message(caller, &from, &target.id))
        }
        Some(_) => None,
        None => declared.map(|name| crate::prompt_provenance::named_sender(&name, &target.id)),
    };
    let opts = crate::hub::PromptOptions {
        prompt_id: Some(format!("task-{id}")),
        provenance,
        ..Default::default()
    };
    let blocks = vec![json!({"type": "text", "text": tasks::brief_text(&row)})];
    let (task_hub, client) = (hub.clone(), conn.label());
    tokio::spawn(async move {
        if let Err(error) = task_hub.prompt_with(&target, blocks, &client, true, opts).await {
            task_hub.briefs.update(&id, |r| r["error"] = json!(error.message));
        }
    });
    Ok(json!({"task": task_row(hub, &row)}))
}

/// `_acpmux/tasks`: the tasks a chat gave (`from`, default the caller's session; `all` for every
/// task here), open ones first, then newest, each with its lane's state now.
pub(super) async fn tasks(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let from = match params.get("from").and_then(Value::as_str) {
        Some(key) => Some(hub.resolve(key)?.id.clone()),
        None if params["all"] == true => None,
        None => conn.caller().map(str::to_owned),
    };
    let open_only = params["open"] == true;
    let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(100).clamp(1, 500) as usize;
    let mut rows: Vec<Value> = hub
        .briefs
        .list(None, 500)
        .into_iter()
        .filter(|row| from.is_none() || row["fromSession"].as_str() == from.as_deref())
        .filter(|row| !open_only || tasks::open(row))
        .collect();
    rows.sort_by_key(|row| {
        let first = (!tasks::orphaned(row), !tasks::open(row));
        (first, std::cmp::Reverse(row["createdAt"].as_u64().unwrap_or(0)))
    });
    let rows: Vec<Value> = rows.iter().take(limit).map(|row| task_row(hub, row)).collect();
    Ok(json!({"tasks": rows}))
}

/// A task as `acpmux task ls` shows it: its brief, its result, and its lane's state now (null
/// when its session closed or is gone).
fn task_row(hub: &Hub, row: &Value) -> Value {
    let session = row["sessionId"].as_str().and_then(|id| hub.resolve(id).ok());
    let summary = session.as_ref().map(|s| hub.session_summary(s));
    let lane = summary.as_ref().map_or(Value::Null, crate::hub::views::lane);
    let status = summary.as_ref().map_or(json!("gone"), |s| s["status"].clone());
    json!({
        "taskId": row["briefId"], "title": row["title"], "from": row["from"],
        "fromSession": row["fromSession"], "to": row["to"], "sessionId": row["sessionId"],
        "host": row["host"], "status": row["status"], "createdAt": row["createdAt"],
        "reportedAt": row["reportedAt"], "result": row["result"], "error": row["error"],
        "lane": lane, "sessionStatus": status,
    })
}
