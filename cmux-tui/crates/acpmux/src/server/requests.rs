//! Request and notification handlers for one client connection.

use super::*;

mod composer;
mod events;
#[path = "requests/mailbox.rs"]
mod mailbox;
mod presets;

/// Subscribe the connection to a session and, when that is new, count it
/// as attached (remote sessions are not counted; their host does that).
pub(super) fn attach(hub: &Hub, conn: &Conn, id: &str) {
    let resolved = hub.resolve(id).ok();
    if conn.subscribe(id)
        && let Some(s) = &resolved
    {
        hub.attach_count(s, 1, true);
    }
    if let Some(s) = resolved {
        conn.bind_mailbox_receipt(crate::session_identity::SessionReceipt::new(
            crate::session_identity::LOCAL_HOST_ID,
            s.id.clone(),
            s.meta().agent_session_id,
            hub.started_at,
        ));
    }
}

fn resolved_session(
    hub: &Hub,
    resolved: Option<&Arc<crate::hub::Session>>,
    params: &Value,
) -> Result<Arc<crate::hub::Session>, RpcError> {
    match resolved {
        Some(session) => Ok(session.clone()),
        None => hub.resolve(session_key(params)?),
    }
}

pub(super) async fn handle_notification(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    mut params: Value,
) {
    match m {
        method::SESSION_CANCEL => {
            // Notifications have no response channel, but they still cross
            // the same origin/ownership boundary as request-form cancels.
            if conn.origin != Origin::Local
                && let Err(e) =
                    super::remote_guard::check(hub, conn.origin, conn.auth, m, &mut params).await
            {
                tracing::debug!(conn = %conn.id, "cancel refused: {e}");
                return;
            }
            if let Ok(key) = session_key(&params) {
                if let Ok(s) = hub.resolve(key) {
                    if let Err(e) = hub.cancel(&s).await {
                        tracing::debug!(conn = %conn.id, "cancel: {e}");
                    }
                } else if let Some((peer, id, _)) = hub.resolve_remote(key) {
                    let mut forwarded = json!({"sessionId": id});
                    super::remote_guard::mark_forwarded(
                        conn.origin,
                        conn.auth,
                        &params,
                        &mut forwarded,
                    );
                    let _ = peer.notify(method::SESSION_CANCEL, forwarded).await;
                }
            }
        }
        method::CANCEL_REQUEST => {}
        _ => tracing::debug!(conn = %conn.id, "ignored notification {m}"),
    }
}

/// The tag the chat lists hide a session by (webviews sessionList.ts `ARCHIVED_TAG`).
const ARCHIVED_TAG: &str = "archived";
// The tag that marks a side chat, valued with its chat's session (`hub/btw.rs`).
use crate::hub::SIDE_TAG;

pub(super) async fn handle_request(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    mut params: Value,
) -> Result<Value, RpcError> {
    // The pane's fork through a turn is a session/fork, checked as one from
    // here on (`fork_through.rs`).
    let m = super::fork_through::as_session_fork(hub, m, &mut params).await?;
    // Before anything runs or is forwarded to a peer (`remote_guard.rs`).
    if conn.origin != Origin::Local {
        super::remote_guard::check(hub, conn.origin, conn.auth, m, &mut params).await?;
    }
    // Only the person allows or widens what runs without asking (`hub/person.rs`): one
    // check, before the request runs or reaches a peer. Held to the Web's rules: a Web
    // connection, or a peer forwarding for its own Web client (`via: web`); a peer
    // forwarding its unix socket or app keeps the person rule.
    let remote_authenticated = conn.auth.authenticated()
        && super::remote_guard::control_of(conn.origin, conn.auth, &params)
            == crate::hub::Control::Web;
    let verdict = hub
        .person_check(
            conn.is_person(),
            remote_authenticated,
            conn.caller(),
            !conn.origin.web_class(),
            m,
            &params,
        )
        .await?;
    let resolved = super::session_key(&params).ok().and_then(|key| hub.resolve(key).ok());
    super::trust_gate::check(hub, conn.origin, m, &params, resolved.as_ref()).await?; // the folder-trust gate
    let key = super::session_key(&params).ok().map(str::to_owned);
    let mut reply = if verdict == crate::hub::person::PersonVerdict::PeerOnly {
        // The check saw a peer's prompt: only the peer decides it. If the
        // name no longer names a peer's session (renamed, killed, a new
        // local session with that prefix), refuse; never handle it here.
        match super::peer_forward::forward(hub, conn, m, &params).await {
            Some(reply) => reply,
            None => Err(crate::hub::person::person_required(
                "answering a prompt whose session moved between this check and its forward",
            )),
        }
    } else {
        dispatch_request(hub, conn, m, params, resolved).await
    };
    super::remote_guard::after(hub, conn.origin, m, key.as_deref(), &mut reply);
    reply
}

