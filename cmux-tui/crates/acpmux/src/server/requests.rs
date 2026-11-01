//! Request and notification handlers for one client connection.

use super::*;
use crate::no_panic::JsonExt;
use crate::no_panic::LockExt;

mod briefs;
pub(super) mod cancel_refused;
mod composer;
mod events;
mod info;
#[path = "requests/mailbox.rs"]
mod mailbox;
pub(super) mod person_stop;
mod presets;
mod queued;
mod session_open;
pub use session_open::FEATURE as SESSION_RESUME_FEATURE;
mod successor;
mod turn_opener;
#[path = "watches.rs"]
mod watches;

/// `_meta.acpmux.disallowedTools`: Claude Code built-in tools the new chat
/// never gets (`acpmux new --worktree` sends `["AskUserQuestion"]`). Each is
/// a tool's name, letters, digits and `_`, so none is a permission rule
/// (`Bash(rm *)`) or a flag; it only takes tools away, from any origin.
fn disallowed_tools(meta: Option<&Value>) -> Result<Vec<String>, RpcError> {
    let refused = || RpcError::invalid_params("disallowedTools must be a list of tool names");
    match meta.and_then(|m| m.get("disallowedTools")) {
        None | Some(Value::Null) => Ok(Vec::new()),
        Some(Value::Array(names)) => names
            .iter()
            .map(|n| {
                n.as_str()
                    .filter(|n| {
                        !n.is_empty() && n.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                    })
                    .map(str::to_owned)
                    .ok_or_else(refused)
            })
            .collect(),
        Some(_) => Err(refused()),
    }
}

/// A create's admission ask (`hub/admission.rs`): `_meta.acpmux.forceAdmit`
/// (`acpmux new --force-admit`), and whether the person asks here (proven, or
/// this host's app pane; a peer's `via: app` is its client's word, not proof).
pub(super) fn ask<'a>(conn: &Conn, params: &Value, who: &'a str) -> crate::hub::admission::Ask<'a> {
    let can_force = can_force(conn.origin);
    let force = can_force && force_asked(params);
    let person = person_asks(conn);
    // A Web client, here or through a peer, learns no host name or path.
    let web =
        super::remote_guard::control_of(conn.origin, conn.auth, params) == crate::hub::Control::Web;
    let name = create_name(params);
    // A peer daemon's connection never learns this host's peers (`redact::hide_peers_from_peer`).
    let peers = conn.origin != Origin::Peer;
    crate::hub::admission::Ask { force, can_force, person, who, local: !web, peers, name }
}

/// A peer request's `reply` with what its `wait` saw (`Hub::wait_for_peer`) as `wait`; none
/// without one.
fn with_wait(mut reply: Value, waited: Value) -> Value {
    if !waited.is_null() {
        reply.set("wait", waited);
    }
    reply
}

/// Whether the person asks on `conn`: it proved it is the person, or it is this host's app pane (a
/// peer's `via: app` is its client's word, not proof). The admission's `person` and a chat's
/// `Session::person` (its start waits as long as its harness works, `hub/lifecycle.rs`).
pub(super) fn person_asks(conn: &Conn) -> bool {
    conn.is_person() || conn.origin == Origin::LocalApp
}

/// The create's name, as `session/new` and `session/fork` read it.
fn create_name(params: &Value) -> Option<String> {
    mux_meta(params)
        .and_then(|m| m.get("name"))
        .and_then(Value::as_str)
        .or_else(|| params.get("name").and_then(Value::as_str))
        .map(str::to_owned)
}

/// `_meta.acpmux.forceAdmit` is true.
pub(super) fn force_asked(params: &Value) -> bool {
    mux_meta(params)
        .and_then(|m| m.get(crate::hub::admission::FORCE_FIELD))
        .and_then(Value::as_bool)
        == Some(true)
}

/// Whether this connection's `forceAdmit` is honoured: this host's unix socket
/// or app, as for `--policy` and `--mode`; a Web client's or a peer's is not.
pub(super) fn can_force(origin: Origin) -> bool {
    !origin.web_class()
}

/// Who asks, for the admission log: the proven caller session, else the
/// connection's origin and id.
pub(super) fn who(conn: &Conn) -> String {
    match conn.caller() {
        Some(session) => format!("session {session}"),
        None => format!("{:?} connection {}", conn.origin, conn.id),
    }
}

/// Subscribe the connection to a session and, when that is new, count it
/// as attached (remote sessions are not counted; their host does that).
pub(super) fn attach(hub: &Hub, conn: &Conn, id: &str) {
    let resolved = hub.resolve(id).ok();
    match &resolved {
        Some(s) => view::subscribe_local(hub, conn, s),
        None => {
            conn.subscribe(id);
        }
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
            // the same origin/ownership boundary as request-form cancels,
            // the VM boundary's owner rule included (`hub/vm_boundary.rs`).
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            let sent = params.get("sessionId").cloned().unwrap_or(Value::Null);
            if let Err(e) = hub.refuse_at_vm_boundary(conn.auth, control, m, &mut params) {
                return cancel_refused::tell(hub, conn, &sent, &e);
            }
            let device = super::remote_guard::full_access_device(hub, conn, &params);
            if conn.origin != Origin::Local
                && let Err(e) = super::remote_guard::check(
                    hub,
                    conn.origin,
                    conn.auth,
                    device.as_deref(),
                    m,
                    &mut params,
                    false,
                )
                .await
            {
                return cancel_refused::tell(hub, conn, &sent, &e);
            }
            // Again after the guard's awaits (`hub/vm_boundary.rs`).
            if let Err(e) = hub.refuse_at_vm_boundary(conn.auth, control, m, &mut params) {
                return cancel_refused::tell(hub, conn, &sent, &e);
            }
            if let Ok(key) = session_key(&params) {
                if let Ok(s) = hub.resolve(key) {
                    conn.cancel_preparation(&s.id);
                    s.abandon_prepared_connection(&conn.id);
                    // The person's Stop holds the agents' messages behind it (`hub/cancel.rs`),
                    // a peer's person's too (`person_stop.rs`).
                    if let Err(e) = person_stop::stop(hub, conn, &params, &s).await {
                        tracing::debug!(conn = %conn.id, "cancel: {e}");
                    }
                } else if let Some((peer, id, row)) = hub.resolve_remote(key) {
                    let turn = cancel_refused::row_turn(&row);
                    let mut forwarded = json!({"sessionId": id});
                    super::remote_guard::mark_forwarded(
                        conn.origin,
                        conn.auth,
                        &params,
                        &mut forwarded,
                    );
                    person_stop::mark(conn, &params, &peer, &mut forwarded);
                    cancel_refused::forward(conn, peer, key, turn, forwarded).await;
                }
            }
        }
        method::CANCEL_REQUEST => {}
        _ => tracing::debug!(conn = %conn.id, "ignored notification {m}"),
    }
}

fn dispatch_text(params: &Value) -> Result<String, RpcError> {
    let text = params
        .get("brief")
        .or_else(|| params.get("text"))
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("dispatch requires brief text"))?;
    if text.trim().is_empty() {
        return Err(RpcError::invalid_params("brief text is empty"));
    }
    if text.len() > 1_000_000 {
        return Err(RpcError::invalid_params("brief exceeds 1 MB"));
    }
    Ok(text.to_owned())
}

fn dispatch_name(params: &Value, brief: &str) -> String {
    let title = params
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_else(|| brief.lines().next().unwrap_or("dispatch"));
    let mut out = title
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_lowercase() } else { '-' })
        .collect::<String>();
    out = out.trim_matches('-').chars().take(60).collect();
    if out.is_empty() {
        let uuid = uuid::Uuid::now_v7().to_string();
        out = format!("dispatch-{}", uuid.get(..8).unwrap_or(&uuid));
    }
    out
}

fn peer_approve_all_allowed(
    policy: Option<&str>,
    preset_policy: Option<PermissionPolicy>,
    approved: bool,
) -> bool {
    policy != Some("approve-all")
        || (approved && preset_policy == Some(PermissionPolicy::ApproveAll))
}

/// `dispatch --host auto`: the placement engine's pick for the brief
/// (`server/place.rs`), `None` for this machine, or why no host has room.
async fn auto_host(hub: &Arc<Hub>, brief: &str) -> Result<Option<String>, String> {
    let v = super::place::pick(hub, super::place::brief_work(brief)).await;
    let why = v.get("why").and_then(Value::as_str).unwrap_or_default().to_owned();
    match v.get("pick").and_then(Value::as_str) {
        Some(_) if v.get("local").and_then(Value::as_bool) == Some(true) => Ok(None),
        Some(name) => Ok(Some(name.to_owned())),
        None => Err(why),
    }
}

/// A dispatch's `host` that is this machine: `auto`, `local`, or its own name.
fn names_this_host(host: &str) -> bool {
    use crate::placement::canonical;
    matches!(host, "auto" | "local") || canonical(host) == canonical(crate::hub::host_label())
}

/// A replayed brief row as `conn` may see it. A peer daemon's connection gets only a brief this
/// host ran (`Hub::brief_ran_here`), without `suggestedHost`, a peer of this host. A row a peer
/// ran names that peer in `host`, `target` and `to`: its id or key is refused as taken, the
/// answer whichever peer ran it.
fn brief_for(hub: &Hub, conn: &Conn, mut row: Value) -> Result<Value, RpcError> {
    if conn.origin != Origin::Peer {
        return Ok(row);
    }
    if !hub.brief_ran_here(&row) {
        return Err(RpcError::invalid_params(
            "another brief has this briefId or idempotencyKey; dispatch with new ones",
        )
        .with_data(json!({"reason": "dispatch.brief_taken"})));
    }
    if let Some(obj) = row.as_object_mut() {
        obj.remove("suggestedHost");
    }
    Ok(row)
}

