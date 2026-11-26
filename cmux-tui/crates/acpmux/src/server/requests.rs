//! Request and notification handlers for one client connection.

use super::*;
use crate::heap_future::heap;
use crate::no_panic::{JsonExt, LockExt};

mod attach;
mod briefs;
pub(super) mod cancel_refused;
mod composer;
mod context;
mod events;
mod extensions;
mod info;
mod initialize;
pub(super) use initialize::note_initialize;
#[path = "requests/mailbox.rs"]
mod mailbox;
pub(super) mod person_stop;
mod prompt_sender;
pub(super) use prompt_sender::person_admitted;
use prompt_sender::{app_pane_unproven, owner_terminal};
mod presets;
mod queued;
mod session_fork;
mod session_new;
mod session_open;
mod session_prompt;
pub use session_open::FEATURE as SESSION_RESUME_FEATURE;
#[cfg(test)]
#[path = "requests/hold_attach_tests.rs"]
mod hold_attach_tests;
#[cfg(test)]
#[path = "requests/op_once_tests.rs"]
mod op_once_tests;
#[cfg(test)]
#[path = "requests/reopen_attach_bytes_tests.rs"]
mod reopen_attach_bytes_tests;
#[cfg(test)]
#[path = "requests/session_load_newest_tests.rs"]
mod session_load_newest_tests;
mod settled_attach;
#[cfg(test)]
#[path = "requests/settled_attach_tests.rs"]
mod settled_attach_tests;
mod shutdown;
mod successor;
mod time_breakdown_gate;
pub(super) use time_breakdown_gate::without as without_time_breakdown;
mod turn_opener;
mod workflow_dispatch;
pub use workflow_dispatch::FEATURE as DURABLE_DISPATCH_FEATURE;
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

/// Validate the read-free `_acpmux/attach {hold:true}` shape and return its exact-kind filter.
fn hold_attach_filter(params: &Value) -> Result<crate::hub::EventFilter, RpcError> {
    if params.get("eventStream") != Some(&Value::Bool(true)) {
        return Err(RpcError::invalid_params("hold attach requires eventStream: true"));
    }
    let kinds = params.get("kinds").and_then(Value::as_array).ok_or_else(|| {
        RpcError::invalid_params("hold attach requires kinds to be an array of exact kinds")
    })?;
    if kinds.len() > 16
        || kinds.iter().any(|kind| {
            kind.as_str().is_none_or(|kind| {
                kind.is_empty() || matches!(kind, "transcript" | "mux" | "wire" | "all")
            })
        })
    {
        return Err(RpcError::invalid_params(
            "hold attach kinds must contain at most 16 non-empty exact kinds",
        ));
    }
    for name in ["limit", "afterSeq", "beforeSeq", "maxBytes", "toolOutputMaxBytes", "settled"] {
        if params.get(name).is_some() {
            return Err(RpcError::invalid_params(format!("hold attach does not accept {name}")));
        }
    }
    crate::hub::EventFilter::parse(Some(&Value::Array(kinds.clone())))
}

/// Whether an `_acpmux/attach` opens the chat on someone's screen, so a hibernated agent wakes
/// for it (`hub/idle.rs` `wake_for`, cause `click`): it says `visible: true`, or it says nothing
/// and is no acpmux CLI (the app's pages say; cmux-tui's and the phone's opens say nothing and
/// were always opens). An acpmux CLI that says nothing is a read (`session tail`, `wait
/// --match`, a send's reply stream), not an open: on cmux NIGHTLY (2026-11-15) the tools that
/// tail lanes every few minutes woke 11 idle Chief sub-sessions and about 20 other chats each
/// pass, a Claude process each for two minutes. `acpmux attach` says `visible: true`.
fn attach_shows(conn: &Conn, params: &Value) -> bool {
    match params.get("visible") {
        Some(Value::Bool(visible)) => *visible,
        _ => conn.declared().is_none(),
    }
}

/// A create's admission ask (`hub/admission.rs`): `_meta.acpmux.forceAdmit`
/// (`acpmux new --force-admit`), and whether the person asks here (proven, or
/// this host's app pane; a peer's `via: app` is its client's word, not proof).
pub(super) fn ask<'a>(
    conn: &'a Conn,
    params: &Value,
    who: &'a str,
) -> crate::hub::admission::Ask<'a> {
    let can_force = can_force(conn.origin);
    let force = can_force && force_asked(params);
    let person = person_asks(conn);
    // A Web client, here or through a peer, learns no host name or path.
    let web =
        super::remote_guard::control_of(conn.origin, conn.auth, params) == crate::hub::Control::Web;
    let name = create_name(params);
    // A peer daemon's connection never learns this host's peers (`redact::hide_peers_from_peer`).
    let peers = conn.origin != Origin::Peer;
    // Only `session/new` follows a placed create (`hub/admission_redirect.rs`).
    let redirect = crate::hub::admission_redirect::movable(params);
    let auto = auto_place_asked(conn.origin, params);
    // The caller hears the wait when it begins (`_acpmux/admission_waiting`), not only in the
    // reply up to `AUTO_WAIT_BOUND` later.
    let waiting: Option<crate::hub::admission::Waiting<'a>> = auto.then(|| {
        Box::new(move |note: Value| {
            conn.send(&Message::notification(method::MUX_ADMISSION_WAITING, note));
        }) as crate::hub::admission::Waiting<'a>
    });
    // The harness it asks for, as `session/new` reads it; none: the default harness.
    let harness = mux_meta(params).and_then(|m| m.get("harness")).and_then(Value::as_str);
    let harness = harness.map(str::to_owned);
    crate::hub::admission::Ask {
        force,
        can_force,
        person,
        who,
        local: !web,
        peers,
        name,
        redirect,
        harness,
        auto,
        waiting,
        // The session this connection proved it runs in: its lane's fan-out cap applies.
        caller: conn.caller().filter(|_| !person),
    }
}

