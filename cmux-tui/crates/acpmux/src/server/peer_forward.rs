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
    // A GitHub action is for this daemon's own caller session (`github_broker.rs`).
    method::MUX_GITHUB_ACTION,
    // The app's cmux sign-in is for this daemon alone (`github_app_token.rs`).
    method::MUX_GITHUB_APP_LEASE,
    // A task is this daemon's brief for one of its own sessions (`hub/tasks.rs`).
    method::MUX_TASK_NEW,
    method::MUX_TASKS,
    // Resolving reads this daemon's own and mirrored session lists (`hub/locate.rs`).
    method::MUX_RESOLVE,
    // An agent message is taken back on this daemon only (`hub/withdraw.rs`).
    method::MUX_PROMPT_WITHDRAW,
    // So is a chat's inbox drained (`hub/inbox_digest.rs`).
    method::MUX_INBOX_DIGEST,
    // A message to deliver is this daemon's (`outbox.rs`), whatever session it names.
    method::MUX_SEND_QUEUE,
    method::MUX_SEND_STATUS,
    // Mesh enqueue borrows only this daemon's identity, after its local-socket check.
    method::MUX_MESH_CONTROL,
    // Forwarded by its own handler, which answers for a peer that is down (`session_auth.rs`).
    method::MUX_SESSION_AUTH,
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
    // Every live chat on this daemon (`host_notice.rs`).
    "_acpmux/host_notice",
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

/// Whether `m` names a session that a peer's session forwards for: not one this daemon answers
/// itself (`SESSION_SCOPED_EXCLUDED`).
pub(super) fn names_a_session(m: &str) -> bool {
    !SESSION_SCOPED_EXCLUDED.contains(&m)
}

/// The reply when `m` is for a peer's session (forwarded there), else None
/// (this daemon handles it).
/// `_meta.acpmux.fromAgent` for a forwarded `session/prompt` with no sender of its own, from the
/// session this connection proved it runs in: the peer sees neither that session nor the caller
/// proof (`mark_forwarded` drops the provenance), so without it the peer records the agent's
/// report as the person's (claude-sr2, 2026-10-24: every remote lane's report a plain bubble), and
/// a keyed prompt could replace another sender's (`hub/supersede.rs`). The person names no one.
/// That session's id and harness go too (`fromSessionId`, `fromHarness`), this daemon's word on
/// its proven caller; whatever a client wrote there is dropped first, and only a prompt that came
/// over a peer link itself keeps what that link said (`prompt_provenance::FROM_SESSION_ID`).
fn name_sender(hub: &Arc<Hub>, conn: &Arc<Conn>, p: &mut Value) {
    // This field is daemon-authored, even when a caller already supplied fromAgent.
    if let Some(meta) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        meta.remove("messageSender");
    }
    if conn.origin != Origin::Peer {
        crate::prompt_provenance::drop_sender_fields(p);
    }
    if conn.is_person() {
        return;
    }
    let Some(caller) = conn.caller() else { return };
    let mut meta = json!({
        "messageSender": {
            "name": hub.session_name(caller),
            "sessionId": caller,
            "host": crate::hub::host_label(),
        },
    });
    if p.pointer("/_meta/acpmux/fromAgent").is_none_or(Value::is_null) {
        meta.set("fromAgent", json!(hub.session_name(caller)));
    }
    // Always replace a client-provided sender identity with the session proven by
    // this connection.  `fromAgent` remains caller-declared for display, but it
    // cannot alter the durable message sender.
    crate::hub::merge_mux_meta(p, meta);
    if let Ok(from) = hub.resolve(caller) {
        let sender = crate::prompt_provenance::BoundSender::of_session(&from.id, &from.meta());
        crate::hub::merge_mux_meta(p, sender.mux_fields());
    }
}

/// A peer's answer for a prompt id it took before (`hub/turns.rs`): the acceptance notice's
/// `duplicate`, or the first run's outcome marked `_meta.acpmux.duplicate`.
fn is_duplicate(v: &Value) -> bool {
    v.get("duplicate").and_then(Value::as_bool) == Some(true)
        || v.pointer("/_meta/acpmux/duplicate").and_then(Value::as_bool) == Some(true)
}

