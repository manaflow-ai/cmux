//! Requests for a session that lives on a peer daemon: forwarded whole,
//! with the folder-trust gate's peer check (`trust_gate.rs`). Part of the
//! request handler (`requests.rs`).

use super::*;

/// Methods that name no session, or that this daemon answers itself even
/// for a peer's session.
const SESSION_SCOPED_EXCLUDED: &[&str] = &[
    method::INITIALIZE,
    // The app pane's reply in place is checked against this daemon's chats (`app_reply.rs`).
    method::MUX_APP_REPLY,
    method::AUTHENTICATE,
    method::SESSION_NEW,
    method::SESSION_LIST,
    method::MUX_STATUS,
    method::MUX_SESSIONS,
    method::MUX_WEB_MODES,
    method::MUX_WEB_TOKEN_ROTATE,
    method::MUX_HARNESSES,
    method::MUX_COMPLETE,
    method::MUX_RELOAD_CONFIG,
    method::MUX_WATCH,
    method::MUX_HARNESS_INVENTORY_WATCH,
    method::MUX_HARNESS_INVENTORY_REFRESH,
    method::MUX_HARNESS_UPDATE_PLAN,
    method::MUX_HARNESS_UPDATE_PREPARE,
    method::MUX_WARM,
    method::MUX_PREWARM,
    method::MUX_START_MODE,
    method::MUX_IMPORT,
    method::MUX_SHUTDOWN,
    // Briefs are daemon-scoped and dispatch selects its peer explicitly.
    method::MUX_DISPATCH,
    method::MUX_STEER,
    method::MUX_BRIEFS,
    method::MUX_REPORT,
    // A task is this daemon's brief for one of its own sessions (`hub/tasks.rs`).
    method::MUX_TASK_NEW,
    method::MUX_TASKS,
    // Resolving reads this daemon's own and mirrored session lists (`hub/locate.rs`).
    method::MUX_RESOLVE,
    // An agent message is taken back on this daemon only (`hub/withdraw.rs`).
    method::MUX_PROMPT_WITHDRAW,
    // A message to deliver is this daemon's (`outbox.rs`), whatever session it names.
    method::MUX_SEND_QUEUE,
    method::MUX_SEND_STATUS,
    // Agent pairs are this daemon's own (`hub/agent_pairs.rs`).
    method::MUX_AGENT_PAIR_RESUME,
    method::MUX_HANDOFF_PREPARE,
    method::MUX_HANDOFF_GET,
    method::MUX_HANDOFF_DRAFT,
    method::MUX_HANDOFF_START,
    method::MUX_HANDOFF_DISCARD,
    "_acpmux/peers",
    "_acpmux/peer_status",
    // Names a peer machine, never a session (`vm_host.rs`).
    "_acpmux/vm_host",
    "_acpmux/host_health",
    "_acpmux/place",
    "_acpmux/models",
    crate::catalog::RPC_GET,
    crate::catalog::RPC_REFRESH,
    "_acpmux/peer_add",
    "_acpmux/peer_lease",
    "_acpmux/peer_remove",
    "_acpmux/peer_reconnect",
    // This daemon's own copy of a peer session's events (`hub/peer_snapshot.rs`),
    // answered here while the peer is down too.
    "_acpmux/peer_snapshot",
];

