//! Explicit completion and wake intent. Kept local, like the goal controls.
use super::*;

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    method: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if method != crate::hub::finished::METHOD {
        return None;
    }
    Some(handle(hub, conn, params).await)
}

async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if str_param(params, "op").is_some_and(|op| op.starts_with("fleet_")) {
        if conn.origin != Origin::Peer || !conn.auth.peer_daemon() {
            return Err(RpcError::invalid_params(
                "fleet admission requires an authenticated peer daemon",
            ));
        }
        return hub.fleet_authority(params).await;
    }
    // As for a terminal's send, this is a local declaration, not permission-approval proof.
    // Old CLIs, unproven agent tokens and generic socket programs do not count as terminals.
    let terminal = conn.origin == Origin::Local
        && !conn.is_trigger()
        && conn.caller().is_none()
        && conn.unproven_caller.get().is_none()
        && matches!(conn.declared(), Some(crate::cli_caller::Declared::Terminal));
    let person = conn.is_person() || terminal;
    if conn.origin.web_class() || (!person && conn.caller().is_none()) {
        return Err(RpcError::invalid_params(
            "session lifecycle requires a local caller or current terminal CLI",
        ));
    }
    if let Some(op @ ("pause" | "resume")) = str_param(params, "op") {
        let reason = str_param(params, "reason").unwrap_or("");
        return hub
            .fleet_call(
                if op == "pause" { "fleet_pause" } else { "fleet_resume" },
                json!({"reason": reason}),
            )
            .await;
    }
    if str_param(params, "op") == Some("bind") {
        let peer = str_param(params, "peer")
            .ok_or_else(|| RpcError::invalid_params("peer is required"))?;
        return hub.bind_fleet(peer).await;
    }
    if str_param(params, "op") == Some("status") {
        return hub.fleet_call("fleet_status", json!({})).await;
    }
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    match str_param(params, "op") {
        Some("finish") => {
            if !person && conn.caller() != Some(session.id.as_str()) {
                return Err(RpcError::invalid_params("an agent may finish only its own session"));
            }
            let handoff = str_param(params, "handoff")
                .filter(|s| !s.trim().is_empty())
                .ok_or_else(|| RpcError::invalid_params("finish requires a handoff"))?;
            let reply = hub.finish_session(&session, handoff)?;
            let _retirement = hub.retire_finished(&session);
            Ok(reply)
        }
        Some("wake") => {
            let reason = str_param(params, "reason")
                .ok_or_else(|| RpcError::invalid_params("wake requires a reason"))?;
            hub.wake_finished(&session, reason)
        }
        Some("fresh") => {
            let name = str_param(params, "name")
                .filter(|s| !s.trim().is_empty())
                .ok_or_else(|| RpcError::invalid_params("fresh requires a name"))?;
            hub.fresh_from_finished(&session, name, conn.caller().map(str::to_owned)).await
        }
        _ => Err(RpcError::invalid_params("op must be finish, wake, fresh, pause or resume")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{Config, StoreMode};
    use tokio::sync::mpsc;

    async fn request(
        hub: &Arc<Hub>,
        origin: Origin,
        caller: Option<&str>,
        op: &str,
        target: &str,
    ) -> Value {
        let (input, incoming) = mpsc::channel(32);
        let (output, mut outgoing) = mpsc::channel(32);
        tokio::spawn(serve_connection_with(hub.clone(), incoming, output, origin));
        let mut hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
        if caller == Some("terminal") {
            hello["_meta"] = json!({"acpmux": {"callerProtocol": 1, "callerKind": "terminal"}});
        } else if let Some(caller) = caller {
            hello["_meta"] = json!({"acpmux": {"callerSession": {
                "sessionId": caller, "token": crate::hub::person::caller_token(caller)
            }}});
        }
        input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
        let next = async |id, output: &mut mpsc::Receiver<String>| {
            tokio::time::timeout(std::time::Duration::from_secs(10), async {
                loop {
                    let reply: Value = serde_json::from_str(&output.recv().await.unwrap()).unwrap();
                    if reply["id"] == id {
                        return reply;
                    }
                }
            })
            .await
            .unwrap()
        };
        let _hello = next(1, &mut outgoing).await;
        let (method, params) = if op == "send" {
            (
                method::MUX_SEND_QUEUE,
                json!({"request": {"sessionId": target,
                "prompt": [{"type": "text", "text": "accidental message"}]}}),
            )
        } else {
            (
                crate::hub::finished::METHOD,
                json!({"op": op, "sessionId": target,
                "handoff": "done", "reason": "explicit follow-up"}),
            )
        };
        input.send(Message::request(2, method, params).to_line()).await.unwrap();
        next(2, &mut outgoing).await
    }

    #[tokio::test]
    async fn finished_lifecycle_requires_local_proof_and_finish_ownership() {
        let mut config = Config::default();
        config.store.mode = StoreMode::Memory;
        let store = crate::store::open(&config.store, std::path::Path::new("/unused")).unwrap();
        for id in ["self", "other"] {
            let meta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "fake",
                "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
            }))
            .unwrap();
            store.save(&meta).unwrap();
        }
        let hub = Hub::new(config, store);
        for (origin, caller, target) in [
            (Origin::Local, None, "self"),
            (Origin::Peer, Some("self"), "self"),
            (Origin::Web, Some("self"), "self"),
            (Origin::Local, Some("self"), "other"),
        ] {
            let reply = request(&hub, origin, caller, "finish", target).await;
            assert!(reply.get("error").is_some(), "{reply}");
            assert!(hub.resolve(target).unwrap().meta().finished.is_none());
        }
        let reply = request(&hub, Origin::Local, Some("self"), "finish", "self").await;
        assert!(reply.get("error").is_none(), "{reply}");
        assert!(hub.resolve("self").unwrap().meta().finished.is_some());
        let refused = request(&hub, Origin::Local, Some("other"), "send", "self").await;
        assert_eq!(refused["error"]["data"]["reason"], "session.finished", "{refused}");
        assert!(refused["error"]["data"]["next"].as_str().unwrap().contains("fresh"));
        let reply = request(&hub, Origin::Local, Some("self"), "wake", "self").await;
        assert!(reply.get("error").is_none(), "{reply}");
        assert!(hub.resolve("self").unwrap().meta().finished.is_none());
        let reply = request(&hub, Origin::Local, Some("terminal"), "finish", "other").await;
        assert!(reply.get("error").is_none(), "{reply}");
        let reply = request(&hub, Origin::Local, Some("terminal"), "wake", "other").await;
        assert!(reply.get("error").is_none(), "{reply}");
    }
}