/// The peer's acceptance names the message its journal kept and that message's sender session
/// (`hub/message_events.rs` `name_message`), and either is not ours (`(sender, message id)`).
/// A peer that names messages (`names`: it lists `session-messages-v1`) and names none kept no
/// session's message under this prompt id (a person's prompt): not ours either. A peer from
/// before that never names one: nothing to check.
fn kept_another(v: &Value, ours: Option<(&str, &str)>, names: bool) -> bool {
    let Some((sender, message_id)) = ours else { return false };
    let differs = |key: &str, ours: &str| match v.get(key).and_then(Value::as_str) {
        Some(kept) => kept != ours,
        None => names,
    };
    differs("messageId", message_id) || differs("messageSenderId", sender)
}

/// `e` with `data.peer` = `peer`, this daemon's own name for the peer that
/// answered: any `peer` the peer's own answer gave is replaced, so the app
/// enrolls this Mac only on a peer of this daemon, never on a host the peer named.
fn name_peer(mut e: RpcError, peer: &str) -> RpcError {
    let data = e.data.get_or_insert_with(|| json!({}));
    if let Some(obj) = data.as_object_mut() {
        obj.insert("peer".into(), Value::String(peer.to_owned()));
    }
    e
}

/// How long a file upload for a peer's chat waits for that peer's link to come back before it is
/// refused. The app gives each upload call 120 s (`AcpmuxStatusClient.putFile`).
pub(super) const UPLOAD_LINK_WAIT: std::time::Duration = std::time::Duration::from_secs(30);

/// The upload methods that wait for a peer's link (`await_upload_link`).
pub(super) fn waits_for_link(m: &str) -> bool {
    matches!(
        m,
        method::MUX_FILE_PUT
            | method::MUX_FILE_PUT_BEGIN
            | method::MUX_FILE_PUT_CHUNK
            | method::MUX_FILE_PUT_FINISH
            | method::MUX_FILE_PUT_STATUS
    )
}

/// A file the person dropped for a chat on `peer` waits, up to `within`, for the peer's link to be
/// up instead of failing at once while it reconnects: the peer is wanted (`peer_wanted.rs`), so the
/// next attempt comes within a second, and each settled attempt is checked. Before, the first
/// try of a pasted video met a link that was reconnecting and failed, and only the person's Retry
/// got it through (Leo, 2026-11-01: "i had to retry to get it to load???"). Whether it came up:
/// a link still down is refused as unreachable by the request, as before.
pub(super) async fn await_upload_link(
    peer: &crate::peer::Peer,
    within: std::time::Duration,
) -> bool {
    if peer.ready() {
        return true;
    }
    let mut settled = peer.settled();
    peer.want();
    let deadline = tokio::time::Instant::now() + within;
    while !peer.ready() {
        match tokio::time::timeout_at(deadline, settled.changed()).await {
            Ok(Ok(())) => {}
            // The deadline passed, or the peer went (its sender dropped).
            _ => break,
        }
    }
    peer.ready()
}

pub(super) async fn forward(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    let reply = forward_inner(hub, conn, m, params).await.transpose();
    // A client waits on a peer that is down (a chat it opens): the peer reconnects within
    // seconds (`peer_wanted.rs`). A peer daemon's connection is no client waiting here.
    if conn.origin != Origin::Peer
        && let Some(Err(e)) = &reply
        && let Some(peer) = unreachable_peer(hub, e)
    {
        peer.want();
    }
    if conn.origin == Origin::Peer {
        return reply.map(|r| r.map_err(super::redact::hide_unreachable_peer));
    }
    reply
}