/// The reply when `m` is for a peer's session (forwarded there), else None
/// (this daemon handles it).
/// `_meta.acpmux.fromAgent` for a forwarded `session/prompt` with no sender of its own, from the
/// session this connection proved it runs in: the peer sees neither that session nor the caller
/// proof (`mark_forwarded` drops the provenance), so without it the peer records the agent's
/// report as the person's (claude-sr2, 2026-10-24: every remote lane's report a plain bubble), and
/// a keyed prompt could replace another sender's (`hub/supersede.rs`). The person names no one.
fn name_sender(hub: &Arc<Hub>, conn: &Arc<Conn>, p: &mut Value) {
    if conn.is_person() {
        return;
    }
    let Some(caller) = conn.caller() else { return };
    if p.pointer("/_meta/acpmux/fromAgent").is_none_or(Value::is_null) {
        crate::hub::merge_mux_meta(p, json!({"fromAgent": hub.session_name(caller)}));
    }
}

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
        super::remote_guard::mark_forwarded(conn.origin, conn.auth, params, &mut forwarded);
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
        && let Some((peer, id, row)) = hub.resolve_remote(key)
    {
        if super::trust_gate::gated(conn.origin, params) && !peer.supports_trust_gate() {
            return Err(super::trust_gate::peer_unsupported(&peer.name));
        }
        // A dropped file crosses the link as one frame: checked here, and only to a peer that
        // takes it (`hub/file_uploads.rs`).
        if m == method::MUX_FILE_PUT {
            crate::hub::file_uploads::check(params)?;
            if !peer.supports_file_put() {
                return Err(crate::hub::file_uploads::peer_unsupported(&peer));
            }
        }
        // A person's prompt is checked here, before `mark_forwarded` drops its provenance
        // (`author.rs`).
        if m == method::SESSION_PROMPT {
            crate::author::of_prompt(params)?;
        }
        // So do a message's attachments, under their caps (`attach.rs`).
        if m == method::SESSION_PROMPT
            && let Some(blocks) = params.get("prompt").and_then(Value::as_array)
        {
            crate::attach::check_wire(params)?;
            if crate::attach::any(blocks) && !peer.supports_send_attach() {
                return Err(crate::attach::peer_unsupported(&peer));
            }
            if crate::prompt_uploads::any(blocks) && !peer.supports_prompt_uploads() {
                return Err(crate::prompt_uploads::peer_unsupported(&peer));
            }
        }
        // An upload for a prompt (`attach::blocks_for`) to a peer that would refuse the prompt
        // naming it: refused before its bytes are sent, so none is left behind.
        if m == method::MUX_FILE_PUT_BEGIN
            && params.get("forPrompt") == Some(&Value::Bool(true))
            && !peer.supports_prompt_uploads()
        {
            return Err(crate::prompt_uploads::peer_unsupported(&peer));
        }
        // An older peer would answer status as unknown and finish without checking `sha256`.
        let checked =
            m == method::MUX_FILE_PUT_FINISH && params.get("sha256").is_some_and(|h| !h.is_null());
        if (checked || m == method::MUX_FILE_PUT_STATUS) && !peer.supports_upload_resume() {
            return Err(crate::hub::file_uploads::peer_unsupported(&peer));
        }
        if m == method::MUX_FILE_PUT_CHUNK {
            crate::hub::file_uploads::check_chunk(params)?;
        }
        // A peer with only the one-shot `file_put` would refuse the upload part way through.
        if matches!(m, method::MUX_FILE_PUT_BEGIN | method::MUX_FILE_PUT_CHUNK)
            && !peer.supports_file_put_chunks()
        {
            return Err(crate::hub::file_uploads::peer_unsupported(&peer));
        }
        // The media reader runs on the peer that owns the chat, if it has one (`hub/media_read.rs`).
        if matches!(m, method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE)
            && !peer.supports_media_read()
        {
            return Err(crate::hub::media_read::peer_unsupported(&peer, m));
        }
        // So does a subagent's transcript (`hub/subagent_transcript.rs`).
        if m == method::MUX_SUBAGENT_TRANSCRIPT && !peer.supports_subagent_transcript() {
            return Err(crate::hub::media_read::peer_unsupported(&peer, m)
                .with_data(json!({"reason": "transcriptRead.unsupported"})));
        }
        // Typing and an authored view are this daemon's own chats only (`hub/presence.rs`):
        // forwarded, whatever the peer serves this link as, one entry there would stand for
        // every client here.
        if m == method::MUX_TYPING || (m == method::MUX_VIEW && crate::author::present(params)) {
            return Err(crate::hub::presence::peer_unsupported());
        }
        let mut p = if params.is_null() { json!({}) } else { params.clone() };
        if let Some(obj) = p.as_object_mut() {
            obj.remove("session");
            obj.remove("name");
            obj.insert("sessionId".into(), Value::String(id.clone()));
        }
        super::remote_guard::mark_forwarded(conn.origin, conn.auth, params, &mut p);
        bound_page(m, params, &mut p);
        // A peer's handles are this connection's own here (`media_forward.rs`).
        if matches!(m, method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE) {
            return super::media_forward::forward(&conn.remote_media, &peer, &id, m, p)
                .await
                .map(Some);
        }
        // The peer cannot see the session this connection runs in: it gets that session's name.
        if m == method::SESSION_PROMPT {
            name_sender(hub, conn, &mut p);
        }
        if m == method::MUX_PERMISSION_RESPOND {
            count_hop(&mut p)?;
        }
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
                let opts = SubOpts { event_stream, filter, ..SubOpts::default() };
                super::view::subscribe_remote(hub, conn, &id, Some(opts));
            } else {
                super::view::subscribe_remote(hub, conn, &id, None);
            }
            if peer.mark_attached(&id) && m != method::MUX_ATTACH {
                // The link is not a person: only a client's own attach or view shows the chat.
                // Its own task, so the attach the marker stands for always goes out, whoever else
                // relies on it; only this client's wait for it ends when the client leaves.
                let attach = tokio::spawn({
                    let (peer, id) = (peer.clone(), id.clone());
                    async move {
                        let _ =
                            peer.request(method::MUX_ATTACH, crate::peer::hidden_attach(&id)).await;
                    }
                });
                tokio::select! {
                    _ = attach => {}
                    () = conn.closed() => {
                        return Err(RpcError::internal("the client closed the connection"));
                    }
                }
            }
        }
        // The peer answers a prompt when its turn (or a steer's step) ends; the client hears
        // the peer's acceptance as soon as it comes (`hub/outbox.rs` `PeerAccepts`).
        let accept = (m == method::SESSION_PROMPT)
            .then(|| p.pointer("/_meta/acpmux/promptId").and_then(Value::as_str))
            .flatten()
            .map(str::to_owned);
        let token = accept.as_ref().map(|prompt_id| {
            let (conn, peer_name) = (conn.clone(), peer.name.clone());
            hub.peer_accepts.wait(
                &peer.name,
                prompt_id,
                Box::new(move |mut v| {
                    if let Some(obj) = v.as_object_mut() {
                        obj.insert("peer".into(), Value::String(peer_name));
                    }
                    conn.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v));
                }),
            )
        });
        // The link the request goes on and the generation the row names as it goes: a page is
        // kept only while that link is the peer's, and only as that generation's.
        let link = peer.link_epoch();
        let pages = matches!(m, method::MUX_ATTACH | method::MUX_EVENTS);
        let purge =
            m == method::MUX_KILL && params.get("purge").and_then(Value::as_bool).unwrap_or(false);
        // The row the request was resolved by names it: a purge removes only that generation, even
        // when the row went (and the id came back as another session) before the answer.
        let asked =
            (pages || purge).then(|| row.get("createdAt").and_then(Value::as_u64)).flatten();
        // A client that left takes its prompt or wait along: those wait on the peer's turn with no
        // deadline (`peer.rs` `waits_on_turn`), and nobody would read the answer. Every other
        // request keeps its deadline and always goes out: an attach the marker above stands for
        // must reach the peer even when its client is gone.
        // A page goes on the link it is labelled with, or fails.
        let on = pages.then_some(link);
        let result = if crate::peer::waits_on_turn(m) {
            tokio::select! {
                result = peer.request_on(m, p, on) => result,
                () = conn.closed() => Err(RpcError::internal("the client closed the connection")),
            }
        } else {
            peer.request_on(m, p, on).await
        };
        if let (Some(prompt_id), Some(token)) = (&accept, token) {
            hub.peer_accepts.forget(&peer.name, prompt_id, token);
        }
        // `Peer::request` already took the peer's display lines out of the result and the error.
        let mut result = result.map_err(|e| {
            if matches!(m, method::MUX_FILE_PUT_BEGIN | method::MUX_FILE_PUT_CHUNK | method::MUX_FILE_PUT_FINISH | method::MUX_FILE_PUT_CANCEL | method::MUX_FILE_PUT_STATUS)
                && e.message.contains("Method not found")
            {
                crate::hub::file_uploads::peer_unsupported(&peer)
            } else if e.message.contains("Method not found") {
                            RpcError::internal(format!("peer {} does not support {m}; it runs acpmux build {} (this daemon: {}); run `acpmux host update {}`", peer.name, peer.remote_build().unwrap_or_else(|| "unknown".into()), crate::hub::BUILD, peer.name))
                                .with_data(json!({
                                    "reason": "peer_version_skew",
                                    "try": format!("acpmux host update {}", peer.name),
                                    "peer": peer.name,
                                    "method": m,
                                }))
                        } else {
                            e
                        }
                    })?;
        let held = |r: &Value| r.get("events").and_then(Value::as_array).map(Vec::len);
        let before = held(&result);
        strip_asks(hub, &peer.name, &id, m, &mut result);
        // What the client reads of a peer's chat is kept here too, so the chat
        // paints while the peer is paused or offline (`hub/peer_snapshot.rs`).
        // A page that lost records here no longer holds every seq it covers.
        if matches!(m, method::MUX_ATTACH | method::MUX_EVENTS) && held(&result) == before {
            let on = (peer.name.as_str(), peer.generation, link, asked);
            hub.capture_peer_page(on, (&id, m == method::MUX_EVENTS), params, &result);
        }
        // This daemon does not carry a peer chat's presence (`hub/presence.rs`).
        if m == method::MUX_ATTACH
            && let Some(obj) = result.as_object_mut()
        {
            obj.insert("presence".into(), crate::hub::presence::none(&id));
        }
        // This daemon's link is never the person on the peer, so the peer
        // refuses every group allow it forwards (`hub/person.rs`), whatever
        // its build says: the client draws none.
        if m == method::MUX_PERMISSION_GROUPS && result.is_object() {
            result["allowRefused"] = json!(crate::hub::person::REASON);
        }
        if m == method::SESSION_FORK
            && let Some(new_id) = result.get("sessionId").and_then(Value::as_str)
        {
            super::view::subscribe_remote(hub, conn, new_id, None);
            peer.mark_attached(new_id);
        }
        if purge {
            hub.forget_remote((&peer.name, peer.generation), &id, asked);
        }
        if let Some(obj) = result.as_object_mut() {
            obj.insert("peer".into(), Value::String(peer.name.clone()));
        }
        return Ok(Some(result));
    }
    // `PEER/name` for a peer that is down and lists no such session: say
    // the peer is unreachable, not that the session does not exist.
    if !SESSION_SCOPED_EXCLUDED.contains(&m)
        && let Ok(key) = session_key(params)
        && hub.resolve(key).is_err()
        && let Some(e) = hub.peer_down_for(key)
    {
        return Err(e);
    }
    Ok(None)
}