async fn dispatch_brief(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mut params: Value,
) -> Result<Value, RpcError> {
    if hub.briefs.load_failed() {
        return Err(RpcError::internal(
            "brief ledger is unreadable; repair $ACPMUX_HOME/briefs.json before dispatch",
        ));
    }
    let brief = dispatch_text(&params)?;
    let id = params
        .get("briefId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("brief-{}", uuid::Uuid::now_v7()));
    let idempotency = params
        .get("idempotencyKey")
        .or_else(|| params.get("idempotency_key"))
        .and_then(Value::as_str)
        .filter(|key| !key.is_empty());
    let selected = params
        .get("host")
        .or_else(|| params.get("target"))
        .and_then(Value::as_str)
        .unwrap_or("auto")
        .to_owned();
    let forwarded = params.get("forwarded").and_then(Value::as_bool) == Some(true);
    // A peer daemon's connection never learns this host's peers (`redact::hide_peers_from_peer`):
    // its brief runs on this host. `auto` weighs no peer, and any other host is refused with one
    // answer, whether this host has a peer of that name or not, up or down.
    let from_peer = conn.origin == Origin::Peer;
    if from_peer && !forwarded && !names_this_host(&selected) {
        return Err(RpcError::invalid_params(format!(
            "a peer's dispatch runs on this host only: host {selected:?} is not this host; pass host \"local\" or \"auto\""
        ))
        .with_data(json!({"reason": "dispatch.peer_host"})));
    }
    // A retry of a brief already taken answers as before, whatever the placement rules now say
    // of a new lane on the host it names (`auto` finding no host, or `role_refusal`).
    let replay = || -> Option<Result<Value, RpcError>> {
        let existing = hub.briefs.existing(&id, idempotency)?;
        Some(brief_for(hub, conn, existing).map(|existing| {
            json!({"brief":existing,"event":crate::hub::dispatch::event("dispatch", &existing),"replayed":true})
        }))
    };
    let host = if forwarded || from_peer || selected == "local" {
        None
    } else if selected == "auto" {
        match auto_host(hub, &brief).await {
            Ok(host) => host,
            Err(why) => {
                if let Some(replayed) = replay() {
                    return replayed;
                }
                return Err(RpcError::not_found(format!(
                    "{why}; use --host HOST or connect a peer"
                )));
            }
        }
    } else {
        if let Some(why) = super::place::role_refusal(&selected, super::place::brief_work(&brief)) {
            if let Some(replayed) = replay() {
                return replayed;
            }
            return Err(RpcError::invalid_params(format!(
                "host {selected:?} is not allowed for this dispatch ({why}); `acpmux host place` lists the hosts that are"
            )));
        }
        Some(selected.clone())
    };
    if let Some(peer_name) = host {
        let peer = hub.peer_by_name(&peer_name).ok_or_else(|| {
            RpcError::not_found(format!(
                "no peer {peer_name:?}; run `acpmux host ls` and connect it"
            ))
        })?;
        if !peer.connected.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(RpcError::internal(format!(
                "peer {peer_name:?} is not connected; retry after it reconnects"
            )));
        }
        if let Some(existing) = hub.briefs.claim(&id, idempotency) {
            return Ok(
                json!({"brief":existing,"event":crate::hub::dispatch::event("dispatch", &existing),"replayed":true}),
            );
        }
        let original = params.clone();
        params.set("forwarded", json!(true));
        params.set("host", json!(peer_name));
        params.set("briefId", json!(id));
        params.set_path(&["_meta", "acpmux", "dispatchSource"], json!({
            "from": conn.caller().map(|id| hub.session_name(id)).unwrap_or_else(|| conn.label()),
            "host": crate::host_pressure::host_name(),
        }));
        super::remote_guard::mark_forwarded(conn.origin, conn.auth, &original, &mut params);
        let result = match peer.request(method::MUX_DISPATCH, params).await {
            Ok(result) => result,
            Err(e) => {
                hub.briefs.release(&id);
                return Err(RpcError::internal(format!(
                    "dispatch to {peer_name} failed: {e}; recovery: reconnect the peer and retry"
                )));
            }
        };
        if let Some(row) = result.get("brief").cloned() {
            hub.briefs.put(row);
        }
        return Ok(result);
    }

    let title = params
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or_else(|| brief.lines().next().unwrap_or("dispatch"))
        .to_owned();
    let from = params
        .pointer("/_meta/acpmux/dispatchSource/from")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .unwrap_or_else(|| {
            conn.caller().map(|id| hub.session_name(id)).unwrap_or_else(|| conn.label())
        });
    let explicit_to = params.get("to").and_then(Value::as_str);
    let target_to = params.get("target").and_then(Value::as_str).filter(|target| *target != "auto");
    let to = explicit_to
        .or(target_to)
        .unwrap_or_else(|| if selected == "auto" { "local" } else { &selected })
        .to_owned();
    let stop = params
        .get("stopCondition")
        .or_else(|| params.get("stop_condition"))
        .and_then(Value::as_str)
        .unwrap_or("report when the task is complete")
        .to_owned();
    let name = dispatch_name(&params, &brief);
    let pick = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_owned);
    let (harness, model) = match (pick("harness"), pick("model")) {
        (Some(harness), model) => (Some(harness), model),
        (None, Some(model)) => {
            model.split_once('/').map_or((Some(model.clone()), None), |(harness, model)| {
                (Some(harness.to_owned()), Some(model.to_owned()))
            })
        }
        (None, None) => (None, None),
    };
    let mut new_params = json!({"mcpServers": [], "_meta": {"acpmux": {"name": name}}});
    if let Some(obj) = new_params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        for (key, value) in [
            ("harness", harness),
            ("preset", pick("preset")),
            ("model", model),
            ("effort", pick("effort")),
            ("policy", pick("policy")),
        ] {
            if let Some(value) = value {
                obj.insert(key.into(), json!(value));
            }
        }
        if let Some(via) = params.pointer("/_meta/acpmux/via") {
            obj.insert("via".into(), via.clone());
        }
    }
    if let Some(cwd) = pick("cwd") {
        new_params.set("cwd", json!(cwd));
    }
    let requested_approve_all = new_params
        .pointer("/_meta/acpmux/policy")
        .and_then(Value::as_str)
        .and_then(|policy| policy.parse::<PermissionPolicy>().ok())
        == Some(PermissionPolicy::ApproveAll);
    if conn.origin == Origin::Peer && requested_approve_all {
        let preset = new_params.pointer("/_meta/acpmux/preset").and_then(Value::as_str);
        let allowed = if let Some(preset) = preset {
            let cfg = hub.config.read().await;
            cfg.presets.get(preset).is_some_and(|p| {
                peer_approve_all_allowed(Some("approve-all"), p.policy, p.mode_approved())
            })
        } else {
            peer_approve_all_allowed(Some("approve-all"), None, false)
        };
        if !allowed {
            return Err(RpcError::new(
                -32000,
                "peer dispatch approve-all requires a person-approved preset",
            )
            .with_data(json!({
                "reason": "policy.denied",
                "recovery": "use an approved preset with policy=approve-all, or dispatch with policy=ask"
            })));
        }
    }
    if conn.origin != Origin::Local {
        super::remote_guard::check(
            hub,
            conn.origin,
            conn.auth,
            None,
            method::SESSION_NEW,
            &mut new_params,
            false,
        )
        .await?;
    }
    let remote_authenticated = conn.auth.authenticated()
        && super::remote_guard::control_of(conn.origin, conn.auth, &new_params)
            == crate::hub::Control::Web;
    hub.person_check(
        conn.is_person(),
        remote_authenticated,
        conn.caller(),
        !conn.origin.web_class(),
        method::SESSION_NEW,
        &new_params,
    )
    .await?;
    super::trust_gate::check(hub, conn.origin, method::SESSION_NEW, &new_params, None).await?;
    if let Some(existing) = hub.briefs.claim(&id, idempotency) {
        let existing = brief_for(hub, conn, existing)?;
        return Ok(
            json!({"brief":existing,"event":crate::hub::dispatch::event("dispatch", &existing),"replayed":true}),
        );
    }
    // A new lane that starts here is checked here too, whoever sent it (`place::here_refusal`);
    // a replay of a brief already taken (above) starts nothing and answers as before.
    if let Some(why) = super::place::here_refusal(super::place::brief_work(&brief)) {
        hub.briefs.release(&id);
        return Err(RpcError::invalid_params(format!(
            "this host is not allowed for this dispatch ({why}); `acpmux host place` lists the hosts that are"
        ))
        .with_data(json!({"reason": "dispatch.host_refused"})));
    }
    let created =
        match Box::pin(dispatch_request(hub, conn, method::SESSION_NEW, new_params, None)).await {
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
    let task_device = super::remote_guard::full_access_device(hub, conn, &prompt);
    tokio::spawn(async move {
        let mut blocks =
            vec![json!({"type":"text","text":prompt.get("text").cloned().unwrap_or(Value::Null)})];
        let web = super::trust_gate::for_web(task_conn.origin, &prompt);
        if let Err(error) = task_hub
            .prompt_with(
                &task_session,
                std::mem::take(&mut blocks),
                &task_conn.label(),
                false,
                crate::hub::PromptOptions {
                    control: super::remote_guard::control_of(
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
            let v = super::place::pick(hub, super::place::brief_work(&brief)).await;
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

/// The tag the chat lists hide a session by (webviews sessionList.ts `ARCHIVED_TAG`).
const ARCHIVED_TAG: &str = "archived";
// The tag that marks a side chat, valued with its chat's session (`hub/btw.rs`).
use crate::hub::SIDE_TAG;

/// An agent a remote device drives (its caller session's turn, or its last one, is a Web turn,
/// `hub/remote_floor.rs`) sends no files: not through `acpmux send --attach` from its shell, now
/// or queued (`--no-wait`), nor by uploading one, as `send_message` may not either
/// (`hub/subsession_send.rs`); nor does it cancel an upload. Refused before anything is saved,
/// sent, deleted or forwarded.
fn caller_sends_no_files(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Result<(), RpcError> {
    let Some(caller) = conn.caller() else { return Ok(()) };
    let blocks = match m {
        method::SESSION_PROMPT => params.get("prompt"),
        method::MUX_SEND_QUEUE => params.pointer("/request/prompt"),
        _ => None,
    };
    let files = blocks
        .and_then(Value::as_array)
        .is_some_and(|b| crate::attach::any(b) || crate::prompt_uploads::any(b));
    let upload = matches!(
        m,
        method::MUX_FILE_PUT
            | method::MUX_FILE_PUT_BEGIN
            | method::MUX_FILE_PUT_CHUNK
            | method::MUX_FILE_PUT_FINISH
            | method::MUX_FILE_PUT_CANCEL
    );
    if !(files || upload) {
        return Ok(());
    }
    match hub.resolve(caller) {
        Ok(caller) => hub.subsession_attach_check(&caller),
        Err(_) => Ok(()),
    }
}

/// Swap the bare session key of `m`'s params (`sessionId` or `session`; a send's
/// `request.sessionId`) for the route [`Hub::key_route`] finds. A method that names no session
/// or answers itself for a peer's session (`peer_forward.rs`) keeps its params as they are, and
/// so does `keep`, whose `sessionId` is an exact id this connection owns (`ephemeral.rs`).
fn route_bare_key(hub: &Arc<Hub>, m: &str, params: &mut Value) -> Result<(), RpcError> {
    let slot = if m == method::MUX_SEND_QUEUE {
        params.pointer_mut("/request/sessionId")
    } else if m != method::MUX_KEEP && super::peer_forward::names_a_session(m) {
        let field = ["sessionId", "session"].into_iter().find(|f| params[*f].is_string());
        field.and_then(|f| params.get_mut(f))
    } else {
        None
    };
    let Some(slot) = slot else { return Ok(()) };
    let Some(key) = slot.as_str() else { return Ok(()) };
    if let Some(route) = hub.key_route(key)? {
        *slot = Value::String(route);
    }
    Ok(())
}

pub(super) async fn handle_request(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    mut params: Value,
) -> Result<Value, RpcError> {
    if conn.is_trigger() && !m.starts_with("trigger/chat.") {
        return Err(RpcError::new(
            -32001,
            "trigger connection accepts trigger/chat operations only",
        ));
    }
    if matches!(
        m,
        method::TRIGGER_CHAT_ENSURE | method::TRIGGER_CHAT_SEND | method::TRIGGER_CHAT_STATUS
    ) {
        return super::trigger_chat::handle(hub, conn, m, params).await;
    }
    // Before forwarding: only the local connection's authenticated caller may attest itself.
    if m == method::MUX_TURN_ATTESTATION {
        let ask =
            crate::turn_attestation::request(&params, conn.caller(), conn.origin == Origin::Local)?;
        let hub = hub.clone();
        return tokio::task::spawn_blocking(move || {
            let identity = cmux_server::pairing::EnrolledIdentity::load_current()
                .map_err(|_| crate::turn_attestation::refused("turn_attestation.not_enrolled"))?;
            hub.issue_turn_attestation(&ask.session_id, &identity, ask.ttl_ms)
        })
        .await
        .map_err(|_| crate::turn_attestation::refused("turn_attestation.unavailable"))?;
    }
    // A bare name or prefix on this machine's socket names the one live session here or on a
    // peer; every check below reads the route it found (`hub/key_route.rs`).
    if conn.origin == Origin::Local {
        route_bare_key(hub, m, &mut params)?;
    }
    // The pane's fork through a turn is a session/fork, checked as one from
    // here on (`fork_through.rs`).
    let m = super::fork_through::as_session_fork(hub, m, &mut params).await?;
    // A request that is not the person's own, naming a session here at the VM
    // boundary, runs under the Web's rules from here on (`hub/vm_boundary.rs`).
    let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
    hub.refuse_at_vm_boundary(conn.auth, control, m, &mut params)?;
    // A policy raise the person proved in another machine's app, for a chat here: counted and
    // its challenge spent once, before any check reads it, and the change goes to that very
    // chat (`hub/person/policy_grant.rs`).
    let proved_chat = hub.take_person_policy(m, &params);
    let policy_proved = proved_chat.is_some();
    // A refused raise of a chat here carries a challenge the person's app can prove.
    let challenge = |e: RpcError, params: &Value| {
        hub.with_policy_challenge(
            m,
            params,
            &[super::remote_guard::POLICY_REFUSED, crate::hub::person::REASON],
            e,
        )
    };
    // Before anything runs or is forwarded to a peer (`remote_guard.rs`).
    if conn.origin != Origin::Local {
        let device = super::remote_guard::full_access_device(hub, conn, &params);
        super::remote_guard::check(
            hub,
            conn.origin,
            conn.auth,
            device.as_deref(),
            m,
            &mut params,
            policy_proved,
        )
        .await
        .map_err(|e| challenge(e, &params))?;
    }
    caller_sends_no_files(hub, conn, m, &params)?;
    // Only the person allows or widens what runs without asking (`hub/person.rs`): one
    // check, before the request runs or reaches a peer. Held to the Web's rules: a Web
    // connection, or a peer forwarding for its own Web client (`via: web`); a peer
    // forwarding its unix socket or app keeps the person rule.
    let remote_authenticated = conn.auth.authenticated()
        && super::remote_guard::control_of(conn.origin, conn.auth, &params)
            == crate::hub::Control::Web;
    let verdict = hub
        .person_check(
            conn.is_person() || policy_proved,
            remote_authenticated,
            conn.caller(),
            !conn.origin.web_class(),
            m,
            &params,
        )
        .await
        .map_err(|e| challenge(e, &params))?;
    // Again after the guard's awaits: a session that took the name meanwhile (`hub/vm_boundary.rs`).
    hub.refuse_at_vm_boundary(conn.auth, control, m, &mut params)?;
    let resolved = proved_chat
        .or_else(|| super::session_key(&params).ok().and_then(|key| hub.resolve(key).ok()));
    super::trust_gate::check(hub, conn.origin, m, &params, resolved.as_ref()).await?; // the folder-trust gate
    // A message's class is checked here, before a peer's prompt is forwarded: an older peer
    // ignores the field, and a send queued for later would fail only once it is delivered.
    match m {
        method::SESSION_PROMPT => {
            crate::prompt_class::declared(&params)?;
        }
        method::MUX_SEND_QUEUE => {
            if let Some(request) = params.get("request") {
                crate::prompt_class::declared(request)?;
            }
        }
        _ => {}
    }
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

#[cfg(unix)]
fn bundled_cli_is_executable(path: &std::path::Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn bundled_cli_is_executable(path: &std::path::Path) -> bool {
    path.is_file()
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
    if matches!(
        m,
        method::MUX_FILE_PUT_BEGIN
            | method::MUX_FILE_PUT_CHUNK
            | method::MUX_FILE_PUT_FINISH
            | method::MUX_FILE_PUT_CANCEL
            | method::MUX_FILE_PUT_STATUS
    ) && super::remote_guard::control_of(conn.origin, conn.auth, &params)
        == crate::hub::Control::Web
    {
        return crate::hub::file_uploads::web::handle(hub, m, params).await;
    }
    match m {
        method::MUX_MESH_CONTROL => super::mesh_control_send::handle(hub, conn, &params).await,
        // Boxed: dispatch_brief's future is large, and inline it widens every request's future
        // (a debug test thread's stack overflowed on an unrelated request).
        method::MUX_DISPATCH => Box::pin(dispatch_brief(hub, conn, params)).await,
        method::MUX_STEER => briefs::steer(hub, conn, params).await,
        method::MUX_BRIEFS => briefs::list(hub, conn, params).await,
        method::MUX_REPORT => briefs::report(hub, conn, params).await,
        method::MUX_TASK_NEW => briefs::task_new(hub, conn, params).await,
        method::MUX_TASKS => briefs::tasks(hub, conn, params).await,
        method::MUX_RESOLVE => {
            let names_hosts = conn.auth != ConnAuth::ReadOnlyDevice && conn.origin != Origin::Peer;
            if params.get("exactSessionId").and_then(Value::as_bool) == Some(true) {
                hub.locate_exact(
                    str_param(&params, "sessionId")
                        .or_else(|| str_param(&params, "query"))
                        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?,
                    names_hosts,
                )
            } else {
                hub.locate(
                    str_param(&params, "query")
                        .ok_or_else(|| RpcError::invalid_params("query is required"))?,
                    params.get("bead").and_then(Value::as_bool) == Some(true),
                    // A read-only machine reads what its session list shows (`pairing/read_only.rs`), and a
                    // peer daemon's connection never learns this host's peers (`redact::hide_peers_from_peer`).
                    names_hosts,
                )
            }
        }
        method::INITIALIZE => {
            if let Some(name) = params.pointer("/clientInfo/name").and_then(Value::as_str) {
                *conn.name.lock_or_recover() = name.to_owned();
            }
            // A Mac that lends this machine its GitHub login: only over a link that read this
            // machine's peer token over ssh, never a paired device's (`hub/github_owner.rs`). It
            // counts from its `_acpmux/watch`, once the Mac's side of the handshake is done.
            let lends = conn.origin == Origin::Peer
                && conn.auth == ConnAuth::PeerToken
                && params.pointer("/_meta/acpmux/githubBroker").and_then(Value::as_bool)
                    == Some(true);
            conn.client_requests.lends_github.store(lends, Ordering::SeqCst);
            // Built outside `json!`: the list is long enough that, inside it, the macro's
            // expansion passes the default recursion limit.
            #[rustfmt::skip]
            let extensions: &[&str] = &[
                method::MUX_STATUS, method::MUX_SESSIONS, method::MUX_HARNESSES, method::MUX_RELOAD_CONFIG, method::MUX_ATTACH, method::MUX_WARM, method::MUX_PREWARM,
                method::MUX_DETACH, method::MUX_WATCH, method::MUX_HARNESS_INVENTORY_WATCH, method::MUX_HARNESS_INVENTORY_REFRESH, method::MUX_HARNESS_UPDATE_PLAN, method::MUX_HARNESS_UPDATE_PREPARE, method::MUX_RENAME, method::MUX_KEEP, method::MUX_KILL, method::MUX_QUEUE_REMOVE, method::MUX_QUEUE_EDIT, method::MUX_QUEUE_APPROVE, method::MUX_QUEUE_DECLINE, method::MUX_QUEUE_TEXT,
                method::MUX_INFO, method::MUX_SESSION_FILES, method::MUX_EVENTS, method::MUX_GITHUB_ACTION, method::MUX_GITHUB_APP_LEASE, method::MUX_ATTACHMENT, method::MUX_MAIL_SEND, method::MUX_MAIL_READ, method::MUX_MAIL_WAIT, method::MUX_MAIL_ACK, method::MUX_TEAM_SEND, method::MUX_TEAM_INBOX, method::MUX_TEAM_READ, method::MUX_TEAM_ACK, method::MUX_PERMISSION_RESPOND, method::MUX_PROCESS_LIST, method::MUX_PROCESS_TAIL, method::MUX_PROCESS_KILL, method::MUX_PROCESS_BACKGROUND, method::MUX_WORKTREE_REPORT, method::MUX_WORKTREE_CLEAN, method::MUX_WORKTREE_RESTORE, method::MUX_RETENTION,
                method::MUX_DRAFT_GET, method::MUX_DRAFT_SET, method::MUX_COMPOSER_SET, method::MUX_COMPOSERS, method::MUX_BOOKMARK_GET, method::MUX_BOOKMARK_SET, method::MUX_ASK, method::MUX_BTW, method::MUX_VIEW, method::MUX_TYPING, method::MUX_MARK_UNREAD, method::MUX_ARCHIVE, method::MUX_SIDE,
                method::MUX_SET_POLICY, method::MUX_SET_TOOLS, method::MUX_MCP_RECONNECT, method::MUX_EXPORT, method::MUX_IMPORT, method::MUX_FILE_PUT, method::MUX_FILE_PUT_BEGIN, method::MUX_FILE_PUT_CHUNK, method::MUX_FILE_PUT_FINISH, method::MUX_FILE_PUT_CANCEL, method::MUX_FILE_PUT_STATUS, method::MUX_MEDIA_OPEN, method::MUX_MEDIA_RANGE, method::MUX_SUBAGENT_TRANSCRIPT, method::MUX_NATIVE_HISTORY, method::MUX_WORKFLOWS, method::MUX_DISPATCH, method::MUX_STEER, method::MUX_BRIEFS, method::MUX_REPORT, method::MUX_TASK_NEW, method::MUX_TASKS, method::MUX_RESOLVE, method::MUX_SHUTDOWN, method::MUX_SESSION_AUTH, method::MUX_MESH_CONTROL,
            ];
            #[allow(unused_mut)]
            let mut reply = json!({
                "protocolVersion": 1,
                "agentInfo": {"name": "acpmux", "title": "acpmux", "version": VERSION},
                "agentCapabilities": {
                    "loadSession": true,
                    "promptCapabilities": {"image": true, "audio": false, "embeddedContext": true},
                    "sessionCapabilities": {"list": {}, "fork": {}, "resume": {}, "close": {}, "delete": {}},
                },
                "authMethods": [],
                "_meta": {"acpmux": {"version": VERSION, "build": crate::hub::build(), "capabilities": crate::capabilities::ids(),
                // `local`: the unix socket or the proven local app
                // (`local_app.rs`), which the session pool serves.
                "origin": match conn.origin { Origin::Web => "remote", Origin::Peer => "peer", _ => "local" },
                // The proof this connection presented (`conn_auth.rs`).
                "auth": conn.auth.as_str(),
                // A paired device's Full-access setting covers it now (`crate::pairing`):
                // a phone offers the modes that do not ask by it. Read again per request.
                "fullAccess": conn.device.as_deref().is_some_and(|d| conn.auth == ConnAuth::Device && hub.pairing.full_access(d)),
                // This connection is the person (`hub/person.rs`): never yet,
                // as the proof comes after this reply.
                "person": conn.is_person(),
                // Only a verified first-initialize caller token supplies this ID.
                "callerSessionId": conn.caller(),
                // The challenge a local connection proves the person key against.
                "personChallenge": if conn.challengeable() {
                    json!({"nonce": conn.nonce, "connection": conn.id})
                } else {
                    Value::Null
                },
                // The daemon run decision proofs bind (`hub/person.rs`).
                "personInstance": hub.person.instance(),
                "extensions": extensions, "operations": crate::hub::HANDOFF_OPERATIONS.iter().chain(crate::hub::PERMISSION_GROUP_OPERATIONS.iter()).chain(super::fork_through::FORK_OPERATIONS.iter()).collect::<Vec<_>>(), "handoff": {"maxCapsuleBytes": crate::hub::MAX_CAPSULE_BYTES},
                "features": ["promptAccepted", "turnIds", "eventPaging", "eventKinds", "eventStream", "cancelRequest", "messageSuperseded", "turnErrorText", "permissionGroups", "trustGate", "chiefBuiltinPresets", "personChallenge", "queueEdit", crate::author::QUEUE_APPROVAL_FEATURE, "steerInterrupt", "personHolds", "sessionTransfer", "approverDecisions", "toolInventory", "promptWithdraw", "processes", "worktreeCare", "harnessInventory", super::inventory_watch::FEATURE, crate::harness_health::INVENTORY_REFRESH_FEATURE, crate::harness_health::UPDATE_PLAN_FEATURE, crate::harness_health::UPDATE_PREPARE_FEATURE, "surfaces", crate::hub::FILE_PUT_FEATURE, crate::hub::file_uploads::CHUNKS_FEATURE, crate::hub::MEDIA_READ_FEATURE, crate::hub::SUBAGENT_TRANSCRIPT_FEATURE, crate::hub::NATIVE_HISTORY_FEATURE, crate::attach::FEATURE, crate::prompt_uploads::FEATURE, crate::hub::file_uploads::RESUME_FEATURE, super::upload_frames::FEATURE, crate::peer_states::STATE_EVENTS_FEATURE, crate::hub::session_auth::FEATURE, crate::agent_login::FEATURE, crate::hub::cancel::PERSON_STOP_FEATURE, crate::hub::stop_if_idle::FEATURE, SESSION_RESUME_FEATURE, crate::watch_delta::FEATURE], "trustGate": true}}
            });
            // Large messages go compressed from here on (`frame_compress.rs`).
            if conn.wire.as_ref().is_some_and(|wire| wire.enabled()) {
                reply.set_path(
                    &["_meta", "acpmux", "compression"],
                    json!(crate::frame_compress::ZLIB),
                );
            }
            // Only a local client can use the app launcher's bundled CLI.
            if conn.origin == Origin::Local
                && let Ok(path) = std::env::var(crate::login_env::BUNDLED_CLI_ENV)
                && std::path::Path::new(&path).is_absolute()
                && bundled_cli_is_executable(std::path::Path::new(&path))
            {
                reply.set_path(&["_meta", "acpmux", "cliPath"], json!(path));
            }
            // Advertised only where they work; other builds answer `not_built`.
            #[cfg(all(unix, feature = "tailnet"))]
            if let Some(extensions) =
                reply.pointer_mut("/_meta/acpmux/extensions").and_then(Value::as_array_mut)
            {
                extensions.extend(
                    [
                        method::MUX_TAILNET_START,
                        method::MUX_TAILNET_LOGIN,
                        method::MUX_TAILNET_STATE,
                        method::MUX_TAILNET_LOGOUT,
                    ]
                    .map(Value::from),
                );
            }
            Ok(reply)
        }
        method::AUTHENTICATE => Ok(json!({})),
        method::MUX_GITHUB_APP_LEASE => {
            if conn.origin != Origin::Local {
                return Err(RpcError::new(
                    -32040,
                    "the app lends its sign-in over the unix socket only",
                ));
            }
            // The app's own connection (it proved the person), never another process's.
            if !conn.is_person() {
                return Err(crate::hub::person::person_required("lending the cmux sign-in"));
            }
            hub.github_app.set(&params)
        }
        method::MUX_GITHUB_ACTION => crate::github_broker::handle(hub, conn, params).await,
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
        method::MUX_MAC_APPROVER_SET if conn.is_person() => hub.person.macs.set_own(&params),
        method::MUX_MAC_APPROVER_SET => {
            Err(crate::hub::person::person_required("setting this Mac's approver key"))
        }
        // This machine's own: never a remote connection's (a peer's included).
        method::MUX_MAC_APPROVERS if conn.origin.web_class() => Err(RpcError::invalid_params(
            "the enrolled Macs are read only on this machine, over its unix socket or app",
        )),
        method::MUX_MAC_APPROVERS => Ok(hub.person.macs.view(&params)),
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
                super::peer_forward::strip_new_meta(&mut p);
                super::remote_guard::mark_forwarded(conn.origin, conn.auth, &params, &mut p);
                // This caller's own opt-out for its remote chains there (`hub/vm_boundary.rs`),
                // for the person's own clients here only (`vm_boundary::owner`).
                if peer.vm_boundary()
                    && crate::hub::vm_boundary::owner(
                        conn.auth,
                        super::remote_guard::control_of(conn.origin, conn.auth, &params),
                        &params,
                    )
                {
                    crate::hub::merge_mux_meta(
                        &mut p,
                        json!({crate::hub::vm_boundary::FIELD: true}),
                    );
                }
                let mut result = super::remote_guard::hint::new_on(&peer, &params, p).await?;
                if let Some(id) = result.get("sessionId").and_then(Value::as_str) {
                    view::subscribe_remote(hub, conn, id, None);
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
            refuse_full_access_policy(hub, policy)?;
            let env = crate::session_env::parse(meta)?;
            let route = pick("route");
            if let Some(r) = &route
                && !crate::routes::is_route_id(r)
            {
                return Err(RpcError::invalid_params(format!("route {r:?} is not a route id")));
            }
            let disallowed_tools = disallowed_tools(meta)?;
            // Its parent is the session this connection proved it runs in (`hub/lineage.rs`):
            // an agent's `acpmux new`. An adopted chat or an ephemeral run is nobody's child.
            let parent_ask = crate::hub::lineage::parent_ask(meta)?;
            let tool_call = crate::hub::lineage::tool_call_id(meta)?;
            let lineage = if adopting || super::ephemeral::requested(&params) {
                // It records none, but a parent it names is still one the caller owns.
                if let crate::hub::lineage::ParentAsk::Named(id) = &parent_ask {
                    hub.check_lineage_parent(conn.caller(), id)?;
                }
                None
            } else {
                hub.new_session_lineage(conn.caller(), parent_ask, tool_call)?
            };
            let lane_parent = super::lane_parent(hub, conn, &params);
            let (asked_policy, agent) =
                (policy.is_some(), conn.caller().filter(|_| !conn.is_person()));
            // A new session needs room on this host (`hub/admission.rs`); an adopt that
            // never forks is not checked. Before the worktree, so a refusal makes none;
            // counted until the create ends.
            let who = who(conn);
            let admitted = match &adopt {
                Some(a) if a.if_live != crate::adopt::IfLive::Fork => None,
                _ => Some(hub.admit_new(ask(conn, &params, &who)).await?),
            };
            // The session this one takes over from: its harness is kept (`requests/successor.rs`).
            let succ = successor::find(hub, conn, &params, lineage.as_ref(), adopting).await?;
            let copy = succ.as_ref().and_then(|s| s.copy.clone()).unwrap_or_default();
            // After the request checks above, so a request they refuse makes no worktree.
            let worktree = super::new_worktree::ensure(conn.origin, meta, &mut cwd).await?;
            let req = crate::hub::NewRequest {
                harness: copy.harness.or_else(|| pick("harness")),
                preset: copy.preset.or_else(|| pick("preset")),
                name: pick("name"),
                cwd,
                policy,
                model: copy.model.or_else(|| pick("model")),
                effort: copy.effort.or_else(|| pick("effort")),
                adopt,
                workspace_id: crate::session_env::workspace_id(meta, &env)?,
                env,
                // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
                remote: conn.origin.web_class(),
                vm_boundary: crate::hub::vm_boundary::asked(
                    conn.auth,
                    super::remote_guard::control_of(conn.origin, conn.auth, &params),
                    &params,
                ),
                keep_harness_mode: hub.keeps_harness_mode(agent, &params).await,
                starter: hub.starter_of(conn.origin.web_class(), agent),
                route,
                subsession: None,
                lineage,
                disallowed_tools,
                checked_cwd: None,
                person: person_asks(conn),
            };
            let s = match &admitted {
                Some(admitted) => admitted.run(hub.new_session(req)).await?,
                None => hub.new_session(req).await?,
            };
            if let Some(tags) = meta.and_then(|m| m.get("tags")).and_then(Value::as_object)
                && !tags.is_empty()
            {
                hub.set_tags(&s, Some(tags), &[], None);
            }
            if conn.origin.web_class() {
                let peer = super::remote_guard::settles_as_peer(conn.origin, conn.auth, &params);
                super::remote_guard::settle_web_session_mode(hub, &s, peer).await?;
                // The VM boundary its caller asked for (`hub/vm_boundary.rs`): a
                // session the owner's peer daemon starts with no policy runs
                // approve-all, as vmHost's did. Web clients still ask.
                let vm_boundary = s.meta().vm_boundary && hub.takes_vm_boundary().await;
                if !asked_policy
                    && crate::hub::vm_boundary_peer_approves(
                        vm_boundary,
                        cfg!(target_os = "macos"),
                        super::remote_guard::control_of(conn.origin, conn.auth, &params)
                            == crate::hub::Control::Peer,
                        hub.approve_all_allowed(),
                    )
                {
                    hub.grant_vm_host_approve_all(&s).await;
                }
            } else {
                hub.start_in_mode(conn.is_person(), conn.caller(), &params, &s, adopting).await?;
            }
            attach(hub, conn, &s.id);
            if let Some(parent) = &lane_parent
                && !adopting
            {
                hub.lane_link(parent, &s.id);
            }
            // An adopted id may name a chat that already exists: never tied to this connection.
            if !adopting && super::ephemeral::requested(&params) {
                super::ephemeral::own(hub, conn, &s).await;
            }
            let meta = s.meta();
            let mut summary = hub.session_summary(&s);
            if let Some(w) = worktree {
                summary.set("worktree", w);
            }
            // Started past the lane cap: the caller hears it (`hub/admission.rs`).
            if let Some(w) = admitted.as_ref().and_then(|a| a.warning.clone()) {
                summary.set("admission", w);
            }
            successor::warn(hub, succ.as_ref(), &s, &mut summary).await;
            Ok(json!({
                "sessionId": s.id,
                "modes": meta.modes,
                "configOptions": meta.config_options,
                "_meta": {"acpmux": summary},
            }))
        }
        method::SESSION_LOAD => session_open::load(hub, conn, resolved.as_ref(), &params),
        method::SESSION_RESUME => session_open::resume(hub, conn, resolved.as_ref(), &params),
        method::SESSION_LIST => super::list_reply::acp_list(hub, conn, &params).await,
        method::SESSION_PROMPT => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            attach(hub, conn, &s.id);
            if person_asks(conn) {
                s.person_wrote();
            }
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
            // The uploads this prompt names as its own (`attach::blocks_for` uploaded them for it
            // alone): a refusal before the session sees it deletes them, so none is left behind.
            let mut owned = crate::attach::OwnedUploads(if web {
                Vec::new()
            } else {
                crate::prompt_uploads::owned(&s.id, &blocks).await
            });
            crate::prompt_context::apply(mux_meta(&params), web, &mut blocks)?;
            let provenance =
                crate::hub::Hub::prompt_provenance(&params, conn.origin, conn.is_trigger())?;
            // The caller's own provenance: a `cmux agent message`, never an inbox item.
            let given_provenance = provenance.is_some();
            // A person's prompt (`author.rs`): the hub stamps who sent it, also for a peer's.
            let author = crate::author::of_prompt(&params)?;
            let provenance = provenance.or_else(|| author.as_ref().map(|a| a.provenance()));
            let person_message = crate::author::of_provenance(provenance.as_ref()).is_some();
            // Sent from inside another session (its proven caller token) with none of its own:
            // that session's message, so the receiver's transcript does not show it as the person's.
            let provenance = match (provenance, conn.caller()) {
                (None, Some(caller)) if !conn.is_person() && caller != s.id => {
                    hub.resolve(caller).ok().map(|from| {
                        let name = from.meta().name;
                        crate::prompt_provenance::session_message(&from.id, &name, &s.id)
                    })
                }
                (provenance, _) => provenance,
            };
            let declared = crate::hub::declared_sender(&params)?;
            // What another agent's message asks of this chat (`prompt_class.rs`).
            let class = crate::prompt_class::declared(&params)?;
            // The inbox thread its sender named (`hub/inbox.rs`).
            let thread = crate::hub::inbox::explicit_thread(mux_meta(&params))?;
            // A sender that named itself, with neither (`--from`, `ACPMUX_FROM`, a peer daemon
            // forwarding its own session's prompt): that agent's message,
            // so the transcript never shows it as the person's. Not a note a session here sends
            // itself; names are each daemon's own, so a peer's `coordinator` is another session.
            let provenance = provenance.or_else(|| {
                let own = s.meta().name;
                let name = declared
                    .as_deref()
                    .filter(|name| conn.origin == super::Origin::Peer || *name != own)?;
                Some(crate::prompt_provenance::named_sender(name, &s.id))
            });
            let provenance =
                stamp_bound_sender(hub, conn, &s.id, &params, provenance, person_message);
            // A Chief's turn names the Chief (manaflow-ai/cmux#27914), by the session's exact id.
            let provenance = provenance.map(|p| {
                crate::prompt_provenance::stamp_chief(p, |id| {
                    hub.resolve(id).ok().filter(|from| from.id == id).map(|from| from.meta())
                })
            });
            // Another agent's message with no provenance (`hub/digest.rs`): one that names its
            // sender, or one from a connection that proved it runs in an acpmux session.
            let agent = declared
                .or_else(|| conn.caller().map(|id| hub.session_name(id)))
                .filter(|_| !person_message);
            let flag = |k| mux_meta(&params).and_then(|m| m.get(k)).and_then(Value::as_bool);
            let steer = flag("steer").or_else(|| params.get("steer").and_then(Value::as_bool));
            let steer = steer.unwrap_or(false);
            let prompt_id = mux_meta(&params)
                .and_then(|m| m.get("promptId"))
                .and_then(Value::as_str)
                .filter(|p| !p.is_empty())
                .map(str::to_owned);
            let message_id = mux_meta(&params)
                .and_then(|m| m.get("messageId"))
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_owned);
            // Only a peer daemon may carry this metadata.  A local or web caller can
            // name arbitrary `_meta` fields, but sender identity is stamped by the
            // proven caller/provenance below; accepting it here would let a client
            // forge durable message records in another session's journal.
            let message_sender = (conn.origin == super::Origin::Peer && !web)
                .then(|| mux_meta(&params).and_then(|m| m.get("messageSender")))
                .flatten()
                .and_then(|sender| {
                    let sender: crate::protocol::MessageSender =
                        serde_json::from_value(sender.clone()).ok()?;
                    (!sender.name.is_empty() && !sender.session_id.is_empty())
                        .then(|| serde_json::to_value(sender).ok())
                        .flatten()
                });
            let on_accepted = Some(composer::on_accepted(hub, conn, &s, &params)?);
            // A key replaces its sender's queued prompts (`supersede.rs`), which knows agents and
            // the owner only: a person's prompt neither replaces nor is replaced.
            let supersede = crate::hub::supersede_key(&params)?.filter(|_| !person_message);
            let supersede_set = supersede.is_some();
            let inbox_on = hub.config.read().await.agent_inbox();
            // Files uploaded first and named in the prompt get their bytes back here, before
            // anything reads them (`prompt_uploads.rs`). A prompt id the chat took already goes on
            // to `prompt_with`, which answers with its first run even once its uploads are gone
            // (`turns.rs` reads any left at dispatch, so none reaches an agent without its bytes).
            if crate::prompt_uploads::any(&blocks) {
                let (hub, s, id) = (hub.clone(), s.clone(), prompt_id.clone());
                let resend = flag("resend") == Some(true);
                let resolved = tokio::task::spawn_blocking(move || {
                    match crate::prompt_uploads::resolve(&s.id, web, &mut blocks) {
                        Err(_)
                            if id.as_deref().is_some_and(|id| hub.knows_prompt(&s, id, resend)) =>
                        {
                            Ok(blocks)
                        }
                        result => result.map(|()| blocks),
                    }
                });
                blocks = resolved.await.map_err(|e| RpcError::internal(e.to_string()))??;
            }
            // Files sent with the message (`acpmux send --attach`), after every check that can
            // refuse it: saved in the session's uploads, and what the agent gets put in their
            // place (`attach.rs`).
            let mut saved = None;
            if crate::attach::any(&blocks) {
                crate::attach::check_wire(&params)?;
                let id = s.id.clone();
                let received = tokio::task::spawn_blocking(move || {
                    crate::attach::receive(&id, web, &mut blocks).map(|saved| (blocks, saved))
                });
                (blocks, saved) =
                    received.await.map_err(|e| RpcError::internal(e.to_string()))??;
            }
            // From here the prompt's own uploads go only if the session refuses it.
            let saved = crate::attach::Saved::with_owned(saved, &s.id, owned.take());
            let cloud_turn: Option<crate::cloud_rewind::CloudTurnEnvelope> =
                match params.get("cloud_turn") {
                    Some(value) => Some(
                        serde_json::from_value(value.clone())
                            .map_err(|_| RpcError::invalid_params("cloud_turn is malformed"))?,
                    ),
                    None => None,
                };
            if let Some(envelope) = cloud_turn.as_ref() {
                if *conn.ended.borrow()
                    || envelope.purpose != "execute"
                    || envelope.session != s.id
                    || prompt_id.as_deref() != Some(envelope.turn.as_str())
                {
                    return Err(RpcError::invalid_params(
                        "cloud execution does not match this prompt",
                    ));
                }
                s.validate_prepared(
                    envelope.turn.as_str(),
                    envelope.turn.as_str(),
                    envelope.generation,
                    &envelope.attempt_id,
                    Some(&conn.id),
                )
                .map_err(|e| RpcError::invalid_params(e.to_string()))?;
            }
            let opts = crate::hub::PromptOptions {
                cloud_turn,
                prompt_id,
                message_id,
                message_sender,
                on_accepted: match &saved {
                    Some(saved) => saved.watch(on_accepted),
                    None => on_accepted,
                },
                resend: flag("resend") == Some(true),
                control: super::remote_guard::control_of(conn.origin, conn.auth, &params),
                trust_gate: super::trust_gate::gated(conn.origin, &params),
                steer_only: flag("steerOnly") == Some(true),
                interrupt: steer && flag("interrupt") == Some(true),
                steer_now: steer && flag("steerNow") == Some(true),
                interrupt_turn: None,
                provenance,
                agent,
                class,
                after_turn: None,
                supersede,
                display_parts: {
                    let parts = crate::hub::prompt_images::validated_display_parts(
                        mux_meta(&params).and_then(|meta| meta.get("inlineParts")),
                        &blocks,
                    );
                    (!parts.is_empty()).then(|| {
                        let mut parts: Vec<_> = parts.into_iter().collect();
                        parts.sort_by_key(|(index, _)| *index);
                        Value::Array(
                            parts
                                .into_iter()
                                .map(|(index, mut part)| {
                                    part["blockIndex"] = Value::Number((index as u64).into());
                                    part
                                })
                                .collect(),
                        )
                    })
                },
                full_access_device: super::remote_guard::full_access_device(hub, conn, &params),
                no_queue: false,
                admitted: false,
                send_now: false,
                thread,
                inbox: inbox_on
                    && crate::hub::inbox::plain_send(
                        conn.origin == super::Origin::Peer,
                        flag("teamMessage") == Some(true),
                        supersede_set,
                        flag("steerOnly") == Some(true),
                        given_provenance,
                    ),
            };
            let agent_message = opts.provenance.is_some() && !person_message;
            super::agent_messages::person_prompt(hub, conn, &s, agent_message).await;
            // The person's own `acpmux send` names the machine it ran on (`cli/sender.rs`): the
            // recorded client says it (`acpmux-cli#…@big-red`), and the transcript shows "via CLI on
            // big-red" under their prompt. An agent's message names its sender instead.
            let host = crate::prompt_provenance::cli_host(&params)
                .filter(|_| !agent_message && opts.agent.is_none());
            let client = match host {
                Some(host) => format!("{}@{host}", conn.label()),
                None => conn.label(),
            };
            let answer = hub.prompt_with(&s, blocks, &client, steer, opts).await;
            if let Some(saved) = saved {
                saved.settle(hub, &answer).await;
            }
            answer
        }
        // ACP defines cancel as a notification; a client that sends it as a
        // request gets an empty result instead of a request forwarded to
        // the agent that never answers.
        method::SESSION_CANCEL => {
            let s = hub.resolve(session_key(&params)?)?;
            conn.cancel_preparation(&s.id);
            s.abandon_prepared_connection(&conn.id);
            if let Err(e) = person_stop::stop(hub, conn, &params, &s).await {
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
            let start_later = super::fork_through::starts_later(&params);
            let who = who(conn);
            let admitted = hub.admit_new(ask(conn, &params, &who)).await?;
            let new = admitted
                .run(hub.fork(&s, name, cwd, env, workspace_id, through, start_later))
                .await?;
            attach(hub, conn, &new.id);
            let meta = new.meta();
            let mut summary = hub.session_summary(&new);
            if let Some(w) = admitted.warning.clone() {
                summary.set("admission", w);
            }
            Ok(
                json!({"sessionId": new.id, "modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": summary}}),
            )
        }
        method::SESSION_SET_MODE => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let mode = str_param(&params, "modeId")
                .ok_or_else(|| RpcError::invalid_params("modeId is required"))?;
            // A paired machine with Full access on (`remote_guard.rs` `full_access_device`).
            if let Some(device) = super::remote_guard::full_access_device(hub, conn, &params) {
                let set = crate::hub::SetRequest::Mode(mode.to_owned());
                return hub.set_for_full_access_device(&s, &device, set).await;
            }
            // A mode pick holds for this chat only; new chats start in the default (start_mode.rs).
            hub.set_mode(&s, mode).await
        }
        method::SESSION_SET_CONFIG_OPTION => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let id = str_param(&params, "configId")
                .ok_or_else(|| RpcError::invalid_params("configId is required"))?;
            let value = params
                .get("value")
                .cloned()
                .ok_or_else(|| RpcError::invalid_params("value is required"))?;
            if let Some(device) = super::remote_guard::full_access_device(hub, conn, &params) {
                let set = crate::hub::SetRequest::Config(id.to_owned(), value);
                return hub.set_for_full_access_device(&s, &device, set).await;
            }
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
        method::MUX_MCP_RECONNECT => {
            hub.reconnect_mcp(&hub.resolve(session_key(&params)?)?, &params).await
        }
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
        method::MUX_TAILNET_START
        | method::MUX_TAILNET_LOGIN
        | method::MUX_TAILNET_STATE
        | method::MUX_TAILNET_LOGOUT => {
            if conn.origin.web_class() || !conn.is_person() {
                return Err(crate::hub::person::person_required(
                    "controlling this daemon's embedded tailnet",
                ));
            }
            #[cfg(all(unix, feature = "tailnet"))]
            {
                let controller = hub.tailnet_controller();
                let snapshot = match m {
                    method::MUX_TAILNET_START => controller.start().await,
                    method::MUX_TAILNET_LOGIN => controller.login().await,
                    method::MUX_TAILNET_LOGOUT => controller.logout().await,
                    // MUX_TAILNET_STATE, the one method left from the arm above.
                    _ => Ok(controller.snapshot()),
                }
                .map_err(RpcError::internal)?;
                Ok(snapshot.to_json(true))
            }
            #[cfg(not(all(unix, feature = "tailnet")))]
            {
                Err(RpcError::new(-32000, "tailnet support is not built")
                    .with_data(json!({"reason": "not_built"})))
            }
        }
        method::MUX_STATUS => Ok(hub.status().await),
        method::MUX_SESSIONS => {
            // `usage: true` (`ls --wide`, `--json`): each chat's usage as its harness recorded it
            // until now first (`hub/usage_view.rs`); else rows carry the last pass's.
            if params.get("usage") == Some(&Value::Bool(true)) {
                let read = hub.refresh_usage_stats();
                let _ = tokio::time::timeout(crate::hub::USAGE_READ_WAIT, read).await;
            }
            super::list_reply::sessions(hub, conn, &params).await
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
            let web = super::trust_gate::for_web(conn.origin, &params);
            // Only the person's own clients start a session at the VM boundary (`hub/vm_boundary.rs`).
            let owner = crate::hub::vm_boundary::owner(
                conn.auth,
                super::remote_guard::control_of(conn.origin, conn.auth, &params),
                &params,
            );
            let warmed = hub.warm_sessions(&requested, limit, web, owner).await;
            Ok(json!({"warmed": warmed}))
        }
        method::MUX_PREWARM => {
            let s = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_owned);
            hub.prewarm(crate::hub::PrewarmRequest {
                harness: s("harness"),
                preset: s("preset"),
                cwd: s("cwd").map(PathBuf::from),
                wait: params.get("wait").and_then(Value::as_bool) == Some(true),
                release: params.get("release").and_then(Value::as_bool) == Some(true),
                // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
                remote: conn.origin.web_class(),
                trust_gate: super::trust_gate::gated(conn.origin, &params),
                trust_web: super::trust_gate::for_web(conn.origin, &params),
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
            refuse_full_access_policy(hub, Some(policy))?;
            {
                let mut cfg = hub.config.write().await;
                cfg.permission_policy = policy;
                hub.permission_defaults_changed();
                cfg.save()
                    .map_err(|e| RpcError::internal(format!("save permission policy: {e}")))?;
            }
            // deny-all is a lockdown: every chat without a policy of its own follows it.
            if policy == PermissionPolicy::DenyAll {
                hub.follow_default_policy().await;
            } else if policy == PermissionPolicy::ApproveAll {
                hub.approve_pending_default_tools().await;
            }
            Ok(json!({"policy":policy.to_string()}))
        }
        "_acpmux/peers" => Ok(json!({"peers": hub.peers()})),
        "_acpmux/host_health" => Ok(super::peer_status::host_health(hub, conn.origin).await),
        "_acpmux/peer_status" => super::peer_status::peer_status(hub, conn.origin, &params).await,
        super::vm_host::METHOD => super::vm_host::handle(hub, conn, &params).await,
        super::host_notice::METHOD => super::host_notice::handle(hub, conn, &params).await,
        // This daemon's copy of a peer session's events (`hub/peer_snapshot.rs`): transcripts
        // this machine's clients read, so for the app and the unix socket only.
        "_acpmux/peer_snapshot" if conn.origin.web_class() => Err(RpcError::invalid_params(
            "_acpmux/peer_snapshot answers this machine's app and unix socket only",
        )),
        "_acpmux/peer_snapshot" => {
            let (hub, params) = (hub.clone(), params.clone());
            tokio::task::spawn_blocking(move || hub.peer_snapshot(&params))
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
        }
        // Names every machine and its numbers: this machine's own clients only.
        "_acpmux/place" if conn.origin != Origin::Local => Err(RpcError::invalid_params(
            "_acpmux/place answers on this machine's unix socket only",
        )),
        "_acpmux/place" => Ok(super::place::place(hub, &params).await),
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
            super::models_fanout::add_peer_harnesses(hub, conn.origin, &params, &mut cat).await;
            Ok(cat)
        }
        crate::catalog::RPC_GET => Ok(hub.catalog.get()),
        crate::catalog::RPC_REFRESH => Ok(hub.catalog.refresh(false).await),
        "_acpmux/peer_add" => {
            let waited = hub.add_peer_from(&params).await?;
            Ok(with_wait(json!({"peers": hub.peers()}), waited))
        }
        // A peer that lasts as long as this connection (`hub/peer_lease.rs`):
        // the unix socket only (`remote_guard.rs`).
        "_acpmux/peer_lease" => {
            let text = |k: &str| str_param(&params, k).filter(|v| !v.is_empty()).map(str::to_owned);
            let required = |k: &str| {
                text(k).ok_or_else(|| RpcError::invalid_params(format!("{k} is required")))
            };
            let (name, url, token) = (required("name")?, required("url")?, required("token")?);
            let wait = params.get("wait").and_then(Value::as_bool).unwrap_or(false);
            // Only `true` opts this caller's remote chains there out of the sandbox
            // (`hub/vm_boundary.rs`); anything else leaves them in it.
            let vm_boundary = params.get("vmBoundary") == Some(&Value::Bool(true));
            let (lease, mut settled) = {
                let cfg = hub.config.read().await;
                hub.lease_peer(&name, &url, token, text("peerToken"), vm_boundary, &cfg)?
            };
            conn.hold_peer_lease(hub, lease);
            let waited = if wait {
                hub.wait_for_peer(&name, &mut settled, crate::hub::PEER_SETTLE_BUDGET).await
            } else {
                Value::Null
            };
            Ok(with_wait(json!({"lease": name, "peers": hub.peers()}), waited))
        }
        "_acpmux/peer_reconnect" => {
            let name = str_param(&params, "name")
                .ok_or_else(|| RpcError::invalid_params("name is required"))?;
            let wait = params.get("wait").and_then(Value::as_bool).unwrap_or(false);
            // A link that is open stays up unless the caller forces it (`host reconnect`).
            let force = params.get("force").and_then(Value::as_bool).unwrap_or(false);
            let waited = hub.reconnect_peer_with(name, wait, force).await?;
            Ok(with_wait(json!({"peers": hub.peers()}), waited))
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
                    let Some(fields) = set.as_object() else {
                        return Err(RpcError::invalid_params("defaults: set must be an object"));
                    };
                    // A JSON null clears one field.
                    for (k, v) in fields {
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
        method::MUX_INFO => info::info(hub, conn, &params).await,
        method::MUX_SESSION_FILES => {
            super::session_files::require_local(conn.origin)?;
            let s = hub.resolve(session_key(&params)?)?;
            Ok(super::session_files::describe(hub, &s))
        }
        method::MUX_WAIT => wait::wait(hub, &params, conn.caller()).await,
        method::MUX_WATCH_ADD | method::MUX_WATCH_LS | method::MUX_WATCH_RM => {
            watches::handle(hub, conn, m, &params).await
        }
        method::MUX_SCHEMA => {
            Ok(serde_json::from_str(crate::schema::SCHEMA).unwrap_or(Value::Null))
        }
        // Read-only and the same for every origin, like `_acpmux/schema`.
        method::MUX_PROTOCOL => Ok(crate::protocol::served().clone()),
        method::MUX_HISTORY => {
            let s = hub.resolve(session_key(&params)?)?;
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(20) as usize;
            let turns = hub.history(&s, limit);
            hub.lane_report_history_read(conn.caller(), &s.id, &turns);
            Ok(json!({"sessionId": s.id, "turns": turns}))
        }
        m if composer::handles(m) => composer::handle(hub, conn, m, &params).await,
        method::MUX_TAG => {
            let s = hub.resolve(session_key(&params)?)?;
            let remove: Vec<String> = params
                .get("remove")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            hub.set_tags_answered(
                &s,
                params.get("set").and_then(Value::as_object),
                &remove,
                params.get("ttlSeconds").and_then(Value::as_u64),
            )?;
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
                hub.set_tags_answered(&s, Some(&set), &[], None)?;
            } else {
                hub.set_tags_answered(&s, None, &[ARCHIVED_TAG.to_owned()], None)?;
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
        name if super::agent_login::METHODS.contains(&name) => {
            super::agent_login::handle(hub, conn, name, &params).await
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
            // Recorded here, not on a peer: only a folder that exists here (`remote_guard.rs`).
            if m == method::ACP_TRUST_SET && conn.origin != Origin::Local {
                super::remote_guard::local_trust_folder(hub, conn.origin, &params).await?;
            }
            super::trust_gate::answer(hub, m, &params).await
        }
        method::MUX_SET_RULES => {
            let s = hub.resolve(session_key(&params)?)?;
            let rules = params.get("rules").cloned().filter(|r| !r.is_null());
            if let Some(r) = &rules {
                crate::hub::rules::validate(r).map_err(RpcError::invalid_params)?;
            }
            hub.set_rules_answered(&s, rules)?;
            Ok(hub.session_summary(&s))
        }
        method::AGENT_SESSION_TURN_PREPARE => {
            let s = hub.resolve(session_key(&params)?)?;
            let prompt_id = params
                .get("prompt_id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .ok_or_else(|| RpcError::invalid_params("prompt_id is required"))?;
            let expected_workspace = std::env::var("CMUX_PLATFORM_WORKSPACE_ID")
                .map_err(|_| RpcError::invalid_params("Cloud workspace is not configured"))?;
            let expected_machine = std::env::var("CMUX_PLATFORM_MACHINE_ID")
                .map_err(|_| RpcError::invalid_params("Cloud machine is not configured"))?;
            if let Some(workspace) = params.get("workspace").and_then(Value::as_str)
                && expected_workspace != workspace
            {
                return Err(RpcError::invalid_params("workspace does not match session"));
            }
            if let Some(machine) = params.get("machine").and_then(Value::as_str)
                && expected_machine != machine
            {
                return Err(RpcError::invalid_params("machine does not match daemon"));
            }
            if params.get("generation").is_some_and(|v| v.as_u64().is_none()) {
                return Err(RpcError::invalid_params("generation must be a number"));
            }
            let generation = params.get("generation").and_then(Value::as_u64);
            let attempt_id = params.get("attempt_id").and_then(Value::as_str).unwrap_or(prompt_id);
            let budget = preparation_budget(params.get("deadline_ms"), crate::store::now_ms())?;
            let expires = tokio::time::Instant::now() + budget;
            let cancellation = conn.preparation_cancel(&s.id);
            let ended = conn.ended.subscribe();
            let workspace = params
                .get("workspace")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("workspace is required"))?;
            let machine = params
                .get("machine")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("machine is required"))?;
            let generation =
                generation.ok_or_else(|| RpcError::invalid_params("generation is required"))?;
            let authorization: crate::cloud_rewind::CloudTurnEnvelope = serde_json::from_value(
                params
                    .get("authorization")
                    .cloned()
                    .ok_or_else(|| RpcError::invalid_params("authorization is required"))?,
            )
            .map_err(|_| RpcError::invalid_params("authorization is malformed"))?;
            let origin = std::env::var("CMUX_PLATFORM_ORIGIN")
                .map_err(|_| RpcError::invalid_params("Cloud platform is not configured"))?;
            let preparation = async {
                crate::cloud_rewind::verify_preparation(
                    &origin,
                    workspace,
                    machine,
                    &s.id,
                    prompt_id,
                    generation,
                    attempt_id,
                    &authorization,
                )
                .await
                .map_err(|e| {
                    RpcError::new(-32000, format!("Cloud turn authorization refused: {e}"))
                })?;
                if *cancellation.borrow() || *conn.ended.borrow() {
                    return Err(RpcError::invalid_params("preparation was canceled"));
                }
                s.prepare_turn(prompt_id, generation, attempt_id, &conn.id)
                    .await
                    .map_err(|e| RpcError::invalid_params(e.to_string()))
            };
            let result =
                bounded_preparation(preparation, expires, ended, cancellation.clone()).await;
            let (turn_id, queued, accepted, generation, attempt_id) = match result {
                Ok(ready) => ready,
                Err(error) => {
                    // Also closes disconnect/cancel arriving after the waiter returned ready
                    // but before its result could be handed to this connection.
                    s.abandon_prepared(prompt_id, generation, attempt_id, &conn.id);
                    return Err(error);
                }
            };
            if accepted {
                Ok(
                    json!({"session": s.id, "turn": turn_id, "generation": generation, "attempt_id": attempt_id, "accepted": {"prompt_id": prompt_id, "turn_id": turn_id, "queued": queued}}),
                )
            } else {
                Ok(
                    json!({"session": s.id, "turn": turn_id, "generation": generation, "attempt_id": attempt_id, "queued": queued}),
                )
            }
        }
        method::AGENT_SESSION_TURN_ABANDON => {
            let s = hub.resolve(session_key(&params)?)?;
            let prompt_id = params
                .get("prompt_id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .ok_or_else(|| RpcError::invalid_params("prompt_id is required"))?;
            let generation = params
                .get("generation")
                .and_then(Value::as_u64)
                .ok_or_else(|| RpcError::invalid_params("generation is required"))?;
            let attempt_id = params
                .get("attempt_id")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("attempt_id is required"))?;
            Ok(
                json!({"abandoned": s.abandon_prepared(prompt_id, generation, attempt_id, &conn.id)}),
            )
        }
        method::MUX_INBOX_THREADS | method::MUX_INBOX_THREAD | method::MUX_INBOX_REPLY => {
            let s = hub.resolve(session_key(&params)?)?;
            // The person's, or the chat's own agent's: no other session reads or answers for it.
            let agent = conn.caller().is_some() || conn.unproven_caller.get().is_some();
            let person = conn.is_person() || (conn.origin == Origin::Local && !agent);
            if !person && conn.caller() != Some(s.id.as_str()) {
                return Err(RpcError::invalid_params(
                    "inbox.other_session: only the person or the chat's own agent reads its inbox",
                )
                .with_data(json!({"reason": "inbox.other_session"})));
            }
            // Its inbox is restored from its log (`restore_queue`): read once that load is done.
            hub.session_log(&s).await;
            let text_of = |k: &str| params.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
            let thread = || {
                text_of("threadId").ok_or_else(|| RpcError::invalid_params("threadId is required"))
            };
            match m {
                method::MUX_INBOX_THREADS => Ok(hub.inbox_threads(&s)),
                method::MUX_INBOX_THREAD => {
                    let mark = params.get("markRead").and_then(Value::as_bool).unwrap_or(false);
                    Ok(hub.inbox_thread(&s, thread()?, mark))
                }
                _ => {
                    let text = text_of("text")
                        .ok_or_else(|| RpcError::invalid_params("text is required"))?;
                    hub.inbox_reply(&s, thread()?, text).await
                }
            }
        }
        method::MUX_SET_TURN_CAP => {
            let s = hub.resolve(session_key(&params)?)?;
            if let Some(value) = params.get("turnCapMs") {
                // The person's: the app, or the local socket with no agent behind it. A
                // session's agent never lifts a cap, its own or another's.
                // A caller token this daemon does not know is an agent's all the same.
                let agent = conn.caller().is_some() || conn.unproven_caller.get().is_some();
                if !conn.is_person() && (conn.origin != Origin::Local || agent) {
                    return Err(crate::hub::person::person_required(
                        "changing a session's turn cap",
                    ));
                }
                let cap = match value {
                    Value::Null => None,
                    v => Some(v.as_u64().ok_or_else(|| {
                        RpcError::invalid_params("turnCapMs must be a whole number of ms or null")
                    })?),
                };
                hub.set_turn_cap_answered(&s, cap)?;
            }
            let meta = s.meta();
            Ok(json!({
                "sessionId": s.id,
                "turnCapMs": meta.turn_cap_ms,
                "effectiveTurnCapMs": crate::hub::turn_cap::turn_cap_ms(&meta),
            }))
        }
        method::MUX_ATTACH => {
            let s = hub.resolve(session_key(&params)?)?;
            let hidden = params.get("visible") == Some(&Value::Bool(false));
            // A restart reads the chat logs after its ready line: the queue, turn and status
            // shown here come from this chat's (`hub/log_load.rs`). A chat opened on screen
            // reads it, and its first page below, ahead of agent work (`qos.rs`).
            // A visible page asks for the newest records immediately (`waitLogs:false`); waiting
            // for the full restore here made a restarted long chat blank for tens of seconds.
            // Callers that need authoritative queue/status details keep the old default.
            if params.get("waitLogs").and_then(Value::as_bool) != Some(false) {
                if hidden {
                    hub.session_log(&s).await;
                } else {
                    hub.session_log_on_screen(&s).await;
                }
            }
            let filter = crate::hub::EventFilter::parse(params.get("kinds"))?;
            let event_stream = params.get("eventStream").and_then(Value::as_bool).unwrap_or(false);
            // Opening a hibernated chat on screen wakes its agent (`hub/idle.rs`).
            if !hidden {
                hub.wake_for(&s, super::trust_gate::for_web(conn.origin, &params), "click");
            }
            view::attach(
                hub,
                conn,
                &s,
                SubOpts { event_stream, filter: filter.clone(), hidden, remote: false },
            );
            let after = params.get("afterSeq").and_then(Value::as_u64);
            let before = params.get("beforeSeq").and_then(Value::as_u64);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(2000) as usize;
            let max_bytes = Some(crate::hub::page_bytes(&params));
            let detail = hub.session_detail(&s);
            // afterSeq alone pages forward (oldest first); otherwise the page
            // is the newest `limit` records before beforeSeq (or the end).
            let newest = after.is_none() || before.is_some();
            // Read before the page, as `_acpmux/events` does: a page that reads to the log's
            // end holds every record up to it (of the kinds asked), so a client may take
            // the page as covering it.
            let last = s.meta().last_seq;
            // The app's open names its bound: superseded tool output stays out of its page
            // (`store/superseded.rs`); the live stream is unchanged.
            let page_filter =
                filter.omitting_superseded(params.get("maxBytes").is_some_and(|b| !b.is_null()));
            let read = || {
                hub.events_page(
                    &s.id,
                    after.unwrap_or(0),
                    before,
                    limit,
                    max_bytes,
                    newest,
                    &page_filter,
                )
            };
            let page = if hidden { read() } else { crate::qos::on_screen(read) }
                .map_err(|e| RpcError::internal(e.to_string()))?;
            // The newest page holds to the log's end; a page of older records, or a forward one
            // with more to read, only to its own last record.
            let through = if before.is_none() && (after.is_none() || !page.has_more) {
                last
            } else {
                events::newest_seq(&page.events)
            };
            // The prompt of the turn the page starts inside, read with it (`turn_opener.rs`).
            let opener = turn_opener::turn_opener(hub, &s.id, &page);
            hub.lane_report_events_read(conn.caller(), &s.id, &page.events);
            let events: Vec<Value> = events::values(&s.id, page.events);
            // Who has the chat open now (`hub/presence.rs`), this attachment included.
            let presence = hub.presence.snapshot(&s.id);
            let mut reply = json!({"session": detail, "events": events, "hasMore": page.has_more, "lastSeq": last, "pageThrough": through, "presence": presence, "turnOpener": opener});
            // The page and its opener each keep a record of up to 14 MiB: together they could
            // pass one message, and the chat then never opened (`hub::fit_reply`).
            crate::hub::fit_reply(&mut reply);
            Ok(reply)
        }
        method::MUX_DETACH => {
            view::detach(hub, conn, &*hub.resolve(session_key(&params)?)?);
            Ok(json!({}))
        }
        method::MUX_VIEW => {
            let done = view::view(hub, conn, &params)?;
            // Showing a hibernated chat wakes its agent (`hub/idle.rs`).
            // The person's own view only: an authored one is a collaborator's presence.
            if params.get("visible").and_then(Value::as_bool) == Some(true)
                && crate::author::author(&params).ok().flatten().is_none()
                && let Ok(session) = hub.resolve(session_key(&params)?)
            {
                hub.wake_for(&session, super::trust_gate::for_web(conn.origin, &params), "click");
            }
            Ok(done)
        }
        method::MUX_TYPING => {
            let done = view::typing(hub, conn, &params)?;
            // A person typing into a hibernated chat wakes its agent now (`hub/idle.rs`).
            if params.get("on").and_then(Value::as_bool) == Some(true)
                && let Ok(session) = hub.resolve(session_key(&params)?)
            {
                hub.wake_for(&session, super::trust_gate::for_web(conn.origin, &params), "typing");
            }
            Ok(done)
        }
        method::MUX_MARK_UNREAD => view::mark_unread(hub, &params),
        method::MUX_APP_REPLY => super::app_reply::check(hub, conn, &params),
        method::MUX_HARNESS_INVENTORY_WATCH => super::inventory_watch::handle(hub, conn, &params),
        // A lending Mac counts once this answer is queued (`server/mod.rs`, `github_owner.rs`).
        method::MUX_WATCH => super::list_reply::watch(hub, conn, &params).await,
        method::MUX_EVENTS | method::MUX_ATTACHMENT => {
            events::handle(hub, m, &params, conn.caller())
        }
        // A read, for whoever may read the log, as `_acpmux/events` (`hub/queue_text.rs`).
        method::MUX_QUEUE_TEXT => Box::pin(queue_text(hub, &params)).await,
        method::MUX_MAIL_SEND
        | method::MUX_MAIL_READ
        | method::MUX_MAIL_WAIT
        | method::MUX_MAIL_ACK => mailbox::handle(hub, conn, m, &params).await,
        method::MUX_TEAM_SEND
        | method::MUX_TEAM_INBOX
        | method::MUX_TEAM_READ
        | method::MUX_TEAM_ACK => super::team::handle(hub, conn, m, &params).await,
        method::MUX_RENAME => {
            let s = hub.resolve(session_key(&params)?)?;
            let name = str_param(&params, "newName")
                .or_else(|| str_param(&params, "to"))
                .ok_or_else(|| RpcError::invalid_params("newName is required"))?;
            crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
            hub.rename(&s, name.to_owned()).await?;
            Ok(hub.session_summary(&s))
        }
        method::MUX_KEEP => {
            let id = str_param(&params, "sessionId")
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            super::ephemeral::keep(conn, id)?;
            Ok(json!({"sessionId": id, "ephemeral": false}))
        }
        method::MUX_KILL => {
            let s = hub.resolve(session_key(&params)?)?;
            let purge = params.get("purge").and_then(Value::as_bool).unwrap_or(false);
            // `ifIdle`: refused unless idle, checked under the turn lock (`stop_if_idle.rs`).
            let condition = crate::hub::stop_if_idle::StopCondition::from_params(&params)?;
            hub.stop(&s, purge, condition).await?;
            Ok(json!({"sessionId": s.id, "purged": purge}))
        }
        method::MUX_WATCH_TAKE_OVER => super::chats::watch_take_over(hub, &params).await,
        method::MUX_QUEUE_EDIT => {
            let s = hub.resolve(session_key(&params)?)?;
            // The queue a restart rebuilds from the logs.
            hub.session_log(&s).await;
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
            let device = super::remote_guard::full_access_device(hub, conn, &params);
            let gated = super::trust_gate::gated(conn.origin, &params);
            hub.queue_edit(&s, &params, control, gated, device.as_deref()).await
        }
        m if queued::handles(m) => queued::handle(hub, conn, m, &params).await,
        method::MUX_SEND_QUEUE | method::MUX_SEND_STATUS => {
            super::outbox::handle(hub, conn, m, &params).await
        }
        method::MUX_SESSION_AUTH => super::session_auth::handle(hub, conn, params).await,
        method::MUX_PROMPT_WITHDRAW
        | method::MUX_AGENT_PAIR_RESUME
        | method::MUX_RETRY
        | method::MUX_INBOX_DIGEST => super::agent_messages::handle(hub, conn, m, &params).await,
        method::MUX_PERMISSION_GROUPS => {
            let s = hub.resolve(session_key(&params)?)?;
            let mut list = hub.permission_groups(&s, &params)?;
            // Only the person allows a group (`hub/person.rs`): a reader that
            // is not one is told so, and draws no Allow it cannot give. An enrolled Mac's
            // signed one-time allow still counts here (`macAllowOnce`), which a peer
            // forwarding for its own person may draw (`peer_forward.rs`).
            if !conn.is_person() {
                list["allowRefused"] = json!(crate::hub::person::REASON);
                list["macAllowOnce"] = json!(true);
            }
            Ok(list)
        }
        method::MUX_PERMISSION_GROUP_RESPOND => {
            let s = hub.resolve(session_key(&params)?)?;
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            hub.respond_permission_group(&s, params, control, conn.is_person()).await
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
            let annotations = params.get("annotations").filter(|v| !v.is_null()).cloned();
            let answered_by = crate::hub::person::answered_by(&params)?;
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            // Who answers, for the person rule under the prompt's lock
            // (`hub/person.rs`): an allow that is not the person's counts
            // only on its decision proof, which the answer spends.
            let mut answerer = crate::hub::person::Answerer::of(conn.is_person(), &params);
            // Who answered, when a person other than the owner did (`author.rs`): a label only.
            let author = crate::author::author(&params)?;
            answerer.author = author.as_ref();
            hub.respond_permission_annotated(
                &s,
                pid,
                option,
                answers,
                annotations,
                answered_by,
                answerer,
                control,
            )
            .await?;
            Ok(json!({}))
        }
        method::MUX_SET_POLICY => {
            // The chat a proved raise was checked for (`hub/person/policy_grant.rs`).
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let policy: PermissionPolicy = str_param(&params, "policy")
                .ok_or_else(|| RpcError::invalid_params("policy is required"))?
                .parse()
                .map_err(RpcError::invalid_params)?;
            refuse_full_access_policy(hub, Some(policy))?;
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
        // A file dropped into one of this daemon's chats; a peer's went there (`peer_forward.rs`).
        method::MUX_FILE_PUT => crate::hub::file_uploads::handle(hub, params).await,
        method::MUX_FILE_PUT_BEGIN => crate::hub::file_uploads::handle_begin(hub, params).await,
        method::MUX_FILE_PUT_CHUNK => crate::hub::file_uploads::handle_chunk(hub, params).await,
        method::MUX_FILE_PUT_FINISH => crate::hub::file_uploads::handle_finish(hub, params).await,
        method::MUX_FILE_PUT_CANCEL => crate::hub::file_uploads::handle_cancel(hub, params).await,
        method::MUX_FILE_PUT_STATUS => crate::hub::file_uploads::handle_status(hub, params).await,
        // Every Claude workflow of this daemon's chats.
        method::MUX_WORKFLOWS => crate::hub::workflow_index::handle(hub, &params),
        // A chat's media, from this connection's handles; a peer's chat went there.
        method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE => {
            crate::hub::media_read::handle(hub, &conn.media, m, &params).await
        }
        // A subagent's transcript, read from the files Claude Code writes for the chat.
        method::MUX_SUBAGENT_TRANSCRIPT => {
            crate::hub::subagent_transcript::handle(hub, &params).await
        }
        // A chat's older turns, read from its Claude Code transcript (`hub/native_history.rs`).
        method::MUX_NATIVE_HISTORY => crate::hub::native_history::handle(hub, &params).await,
        method::MUX_SHUTDOWN => {
            // Stopping the daemon ends what runs at the VM boundary too: the owner's call only
            // (`hub/vm_boundary.rs`).
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            if !crate::hub::vm_boundary::owner(conn.auth, control, &params)
                && hub.any_at_vm_boundary()
            {
                return Err(RpcError::new(
                    -32000,
                    "a chat here runs without the sandbox on its owner's own VM; only the owner's own devices stop this daemon",
                )
                .with_data(json!({"reason": "remote.unsandboxed_agent"})));
            }
            // The person's own daemon is never stopped by a test runner or a client from a
            // runner's `_work` or a temp folder (`exe_path::shutdown_refusal`). Only the daemon's
            // own environment can allow those; nothing a client sends does.
            let allow = crate::daemon::exe_path::allowed_by_env();
            if let Some(why) =
                crate::daemon::exe_path::peer_shutdown_refusal(conn.peer.as_ref(), allow)
            {
                tracing::warn!("{why}");
                return Err(RpcError::new(-32000, why)
                    .with_data(json!({"reason": "shutdown.refused_client"})));
            }
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
            if params.get("restart").and_then(Value::as_bool) == Some(true) {
                hub.restart_requested.store(true, std::sync::atomic::Ordering::SeqCst);
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

/// MDM forces `sessions.allowFullAccess` off: a request for the approve-all policy (`approve-all`, `yolo`)
/// on `session/new`, `_acpmux/set_policy` or `_acpmux/set_default_policy` is refused, as a
/// switch into a full-access mode is (`full_access_off`). A stored approve-all runs as `ask`
/// meanwhile (`Hub::policy_for`).
fn refuse_full_access_policy(hub: &Hub, policy: Option<PermissionPolicy>) -> Result<(), RpcError> {
    if policy.is_some_and(crate::hub::full_access_bound::policy_is_full_access)
        && !hub.approve_all_allowed()
    {
        return Err(crate::hub::start_mode::full_access_off());
    }
    Ok(())
}

#[cfg(test)]
mod dispatch_policy_tests {
    use super::peer_approve_all_allowed;
    use crate::config::PermissionPolicy;

    #[test]
    fn peer_approve_all_requires_approved_preset() {
        assert!(!peer_approve_all_allowed(Some("approve-all"), None, false));
        assert!(!peer_approve_all_allowed(
            Some("approve-all"),
            Some(PermissionPolicy::ApproveAll),
            false
        ));
        assert!(peer_approve_all_allowed(
            Some("approve-all"),
            Some(PermissionPolicy::ApproveAll),
            true
        ));
        assert!(peer_approve_all_allowed(Some("ask"), None, false));
    }
}

#[cfg(test)]
mod admission_force_tests {
    use super::*;

    #[test]
    fn force_admit_is_honoured_only_from_this_machine() {
        let forced = json!({"_meta": {"acpmux": {"forceAdmit": true}}});
        assert!(force_asked(&forced));
        assert!(!force_asked(&json!({})));
        assert!(can_force(Origin::Local), "the unix socket");
        assert!(can_force(Origin::LocalApp), "the app");
        assert!(!can_force(Origin::Web), "a Web client");
        assert!(!can_force(Origin::Peer), "a peer");
    }

    #[test]
    fn the_admission_name_is_the_one_the_create_takes() {
        let name = |p: Value| create_name(&p);
        assert_eq!(name(json!({"name": "top"})).as_deref(), Some("top"));
        let both = json!({"name": "top", "_meta": {"acpmux": {"name": "meta"}}});
        assert_eq!(name(both).as_deref(), Some("meta"));
        // A `_meta` name that is not a string falls back to the top-level one, as the create does.
        let null = json!({"name": "top", "_meta": {"acpmux": {"name": null}}});
        assert_eq!(name(null).as_deref(), Some("top"));
        assert_eq!(name(json!({})), None);
    }
}

/// `_acpmux/queue_text` (`hub/queue_text.rs`), out of `dispatch_request` and boxed there, so its
/// wait adds nothing to that future's size.
async fn queue_text(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    // The queue a restart rebuilds from the log.
    hub.session_log(&s).await;
    let prompt_id = str_param(params, "promptId")
        .ok_or_else(|| RpcError::invalid_params("promptId is required"))?;
    hub.queued_text(&s, prompt_id)
}

/// An agent message's provenance with which session sent it and on what harness, for display
/// only (`prompt_provenance::FROM_SESSION_ID`): the session this connection proved, else what a
/// peer daemon said of its own proven caller; a client's claim is dropped. A person's prompt and
/// none are left as they are. Out of `dispatch_request`, whose future must stay small.
fn stamp_bound_sender(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    to: &str,
    params: &Value,
    provenance: Option<Value>,
    person_message: bool,
) -> Option<Value> {
    let provenance = provenance?;
    if person_message {
        return Some(provenance);
    }
    let bound = match conn.caller() {
        Some(caller) if !conn.is_person() && caller != to => hub
            .resolve(caller)
            .ok()
            .map(|from| crate::prompt_provenance::BoundSender::of_session(&from.id, &from.meta())),
        _ if conn.origin == super::Origin::Peer => crate::prompt_provenance::peer_sender(params),
        _ => None,
    };
    Some(crate::prompt_provenance::stamp_sender(provenance, bound.as_ref()))
}

fn preparation_budget(deadline: Option<&Value>, now: u64) -> Result<std::time::Duration, RpcError> {
    let deadline = match deadline {
        None => now.saturating_add(120_000),
        Some(value) => value
            .as_u64()
            .ok_or_else(|| RpcError::invalid_params("deadline_ms must be an unsigned integer"))?,
    };
    let remaining =
        deadline.checked_sub(now).filter(|ms| *ms > 0 && *ms <= 600_000).ok_or_else(|| {
            RpcError::invalid_params("prepare deadline must be within the next 600 seconds")
        })?;
    Ok(std::time::Duration::from_millis(remaining))
}

/// No task or timer survives a ready response: the deadline bounds waiting, not snapshot time.
async fn bounded_preparation<T>(
    preparation: impl std::future::Future<Output = Result<T, RpcError>>,
    expires: tokio::time::Instant,
    mut ended: tokio::sync::watch::Receiver<bool>,
    mut cancellation: tokio::sync::watch::Receiver<bool>,
) -> Result<T, RpcError> {
    let stopped = || RpcError::invalid_params("preparation was canceled or disconnected");
    if *ended.borrow() || *cancellation.borrow() {
        return Err(stopped());
    }
    let result = tokio::select! {
        biased;
        _ = ended.changed() => Err(stopped()),
        _ = cancellation.changed() => Err(stopped()),
        _ = tokio::time::sleep_until(expires) => Err(RpcError::invalid_params("prepare deadline has expired")),
        result = preparation => result,
    };
    if *ended.borrow() || *cancellation.borrow() {
        return Err(stopped());
    }
    result
}

#[cfg(test)]
mod cloud_preparation_tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;

    #[test]
    fn cloud_prepare_deadline_is_defaulted_bounded_and_strictly_typed() {
        assert_eq!(preparation_budget(None, 1000).unwrap(), Duration::from_secs(120));
        assert_eq!(
            preparation_budget(Some(&json!(601000)), 1000).unwrap(),
            Duration::from_secs(600)
        );
        for invalid in
            [json!(1000), json!(999), json!(601001), json!(null), json!("2000"), json!(-1)]
        {
            assert!(preparation_budget(Some(&invalid), 1000).is_err(), "{invalid}");
        }
    }

    struct Dropped(Arc<AtomicBool>);
    impl Drop for Dropped {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    #[tokio::test(start_paused = true)]
    async fn cloud_prepare_timeout_drops_waiter_without_a_background_task() {
        let (ended, receiver) = tokio::sync::watch::channel(false);
        let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
        let dropped = Arc::new(AtomicBool::new(false));
        let guard = Dropped(dropped.clone());
        let wait = async move {
            let _guard = guard;
            std::future::pending::<Result<(), RpcError>>().await
        };
        assert!(
            bounded_preparation(
                wait,
                tokio::time::Instant::now() + Duration::from_secs(1),
                receiver,
                cancel.clone()
            )
            .await
            .is_err()
        );
        assert!(dropped.load(Ordering::SeqCst));
        drop((ended, cancel_sender));
    }

    #[tokio::test]
    async fn cloud_prepare_disconnect_and_cancel_drop_inflight_verification_or_wait() {
        for disconnect in [false, true] {
            let (ended, receiver) = tokio::sync::watch::channel(false);
            let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
            let dropped = Arc::new(AtomicBool::new(false));
            let guard = Dropped(dropped.clone());
            let wait = async move {
                let _guard = guard;
                std::future::pending::<Result<(), RpcError>>().await
            };
            let mut ready = Box::pin(bounded_preparation(
                wait,
                tokio::time::Instant::now() + Duration::from_secs(120),
                receiver,
                cancel.clone(),
            ));
            assert!(futures::poll!(&mut ready).is_pending());
            if disconnect {
                ended.send_replace(true);
            } else {
                cancel_sender.send_replace(true);
            }
            assert!(ready.await.is_err());
            assert!(dropped.load(Ordering::SeqCst));
        }
    }

    #[tokio::test(start_paused = true)]
    async fn cloud_prepare_ready_response_has_no_remaining_deadline_timer() {
        let (ended, receiver) = tokio::sync::watch::channel(false);
        let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
        let ready = bounded_preparation(
            async { Ok("reserved") },
            tokio::time::Instant::now() + Duration::from_secs(1),
            receiver,
            cancel.clone(),
        )
        .await
        .unwrap();
        tokio::time::advance(Duration::from_secs(600)).await;
        assert_eq!(ready, "reserved");
        assert!(!*cancel.borrow());
        drop((ended, cancel_sender));
    }

    #[tokio::test]
    async fn cloud_prepare_rechecks_disconnect_after_ready_result() {
        let (ended, receiver) = tokio::sync::watch::channel(false);
        let (cancel_sender, cancel) = tokio::sync::watch::channel(false);
        let wait = async {
            ended.send_replace(true);
            Ok("ready but disconnected")
        };
        assert!(
            bounded_preparation(
                wait,
                tokio::time::Instant::now() + Duration::from_secs(1),
                receiver,
                cancel.clone()
            )
            .await
            .is_err()
        );
        drop(cancel_sender);
    }
}
