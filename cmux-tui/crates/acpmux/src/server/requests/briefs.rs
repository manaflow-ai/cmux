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
    let row = brief_for(hub, conn, id)?;
    let idempotency = params
        .get("idempotencyKey")
        .or_else(|| params.get("idempotency_key"))
        .and_then(Value::as_str);
    if idempotency.is_some_and(|key| row.get("lastSteerKey").and_then(Value::as_str) == Some(key)) {
        return Ok(
            json!({"brief":row,"event":crate::hub::dispatch::event("steer", &row),"replayed":true}),
        );
    }
    // A peer daemon's connection reaches a brief this host ran only (`brief_for`): never forwarded.
    if conn.origin != Origin::Peer
        && let Some(host) = row.get("host").and_then(Value::as_str).filter(|host| *host != "local")
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
        p.set_path(&["_meta", "acpmux", "via"], via);
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
    let row = shown(conn, row);
    Ok(json!({"brief":row,"event":crate::hub::dispatch::event("steer", &row)}))
}

/// A peer daemon's connection (paired devices included) never learns this host's peers
/// (`redact::hide_peers_from_peer`). Of the brief ledger it sees what this host ran: a row with a
/// session of this host's (`Hub::brief_ran_here`; not one still being claimed, which may be on
/// its way to a peer), without `suggestedHost`. A row a peer ran names that peer in `host`,
/// `target` and `to`.
fn peer_sees(hub: &Hub, row: &Value) -> bool {
    row.get("sessionId").and_then(Value::as_str).is_some() && hub.brief_ran_here(row)
}

/// `row` as `conn` may see it: without `suggestedHost`, a peer of this host, for a peer daemon's.
fn shown(conn: &Conn, mut row: Value) -> Value {
    if conn.origin == Origin::Peer
        && let Some(obj) = row.as_object_mut()
    {
        obj.remove("suggestedHost");
    }
    row
}

/// Brief `id` for a steer or report from `conn`. A peer daemon's connection gets one answer for a
/// brief a peer ran and for one that does not exist ([`peer_sees`]).
fn brief_for(hub: &Hub, conn: &Conn, id: &str) -> Result<Value, RpcError> {
    hub.briefs
        .get(id)
        .filter(|row| conn.origin != Origin::Peer || peer_sees(hub, row))
        .map(|row| shown(conn, row))
        .ok_or_else(|| RpcError::not_found(format!("no brief {id:?}")))
}

/// How long the peers together may take to list their briefs (they are asked at once); one
/// that has not answered by then is left out and named in `peersFailed`.
const PEERS_BUDGET: std::time::Duration = std::time::Duration::from_secs(10);

pub(super) async fn list(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let status = params.get("status").and_then(Value::as_str);
    let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(100) as usize;
    let wanted = |row: &Value| {
        status.is_none_or(|want| row.get("status").and_then(Value::as_str) == Some(want))
    };
    // A peer daemon's connection is listed the briefs this host ran ([`peer_sees`]), newest first
    // as below, and no peer of this host is asked for theirs.
    if conn.origin == Origin::Peer {
        let rows: Vec<Value> = hub
            .briefs
            .matching(wanted)
            .into_iter()
            .rev()
            .filter(|row| peer_sees(hub, row))
            .take(limit.clamp(1, 500))
            .map(|row| shown(conn, row))
            .collect();
        return Ok(json!({ "briefs": rows }));
    }
    let mut rows = hub.briefs.list(status, limit);
    // The peers at once, under one deadline: one by one, each with the request budget (600 s),
    // a stalled peer held the list for ten minutes. A peer left out is named, with why.
    let deadline = tokio::time::Instant::now() + PEERS_BUDGET;
    let peers = hub.connected_peers();
    let replies = futures::future::join_all(peers.iter().map(|peer| {
        tokio::time::timeout_at(deadline, peer.request(method::MUX_BRIEFS, json!({"limit": 500})))
    }))
    .await;
    let mut failed = Vec::new();
    for (peer, reply) in peers.iter().zip(replies) {
        let remote = match reply {
            Ok(Ok(remote)) => remote,
            Ok(Err(e)) => {
                failed.push(json!({"peer": peer.name, "error": e.message}));
                continue;
            }
            Err(_) => {
                let error = format!("no answer within {}s", PEERS_BUDGET.as_secs());
                failed.push(json!({"peer": peer.name, "error": error}));
                continue;
            }
        };
        for row in remote.get("briefs").and_then(Value::as_array).into_iter().flatten() {
            let Some(id) = row.get("briefId").and_then(Value::as_str) else { continue };
            if let Some(local) = rows
                .iter_mut()
                .find(|candidate| candidate.get("briefId").and_then(Value::as_str) == Some(id))
            {
                *local = row.clone();
            } else if wanted(row) {
                rows.push(row.clone());
            }
            hub.briefs.put(row.clone());
        }
    }
    if status.is_some() {
        rows.retain(wanted);
    }
    let mut reply =
        json!({"briefs":rows.into_iter().take(limit.clamp(1, 500)).collect::<Vec<_>>() });
    if !failed.is_empty() {
        tracing::warn!(peers = ?failed, "briefs left out the peers that did not answer");
        reply.set("peersFailed", Value::Array(failed));
    }
    Ok(reply)
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
    let row = brief_for(hub, conn, id)?;
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
    // A peer daemon's connection reaches a brief this host ran only (`brief_for`): never forwarded.
    if conn.origin != Origin::Peer
        && let Some(host) = row.get("host").and_then(Value::as_str).filter(|host| *host != "local")
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
    let row = shown(conn, row);
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
        let uuid = uuid::Uuid::new_v4().simple().to_string();
        let id = format!("t-{}", uuid.get(..8).unwrap_or(&uuid));
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
        record.set("fromSession", json!(caller));
    }
    if let Some(key) = idempotency {
        record.set("idempotencyKey", json!(key));
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
        // A peer daemon's connection: the briefs this host ran ([`peer_sees`]).
        .filter(|row| conn.origin != Origin::Peer || peer_sees(hub, row))
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