/// Drop from a peer's reply for its session `id` every ask the peer may
/// not put before this daemon's clients: the `pending` entries of an
/// `_acpmux/info` detail or an `_acpmux/attach` `session` that fail
/// `Hub::peer_ask_counts`, and the ask records in `events`
/// (`_acpmux/attach`, `_acpmux/events`), which the app reads a nonce and run
/// from too, that `Hub::peer_history_ask_counts` drops (its own asks from an
/// older run stay there without their nonce). The rest of the reply, and the
/// session, stay.
fn strip_asks(hub: &Hub, peer: &str, id: &str, m: &str, result: &mut Value) {
    let pending = match m {
        method::MUX_INFO => Some("/pending"),
        method::MUX_ATTACH => Some("/session/pending"),
        _ => None,
    };
    if let Some(Value::Array(asks)) = pending.and_then(|p| result.pointer_mut(p)) {
        asks.retain(|ask| hub.peer_ask_counts(peer, id, ask));
    }
    if let Some(Value::Array(records)) = result.get_mut("events") {
        records.retain_mut(|r| {
            let kind = r.get("kind").and_then(Value::as_str).unwrap_or("");
            if !crate::hub::is_permission_ask(kind) {
                return true;
            }
            match r.get_mut("msg") {
                Some(msg) => hub.peer_history_ask_counts(peer, id, msg),
                None => false,
            }
        });
    }
}