/// The peer of this daemon that `e` refused a request for because its link is down.
fn unreachable_peer(hub: &Hub, e: &RpcError) -> Option<Arc<crate::peer::Peer>> {
    let data = e.data.as_ref()?;
    if data.get("reason").and_then(Value::as_str) != Some("peer_unreachable") {
        return None;
    }
    hub.peer_by_name(data.get("peer").and_then(Value::as_str)?)
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
        // A conditional stop runs only where the session lives: an older peer would ignore the
        // condition and stop it anyway (`hub/stop_if_idle.rs`).
        if m == method::MUX_KILL && crate::hub::stop_if_idle::StopCondition::asked(params) {
            return Err(crate::hub::stop_if_idle::remote_refusal(&peer.name));
        }
        // An upload waits for a link that is reconnecting; the client that leaves stops the wait.
        if waits_for_link(m) && !peer.ready() {
            tokio::select! {
                _ = await_upload_link(&peer, UPLOAD_LINK_WAIT) => {}
                () = conn.closed() => return Err(RpcError::internal("the client closed the connection")),
            }
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
        // A prompt that waits for the owner, and the owner's answer to one, go only to a peer
        // that holds it (`hub/queue_approve.rs`): an older one would run it unapproved.
        // It goes on the link that listed the feature, never on one a reconnect brought since.
        let held = m == method::SESSION_PROMPT
            && crate::author::author(params)?.is_some_and(|a| a.awaits_owner);
        let approval = held || matches!(m, method::MUX_QUEUE_APPROVE | method::MUX_QUEUE_DECLINE);
        let feature = match m {
            method::MUX_QUEUE_GET => Some(crate::author::QUEUE_GET_FEATURE),
            _ => approval.then_some(crate::author::QUEUE_APPROVAL_FEATURE),
        };
        let bound = feature.map(|f| peer.lists_on(f));
        if bound.is_some_and(|link| link.is_none()) {
            return Err(crate::author::approval_unsupported(&peer));
        }
        // So do a message's attachments, under their caps (`attach.rs`).
        if m == method::SESSION_PROMPT
            && let Some(blocks) = params.get("prompt").and_then(Value::as_array)
        {
            crate::attach::check_wire(params)?;
            if crate::attach::any(blocks) && !peer.lists(crate::attach::FEATURE) {
                return Err(crate::attach::peer_unsupported(&peer));
            }
            if crate::prompt_uploads::any(blocks) && !peer.lists(crate::prompt_uploads::FEATURE) {
                return Err(crate::prompt_uploads::peer_unsupported(&peer));
            }
        }
        // An upload for a prompt (`attach::blocks_for`) to a peer that would refuse the prompt
        // naming it: refused before its bytes are sent, so none is left behind.
        if m == method::MUX_FILE_PUT_BEGIN
            && params.get("forPrompt") == Some(&Value::Bool(true))
            && !peer.lists(crate::prompt_uploads::FEATURE)
        {
            return Err(crate::prompt_uploads::peer_unsupported(&peer));
        }
        // An older peer would answer status as unknown and finish without checking `sha256`.
        let checked =
            m == method::MUX_FILE_PUT_FINISH && params.get("sha256").is_some_and(|h| !h.is_null());
        if (checked || m == method::MUX_FILE_PUT_STATUS)
            && !peer.lists(crate::hub::file_uploads::RESUME_FEATURE)
        {
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
        // A peer on an older build replays the chat for `session/resume`, as for a load, and
        // the replay would reach this client: the resume `initialize` advertises would not hold.
        // The resume then goes on the link that listed it, or fails (`Peer::session_resume_link`).
        let resume_link = (m == method::SESSION_RESUME).then(|| peer.session_resume_link());
        // A link that is down says nothing of the peer's build: the client hears it is down.
        if resume_link == Some(None) && !peer.ready() {
            return Err(peer.unreachable_error());
        }
        if resume_link == Some(None) {
            let build = peer.remote_build().unwrap_or_else(|| "unknown".into());
            return Err(RpcError::method_not_found(&format!(
                "{m} (peer {} runs acpmux build {build}, whose resume replays the chat; run `acpmux host update {}`)",
                peer.name, peer.name
            ))
            .with_data(json!({"reason": "sessionResume.unsupported", "peer": peer.name})));
        }
        // So does a subagent's transcript (`hub/subagent_transcript.rs`).
        if m == method::MUX_SUBAGENT_TRANSCRIPT && !peer.supports_subagent_transcript() {
            return Err(crate::hub::media_read::peer_unsupported(&peer, m)
                .with_data(json!({"reason": "transcriptRead.unsupported"})));
        }
        // And a chat's older native turns (`hub/native_history.rs`): a pane stops paging on it.
        if m == method::MUX_NATIVE_HISTORY && !peer.supports_native_history() {
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
        // A held prompt names its hold to the peer: a link guest's waits with `approval` left
        // off here, which a peer that reads only `approval` would run unapproved.
        if held
            && let Some(author) =
                p.pointer_mut("/_meta/acpmux/author").and_then(Value::as_object_mut)
        {
            author.insert("approval".into(), json!(crate::author::APPROVAL_OWNER));
        }
        if m == method::SESSION_CANCEL {
            super::requests::person_stop::mark(conn, params, &peer, &mut p);
        }
        bound_page(m, params, &mut p);
        // This connection's own reopen hears the chat's messages again; the replay comes over
        // the link every viewer here shares (`MessageNotices`).
        if matches!(m, method::SESSION_LOAD | method::SESSION_RESUME) {
            conn.message_notices
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .reopen(Some(&peer.name), &id);
        }
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
                        // A failed attach is logged there, and unmarked when the peer refused
                        // it; the prompt still goes, and answers with the peer's own error if
                        // the chat is gone.
                        let _ = peer.attach_hidden(&id).await;
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
        // A prompt without a client id still needs an acceptance key so the sender-side
        // journal copy can be recorded when the peer accepts it.  The generated id is
        // internal to this forwarded request and is not exposed as a client id.
        if m == method::SESSION_PROMPT
            && p.pointer("/_meta/acpmux/promptId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .is_none()
        {
            crate::hub::merge_mux_meta(
                &mut p,
                json!({"promptId": uuid::Uuid::now_v7().to_string()}),
            );
        }
        // The peer answers a prompt when its turn (or a steer's step) ends; the client hears
        // the peer's acceptance as soon as it comes (`hub/outbox.rs` `PeerAccepts`).
        let accept = (m == method::SESSION_PROMPT)
            .then(|| p.pointer("/_meta/acpmux/promptId").and_then(Value::as_str))
            .flatten()
            .map(str::to_owned);
        // Only a link the peer serves as a peer daemon carries the sender's identity there
        // (`requests.rs` takes `messageSender` from a Peer connection alone), and only a peer
        // that lists `session-messages-v1` records the message: over a link added with the
        // dashboard token, or to an older peer, the receiver records no message, so the sender
        // records none and waits on none either.
        let sender_message = if m == method::SESSION_PROMPT
            && !conn.is_person()
            && peer.served_as().as_deref() == Some("peer")
            && peer.supports_session_messages()
        {
            conn.caller().map(|sender_session| {
                let sender =
                    p.pointer("/_meta/acpmux/messageSender").cloned().unwrap_or_else(|| {
                        json!({
                            "name": hub.session_name(sender_session),
                            "sessionId": sender_session,
                            "host": crate::hub::host_label(),
                        })
                    });
                let text = p
                    .get("prompt")
                    .and_then(Value::as_array)
                    .map(|blocks| crate::hub::prompt_text(blocks))
                    .or_else(|| p.get("text").and_then(Value::as_str).map(str::to_owned))
                    .unwrap_or_default();
                let message_id = super::outbox::forwarded_message_id(&p).to_owned();
                (sender_session.to_owned(), sender, text, message_id)
            })
        } else {
            None
        };
        let forward_intent = if let Some((sender_session, ..)) = &sender_message {
            Some(super::outbox::remember_forward(hub, &peer.name, &id, sender_session, &p).await?)
        } else {
            None
        };
        // The peer's acceptance said this prompt id was a duplicate (`is_duplicate`) or kept
        // another send's message (`kept_another`): its answer records nothing either.
        let duplicate = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let token = accept.as_ref().map(|prompt_id| {
            let (conn, peer_name) = (conn.clone(), peer.name.clone());
            let duplicate_seen = duplicate.clone();
            let callback_hub = hub.clone();
            let sender_message = sender_message.clone();
            let forward_intent = forward_intent.clone();
            let (target_peer, target_id) = (peer.name.clone(), id.clone());
            let (provisional_conn, provisional_peer) = (conn.clone(), peer_name.clone());
            let names = peer.supports_session_messages();
            hub.peer_accepts.wait(
                &peer.name,
                &id,
                prompt_id,
                Box::new(move |mut v| {
                    let ours = sender_message
                        .as_ref()
                        .map(|(sender, _, _, message_id)| (sender.as_str(), message_id.as_str()));
                    if is_duplicate(&v) || kept_another(&v, ours, names) {
                        // The peer ran this prompt id before, or kept another send's message
                        // under it (a direct send and its `send_queue` retry both hear the one
                        // acceptance): only its journal says whether this message is there.
                        duplicate_seen.store(true, std::sync::atomic::Ordering::SeqCst);
                        if let Some(intent) = forward_intent {
                            super::outbox::forward_unconfirmed(&callback_hub, &intent);
                        }
                    } else {
                        let stored = if let Some((sender_session, sender, text, message_id)) =
                            sender_message
                        {
                            callback_hub.append_sender_message_event(
                                &sender_session,
                                sender,
                                text,
                                message_id,
                                crate::store::now_ms(),
                                &target_peer,
                                &target_id,
                            )
                        } else {
                            false
                        };
                        if let Some(intent) = forward_intent {
                            super::outbox::forward_accepted(
                                &callback_hub,
                                &intent,
                                v.clone(),
                                stored,
                            );
                        }
                    }
                    if let Some(obj) = v.as_object_mut() {
                        obj.insert("peer".into(), Value::String(peer_name));
                    }
                    conn.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v));
                }),
                Arc::new(move |mut v| {
                    if let Some(obj) = v.as_object_mut() {
                        obj.insert("peer".into(), Value::String(provisional_peer.clone()));
                    }
                    provisional_conn.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v));
                }),
            )
        });
        // The link the request goes on and the generation the row names as it goes: a page is
        // kept only while that link is the peer's, and only as that generation's.
        let link = peer.link_epoch();
        // A client here opens peer chats: their copies are read ahead from now on, so the next
        // one opens on its copy even while its peer reconnects (`hub/peer_snapshot/warm.rs`).
        if m == method::MUX_ATTACH && conn.origin != Origin::Peer {
            hub.want_peer_copies();
        }
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
        // A page goes on the link it is labelled with, or fails; so does a held prompt, an
        // answer to one or a read of one, on the link that listed its feature.
        let on = bound.unwrap_or_else(|| pages.then_some(link).or(resume_link.flatten()));
        let result = if crate::peer::waits_on_turn(m) {
            tokio::select! {
                result = peer.request_on(m, p, on) => result,
                () = conn.closed() => Err(RpcError::internal("the client closed the connection")),
            }
        } else {
            peer.request_on(m, p, on).await
        };
        // Older peers can answer without a separate acceptance notification.
        // Reconcile that successful result too, before the intent is settled.
        if let Some(intent) = forward_intent.as_deref() {
            match &result {
                Ok(accepted)
                    if is_duplicate(accepted)
                        || duplicate.load(std::sync::atomic::Ordering::SeqCst) =>
                {
                    super::outbox::forward_unconfirmed(hub, intent);
                }
                Ok(accepted) => {
                    let stored =
                        if let Some((sender_session, sender, text, message_id)) = sender_message {
                            hub.append_sender_message_event(
                                &sender_session,
                                sender,
                                text,
                                message_id,
                                crate::store::now_ms(),
                                &peer.name,
                                &id,
                            )
                        } else {
                            false
                        };
                    super::outbox::forward_accepted(hub, intent, accepted.clone(), stored);
                }
                Err(error) => super::outbox::forward_refused(hub, intent, error),
            }
        }
        if let (Some(prompt_id), Some(token)) = (&accept, token) {
            hub.peer_accepts.forget(&peer.name, &id, prompt_id, token);
        }
        // `Peer::request` already took the peer's display lines out of the result and the error.
        let mut result = result.map_err(|e| {
            if matches!(m, method::MUX_FILE_PUT_BEGIN | method::MUX_FILE_PUT_CHUNK | method::MUX_FILE_PUT_FINISH | method::MUX_FILE_PUT_CANCEL | method::MUX_FILE_PUT_STATUS)
                && e.message.contains("Method not found")
            {
                crate::hub::file_uploads::peer_unsupported(&peer)
            } else if e.message.contains("Method not found") {
                            RpcError::internal(format!("peer {} does not support {m}; it runs acpmux build {} (this daemon: {}); run `acpmux host update {}`", peer.name, peer.remote_build().unwrap_or_else(|| "unknown".into()), crate::hub::build(), peer.name))
                                .with_data(json!({
                                    "reason": "peer_version_skew",
                                    "try": format!("acpmux host update {}", peer.name),
                                    "peer": peer.name,
                                    "method": m,
                                }))
                        } else if matches!(m, method::MUX_PERMISSION_RESPOND | method::MUX_PERMISSION_GROUP_RESPOND) {
                            // A refused answer names the peer that refused it, so the app can say
                            // where to enroll this Mac (`hub/mac_approvers.rs`).
                            name_peer(e, &peer.name)
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
        if m == method::MUX_PERMISSION_GROUPS && result.is_object() {
            mac_group_read(&mut result, conn.is_person() && hub.person.macs.has_own());
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
    // the peer is unreachable, not that the session does not exist. A peer daemon's
    // connection never learns this host's peers or their state (`redact::hide_peers_from_peer`):
    // it gets the answer a name no peer has gets.
    if !SESSION_SCOPED_EXCLUDED.contains(&m)
        && conn.origin != Origin::Peer
        && let Ok(key) = session_key(params)
        && hub.resolve(key).is_err()
        && let Some(e) = hub.peer_down_for(key)
    {
        return Err(e);
    }
    Ok(None)
}

/// A peer's `_acpmux/permission_groups` reply, as this daemon's client may draw it. This
/// daemon's link is never the person on the peer, so the peer refuses every group allow it
/// forwards (`hub/person.rs`), whatever its build says: the client draws none
/// (`allowRefused`). One exception: the peer counts an enrolled Mac's signed Allow once
/// (`macAllowOnce`), and the reader is this machine's person whose app holds this Mac's
/// approver key (`mac_signs`): it may draw Allow once and Deny, never Allow for the chat.
fn mac_group_read(result: &mut Value, mac_signs: bool) {
    if !(mac_signs && result.get("macAllowOnce") == Some(&Value::Bool(true))) {
        result["allowRefused"] = json!(crate::hub::person::REASON);
        return;
    }
    if let Some(obj) = result.as_object_mut() {
        obj.remove("allowRefused");
    }
    for group in result.get_mut("groups").and_then(Value::as_array_mut).into_iter().flatten() {
        if let Some(decisions) = group.get_mut("decisions").and_then(Value::as_array_mut) {
            decisions.retain(|d| d != "allow_chat");
        }
    }
}

/// Drop from a peer's reply for its session `id` every ask the peer may
/// not put before this daemon's clients: the `pending` entries of an
/// `_acpmux/info` detail or an `_acpmux/attach` `session` that fail
/// `Hub::peer_ask_counts`, and the ask records in `events`
/// (`_acpmux/attach`, `_acpmux/events`), which the app reads a nonce and run
/// from too, that `Hub::peer_history_ask_counts` drops (its own asks from an
/// older run stay there without their nonce). The rest of the reply, and the
/// session, stay.
pub(crate) fn strip_asks(hub: &Hub, peer: &str, id: &str, m: &str, result: &mut Value) {
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

/// The `_meta.acpmux` fields of a `session/new` that stay on this daemon when it is forwarded
/// to a peer (`_meta.acpmux.peer`).
pub(super) fn strip_new_meta(p: &mut Value) {
    if let Some(m) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        m.remove("peer");
        // A family lives on one daemon: this daemon's caller is no session there.
        m.remove(crate::hub::lineage::PARENT_FIELD);
        m.remove(crate::hub::lineage::TOOL_CALL_FIELD);
        // The peer would tie it to this daemon's long-lived connection, never to the
        // client's: the client's own kill purges it (`ephemeral.rs`).
        m.remove("ephemeral");
        // Retry hints use the original params here; the peer does not need the
        // CLI argv or a second copy of the prompt file to create the session.
        m.remove("argv");
        m.remove("promptFileText");
        // Only this daemon decides the VM boundary, never its caller.
        m.remove(crate::hub::vm_boundary::FIELD);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An explicit peer removal must release *every* upload waiting for the
    /// reconnect. The old waiter listened only to completed connection attempts,
    /// so an idle/stopped peer kept these calls for 30 seconds.
    #[tokio::test]
    async fn removed_peer_wakes_all_waiting_uploads_without_a_connect_attempt() {
        let (notices, _receiver) = tokio::sync::mpsc::channel(1);
        let peer = crate::peer::Peer::new(
            "gone",
            "ws://127.0.0.1:9",
            None,
            None,
            notices,
        );
        let mut pending = Vec::new();
        for _ in 0..2 {
            let peer = peer.clone();
            pending.push(tokio::spawn(async move {
                await_upload_link(&peer, std::time::Duration::from_secs(30)).await
            }));
        }
        // Peer::run is deliberately absent: removal itself, not a later
        // connection outcome, must wake each waiter.
        tokio::task::yield_now().await;
        peer.stop();
        for task in pending {
            let result = tokio::time::timeout(std::time::Duration::from_secs(1), task)
                .await
                .expect("a stopped peer left its upload waiting for the 30 s timeout")
                .unwrap();
            assert!(!result, "stopped peer was reported ready");
        }
    }

    /// A refused answer for a peer's prompt names that peer, so the app can say where to
    /// enroll this Mac; a peer the answer named itself is replaced by this daemon's name.
    #[test]
    fn a_refused_answer_names_the_peer() {
        let e = name_peer(crate::hub::person::person_required("allowing a permission"), "hb");
        assert_eq!(e.data.as_ref().unwrap()["peer"], "hb");
        assert_eq!(e.data.as_ref().unwrap()["reason"], crate::hub::person::REASON);
        let e = name_peer(RpcError::internal("x").with_data(json!({"peer": "far"})), "hb");
        assert_eq!(e.data.unwrap()["peer"], "hb");
    }

    /// A peer's group read: the person here whose app holds this Mac's key draws Allow once and
    /// Deny when the peer counts a Mac's signed allow; every other reader, or a peer that does
    /// not say so, draws no Allow.
    #[test]
    fn a_peers_group_read_draws_allow_once_only_for_a_mac_that_signs() {
        let read = || {
            json!({"groups": [{"decisions": ["allow_once", "allow_chat", "deny"]}],
                   "allowRefused": crate::hub::person::REASON, "macAllowOnce": true})
        };
        let mut r = read();
        mac_group_read(&mut r, true);
        assert!(r.get("allowRefused").is_none(), "{r}");
        assert_eq!(r["groups"][0]["decisions"], json!(["allow_once", "deny"]));
        let mut r = read();
        mac_group_read(&mut r, false);
        assert_eq!(r["allowRefused"], crate::hub::person::REASON);
        assert_eq!(r["groups"][0]["decisions"].as_array().unwrap().len(), 3);
        for old in [json!({"groups": []}), json!({"groups": [], "macAllowOnce": false})] {
            let mut r = old;
            mac_group_read(&mut r, true);
            assert_eq!(r["allowRefused"], crate::hub::person::REASON, "{r}");
        }
    }

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

#[cfg(test)]
mod message_identity_tests {
    use super::{is_duplicate, kept_another};
    use serde_json::json;

    /// A sender's copy is recorded only for the message the peer's acceptance names, and only
    /// when that acceptance is no duplicate; a peer that names none is taken at its word.
    #[test]
    fn an_acceptance_confirms_only_the_message_it_names() {
        let named = json!({"sessionId": "t", "promptId": "p", "messageId": "p",
                           "messageSenderId": "sender-a"});
        for names in [true, false] {
            assert!(!kept_another(&named, Some(("sender-a", "p")), names));
            assert!(kept_another(&named, Some(("sender-a", "delivery-1")), names));
            // Another session's send of the same prompt id is not ours either.
            assert!(kept_another(&named, Some(("sender-b", "p")), names));
            assert!(!kept_another(&named, None, names));
        }
        // An acceptance naming no message: from a peer that names messages it is another
        // prompt's (a person's, under the same id), so it confirms no session's send; from a
        // peer that never names one it is taken at its word.
        let unnamed = json!({"sessionId": "t", "promptId": "p"});
        assert!(kept_another(&unnamed, Some(("sender-a", "p")), true));
        assert!(!kept_another(&unnamed, Some(("sender-a", "delivery-1")), false));
        let half = json!({"sessionId": "t", "promptId": "p", "messageId": "p"});
        assert!(kept_another(&half, Some(("sender-a", "p")), true));
        assert!(!kept_another(&half, Some(("sender-a", "p")), false));
        assert!(is_duplicate(&json!({"promptId": "p", "duplicate": true, "turnId": "t1"})));
        assert!(is_duplicate(&json!({"stopReason": "end_turn",
                                     "_meta": {"acpmux": {"duplicate": true}}})));
        assert!(!is_duplicate(&named));
    }

    /// An empty `messageId` is no id: the receiver keeps the prompt id, and so does the sender.
    #[test]
    fn a_forwarded_message_is_named_as_its_receiver_names_it() {
        use super::super::outbox::forwarded_message_id;
        let with = |meta: serde_json::Value| json!({"_meta": {"acpmux": meta}});
        assert_eq!(forwarded_message_id(&with(json!({"messageId": "", "promptId": "p"}))), "p");
        assert_eq!(forwarded_message_id(&with(json!({"messageId": "m", "promptId": "p"}))), "m");
        assert_eq!(forwarded_message_id(&with(json!({"promptId": "p"}))), "p");
    }
}