/// Whether a create may wait for the fleet to add a machine: only a start whose place choice was
/// Auto (`_meta.acpmux.autoPlace: true`, sent by `acpmux new --host auto` or a placed `new`, and by
/// the app's Auto start). An explicit choice (a named machine, this Mac, Cloud) never sends it and
/// is admitted as before. A peer daemon's connection never waits: the daemon that forwarded or
/// redirected the create already did.
pub(super) fn auto_place_asked(origin: Origin, params: &Value) -> bool {
    origin != Origin::Peer
        && mux_meta(params)
            .and_then(|meta| meta.get(crate::hub::admission::AUTO_PLACE_FIELD))
            .and_then(Value::as_bool)
            == Some(true)
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

/// `_meta.acpmux.waitStart` from a local connection that is no agent's or lane's: those keep the
/// start deadline (cx-m5up), as does a remote connection.
fn asks_to_wait_on_its_harness(conn: &Conn, params: &Value) -> bool {
    !conn.agent_side()
        && !conn.origin.web_class()
        && mux_meta(params).and_then(|m| m.get("waitStart")).and_then(Value::as_bool) == Some(true)
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

/// The part of a cancel that belongs to the connection it came on: the turn preparations made
/// there end. The repeat of a cancel sent on two paths (`dual_requests.rs`) runs this, and
/// takes the first copy's Stop.
pub(super) fn cancel_on_connection(hub: &Hub, conn: &Conn, params: Option<&Value>) {
    let Some(params) = params else { return };
    if let Ok(key) = session_key(params)
        && let Ok(s) = hub.resolve(key)
    {
        conn.cancel_preparation(&s.id);
        s.abandon_prepared_connection(&conn.id);
    }
}

pub(super) async fn handle_notification(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    mut params: Value,
) {
    super::remote_guard::note_vouched_phone(hub, conn, &params);
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
            let device = super::remote_guard::sending_device(conn, &params);
            if conn.origin != Origin::Local
                && let Err(e) = super::remote_guard::check(
                    hub,
                    conn.origin,
                    conn.auth,
                    device.as_deref(),
                    m,
                    &mut params,
                    false,
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
                // A chat that moved to a peer is stopped there (`hub/moved_forward.rs`).
                let moved = hub.moved_forward(key);
                if let Ok(s) = hub.resolve(key)
                    && moved.is_none()
                {
                    conn.cancel_preparation(&s.id);
                    s.abandon_prepared_connection(&conn.id);
                    // The person's Stop holds the agents' messages behind it (`hub/cancel.rs`),
                    // a peer's person's too (`person_stop.rs`).
                    if let Err(e) = person_stop::stop(hub, conn, &params, &s).await {
                        tracing::debug!(conn = %conn.id, "cancel: {e}");
                    }
                } else if let Some((peer, id, row)) = moved.or_else(|| hub.resolve_remote(key)) {
                    let turn = cancel_refused::row_turn(&row);
                    let mut forwarded = json!({"sessionId": id});
                    super::remote_guard::mark_forwarded(
                        conn.origin,
                        conn.auth,
                        &params,
                        &mut forwarded,
                    );
                    super::remote_guard::attest_person(
                        &mut forwarded,
                        person_admitted(conn, &params),
                    );
                    super::remote_guard::attest_owner_phone(hub, conn, &params, &mut forwarded);
                    person_stop::mark(conn, &params, &peer, &mut forwarded);
                    cancel_refused::forward(conn, peer, key, turn, forwarded).await;
                }
            }
        }
        // Taken by the connection's read loop, in order with its requests (`in_flight.rs`).
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

/// The child's name: the caller's `name` as given, else one made from its title or brief.
fn dispatch_name(params: &Value, brief: &str) -> String {
    if let Some(name) =
        params.get("name").and_then(Value::as_str).map(str::trim).filter(|n| !n.is_empty())
    {
        return name.to_owned();
    }
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
fn brief_for(
    hub: &Hub,
    conn: &Conn,
    mut row: Value,
    identity: Option<&workflow_dispatch::Identity>,
) -> Result<Value, RpcError> {
    if row.get("durable").and_then(Value::as_bool) == Some(true) {
        let identity =
            identity.ok_or_else(|| RpcError::not_found("no durable brief for this caller"))?;
        workflow_dispatch::check_caller(conn, &row)?;
        workflow_dispatch::check(&row, identity)?;
    }
    if conn.origin != Origin::Peer {
        return Ok(row);
    }
    if !hub.brief_ran_here(&row) && !workflow_dispatch::local_reservation(&row) {
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
    let durable = workflow_dispatch::requested(&params)?;
    let cancelling = match params.get("action").and_then(Value::as_str) {
        None | Some("start") => false,
        Some("cancel") if durable => true,
        _ => {
            return Err(RpcError::invalid_params(
                "dispatch action must be start or durable cancel",
            ));
        }
    };
    let id = params
        .get("briefId")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| format!("brief-{}", uuid::Uuid::now_v7()));
    let identity = durable.then(|| workflow_dispatch::identity(&params, &id));
    if let Some(identity) = &identity
        && let Some(previous) = hub.briefs.get(&id)
    {
        workflow_dispatch::check_caller(conn, &previous)?;
        workflow_dispatch::check(&previous, identity)?;
    }
    let idempotency = params
        .get("idempotencyKey")
        .or_else(|| params.get("idempotency_key"))
        .and_then(Value::as_str)
        .filter(|key| !key.is_empty());
    let requested_host = params
        .get("host")
        .or_else(|| params.get("target"))
        .and_then(Value::as_str)
        .unwrap_or("auto")
        .to_owned();
    let selected = if durable {
        hub.briefs
            .get(&id)
            .and_then(|row| row.get("host").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or(requested_host)
    } else {
        requested_host
    };
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
        if durable && existing.get("outcome").is_none() {
            return None;
        }
        Some(brief_for(hub, conn, existing, identity.as_ref()).map(|existing| {
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
                    "{why}; use --machine MACHINE or connect one with `acpmux machine add`"
                )));
            }
        }
    } else {
        if let Some(why) = super::place::role_refusal(&selected, super::place::brief_work(&brief)) {
            if let Some(replayed) = replay() {
                return replayed;
            }
            return Err(RpcError::invalid_params(format!(
                "host {selected:?} is not allowed for this dispatch ({why}); `acpmux machine pick` lists the hosts that are"
            )));
        }
        Some(selected.clone())
    };
    if let Some(peer_name) = host {
        let peer = hub.peer_by_name(&peer_name).ok_or_else(|| {
            RpcError::not_found(format!(
                "no peer {peer_name:?}; run `acpmux machine ls` and connect it"
            ))
        })?;
        if !peer.connected.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(RpcError::internal(format!(
                "peer {peer_name:?} is not connected; retry after it reconnects"
            )));
        }
        let epoch = if durable {
            Some(peer.lists_on(workflow_dispatch::FEATURE).ok_or_else(|| {
                RpcError::invalid_params("this peer does not support durable agent dispatch")
                    .with_data(json!({"reason":"dispatch.durable_unsupported"}))
            })?)
        } else {
            None
        };
        if !durable && let Some(existing) = hub.briefs.claim(&id, idempotency) {
            let existing = brief_for(hub, conn, existing, None)?;
            return Ok(
                json!({"brief":existing,"event":crate::hub::dispatch::event("dispatch", &existing),"replayed":true}),
            );
        }
        if let Some(identity) = &identity {
            workflow_dispatch::reserve_remote(
                hub,
                conn.caller(),
                &params,
                &id,
                identity,
                &peer_name,
            )
            .await?;
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
        // Its session there is this caller's (a workflow's remote activity: its owning agent).
        crate::hub::merge_mux_meta(&mut params, created_by_stamp(hub, conn, &original));
        // Its chat there follows this Mac's answer to cmux's tools (`cmux_tools_answer.rs`).
        let answer = crate::hub::cmux_tools_answer::here_for(
            crate::user_settings::text().as_deref(),
            &params,
        );
        crate::hub::cmux_tools_answer::stamp(&mut params, answer);
        let mut result = match peer.request_on(method::MUX_DISPATCH, params, epoch).await {
            Ok(result) => result,
            Err(e) => {
                if !durable {
                    hub.briefs.release(&id);
                }
                return Err(RpcError::internal(format!(
                    "dispatch to {peer_name} failed: {e}; recovery: reconnect the peer and retry"
                )));
            }
        };
        if let Some(row) = result.get("brief").cloned() {
            if let Some(identity) = &identity {
                let row = workflow_dispatch::cache_remote(hub, &id, identity, row).await?;
                result.set("brief", row);
            } else {
                hub.briefs.put(row);
            }
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
    let mut name = dispatch_name(&params, &brief);
    if let Some(identity) = &identity {
        // Separate attempts/corrections may share a human title, but own
        // distinct durable children. Replays retain the same stable name.
        name = format!(
            "{}-{}",
            name.chars().take(40).collect::<String>(),
            identity.session_id.chars().skip(4).take(12).collect::<String>()
        );
    }
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
    // A taken name is kept with a `-N` suffix, never the agent's; a replay with an identity
    // keeps its exact name, so the same child is found again.
    if identity.is_none() {
        new_params
            .set_path(&["_meta", "acpmux", "ifNameTaken"], json!(crate::hub::SUFFIX_TAKEN_NAME));
    }
    if let Some(obj) = new_params.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        for (key, value) in [
            ("harness", harness),
            ("preset", pick("preset")),
            ("model", model),
            ("effort", pick("effort")),
            ("policy", pick("policy")),
            ("route", pick("route")),
        ] {
            if let Some(value) = value {
                obj.insert(key.into(), json!(value));
            }
        }
        if let Some(via) = params.pointer("/_meta/acpmux/via") {
            obj.insert("via".into(), via.clone());
        }
        // A forwarding peer's own answer of who creates it; `creator_of` takes it from a
        // proven peer only (`hub/created_by.rs`).
        if let Some(by) =
            params.pointer(&format!("/_meta/acpmux/{}", crate::hub::created_by::FIELD))
        {
            obj.insert(crate::hub::created_by::FIELD.into(), by.clone());
        }
        // The forwarding Mac's answer to cmux's tools; the session/new below takes it from a
        // peer daemon only (`cmux_tools_answer::asked`).
        let answer = format!("/_meta/acpmux/{}", crate::hub::cmux_tools_answer::FIELD);
        if let Some(answer) = params.pointer(&answer) {
            obj.insert(crate::hub::cmux_tools_answer::FIELD.into(), answer.clone());
        }
    }
    if durable && let Some(ceiling) = params.get("allowedTools") {
        new_params.set_path(&["_meta", "acpmux", "workflowAllowedTools"], ceiling.clone());
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
    if !durable && let Some(existing) = hub.briefs.claim(&id, idempotency) {
        let existing = brief_for(hub, conn, existing, None)?;
        return Ok(
            json!({"brief":existing,"event":crate::hub::dispatch::event("dispatch", &existing),"replayed":true}),
        );
    }
    // A new lane that starts here is checked here too, whoever sent it (`place::here_refusal`);
    // a replay of a brief already taken (above) starts nothing and answers as before.
    if !cancelling && let Some(why) = super::place::here_refusal(super::place::brief_work(&brief)) {
        if !durable {
            hub.briefs.release(&id);
        }
        return Err(RpcError::invalid_params(format!(
            "this host is not allowed for this dispatch ({why}); `acpmux machine pick` lists the hosts that are"
        ))
        .with_data(json!({"reason": "dispatch.host_refused"})));
    }
    if durable {
        let row = json!({"briefId":id,"title":title,"brief":brief,"from":from,"to":to,
            "target":selected,"host":if forwarded {params.get("host").cloned().unwrap_or(json!("local"))}else{json!("local")},"stopCondition":stop,"fromSession":conn.caller()});
        if cancelling {
            return Box::pin(workflow_dispatch::cancel(hub, conn, &params, &id, row)).await;
        }
        return Box::pin(workflow_dispatch::local(hub, conn, &params, &id, new_params, row)).await;
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
    let task_device = super::remote_guard::sending_device(conn, &prompt);
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

// The tag that marks a side chat, valued with its chat's session (`hub/btw.rs`).

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
/// A permission answer sent to a chat for an ask pending in an open sub-session below it (the
/// parent's page draws its children's asks, `hub/asks_below.rs`) names that sub-session from here
/// on, so every check below is the child's own, as if it had been sent there. Only on this
/// machine's socket and the app's own pane (`Origin::LocalApp`): the answer still needs what an
/// answer to the child needs (the person, or a proof); a key that does not resolve, or an ask
/// pending in the named chat, stays as it was.
fn route_ask_below(hub: &Arc<Hub>, m: &str, params: &mut Value) {
    if m != method::MUX_PERMISSION_RESPOND {
        return;
    }
    let Some(field) = ["sessionId", "session"].into_iter().find(|f| params[*f].is_string()) else {
        return;
    };
    let (Some(key), Some(pid)) = (params[field].as_str(), params["permissionId"].as_str()) else {
        return;
    };
    if let Ok(session) = hub.resolve(key)
        && let Some(child) = hub.asking_below(&session, pid)
    {
        params[field] = Value::String(child);
    }
}

fn route_bare_key(hub: &Arc<Hub>, m: &str, params: &mut Value) -> Result<(), RpcError> {
    // A machine named in another case or by a prefix (`new --host`, `dispatch --host`) reads as
    // the one peer it names, by the same rule (`Hub::host_route`).
    let host = match m {
        method::SESSION_NEW | method::MUX_HARNESSES | method::MUX_HARNESS_HEALTH => {
            params.pointer_mut("/_meta/acpmux/peer")
        }
        method::MUX_DISPATCH => {
            let field = ["host", "target"].into_iter().find(|f| params[*f].is_string());
            field.and_then(|f| params.get_mut(f))
        }
        _ => None,
    };
    if let Some(slot) = host
        && let Some(peer) = slot.as_str().map(|h| hub.host_route(h)).transpose()?.flatten()
    {
        *slot = Value::String(peer);
    }
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

/// Whether a start on `conn` is the person's own here, which carries the person's start level to
/// another machine (`hub/full_access_children.rs`): the unix socket or the app, by the proof
/// the connection presented, and not held to the Web's rules (`remote_guard::control_of`).
/// A proven caller session is told apart by `Hub::forward_start_policy` itself.
pub(super) fn person_start(conn: &Conn, params: &Value) -> bool {
    matches!(conn.auth, ConnAuth::LocalSocket | ConnAuth::LocalApp)
        && super::remote_guard::control_of(conn.origin, conn.auth, params)
            == crate::hub::Control::Local
}

/// `_meta.acpmux` for a start this daemon forwards to a peer: who creates it, as this daemon
/// decides it (`hub/created_by.rs`); the peer takes it from this link only.
fn created_by_stamp(hub: &Hub, conn: &Conn, params: &Value) -> Value {
    let by = hub.creator_of(crate::hub::created_by::Creator {
        person: person_asks(conn),
        caller: conn.caller(),
        control: super::remote_guard::proven_control(conn.origin, conn.auth),
        meta: mux_meta(params),
        workspace: crate::session_env::workspace_id(mux_meta(params), &Default::default())
            .ok()
            .flatten(),
    });
    json!({crate::hub::created_by::FIELD: serde_json::to_value(by).unwrap_or_default()})
}

pub(super) async fn handle_request(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    mut params: Value,
    sender_token: Option<crate::sender_token::Presented>,
) -> Result<Value, RpcError> {
    // Freed memory goes back to the system once requests stop (malloc_quiet_trim.rs).
    cmux_tui_platform::malloc_quiet_trim::note_activity();
    if conn.is_trigger() && !m.starts_with("trigger/chat.") {
        return Err(RpcError::new(
            -32001,
            "trigger connection accepts trigger/chat operations only",
        ));
    }
    if m == method::MUX_V2 {
        return Err(RpcError::method_not_found(method::MUX_V2));
    }
    // The person is here (the app's pane or a proven person on this machine, never a script, an
    // agent or a remote client): a spare that idled out while they were away starts again now,
    // before their next new chat (`hub/pool/spare.rs`).
    if person_asks(conn) && !conn.origin.web_class() && !conn.agent_side() {
        hub.spare_on_person_request();
    }
    if matches!(
        m,
        method::TRIGGER_CHAT_ENSURE | method::TRIGGER_CHAT_SEND | method::TRIGGER_CHAT_STATUS
    ) {
        return heap(|| super::trigger_chat::handle(hub, conn, m, params)).await;
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
    // The owner's Cloud credential for one of this daemon's own sessions, by its exact id: handled
    // here, before any name routing or peer forward can send it elsewhere (`agent_credentials.rs`).
    if m == crate::agent_credentials::UPDATE_METHOD {
        return agent_credentials_update(hub, conn, &params).await;
    }
    // A bare name or prefix on this machine's socket names the one live session here or on a
    // peer; every check below reads the route it found (`hub/key_route.rs`).
    if conn.origin == Origin::Local {
        route_bare_key(hub, m, &mut params)?;
    }
    // The app's pane answers as `LocalApp`; a Web or peer connection never reaches a child so.
    if matches!(conn.origin, Origin::Local | Origin::LocalApp) {
        route_ask_below(hub, m, &mut params);
    }
    // The pane's fork through a turn is a session/fork, checked as one from
    // here on (`fork_through.rs`).
    let m = super::fork_through::as_session_fork(hub, m, &mut params).await?;
    // A request that is not the person's own, naming a session here at the VM
    // boundary, runs under the Web's rules from here on (`hub/vm_boundary.rs`).
    let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
    hub.refuse_at_vm_boundary(conn.auth, control, m, &mut params)?;
    // A policy raise the person proved in another machine's app: count and spend it before checks.
    let proved_chat = hub.take_person_policy(m, &params);
    let policy_proved = proved_chat.is_some();
    let challenge = |e: RpcError, params: &Value| {
        hub.with_policy_challenge(
            m,
            params,
            &[super::remote_guard::POLICY_REFUSED, crate::hub::person::REASON],
            e,
        )
    };
    // A transitive start is refused before remote mode checks, including via:web.
    if m == method::SESSION_NEW {
        super::peer_forward::refuse_peer_selector(conn.origin, m, &params)?;
    }
    // Before anything runs or is forwarded to a peer (`remote_guard.rs`).
    if conn.origin != Origin::Local {
        let device = super::remote_guard::sending_device(conn, &params);
        super::remote_guard::check(
            hub,
            conn.origin,
            conn.auth,
            device.as_deref(),
            m,
            &mut params,
            policy_proved,
            conn.presented_web_device(),
        )
        .await
        .map_err(|e| challenge(e, &params))?;
    }
    caller_sends_no_files(hub, conn, m, &params)?;
    // For trust writes, remote_guard retains trust.remote for forwarded Web callers.
    super::peer_forward::refuse_peer_selector(conn.origin, m, &params)?;
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
            crate::prompt_provenance::notice_checked(&params)?;
        }
        method::MUX_SEND_QUEUE => {
            if let Some(request) = params.get("request") {
                crate::prompt_class::declared(request)?;
                crate::prompt_provenance::notice_checked(request)?;
            }
        }
        _ => {}
    }
    // What the socket peer's process chain shows of a send that names its harness, looked at
    // once here, before the outbox keeps it or a peer gets it (`sender_harness.rs`).
    if matches!(m, method::SESSION_PROMPT | method::MUX_SEND_QUEUE) {
        let (pid, carried) = crate::sender_harness::check_trust(
            conn.socket_peer,
            conn.origin == super::Origin::Local,
            conn.origin == super::Origin::Peer && conn.auth.peer_daemon(),
        );
        let prompt =
            if m == method::MUX_SEND_QUEUE { params.get_mut("request") } else { Some(&mut params) };
        if let Some(prompt) = prompt {
            crate::sender_harness::stamp_checked(prompt, pid, carried).await;
            // The program that ran a send no session proved (`sender_program.rs`), so a prompt
            // no proof attributes still says which program sent it.
            crate::sender_program::stamp(prompt, pid, carried, conn.caller().is_none()).await;
            // Whether a local send presented this host's sender token (`sender_token.rs`): only a
            // unix connection's is read; the Web's, the app pane's and a peer link's were taken
            // out unread (`server/mod.rs`).
            let token = sender_token.filter(|_| {
                conn.origin == super::Origin::Local
                    && matches!(conn.socket_peer, crate::sender_harness::SocketPeer::Pid(_))
            });
            let matched = match token {
                Some(token) => {
                    let home = crate::config::home();
                    let check = move || crate::sender_token::matches(&home, &token);
                    Some(tokio::task::spawn_blocking(check).await.unwrap_or(false))
                }
                None => None,
            };
            crate::sender_token::stamp(prompt, matched, carried);
            // Who sent it, as the `Sent-by:` line the daemon appends to its text (`sent_by.rs`):
            // only a local connection that proved its session, before the outbox or a peer
            // takes it, so every route carries the sender's own line. Its `_meta` copy is the
            // daemon's alone: one a client sent is dropped.
            crate::sent_by::drop_claimed(prompt, carried);
            if conn.origin == super::Origin::Local
                && let Some(caller) = conn.caller()
            {
                crate::sent_by::stamp_send(hub, prompt, caller);
            }
            // A Claude desktop session's own send, bound to its bridged chat by the same pid
            // (`hub/desktop_bridge.rs`), so an answer reaches it.
            let outbox = conn.socket_peer == crate::sender_harness::SocketPeer::Outbox;
            hub.stamp_bridged_sender(prompt, pid, outbox, conn.caller().is_some()).await;
        }
    }
    let key = super::session_key(&params).ok().map(str::to_owned);
    // Audited on arrival, once every gate above took it: a `session/prompt`'s reply comes only
    // when its turn ends, which may be minutes (2026-11-05: a message between two lane machines
    // was in the receiver's log 186 s after it arrived). A refusal after this is its own line.
    let crossing = cross_host_prompt(conn.origin, m, &params);
    if let Some(fields) = &crossing {
        crate::xhost_audit::record("received", fields.clone());
    }
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
        heap(|| dispatch_request(hub, conn, m, params, resolved)).await
    };
    // A session only the hub reaches, for a verb the hub does not carry: said so, never
    // `no session` (`mesh_read.rs`).
    super::mesh_relay::read::explain_no_session(hub, conn, m, key.as_deref(), &mut reply);
    super::remote_guard::after(hub, conn.origin, m, key.as_deref(), &mut reply);
    if let (Some(mut fields), Err(e)) = (crossing, &reply) {
        // Never the error's text, which may quote the message: its code only.
        fields.set("error", json!(e.code));
        crate::xhost_audit::record("refused", fields);
    }
    reply
}

/// The cross-host audit line's fields (`xhost_audit.rs`) for a message request that crossed
/// machines to reach this daemon: a peer daemon forwarded it, or its sender names another
/// machine (a broker on this host relaying a lane VM's message). None for any other request.
fn cross_host_prompt(origin: Origin, m: &str, params: &Value) -> Option<Value> {
    if !matches!(m, method::SESSION_PROMPT | method::MUX_SEND_QUEUE) {
        return None;
    }
    let mut fields = crate::xhost_audit::prompt_fields(params);
    let from = fields.get("from").and_then(Value::as_str).map(str::to_owned);
    let sender_far = from.as_deref().and_then(crate::xhost_audit::other_machine).map(str::to_owned);
    if origin != Origin::Peer && sender_far.is_none() {
        return None;
    }
    fields.set("via", json!(if origin == Origin::Peer { "peer" } else { "socket" }));
    fields.set("fromHost", json!(sender_far));
    Some(fields)
}

pub(super) async fn dispatch_request(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
    resolved: Option<Arc<crate::hub::Session>>,
) -> Result<Value, RpcError> {
    heap(|| dispatch_request_with_identity(hub, conn, m, params, resolved, None)).await
}

/// `_acpmux/rename`: a chat's name, or its spoken handle (`newHandle`).
async fn rename(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    // `newIcon`: the icon every surface draws for it (`session_icon.rs`), alone or with a
    // new handle; null or "none" clears it.
    let icon = match params.get("newIcon") {
        None => None,
        Some(Value::Null) => Some(None),
        Some(Value::String(raw)) if crate::session_icon::clears(raw) => Some(None),
        Some(Value::String(raw)) => {
            let (id, name) =
                s.read_meta(|m| (m.id.clone(), m.handle.clone().unwrap_or_else(|| m.name.clone())));
            let name = params.get("newHandle").and_then(Value::as_str).unwrap_or(&name);
            Some(Some(
                crate::session_icon::SessionIcon::parse(raw, &id, name)
                    .map_err(RpcError::invalid_params)?,
            ))
        }
        Some(_) => {
            return Err(RpcError::invalid_params("newIcon must be a string or null"));
        }
    };
    if params.get("newHandle").is_some() || icon.is_some() {
        if params.get("newName").is_some() || params.get("to").is_some() {
            return Err(RpcError::invalid_params(
                "rename a name, or set a handle and an icon, in one request",
            ));
        }
        if let Some(handle) = params.get("newHandle") {
            let handle = handle
                .as_str()
                .ok_or_else(|| RpcError::invalid_params("newHandle must be a string"))?;
            hub.rename_spoken_handle(&s, handle)?;
        }
        if let Some(icon) = icon {
            hub.set_session_icon(&s, icon)?;
        }
        return Ok(hub.session_summary(&s));
    }
    let name = str_param(params, "newName")
        .or_else(|| str_param(params, "to"))
        .ok_or_else(|| RpcError::invalid_params("newName is required"))?;
    crate::session_name::validate(name).map_err(RpcError::invalid_params)?;
    // A registered chat's name is its address: only `acpmux register` moves it, so no
    // client renames it away for another session to take.
    if crate::hub::register::is_registered(&s) && s.meta().name != name {
        return Err(RpcError::invalid_params(
            "a registered chat is renamed only by `acpmux register NAME` from its own session",
        )
        .with_data(json!({"reason": "rename.registered"})));
    }
    hub.rename(&s, name.to_owned()).await?;
    // The name the rename settled on, as one edit in the synced replica (`hub/synced.rs`).
    hub.synced_record(crate::hub::synced::title_key(&s.id), json!(s.meta().name));
    Ok(hub.session_summary(&s))
}

/// A read or unread mark a person set here, as one edit in the synced replica (`hub/synced.rs`).
fn synced_mark(hub: &Hub, params: &Value, read: bool) {
    if let Ok(key) = session_key(params)
        && let Ok(s) = hub.resolve(key)
    {
        hub.synced_record(crate::hub::synced::read_key(&s.id), json!(read));
    }
}

/// A fixed identity is a typed internal argument, never a session/new field.
async fn dispatch_request_with_identity(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
    resolved: Option<Arc<crate::hub::Session>>,
    fixed_id: Option<String>,
) -> Result<Value, RpcError> {
    // The Chief reads a paired machine's harnesses before placing a task there.
    // Only this machine's own clients may select a peer; send no caller params
    // onward, so neither another hop nor a health refresh/update can be requested.
    if matches!(m, method::MUX_HARNESSES | method::MUX_HARNESS_HEALTH) {
        if let Some(selected) = params.pointer("/_meta/acpmux/peer") {
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) {
                return Err(RpcError::invalid_params(
                    "only the local app or unix socket may read a peer's harnesses",
                ));
            }
            let name = selected
                .as_str()
                .filter(|name| !name.is_empty())
                .ok_or_else(|| RpcError::invalid_params("peer must name a paired machine"))?;
            let peer = hub
                .peer_by_name(name)
                .ok_or_else(|| RpcError::not_found(format!("no peer {name:?}")))?;
            if !peer.ready() {
                return Err(peer.unreachable_error());
            }
            let mut answer =
                tokio::time::timeout(std::time::Duration::from_secs(5), peer.request(m, json!({})))
                    .await
                    .map_err(|_| {
                        RpcError::internal(format!("peer {name:?} did not report harnesses in 5 s"))
                    })??;
            answer
                .as_object_mut()
                .ok_or_else(|| RpcError::internal("peer did not report a harness object"))?
                .insert("peer".into(), json!(name));
            return Ok(answer);
        }
        if m == method::MUX_HARNESS_HEALTH && conn.origin == Origin::Peer {
            if !params.as_object().is_some_and(|p| p.is_empty()) {
                return Err(RpcError::invalid_params(
                    "a peer reads only cached harness sign-in status with no parameters",
                ));
            }
            // A peer needs auth enums, never diagnostic paths or a probe that
            // runs programs. Missing cached rows remain unknown to its picker.
            let rows: Vec<Value> = hub
                .health
                .rows_for_subjects(&hub.health_subjects().await)
                .into_iter()
                .map(|row| json!({"id": row.id, "auth": row.auth}))
                .collect();
            return Ok(json!({"harnesses": rows}));
        }
    }
    if m == method::MUX_SESSION_SEARCH && params.get("allSessions") == Some(&Value::Bool(true)) {
        if params.get("sessionId").is_some() || params.get("session").is_some() {
            return Err(RpcError::invalid_params("allSessions cannot name a session"));
        }
        let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
        if !crate::hub::vm_boundary::owner(conn.auth, control, &params) {
            return Err(RpcError::new(
                -32001,
                "history search requires the owner's local or peer connection",
            ));
        }
        return hub.search_history(&params, conn.origin != Origin::Peer).await;
    }
    // Rows by key (`info.rs`) are answered here, a peer's from its mirror: never forwarded, and
    // refused when they name one session beside them.
    let rows_by_key =
        m == method::MUX_INFO && params.get("sessionIds").is_some_and(|keys| !keys.is_null());
    // A session that lives on a peer (`peer_forward.rs`).
    if !rows_by_key && let Some(reply) = super::peer_forward::forward(hub, conn, m, &params).await {
        return reply;
    }
    // A session on a machine only the mesh hub reaches (`mesh_read.rs`).
    if !rows_by_key
        && let Some(reply) = super::mesh_relay::read::forward(hub, conn, m, &params).await
    {
        return reply;
    }
    // The app's prompt to a chat on a machine only the hub reaches (`mesh_read.rs`).
    if let Some(reply) = super::mesh_relay::read::prompt(hub, conn, m, &params).await {
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
        method::CHAT_FIX_FROM_LINK => super::fix_from_link::handle(hub, conn, params, false).await,
        method::CHAT_FIX_FROM_LINK_PREPARE => {
            super::fix_from_link::handle(hub, conn, params, true).await
        }
        // Boxed: dispatch_brief's future is large, and inline it widens every request's future
        // (a debug test thread's stack overflowed on an unrelated request).
        method::MUX_DISPATCH => Box::pin(dispatch_brief(hub, conn, params)).await,
        method::MUX_STEER => briefs::steer(hub, conn, params).await,
        method::MUX_BRIEFS => briefs::list(hub, conn, params).await,
        method::MUX_REPORT => briefs::report(hub, conn, params).await,
        method::MUX_TASK_NEW => briefs::task_new(hub, conn, params).await,
        method::MUX_TASKS => briefs::tasks(hub, conn, params).await,
        method::MUX_WHO_ELSE => {
            hub.who_else(&params, conn.origin == Origin::Local, conn.origin == Origin::Peer).await
        }
        // Counts this machine's own sends only: a peer's note would mix another daemon's callers.
        method::MUX_SEND_FANOUT if conn.origin == Origin::Local => {
            Ok(crate::send_fanout::handle(conn.caller(), &params, crate::store::now_ms()))
        }
        method::MUX_SEND_FANOUT => Ok(serde_json::json!({"fanout": null})),
        method::MUX_RESOLVE => {
            let names_hosts = conn.auth != ConnAuth::ReadOnlyDevice && conn.origin != Origin::Peer;
            let exact = params.get("exactSessionId").and_then(Value::as_bool) == Some(true);
            let query = if exact {
                str_param(&params, "sessionId")
                    .or_else(|| str_param(&params, "query"))
                    .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?
            } else {
                str_param(&params, "query")
                    .ok_or_else(|| RpcError::invalid_params("query is required"))?
            };
            let bead_only = params.get("bead").and_then(Value::as_bool) == Some(true);
            // A peer request is always owner-only: it cannot ask this daemon to transit a
            // selector to a third machine. Local callers stay on v1 until cut E removes the
            // watched table; this additive cut must not change what a local reader sees.
            if conn.origin == Origin::Peer {
                let query = Hub::validate_owner_selector(query)?;
                hub.locate_owner(query, bead_only, exact, names_hosts)
            } else {
                if exact {
                    hub.locate_exact(query, names_hosts)
                } else {
                    hub.locate(query, bead_only, names_hosts)
                }
            }
        }
        method::INITIALIZE => initialize::initialize(hub, conn, &params),
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
        method::MUX_GITHUB_REST => {
            if conn.origin != Origin::Local {
                return Err(RpcError::new(
                    -32040,
                    "the app's GitHub calls come over the unix socket only",
                ));
            }
            if !conn.is_person() {
                return Err(crate::hub::person::person_required("the app's GitHub calls"));
            }
            crate::github_rest_op::serve(params, &hub.github_app).await
        }
        method::MUX_GITHUB_ACTION => super::github_lane::handle(hub, conn, params).await,
        // Decided in order in `Conn::bind_person`; a proof that came before this run's key waits
        // for it here (`Conn::settle_prove`).
        method::MUX_PERSON_PROVE => {
            if conn.settle_prove(hub, &params).await {
                Ok(json!({"person": true}))
            } else {
                Err(RpcError::new(
                    -32000,
                    "the person proof does not answer this connection's challenge under this daemon's key (it comes after initialize)",
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
        method::MUX_MAC_APPROVERS => {
            // With this Mac's paired phones' public keys, which `host approvals enroll` also
            // enrolls on a peer, so a phone may allow once there too.
            let mut view = hub.person.macs.view(&params);
            if let Some(fields) = view.as_object_mut() {
                fields.insert("thisMacPhones".into(), json!(hub.person.approvers.peer_entries()));
                fields
                    .insert("thisMacPhonePrefix".into(), json!(hub.person.approvers.peer_prefix()));
            }
            Ok(view)
        }
        super::browser_workspaces::SET => hub.person.browser_workspaces.set(conn, &params),
        super::browser_workspaces::READ => hub.person.browser_workspaces.read(conn).await,
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
                // The VM provisioning exec (root) gives an unsigned daemon its key
                // (`daemon/provision.rs`); an agent, the daemon's own user, never can.
                (false, _)
                    if matches!(conn.transport, Transport::LocalStream { provisioner: true }) =>
                {
                    return hub.person.provision(key);
                }
                (false, _) => false,
            };
            hub.person.enroll(key, verified)
        }
        // Computer Use on another of the person's machines (`computer_use_relay.rs`).
        method::MUX_COMPUTER_USE_CALL => super::computer_use_relay::call(hub, conn, &params).await,
        method::MUX_COMPUTER_USE_MACHINES => super::computer_use_relay::machines(hub, conn).await,
        method::MUX_COMPUTER_USE_STATE => super::computer_use_relay::state(hub, conn).await,
        // A file or command action on another of the person's machines (`machine_files_relay.rs`).
        method::MUX_MACHINE_FILES_CALL => {
            super::machine_files_relay::call(hub, conn, &params).await
        }
        // A scoped key from the machine that keeps its provider's bootstrap (`keys_relay.rs`).
        method::MUX_KEYS_MINT => super::keys_relay::mint(hub, conn, &params).await,
        method::SESSION_NEW => session_new::new(hub, conn, params, fixed_id).await,
        method::SESSION_LOAD => session_open::load(hub, conn, resolved.as_ref(), &params),
        method::SESSION_RESUME => session_open::resume(hub, conn, resolved.as_ref(), &params),
        method::SESSION_LIST => super::list_reply::acp_list(hub, conn, &params).await,
        method::SESSION_PROMPT => session_prompt::prompt(hub, conn, params, resolved).await,
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
        method::SESSION_FORK => session_fork::fork(hub, conn, params, resolved).await,
        method::SESSION_SET_MODE => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let mode = str_param(&params, "modeId")
                .ok_or_else(|| RpcError::invalid_params("modeId is required"))?;
            // A paired machine with Full access on (`remote_guard.rs` `full_access_device`).
            if let Some(device) = super::remote_guard::full_access_device(hub, conn, &params) {
                let set = crate::hub::SetRequest::Mode(mode.to_owned());
                return heap(|| hub.set_for_full_access_device(&s, &device, set)).await;
            }
            // The person's pick of a mode that does not ask widens a narrower policy first
            // (`policy_mode.rs`, user 20336).
            if conn.is_person() && !conn.origin.web_class() {
                heap(|| hub.person_widens_policy_for(&s, method::SESSION_SET_MODE, &params)).await;
            }
            // A mode pick holds for this chat only; new chats start in the default (start_mode.rs).
            heap(|| hub.set_mode(&s, mode)).await
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
                return heap(|| hub.set_for_full_access_device(&s, &device, set)).await;
            }
            if conn.is_person() && !conn.origin.web_class() {
                let m = method::SESSION_SET_CONFIG_OPTION;
                heap(|| hub.person_widens_policy_for(&s, m, &params)).await;
            }
            // The app pane's effort pick is saved for the next new chat (start_defaults.rs).
            heap(|| hub.client_set_config(&s, id, value, conn.origin == Origin::LocalApp)).await
        }
        method::SESSION_SET_MODEL => {
            let s = hub.resolve(session_key(&params)?)?;
            let model = str_param(&params, "modelId")
                .ok_or_else(|| RpcError::invalid_params("modelId is required"))?;
            // The app pane's model pick is saved for the next new chat (start_defaults.rs).
            heap(|| hub.client_set_model(&s, model, conn.origin == Origin::LocalApp)).await
        }
        method::MUX_SET_TOOLS => hub.set_tools(&hub.resolve(session_key(&params)?)?, &params).await,
        method::MUX_PROJECT_NEW => super::project_new::handle(hub, conn.origin, &params).await,
        method::MUX_SET_DIRECTORIES => {
            hub.set_directories(&hub.resolve(session_key(&params)?)?, &params).await
        }
        method::MUX_MCP_RECONNECT => {
            hub.reconnect_mcp(&hub.resolve(session_key(&params)?)?, &params).await
        }
        method::SESSION_CLOSE => {
            let s = hub.resolve(session_key(&params)?)?;
            let why = crate::close_why::CloseWhy::from_params(conn.close_actor(&s.id), &params);
            heap(|| hub.kill_why(&s, false, why)).await?;
            Ok(json!({}))
        }
        method::SESSION_DELETE => {
            let s = hub.resolve(session_key(&params)?)?;
            let why = crate::close_why::CloseWhy::from_params(conn.close_actor(&s.id), &params);
            heap(|| hub.kill_why(&s, true, why)).await?;
            Ok(json!({}))
        }
        _ => extensions::dispatch(hub, conn, m, params, resolved).await,
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
mod dispatch_policy_tests;

#[cfg(test)]
#[path = "requests/admission_force_tests.rs"]
mod admission_force_tests;

/// `_acpmux/rows` (`rows/serve.rs`), off the async thread: a chat's first read folds its log.
/// With `follow`, the connection must be attached to the chat; its later row changes go to it
/// as `_acpmux/rows_patch` (`deliver`).
async fn rows(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let s = hub.resolve(session_key(params)?)?;
    let follow = params.get("follow").and_then(Value::as_bool) == Some(true);
    if follow && conn.sub_opts(&s.id).is_none() {
        return Err(RpcError::invalid_params("follow reads an attached chat: attach it first")
            .with_data(json!({"reason": "rows.not_attached"})));
    }
    let (hub2, id, params) = (hub.clone(), s.id.clone(), params.clone());
    let (reply, following) =
        tokio::task::spawn_blocking(move || crate::rows::read(&*hub2, &id, &params))
            .await
            .map_err(|e| RpcError::internal(format!("rows: {e}")))??;
    if let Some(following) = following
        && let Some(sub) = conn.subs.lock_or_recover().get_mut(&s.id)
    {
        sub.rows = Some(following);
    }
    Ok(reply)
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
/// peer daemon said of its own proven caller, else what a relay on this machine's unix socket
/// said of the machine it relays for (`prompt_provenance::FROM_RELAY`); a client's claim is dropped. A person's prompt and
/// none are left as they are. Out of `dispatch_request`, whose future must stay small.
/// How a prompt reached this daemon, as it saw it (`prompt_provenance::TRANSPORT`).
fn transport_of(conn: &Conn) -> &'static str {
    if conn.is_trigger() {
        return "trigger";
    }
    match conn.origin {
        super::Origin::Local => "unix",
        super::Origin::LocalApp => "app",
        super::Origin::Web | super::Origin::Peer => super::carrier::transport(conn),
    }
}

/// The labels a prompt's sender gave about itself, kept as claims (`prompt_provenance::CLAIMED`),
/// and the old acpmux CLI its connection is (`cli_caller.rs`), which proves no caller.
fn claimed_labels(conn: &Conn, params: &Value) -> serde_json::Map<String, Value> {
    let mut out = serde_json::Map::new();
    if let Some(client) = conn.declared().and_then(crate::cli_caller::Declared::old_client) {
        out.insert(crate::cli_caller::CLAIMED_CLIENT.to_owned(), json!(client));
    }
    let Some(mux) = params.pointer("/_meta/acpmux") else { return out };
    for key in ["cliHost", "fromHarness", "via"] {
        if let Some(value) = mux.get(key).and_then(Value::as_str) {
            let value = value.trim();
            if !value.is_empty() && value.len() <= 256 && !value.chars().any(char::is_control) {
                out.insert(key.to_owned(), json!(value));
            }
        }
    }
    out
}

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
    // The session this connection proved, else the bridged chat a Claude desktop session's send
    // was bound to by its process tree (`hub/desktop_bridge.rs`).
    let bridged = crate::hub::desktop_bridge::bridged_sender(params);
    let caller = conn.caller().or(bridged);
    let bound = match caller {
        Some(caller) if !conn.is_person() && caller != to => hub
            .resolve(caller)
            .ok()
            .map(|from| crate::prompt_provenance::BoundSender::of_session(&from.id, &from.meta())),
        _ if conn.origin == super::Origin::Peer => crate::prompt_provenance::peer_sender(params),
        // A relay on this machine (the lane-gh broker's `acpmux send`), outside any session: its
        // word on the machine and session it took the message from (`prompt_provenance::FROM_RELAY`).
        None if conn.origin == super::Origin::Local => {
            crate::prompt_provenance::relay_sender(params)
        }
        _ => None,
    };
    let caller_bound = caller.is_some_and(|caller| !conn.is_person() && caller != to)
        && bound.as_ref().is_some_and(|b| b.session_id.is_some());
    let mut provenance = crate::prompt_provenance::stamp_sender(provenance, bound.as_ref());
    // A caller token proved the sending session: the daemon bound who sent it, whatever name it
    // gave (`prompt_provenance::VERIFIED`).
    if let (true, Some(fields)) = (caller_bound, provenance.as_object_mut()) {
        fields.insert(crate::prompt_provenance::VERIFIED.to_owned(), json!(true));
    }
    Some(provenance)
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
#[path = "requests/cloud_preparation_tests.rs"]
mod cloud_preparation_tests;

/// `agent/credentials.update {sessionId, env}` (`hub/credentials.rs`): this socket's, never an
/// agent's own connection; the session by its exact id on this daemon.
async fn agent_credentials_update(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    crate::agent_credentials::admit(conn.origin == Origin::Local, conn.caller())?;
    let id = params
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    if params.as_object().is_some_and(|o| o.keys().any(|k| k != "sessionId" && k != "env")) {
        return Err(RpcError::invalid_params("agent/credentials.update takes sessionId and env"));
    }
    let env = params.get("env").cloned().unwrap_or(Value::Null);
    let credential = crate::agent_credentials::AgentCredential::parse(&json!({"env": env}))?;
    hub.update_credential(id, credential).await
}

/// The attach asked for no `timeBreakdown` (`omitTimeBreakdown: true`, the phone): its rows leave
/// it out as its reply does (`SubOpts::omit_time_breakdown`).
fn omits_time_breakdown(params: &Value) -> bool {
    params.get("omitTimeBreakdown").and_then(Value::as_bool) == Some(true)
}