/// `_meta.acpmux` field of a forwarded `permission_respond`: how many
/// daemons forwarded it so far.
pub const PEER_HOPS_FIELD: &str = "peerHops";
/// At most this many forwards: a chain of peers needs a few, and two
/// daemons that each list the session as the other's cannot pass an
/// answer back and forth without end.
pub const MAX_PEER_HOPS: u64 = 4;

/// A history read (`attach`, `events`) goes to the peer with the byte limit this daemon would
/// page to: a peer on an older build has no limit of its own and answers in one reply however
/// large, and one of 32.8 MB reset the link with its 29 chats (2026-10-21).
fn bound_page(m: &str, params: &Value, forwarded: &mut Value) {
    if matches!(m, method::MUX_ATTACH | method::MUX_EVENTS)
        && let Some(object) = forwarded.as_object_mut()
    {
        object.insert("maxBytes".into(), json!(crate::hub::page_bytes(params)));
    }
}

/// Count one more forward of an answer, or refuse one past the limit.
fn count_hop(forwarded: &mut Value) -> Result<(), RpcError> {
    let hops = forwarded
        .pointer(&format!("/_meta/acpmux/{PEER_HOPS_FIELD}"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    if hops >= MAX_PEER_HOPS {
        return Err(RpcError::invalid_params(format!(
            "this permission answer was forwarded between peers {hops} times (at most {MAX_PEER_HOPS} hops)"
        )));
    }
    crate::hub::merge_mux_meta(forwarded, json!({PEER_HOPS_FIELD: hops + 1}));
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A history read forwarded to a peer names its byte limit: a peer on an older build pages to
    /// no limit of its own, and 5000 records of long tool outputs were one 32.8 MB reply that reset
    /// the link with its 29 chats (2026-10-21).
    #[test]
    fn a_forwarded_history_read_names_its_byte_limit() {
        for m in [method::MUX_ATTACH, method::MUX_EVENTS] {
            let mut p = json!({"sessionId": "s", "limit": 5000});
            bound_page(m, &json!({"limit": 5000}), &mut p);
            assert_eq!(p["maxBytes"], crate::hub::page_bytes(&json!({})), "{m}");
            // A limit the client asked for goes as this daemon caps it.
            let mut p = json!({"sessionId": "s"});
            bound_page(m, &json!({"maxBytes": 1u64 << 40}), &mut p);
            assert_eq!(p["maxBytes"], crate::hub::MAX_PAGE_BYTES, "{m}");
        }
        let mut p = json!({"sessionId": "s"});
        bound_page(method::SESSION_PROMPT, &json!({}), &mut p);
        assert!(p.get("maxBytes").is_none());
    }
}
