//! Requests for a session that lives on a peer daemon: forwarded whole,
//! with the folder-trust gate's peer check (`trust_gate.rs`). Part of the
//! request handler (`requests.rs`).

use super::*;

/// Methods that name no session, or that this daemon answers itself even
/// for a peer's session.
const SESSION_SCOPED_EXCLUDED: &[&str] = &[
    method::INITIALIZE,
    method::AUTHENTICATE,
    method::SESSION_NEW,
    method::SESSION_LIST,
    method::MUX_STATUS,
    method::MUX_SESSIONS,
    method::MUX_WEB_MODES,
    method::MUX_HARNESSES,
    method::MUX_RELOAD_CONFIG,
    method::MUX_WATCH,
    method::MUX_WARM,
    method::MUX_PREWARM,
    method::MUX_IMPORT,
    method::MUX_SHUTDOWN,
    method::MUX_HANDOFF_PREPARE,
    method::MUX_HANDOFF_GET,
    method::MUX_HANDOFF_DRAFT,
    method::MUX_HANDOFF_START,
    method::MUX_HANDOFF_DISCARD,
    "_acpmux/peers",
    "_acpmux/models",
    crate::catalog::RPC_GET,
    crate::catalog::RPC_REFRESH,
    "_acpmux/peer_add",
    "_acpmux/peer_remove",
    "_acpmux/peer_reconnect",
];

/// The reply when `m` is for a peer's session (forwarded there), else None
/// (this daemon handles it).
pub(super) async fn forward(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    forward_inner(hub, conn, m, params).await.transpose()
}

async fn forward_inner(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Option<Value>, RpcError> {
    // Trust answers for a remote session belong to the daemon that owns it.
    if matches!(m, method::ACP_TRUST_GET | method::ACP_TRUST_SET)
        && let Ok(key) = session_key(params)
        && hub.resolve(key).is_err()
        && let Some((peer, id, _)) = hub.resolve_remote(key)
    {
        if super::trust_gate::gated(conn.origin, params) && !peer.supports_trust_gate() {
            return Err(super::trust_gate::peer_unsupported(&peer.name));
        }
        let mut forwarded = params.clone();
        if let Some(object) = forwarded.as_object_mut() {
            object.insert("sessionId".into(), Value::String(id));
        }
        super::remote_guard::mark_forwarded(conn.origin, params, &mut forwarded);
        let mut result = peer.request(m, forwarded).await?;
        if let Some(object) = result.as_object_mut() {
            object.insert("peer".into(), Value::String(peer.name.clone()));
        }
        return Ok(Some(result));
    }
    // A session that lives on a peer: forward the whole request there.
    if !SESSION_SCOPED_EXCLUDED.contains(&m)
        && let Ok(key) = session_key(params)
        && hub.resolve(key).is_err()
        && let Some((peer, id, _)) = hub.resolve_remote(key)
    {
        if super::trust_gate::gated(conn.origin, params) && !peer.supports_trust_gate() {
            return Err(super::trust_gate::peer_unsupported(&peer.name));
        }
        let mut p = if params.is_null() { json!({}) } else { params.clone() };
        if let Some(obj) = p.as_object_mut() {
            obj.remove("session");
            obj.remove("name");
            obj.insert("sessionId".into(), Value::String(id.clone()));
        }
        super::remote_guard::mark_forwarded(conn.origin, params, &mut p);
        if matches!(
            m,
            method::MUX_ATTACH
                | method::SESSION_PROMPT
                | method::SESSION_LOAD
                | method::SESSION_RESUME
                | method::SESSION_FORK
        ) {
            if m == method::MUX_ATTACH {
                let filter = crate::hub::EventFilter::parse(params.get("kinds"))?;
                let event_stream =
                    params.get("eventStream").and_then(Value::as_bool).unwrap_or(false);
                conn.subscribe_with(&id, SubOpts { event_stream, filter });
            } else {
                super::requests::attach(hub, conn, &id);
            }
            if peer.mark_attached(&id) && m != method::MUX_ATTACH {
                let _ =
                    peer.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await;
            }
        }
        let mut result = peer.request(m, p).await.map_err(|e| {
                        if e.message.contains("Method not found") {
                            RpcError::internal(format!("{}; peer {} runs acpmux build {} (this daemon: {}); run `acpmux host update {}`", e.message, peer.name, peer.remote_build().unwrap_or_else(|| "unknown".into()), crate::hub::BUILD, peer.name))
                        } else {
                            e
                        }
                    })?;
        if m == method::SESSION_FORK
            && let Some(new_id) = result.get("sessionId").and_then(Value::as_str)
        {
            super::requests::attach(hub, conn, new_id);
            peer.mark_attached(new_id);
        }
        if m == method::MUX_KILL && params.get("purge").and_then(Value::as_bool).unwrap_or(false) {
            hub.forget_remote(&id);
        }
        if let Some(obj) = result.as_object_mut() {
            obj.insert("peer".into(), Value::String(peer.name.clone()));
        }
        return Ok(Some(result));
    }
    Ok(None)
}