async fn dispatch_request(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
    resolved: Option<Arc<crate::hub::Session>>,
) -> Result<Value, RpcError> {
    // A session that lives on a peer (`peer_forward.rs`).
    if let Some(reply) = super::peer_forward::forward(hub, conn, m, &params).await {
        return reply;
    }
    match m {
        method::INITIALIZE => {
            if let Some(name) = params.pointer("/clientInfo/name").and_then(Value::as_str) {
                *conn.name.lock().unwrap() = name.to_owned();
            }
            Ok(json!({
                "protocolVersion": 1,
                "agentInfo": {"name": "acpmux", "title": "acpmux", "version": VERSION},
                "agentCapabilities": {
                    "loadSession": true,
                    "promptCapabilities": {"image": true, "audio": false, "embeddedContext": true},
                    "sessionCapabilities": {"list": {}, "fork": {}, "close": {}, "delete": {}},
                },
                "authMethods": [],
                "_meta": {"acpmux": {"version": VERSION, "build": crate::hub::BUILD,
                // `local`: the unix socket or the proven local app
                // (`local_app.rs`), which the session pool serves.
                "origin": match conn.origin { Origin::Web => "remote", Origin::Peer => "peer", _ => "local" },
                // The proof this connection presented (`conn_auth.rs`).
                "auth": conn.auth.as_str(),
                // This connection is the person (`hub/person.rs`): never yet,
                // as the proof comes after this reply.
                "person": conn.is_person(),
                // The challenge a local connection proves the person key against.
                "personChallenge": if conn.challengeable() {
                    json!({"nonce": conn.nonce, "connection": conn.id})
                } else {
                    Value::Null
                },
                // The daemon run decision proofs bind (`hub/person.rs`).
                "personInstance": hub.person.instance(),
                "extensions": [
                    method::MUX_STATUS, method::MUX_SESSIONS, method::MUX_HARNESSES, method::MUX_RELOAD_CONFIG, method::MUX_ATTACH, method::MUX_WARM, method::MUX_PREWARM,
                    method::MUX_DETACH, method::MUX_WATCH, method::MUX_HARNESS_INVENTORY_WATCH, method::MUX_HARNESS_INVENTORY_REFRESH, method::MUX_HARNESS_UPDATE_PLAN, method::MUX_HARNESS_UPDATE_PREPARE, method::MUX_RENAME, method::MUX_KILL, method::MUX_QUEUE_REMOVE, method::MUX_QUEUE_EDIT,
                    method::MUX_INFO, method::MUX_EVENTS, method::MUX_ATTACHMENT, method::MUX_MAIL_SEND, method::MUX_MAIL_READ, method::MUX_MAIL_WAIT, method::MUX_MAIL_ACK, method::MUX_PERMISSION_RESPOND, method::MUX_PROCESS_LIST, method::MUX_PROCESS_TAIL, method::MUX_PROCESS_KILL,
                    method::MUX_DRAFT_GET, method::MUX_DRAFT_SET, method::MUX_BOOKMARK_GET, method::MUX_BOOKMARK_SET, method::MUX_ASK, method::MUX_BTW, method::MUX_VIEW, method::MUX_MARK_UNREAD, method::MUX_ARCHIVE, method::MUX_SIDE,
                    method::MUX_SET_POLICY, method::MUX_SET_TOOLS, method::MUX_EXPORT, method::MUX_IMPORT, method::MUX_SHUTDOWN,
                ], "operations": crate::hub::HANDOFF_OPERATIONS.iter().chain(crate::hub::PERMISSION_GROUP_OPERATIONS.iter()).chain(super::fork_through::FORK_OPERATIONS.iter()).collect::<Vec<_>>(), "handoff": {"maxCapsuleBytes": crate::hub::MAX_CAPSULE_BYTES},
                "features": ["promptAccepted", "turnIds", "eventPaging", "eventKinds", "eventStream", "cancelRequest", "messageSuperseded", "turnErrorText", "permissionGroups", "trustGate", "chiefBuiltinPresets", "personChallenge", "queueEdit", "steerInterrupt", "personHolds", "sessionTransfer", "approverDecisions", "toolInventory", "promptWithdraw", "processes", "harnessInventory", super::inventory_watch::FEATURE, crate::harness_health::INVENTORY_REFRESH_FEATURE, crate::harness_health::UPDATE_PLAN_FEATURE, crate::harness_health::UPDATE_PREPARE_FEATURE], "trustGate": true}}
            }))
        }
        method::AUTHENTICATE => Ok(json!({})),
        // Decided in order in `Conn::bind_person`; this only reports it.
        method::MUX_PERSON_PROVE => {
            if conn.is_person() {
                Ok(json!({"person": true}))
            } else {
                Err(RpcError::new(
                    -32000,
                    "the person proof does not answer this connection's challenge (it must be the second request, after initialize)",
                )
                .with_data(json!({"reason": crate::hub::person::PROOF_REFUSED})))
            }
        }
        // The person only (`Hub::person_check`): never reached otherwise.
        method::MUX_APPROVERS_SET if conn.is_person() => hub.person.approvers.set(&params),
        method::MUX_APPROVERS if conn.is_person() => Ok(hub.person.approvers.list()),
        method::MUX_APPROVERS_SET | method::MUX_APPROVERS => {
            Err(crate::hub::person::person_required("changing or reading trusted approvers"))
        }
        method::MUX_WORKSPACE_ROOTS_SET if conn.is_person() => {
            hub.person.set_workspace_roots(&params)
        }
        method::MUX_WORKSPACE_ROOTS_SET => {
            Err(crate::hub::person::person_required("changing the workspace folders"))
        }
        method::MUX_NEW_CHAT_PICKS_SET if conn.is_person() => {
            hub.person.set_new_chat_picks(&params)
        }
        method::MUX_NEW_CHAT_PICKS_SET => {
            Err(crate::hub::person::person_required("changing the new chat picks"))
        }
        method::MUX_PERSON_HOLDS => {
            // The unix socket only: the app reaches a daemon it started over
            // its own exec channel (`acp stdio`), never over a WebSocket.
            if conn.origin != Origin::Local {
                return Err(RpcError::invalid_params(
                    "_acpmux/person_holds is accepted only over the local unix socket",
                ));
            }
            // A few answers per connection. Not a security bound (a new
            // connection gets 8 more): the answers are an HMAC over
            // caller-chosen nonces that is valid only in its own domain, so
            // they never serve as a decision or connection proof.
            let calls = conn.holds_calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            if calls >= crate::hub::person::HOLDS_PER_CONNECTION {
                return Err(RpcError::new(
                    -32000,
                    "this connection asked _acpmux/person_holds too often: open a new connection",
                )
                .with_data(json!({"reason": crate::hub::person::HOLDS_LIMIT})));
            }
            let nonce = str_param(&params, "nonce")
                .filter(|n| crate::hub::person::valid_key(n))
                .ok_or_else(|| {
                    RpcError::invalid_params("nonce must be 64 lowercase hex characters")
                })?;
            match hub.person.holds(nonce) {
                Some(proof) => Ok(json!({"instance": hub.person.instance(), "proof": proof})),
                None => Err(RpcError::new(-32000, "this daemon holds no person key")
                    .with_data(json!({"reason": crate::hub::person::NO_KEY}))),
            }
        }
        method::MUX_PERSON_ENROLL => {
            // The unix socket only: a WebSocket peer has no audit token.
            if conn.origin != Origin::Local {
                return Err(RpcError::invalid_params(
                    "_acpmux/person_enroll is accepted only over the local unix socket",
                )
                .with_data(json!({"reason": crate::hub::person::ENROLL_REFUSED})));
            }
            let key = str_param(&params, "key")
                .ok_or_else(|| RpcError::invalid_params("key is required"))?;
            let signed = cmux_link::app_caller::signed_app_build();
            let verified = match (signed, conn.peer.as_ref()) {
                (true, Some(token)) => match cmux_link::app_caller::verify_containing_app(token) {
                    Ok(()) => true,
                    Err(why) => {
                        tracing::warn!("person_enroll refused: {why}");
                        return Err(RpcError::new(
                            -32000,
                            "only the cmux app that contains this daemon may enroll a person key",
                        )
                        .with_data(json!({"reason": crate::hub::person::ENROLL_REFUSED})));
                    }
                },
                (true, None) => {
                    return Err(RpcError::new(-32000, "the peer's audit token is unknown")
                        .with_data(json!({"reason": crate::hub::person::ENROLL_REFUSED})));
                }
                (false, _) => false,
            };
            hub.person.enroll(key, verified)
        }
        method::MUX_COMPUTER_USE_ENROLL => {
            // Private lifecycle RPC: no CLI/MCP/palette/WebSocket/remote-relay
            // surface. It carries a per-launch credential only on a local
            // socket whose peer is the signed app containing this daemon.
            if conn.origin != Origin::Local {
                return Err(RpcError::invalid_params(
                    "_acpmux/computer_use_enroll is accepted only over the local unix socket",
                ));
            }
            if !cmux_link::app_caller::signed_app_build() {
                return Err(RpcError::invalid_params(
                    "an unsigned daemon takes Computer Use credentials only at spawn",
                ));
            }
            let Some(token) = conn.peer.as_ref() else {
                return Err(RpcError::invalid_params("the peer's audit token is unknown"));
            };
            if let Err(why) = cmux_link::app_caller::verify_containing_app(token) {
                tracing::warn!("computer_use_enroll refused: {why}");
                return Err(RpcError::invalid_params(
                    "only the cmux app that contains this daemon may enroll Computer Use",
                ));
            }
            let socket = params
                .get("socket")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("socket must be a string"))?;
            let agent_token = params
                .get("agentToken")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("agentToken must be a string"))?;
            if socket.len() > 4096 || agent_token.len() > 4096 {
                return Err(RpcError::invalid_params(
                    "the Computer Use socket and agent token must each be at most 4096 bytes",
                ));
            }
            crate::cua_socket::enroll(socket.to_owned(), agent_token.to_owned());
            Ok(json!({"enrolled": true}))
        }
        method::SESSION_NEW => {
            // A peer name in _meta.acpmux.peer creates the session on that daemon.
            if let Some(peer_name) =
                mux_meta(&params).and_then(|m| m.get("peer")).and_then(Value::as_str)
                && !peer_name.is_empty()
            {
                let peer = hub
                    .peer_by_name(peer_name)
                    .ok_or_else(|| RpcError::not_found(format!("no peer {peer_name:?}")))?;
                if super::trust_gate::gated(conn.origin, &params) && !peer.supports_trust_gate() {
                    return Err(super::trust_gate::peer_unsupported(&peer.name));
                }
                let mut p = params.clone();
                if let Some(m) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
                    m.remove("peer");
                }
                super::remote_guard::mark_forwarded(conn.origin, conn.auth, &params, &mut p);
                let mut result = peer.request(method::SESSION_NEW, p).await?;
                if let Some(id) = result.get("sessionId").and_then(Value::as_str) {
                    attach(hub, conn, id);
                    peer.mark_attached(id);
                }
                if let Some(obj) = result.as_object_mut() {
                    obj.insert("peer".into(), Value::String(peer.name.clone()));
                }
                return Ok(result);
            }
            let mut cwd = str_param(&params, "cwd").map(PathBuf::from);
            let meta = mux_meta(&params);
            // The local app starts a preset by its id only: anything that
            // would shape the harness command from the request is refused.
            // LocalApp cwd: any existing directory of this user until the native transport limits it to workspace roots.
            if conn.origin == Origin::LocalApp {
                super::local_app::preset_by_id_only(&params, meta)?;
                if super::local_app::names_preset(&params, meta)
                    && let Some(given) = &cwd
                {
                    cwd = Some(super::local_app::canonical_cwd(given).await?);
                }
            }
            let adopt =
                crate::adopt::AdoptRequest::from_meta(meta).map_err(RpcError::invalid_params)?;
            let adopting = adopt.is_some();
            let pick = |key: &str| {
                meta.and_then(|m| m.get(key))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| params.get(key).and_then(Value::as_str).map(str::to_owned))
            };
            let policy = pick("policy")
                .map(|p| p.parse::<PermissionPolicy>().map_err(RpcError::invalid_params))
                .transpose()?;
            let env = crate::session_env::parse(meta)?;
            let route = pick("route");
            if let Some(r) = &route
                && !crate::routes::is_route_id(r)
            {
                return Err(RpcError::invalid_params(format!("route {r:?} is not a route id")));
            }
            let asked_policy = policy.is_some();
            let req = crate::hub::NewRequest {
                harness: pick("harness"),
                preset: pick("preset"),
                name: pick("name"),
                cwd,
                policy,
                model: pick("model"),
                effort: pick("effort"),
                adopt,
                workspace_id: crate::session_env::workspace_id(meta, &env)?,
                env,
                // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
                remote: conn.origin.web_class(),
                keep_harness_mode: hub
                    .keeps_harness_mode(conn.is_person(), conn.caller(), &params)
                    .await,
                route,
                subsession: None,
            };
            let s = hub.new_session(req).await?;
            if conn.origin.web_class() {
                super::remote_guard::settle_web_session_mode(hub, &s).await?;
                // A dedicated agent VM (vmHost): a session its owner's peer
                // daemon starts with no policy runs approve-all; the VM is the
                // sandbox (hub/remote_sandbox.rs). Web clients still ask.
                let vm_host = hub.config.read().await.vm_host;
                if !asked_policy
                    && crate::hub::vm_host_peer_approves(
                        vm_host,
                        cfg!(target_os = "macos"),
                        super::remote_guard::control_of(conn.origin, conn.auth, &params)
                            == crate::hub::Control::Peer,
                    )
                {
                    hub.set_policy(&s, crate::config::PermissionPolicy::ApproveAll).await;
                }
            } else {
                hub.start_in_mode(conn.is_person(), conn.caller(), &params, &s, adopting).await?;
            }
            attach(hub, conn, &s.id);
            let meta = s.meta();
            Ok(json!({
                "sessionId": s.id,
                "modes": meta.modes,
                "configOptions": meta.config_options,
                "_meta": {"acpmux": hub.session_summary(&s)},
            }))
        }
        method::SESSION_LOAD | method::SESSION_RESUME => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            attach(hub, conn, &s.id);
            // Replay history as ACP updates, then answer.
            let events =
                hub.events(&s.id, 0, 100_000).map_err(|e| RpcError::internal(e.to_string()))?;
            for rec in events {
                if rec.dir == "mux" && rec.kind == "user_message" {
                    let text = rec.msg.get("text").and_then(Value::as_str).unwrap_or("");
                    conn.send(&Message::notification(
                        method::SESSION_UPDATE,
                        json!({"sessionId": s.id, "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}}, "_meta": {"acpmux": {"seq": rec.seq, "at": rec.at, "replay": true}}}),
                    ));
                } else if rec.dir == "in"
                    && !rec.kind.ends_with(".replay")
                    && rec.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE)
                {
                    let mut p = rec.msg.get("params").cloned().unwrap_or(json!({}));
                    p["sessionId"] = Value::String(s.id.clone());
                    crate::hub::merge_mux_meta(
                        &mut p,
                        json!({"seq": rec.seq, "at": rec.at, "kind": rec.kind, "replay": true}),
                    );
                    conn.send(&Message::notification(method::SESSION_UPDATE, p));
                }
            }
            let meta = s.meta();
            Ok(
                json!({"modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(&s)}}),
            )
        }
        method::SESSION_LIST => {
            let sessions: Vec<Value> = hub
                .all_session_summaries()
                .into_iter()
                .map(|s| {
                    json!({
                        "sessionId": s.get("sessionId").cloned().unwrap_or(Value::Null),
                        "cwd": s.get("cwd").cloned().unwrap_or(Value::Null),
                        "title": s.get("title").and_then(Value::as_str).map(str::to_owned).or_else(|| s.get("name").and_then(Value::as_str).map(str::to_owned)),
                        "updatedAt": iso(s.get("updatedAt").and_then(Value::as_u64).unwrap_or(0)),
                        "_meta": {"acpmux": s},
                    })
                })
                .collect();
            Ok(json!({"sessions": sessions}))
        }
        method::SESSION_PROMPT => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            attach(hub, conn, &s.id);
            let mut blocks = params
                .get("prompt")
                .and_then(Value::as_array)
                .cloned()
                .or_else(|| {
                    params
                        .get("text")
                        .and_then(Value::as_str)
                        .map(|t| vec![json!({"type": "text", "text": t})])
                })
                .ok_or_else(|| {
                    RpcError::invalid_params("prompt must be an array of content blocks")
                })?;
            // A remote web client may not hide text, directly or through a peer daemon.
            let web = super::remote_guard::control_of(conn.origin, conn.auth, &params)
                == crate::hub::Control::Web;
            crate::prompt_context::apply(mux_meta(&params), web, &mut blocks)?;
            let provenance = crate::prompt_provenance::of(&params, conn.origin == Origin::Local)?;
            let flag = |k| mux_meta(&params).and_then(|m| m.get(k)).and_then(Value::as_bool);
            let steer = flag("steer").or_else(|| params.get("steer").and_then(Value::as_bool));
            let steer = steer.unwrap_or(false);
            let prompt_id = mux_meta(&params)
                .and_then(|m| m.get("promptId"))
                .and_then(Value::as_str)
                .filter(|p| !p.is_empty())
                .map(str::to_owned);
            let notify = conn.clone();
            let opts = crate::hub::PromptOptions {
                prompt_id,
                on_accepted: Some(Box::new(move |v| {
                    notify.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v))
                })),
                resend: flag("resend") == Some(true),
                control: super::remote_guard::control_of(conn.origin, conn.auth, &params),
                trust_gate: super::trust_gate::gated(conn.origin, &params),
                steer_only: flag("steerOnly") == Some(true),
                interrupt: steer && flag("interrupt") == Some(true),
                provenance,
                after_turn: None,
            };
            hub.prompt_with(&s, blocks, &conn.label(), steer, opts).await
        }
        // ACP defines cancel as a notification; a client that sends it as a
        // request gets an empty result instead of a request forwarded to
        // the agent that never answers.
        method::SESSION_CANCEL => {
            let s = hub.resolve(session_key(&params)?)?;
            if let Err(e) = hub.cancel(&s).await {
                tracing::debug!(conn = %conn.id, "cancel: {e}");
            }
            Ok(json!({}))
        }
        method::SESSION_FORK => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let cwd = str_param(&params, "cwd").map(PathBuf::from);
            let name = mux_meta(&params)
                .and_then(|m| m.get("name"))
                .and_then(Value::as_str)
                .or_else(|| params.get("name").and_then(Value::as_str))
                .map(str::to_owned);
            let env = crate::session_env::parse(mux_meta(&params))?;
            let workspace_id = crate::session_env::workspace_id(mux_meta(&params), &env)?;
            let through = super::fork_through::through(&params);
            let new = hub.fork(&s, name, cwd, env, workspace_id, through).await?;
            attach(hub, conn, &new.id);
            let meta = new.meta();
            Ok(
                json!({"sessionId": new.id, "modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(&new)}}),
            )
        }
        method::SESSION_SET_MODE => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let mode = str_param(&params, "modeId")
                .ok_or_else(|| RpcError::invalid_params("modeId is required"))?;
            // The app pane's mode pick is saved for the next new chat (start_mode.rs).
            hub.client_set_mode(&s, mode, conn.origin == Origin::LocalApp).await
        }
        method::SESSION_SET_CONFIG_OPTION => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let id = str_param(&params, "configId")
                .ok_or_else(|| RpcError::invalid_params("configId is required"))?;
            let value = params
                .get("value")
                .cloned()
                .ok_or_else(|| RpcError::invalid_params("value is required"))?;
            // The app pane's effort pick is saved for the next new chat (start_defaults.rs).
            hub.client_set_config(&s, id, value, conn.origin == Origin::LocalApp).await
        }
        method::SESSION_SET_MODEL => {
            let s = hub.resolve(session_key(&params)?)?;
            let model = str_param(&params, "modelId")
                .ok_or_else(|| RpcError::invalid_params("modelId is required"))?;
            // The app pane's model pick is saved for the next new chat (start_defaults.rs).
            hub.client_set_model(&s, model, conn.origin == Origin::LocalApp).await
        }
        method::MUX_SET_TOOLS => hub.set_tools(&hub.resolve(session_key(&params)?)?, &params).await,
        method::SESSION_CLOSE => {
            let s = hub.resolve(session_key(&params)?)?;
            hub.kill(&s, false).await?;
            Ok(json!({}))
        }
        method::SESSION_DELETE => {
            let s = hub.resolve(session_key(&params)?)?;
            hub.kill(&s, true).await?;
            Ok(json!({}))
        }
        // ------------------------------------------------ acpmux extensions
        method::MUX_STATUS => Ok(hub.status().await),
        method::MUX_SESSIONS => {
            crate::hub::session_pages::session_list_reply(hub.all_session_summaries(), &params)
        }
        method::MUX_WEB_MODES => hub.web_modes_view(&params),
        method::MUX_WEB_TOKEN_ROTATE => hub.rotate_web_token().await,
        method::MUX_WARM => {
            let requested: Vec<String> = params
                .get("sessionIds")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            let limit =
                params.get("limit").and_then(Value::as_u64).unwrap_or(3).clamp(1, 8) as usize;
            let warmed = hub.warm_sessions(&requested, limit).await;
            Ok(json!({"warmed": warmed}))
        }
        method::MUX_PREWARM => {
            let s = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_owned);
            hub.prewarm(crate::hub::PrewarmRequest {
                harness: s("harness"),
                preset: s("preset"),
                cwd: s("cwd").map(PathBuf::from),
                wait: params.get("wait").and_then(Value::as_bool) == Some(true),
                // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
                remote: conn.origin.web_class(),
                trust_gate: super::trust_gate::gated(conn.origin, &params),
            })
            .await
        }
        // Read only. A connection asks for its own context: a remote-origin
        // one (Web, Peer) gets the answer its own session/new would get,
        // which sets no start mode.
        method::MUX_START_MODE => {
            let s = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_owned);
            hub.start_mode_answer(
                s("harness"),
                s("preset"),
                s("cwd").map(PathBuf::from),
                conn.origin.web_class(),
            )
            .await
        }
        "_acpmux/set_default_policy" => {
            let policy: PermissionPolicy = str_param(&params, "policy")
                .ok_or_else(|| RpcError::invalid_params("policy is required"))?
                .parse()
                .map_err(RpcError::invalid_params)?;
            let mut cfg = hub.config.write().await;
            cfg.permission_policy = policy;
            hub.permission_defaults_changed();
            cfg.save().map_err(|e| RpcError::internal(format!("save permission policy: {e}")))?;
            Ok(json!({"policy":policy.to_string()}))
        }
        "_acpmux/peers" => Ok(json!({"peers": hub.peers()})),
        "_acpmux/directories" => {
            let home = dirs::home_dir().unwrap_or_default();
            let base = str_param(&params, "cwd").map(PathBuf::from).unwrap_or_else(|| home.clone());
            let value = str_param(&params, "path").unwrap_or("");
            let path = crate::tui::directory::resolve(&base, value, &home, None)
                .map_err(|e| RpcError::invalid_params(e.to_string()))?;
            let result = tokio::task::spawn_blocking(move || -> Result<Value, std::io::Error> {
                let path = std::fs::canonicalize(path)?;
                if !path.is_dir() { return Err(std::io::Error::other("not a directory")); }
                let children = crate::tui::directory::children(&path);
                Ok(json!({"path": path, "parent": path.parent(), "home": home, "directories": children}))
            }).await.map_err(|e| RpcError::internal(e.to_string()))?.map_err(|e| RpcError::invalid_params(e.to_string()))?;
            Ok(result)
        }
        "_acpmux/models" => {
            // `probe`: harnesses a client now uses (the Chief's engine set),
            // probed now even when the start-time list left them out.
            if let Some(names) = params.get("probe").and_then(Value::as_array) {
                let names: std::collections::BTreeSet<String> =
                    names.iter().filter_map(Value::as_str).map(str::to_owned).collect();
                if !names.is_empty() {
                    hub.allow_probes(names).await;
                }
            }
            if params.get("refresh").and_then(Value::as_bool).unwrap_or(false) {
                hub.refresh_models().await;
            }
            let mut cat = hub.models_catalog().await;
            // Remote harnesses, labelled peer/agent, from each connected peer.
            for peer in hub.connected_peers() {
                if let Ok(remote) = peer.request("_acpmux/models", json!({})).await
                    && let Some(hs) = remote.get("harnesses").and_then(Value::as_array)
                {
                    for h in hs {
                        let mut h = h.clone();
                        let agent =
                            h.get("harness").and_then(Value::as_str).unwrap_or("").to_owned();
                        h["harness"] = Value::String(format!("{}/{}", peer.name, agent));
                        h["peer"] = Value::String(peer.name.clone());
                        h["isDefault"] = Value::Bool(false);
                        if let Some(arr) = cat.get_mut("harnesses").and_then(Value::as_array_mut) {
                            arr.push(h);
                        }
                    }
                }
            }
            Ok(cat)
        }
        crate::catalog::RPC_GET => Ok(hub.catalog.get()),
        crate::catalog::RPC_REFRESH => Ok(hub.catalog.refresh(false).await),
        "_acpmux/peer_add" => {
            hub.add_peer_from(&params).await?;
            Ok(json!({"peers": hub.peers()}))
        }
        "_acpmux/peer_reconnect" => {
            let name = str_param(&params, "name")
                .ok_or_else(|| RpcError::invalid_params("name is required"))?;
            let wait = params.get("wait").and_then(Value::as_bool).unwrap_or(false);
            hub.reconnect_peer(name, wait).await?;
            Ok(json!({"peers": hub.peers()}))
        }
        "_acpmux/peer_remove" => {
            let name = str_param(&params, "name")
                .ok_or_else(|| RpcError::invalid_params("name is required"))?;
            hub.remove_peer(name).await?;
            Ok(json!({"peers": hub.peers()}))
        }
        method::MUX_HARNESSES => hub.harnesses_reply(&params, conn.origin.web_class()).await,
        method::MUX_RELOAD_CONFIG => hub.reload_catalog().await,
        // Read or change family defaults: {family?, set?: {...}, clear?: bool}.
        method::MUX_DEFAULTS => {
            let family = str_param(&params, "family").map(str::to_owned);
            let set = params.get("set").filter(|v| v.is_object());
            let clear = params.get("clear").and_then(Value::as_bool).unwrap_or(false);
            if set.is_some() || clear {
                let family = family.clone().ok_or_else(|| {
                    RpcError::invalid_params("family is required to change defaults")
                })?;
                let mut cfg = hub.config.write().await;
                if clear {
                    cfg.defaults.remove(&family);
                } else if let Some(set) = set {
                    let patch: crate::config::SessionDefaults = serde_json::from_value(set.clone())
                        .map_err(|e| RpcError::invalid_params(format!("defaults: {e}")))?;
                    let entry = cfg.defaults.entry(family.clone()).or_default();
                    let mut merged = entry.clone();
                    // A JSON null clears one field.
                    for (k, v) in set.as_object().unwrap() {
                        if v.is_null() {
                            match k.as_str() {
                                "model" => merged.model = None,
                                "effort" => merged.effort = None,
                                "policy" => merged.policy = None,
                                "prefer" => merged.prefer.clear(),
                                "env" => merged.env.clear(),
                                _ => {}
                            }
                        }
                    }
                    if patch.model.is_some() {
                        merged.model = patch.model;
                    }
                    if patch.effort.is_some() {
                        merged.effort = patch.effort;
                    }
                    if patch.policy.is_some() {
                        merged.policy = patch.policy;
                    }
                    if !patch.prefer.is_empty() {
                        merged.prefer = patch.prefer;
                    }
                    for (k, v) in patch.env {
                        merged.env.insert(k, v);
                    }
                    if merged.is_empty() {
                        cfg.defaults.remove(&family);
                    } else {
                        *entry = merged;
                    }
                }
                if let Err(e) = cfg.save() {
                    return Err(RpcError::internal(format!("save config: {e}")));
                }
            }
            let cfg = hub.config.read().await;
            let mut resolved = serde_json::Map::new();
            let fams = cfg.families();
            for f in fams.keys().chain(cfg.defaults.keys()) {
                if resolved.contains_key(f) {
                    continue;
                }
                let (profile, error) = match cfg.resolve_harness(f) {
                    Ok(p) => (Some(p), None),
                    Err(e) => (None, Some(e)),
                };
                let d = profile.as_deref().map(|p| cfg.defaults_for(p)).unwrap_or_default();
                let kind = if fams.contains_key(f) {
                    "family"
                } else if cfg.harnesses.contains_key(f) {
                    "profile"
                } else {
                    "unused"
                };
                resolved.insert(f.clone(), json!({"kind": kind, "profile": profile, "error": error, "profiles": fams.get(f).cloned().unwrap_or_default(), "model": d.model, "effort": d.effort, "policy": d.policy, "prefer": d.prefer, "env": d.env}));
            }
            match family {
                Some(f) => Ok(resolved
                    .get(&f)
                    .cloned()
                    .unwrap_or(json!({"profile": null, "profiles": []}))),
                None => Ok(json!({"families": resolved, "defaults": cfg.defaults})),
            }
        }
        // Read or change presets (`requests/presets.rs`).
        method::MUX_PRESETS => presets::handle(hub, conn, &params).await,
        method::MUX_INFO => {
            let s = hub.resolve(session_key(&params)?)?;
            let mut detail = hub.session_detail(&s);
            // The session env reaches the unix socket only: no summary or
            // event carries it, so a key added to the allowlist later never
            // reaches another origin by default (session_env.rs).
            if conn.origin == Origin::Local
                && let Some(obj) = detail.as_object_mut()
            {
                obj.insert(
                    "sessionEnv".into(),
                    json!(crate::session_env::shown(&s.meta().session_env)),
                );
            }
            Ok(detail)
        }
        method::MUX_WAIT => wait::wait(hub, &params).await,
        method::MUX_SCHEMA => {
            Ok(serde_json::from_str(crate::schema::SCHEMA).unwrap_or(Value::Null))
        }
        method::MUX_HISTORY => {
            let s = hub.resolve(session_key(&params)?)?;
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            Ok(json!({"sessionId": s.id, "turns": hub.history(&s, limit)}))
        }
        m if composer::handles(m) => composer::handle(hub, conn, m, &params).await,
        method::MUX_TAG => {
            let s = hub.resolve(session_key(&params)?)?;
            let remove: Vec<String> = params
                .get("remove")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            hub.set_tags(
                &s,
                params.get("set").and_then(Value::as_object),
                &remove,
                params.get("ttlSeconds").and_then(Value::as_u64),
            );
            Ok(hub.session_summary(&s))
        }
        // One tag with one value, so a page relay can allow it without
        // reading tag names (`_acpmux/tag` may set any tag).
        method::MUX_ARCHIVE => {
            let s = hub.resolve(session_key(&params)?)?;
            let archived = params
                .get("archived")
                .and_then(Value::as_bool)
                .ok_or_else(|| RpcError::invalid_params("archived must be true or false"))?;
            if archived {
                let mut set = serde_json::Map::new();
                set.insert(ARCHIVED_TAG.into(), Value::String(crate::store::now_ms().to_string()));
                hub.set_tags(&s, Some(&set), &[], None);
            } else {
                hub.set_tags(&s, None, &[ARCHIVED_TAG.to_owned()], None);
            }
            Ok(hub.session_summary(&s))
        }
        // One tag with a session as its value: never another tag (`_acpmux/tag`).
        method::MUX_SIDE => {
            let s = hub.resolve(session_key(&params)?)?;
            let chat = params.get("chat").and_then(Value::as_str).ok_or_else(|| {
                RpcError::invalid_params("chat (the side chat's chat) is required")
            })?;
            // The exact session id, never a name or a prefix.
            let chat = hub.resolve(chat).ok().filter(|c| c.id == chat).ok_or_else(|| {
                RpcError::not_found(format!("no chat with the session id {chat:?}"))
            })?;
            if chat.id == s.id {
                return Err(RpcError::invalid_params("a chat is not its own side chat"));
            }
            let mut set = serde_json::Map::new();
            set.insert(SIDE_TAG.into(), Value::String(chat.id.clone()));
            hub.set_tags(&s, Some(&set), &[], None);
            Ok(hub.session_summary(&s))
        }
        method::MUX_HARNESS_ENABLE => {
            super::harness_enable::handle(hub, conn.origin, &params).await
        }
        name if super::harness_admin::METHODS.contains(&name) => {
            super::harness_admin::handle(hub, conn.origin, name, &params).await
        }
        method::MUX_ROUTE_LIST
        | method::MUX_ROUTE_SHOW
        | method::MUX_ROUTE_ADD
        | method::MUX_ROUTE_EDIT
        | method::MUX_ROUTE_REMOVE
        | method::MUX_ROUTE_RESTORE
        | method::MUX_ROUTE_TEST
        | method::MUX_ROUTE_DEFAULT_SET
        | method::MUX_CHAT_ROUTE_SET => super::routes::handle(hub, conn.origin, m, &params).await,
        method::ACP_TRUST_GET | method::ACP_TRUST_SET => {
            super::trust_gate::answer(hub, m, &params).await
        }
        method::MUX_SET_RULES => {
            let s = hub.resolve(session_key(&params)?)?;
            let rules = params.get("rules").cloned().filter(|r| !r.is_null());
            if let Some(r) = &rules {
                crate::hub::rules::validate(r).map_err(RpcError::invalid_params)?;
            }
            hub.set_rules(&s, rules);
            Ok(hub.session_summary(&s))
        }
        method::MUX_ATTACH => {
            let s = hub.resolve(session_key(&params)?)?;
            let filter = crate::hub::EventFilter::parse(params.get("kinds"))?;
            let event_stream = params.get("eventStream").and_then(Value::as_bool).unwrap_or(false);
            let hidden = params.get("visible") == Some(&Value::Bool(false));
            view::attach(hub, conn, &s, SubOpts { event_stream, filter: filter.clone(), hidden });
            let after = params.get("afterSeq").and_then(Value::as_u64);
            let before = params.get("beforeSeq").and_then(Value::as_u64);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(2000) as usize;
            let max_bytes = params.get("maxBytes").and_then(Value::as_u64).map(|b| b as usize);
            let detail = hub.session_detail(&s);
            // afterSeq alone pages forward (oldest first); otherwise the page
            // is the newest `limit` records before beforeSeq (or the end).
            let newest = after.is_none() || before.is_some();
            let page = hub
                .events_page(&s.id, after.unwrap_or(0), before, limit, max_bytes, newest, &filter)
                .map_err(|e| RpcError::internal(e.to_string()))?;
            let events: Vec<Value> = page.events.iter().map(|r| event_value(&s.id, r)).collect();
            Ok(
                json!({"session": detail, "events": events, "hasMore": page.has_more, "lastSeq": s.meta().last_seq}),
            )
        }
        method::MUX_DETACH => {
            view::detach(hub, conn, &*hub.resolve(session_key(&params)?)?);
            Ok(json!({}))
        }
        method::MUX_VIEW => view::view(hub, conn, &params),
        method::MUX_MARK_UNREAD => view::mark_unread(hub, &params),
        method::MUX_HARNESS_INVENTORY_WATCH => super::inventory_watch::handle(hub, conn, &params),
        method::MUX_WATCH => {
            let on = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
            conn.watch_all.store(on, Ordering::SeqCst);
            crate::hub::session_pages::session_list_reply(hub.all_session_summaries(), &params)
        }
        method::MUX_EVENTS | method::MUX_ATTACHMENT => events::handle(hub, m, &params),
        method::MUX_MAIL_SEND
        | method::MUX_MAIL_READ
        | method::MUX_MAIL_WAIT
        | method::MUX_MAIL_ACK => mailbox::handle(hub, conn, m, &params).await,
        method::MUX_RENAME => {
            let s = hub.resolve(session_key(&params)?)?;
            let name = str_param(&params, "newName")
                .or_else(|| str_param(&params, "to"))
                .ok_or_else(|| RpcError::invalid_params("newName is required"))?;
            crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
            hub.rename(&s, name.to_owned()).await?;
            Ok(hub.session_summary(&s))
        }
        method::MUX_KILL => {
            let s = hub.resolve(session_key(&params)?)?;
            let purge = params.get("purge").and_then(Value::as_bool).unwrap_or(false);
            hub.kill(&s, purge).await?;
            Ok(json!({"sessionId": s.id, "purged": purge}))
        }
        method::MUX_QUEUE_EDIT => {
            let s = hub.resolve(session_key(&params)?)?;
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            // A peer read the prompt masked (`peer_text.rs`): it may move or send one
            // with a secret, not rewrite it.
            if super::peer_text::masks(conn.origin)
                && str_param(&params, "op") == Some("update")
                && hub.queued_holds_secret(&s, str_param(&params, "promptId").unwrap_or_default())
            {
                return Err(RpcError::invalid_params(
                    "this queued prompt holds a masked secret: edit it on the machine that runs the session",
                ));
            }
            hub.queue_edit(&s, &params, control, super::trust_gate::gated(conn.origin, &params))
                .await
        }
        method::MUX_QUEUE_REMOVE => {
            let s = hub.resolve(session_key(&params)?)?;
            let prompt_id = str_param(&params, "promptId")
                .ok_or_else(|| RpcError::invalid_params("promptId is required"))?;
            let removed = hub.withdraw_queued(&s, prompt_id)?;
            Ok(json!({"sessionId": s.id, "promptId": prompt_id, "removed": removed}))
        }
        method::MUX_PROMPT_WITHDRAW => {
            // The unix socket only; `remote_guard.rs` refuses every other origin first.
            if conn.origin != Origin::Local {
                return Err(crate::prompt_provenance::withdraw_origin_refused());
            }
            let s = hub.resolve(session_key(&params)?)?;
            hub.prompt_withdraw(&s, &params).await
        }
        method::MUX_PERMISSION_GROUPS => {
            let s = hub.resolve(session_key(&params)?)?;
            hub.permission_groups(&s, &params)
        }
        method::MUX_PERMISSION_GROUP_RESPOND => {
            let s = hub.resolve(session_key(&params)?)?;
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            hub.respond_permission_group(&s, params, control).await
        }
        method::MUX_PERMISSION_CHAT_REVOKE => {
            let s = hub.resolve(session_key(&params)?)?;
            Ok(hub.revoke_permission_chat(&s))
        }
        method::MUX_PERMISSION_RESPOND => {
            let s = hub.resolve(session_key(&params)?)?;
            let pid = str_param(&params, "permissionId")
                .ok_or_else(|| RpcError::invalid_params("permissionId is required"))?;
            let option = str_param(&params, "optionId").map(str::to_owned);
            let answers = params.get("answers").cloned();
            let answered_by = crate::hub::person::answered_by(&params)?;
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            // Who answers, for the person rule under the prompt's lock
            // (`hub/person.rs`): an allow that is not the person's counts
            // only on its decision proof, which the answer spends.
            let answerer = crate::hub::person::Answerer::of(conn.is_person(), &params);
            hub.respond_permission(&s, pid, option, answers, answered_by, answerer, control)
                .await?;
            Ok(json!({}))
        }
        method::MUX_SET_POLICY => {
            let s = hub.resolve(session_key(&params)?)?;
            let policy: PermissionPolicy = str_param(&params, "policy")
                .ok_or_else(|| RpcError::invalid_params("policy is required"))?
                .parse()
                .map_err(RpcError::invalid_params)?;
            hub.set_policy_unless_moving(&s, policy).await?;
            Ok(hub.session_summary(&s))
        }
        method::MUX_EXPORT => {
            let s = hub.resolve(session_key(&params)?)?;
            let dest = str_param(&params, "dest")
                .map(PathBuf::from)
                .unwrap_or_else(|| crate::config::home().join("bundles"));
            let path = hub.export(&s, &dest).map_err(|e| RpcError::internal(e.to_string()))?;
            Ok(json!({"path": path}))
        }
        method::MUX_IMPORT => {
            let path = str_param(&params, "path")
                .map(PathBuf::from)
                .ok_or_else(|| RpcError::invalid_params("path is required"))?;
            let name = str_param(&params, "name").map(str::to_owned);
            let s = hub.import(&path, name).await?;
            attach(hub, conn, &s.id);
            Ok(hub.session_summary(&s))
        }
        method::MUX_SHUTDOWN => {
            // `endAgents: true` (the app's Quit Everything) ends agents that
            // run under agent hosts; otherwise they keep running for the next
            // daemon.
            // `keepSessions` (session ids) keeps those sessions' hosted agents
            // running even then (the app's Home Chief).
            let end_agents = params.get("endAgents").and_then(Value::as_bool) == Some(true);
            let keep: std::collections::HashSet<String> = params
                .get("keepSessions")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            if end_agents {
                hub.end_agents_at_shutdown(keep.clone())?;
            }
            hub.stop_idle_reaper();
            hub.shutdown.notify_waiters();
            hub.shutdown.notify_one();
            let kept = if end_agents {
                keep.iter().filter(|id| hub.resolve(id).is_ok()).count()
            } else {
                0
            };
            Ok(json!({"endAgents": end_agents, "keptSessions": kept}))
        }
        method::MUX_HANDOFF_PREPARE => hub.handoff_prepare(&params, conn.origin.web_class()).await,
        method::MUX_HANDOFF_GET => hub.handoff_get(&params),
        method::MUX_HANDOFF_DRAFT => hub.handoff_draft(&params).await,
        method::MUX_HANDOFF_START => {
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            hub.handoff_start(&params, control).await
        }
        method::MUX_HANDOFF_DISCARD => hub.handoff_discard(&params).await,
        // Anything else that names a session goes to the agent untouched, from the unix
        // socket (the app: only a subagent stop); it may spawn or read (`remote_guard.rs`).
        other => {
            if !super::remote_guard::forwards(conn.origin, other) && session_key(&params).is_ok() {
                return Err(RpcError::invalid_params(format!(
                    "{other} is passed to the harness only from the local unix socket"
                )));
            }
            if let Ok(key) = session_key(&params) {
                let s = hub.resolve(key)?;
                crate::hub::person::harness_forward_check(conn.is_person(), other)?;
                return hub.forward(&s, other, params).await;
            }
            Err(RpcError::method_not_found(other))
        }
    }
}
