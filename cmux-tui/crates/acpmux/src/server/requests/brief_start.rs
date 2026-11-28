//! A local brief's new chat is made after `dispatch_brief` has returned: its frame, with the
//! brief's parsing and placement locals, is not under the `session/new` that makes the chat (a
//! default Tokio worker's 2 MiB, `tests/request_stack.rs`).

use super::*;

/// What the brief's reply needs once its chat exists.
pub(super) struct Pending {
    pub(super) id: String,
    pub(super) title: String,
    pub(super) brief: String,
    pub(super) from: String,
    pub(super) to: String,
    pub(super) selected: String,
    pub(super) stop: String,
    pub(super) forwarded: bool,
    pub(super) from_peer: bool,
    pub(super) idempotency: Option<String>,
    pub(super) params: Value,
}

pub(super) async fn run(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let mut start = None;
    let answer = heap(|| dispatch_brief(hub, conn, params, &mut start)).await?;
    let Some((pending, new_params)) = start else { return Ok(answer) };
    let created =
        Box::pin(dispatch_request(hub, conn, method::SESSION_NEW, new_params, None)).await;
    heap(|| finish(hub, conn, pending, created)).await
}

async fn finish(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    pending: Pending,
    created: Result<Value, RpcError>,
) -> Result<Value, RpcError> {
    let Pending {
        id,
        title,
        brief,
        from,
        to,
        selected,
        stop,
        forwarded,
        from_peer,
        idempotency,
        params,
    } = pending;
    let created = match created {
        Ok(created) => created,
        Err(error) => {
            hub.briefs.release(&id);
            return Err(error);
        }
    };
    let sid = created
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::internal("dispatch session/new returned no sessionId"))?
        .to_owned();
    let session = hub.resolve(&sid)?;
    let mut record = json!({"briefId":id,"title":title,"brief":brief,"from":from,"to":to,"target":selected,"host":match params.get("host").and_then(Value::as_str) { None => json!("local"), Some("auto") if !forwarded => json!("local"), Some(h) => json!(h) },"stopCondition":stop,"status":"running","sessionId":sid,"harness":session.meta().harness,"model":session.meta().model_request});
    if let Some(key) = idempotency {
        record.set("idempotencyKey", json!(key));
    }
    if let Some(caller) = conn.caller() {
        record.set("fromSession", json!(caller)); // its result card's chat (`hub/tasks.rs`)
    }
    let row = hub.briefs.put(record);
    let mut prompt = json!({"sessionId":session.id,"text":row.get("brief"),"_meta":{"acpmux":{"briefId":id,"fromAgent":row.get("from")}}});
    if let Some(via) = params.pointer("/_meta/acpmux/via").cloned() {
        prompt.set_path(&["_meta", "acpmux", "via"], via);
    }
    let task_hub = hub.clone();
    let task_conn = conn.clone();
    let task_id = id.clone();
    let task_session = session.clone();
    let task_via = params.pointer("/_meta/acpmux/via").cloned();
    let task_agent = row.get("from").and_then(Value::as_str).map(str::to_owned);
    let task_device = crate::server::remote_guard::sending_device(conn, &prompt);
    tokio::spawn(async move {
        let mut blocks =
            vec![json!({"type":"text","text":prompt.get("text").cloned().unwrap_or(Value::Null)})];
        let web = crate::server::trust_gate::for_web(task_conn.origin, &prompt);
        if let Err(error) = task_hub
            .prompt_with(
                &task_session,
                std::mem::take(&mut blocks),
                &task_conn.label(),
                false,
                crate::hub::PromptOptions {
                    control: crate::server::remote_guard::control_of(
                        task_conn.origin,
                        task_conn.auth,
                        &prompt,
                    ),
                    trust_gate: task_via.is_some() || web,
                    agent: task_agent,
                    full_access_device: task_device,
                    ..Default::default()
                },
            )
            .await
        {
            let _ = task_hub.briefs.update(&task_id, |r| {
                r["status"] = json!("reported");
                r["error"] = json!(error.message);
            });
        }
    });
    let pressure = hub
        .status()
        .await
        .pointer("/host_pressure/warning")
        .and_then(Value::as_str)
        .map(str::to_owned);
    // Another host only when it has room: an overloaded pick is no better a place (`placement.rs`).
    // A peer daemon's connection hears that this host is over its budget, and of no other host.
    let suggestion = match &pressure {
        Some(_) if !from_peer => {
            let v = crate::server::place::pick(hub, crate::server::place::brief_work(&brief)).await;
            let flag = |k: &str| v.get(k).and_then(Value::as_bool) == Some(true);
            (!flag("overloaded") && !flag("local"))
                .then(|| v.get("pick").and_then(Value::as_str).map(str::to_owned))
                .flatten()
        }
        _ => None,
    }
    .filter(|host| row.get("host").and_then(Value::as_str) != Some(host));
    let row = hub
        .briefs
        .update(&id, |r| {
            if let Some(warning) = &pressure {
                r["warning"] = json!(warning);
            }
            if let Some(host) = &suggestion {
                r["suggestedHost"] = json!(host);
            }
        })
        .unwrap_or(row);
    Ok(
        json!({"brief":row,"event":crate::hub::dispatch::event("dispatch", &row),"status":"running","warning":pressure,"suggestedHost":suggestion}),
    )
}
