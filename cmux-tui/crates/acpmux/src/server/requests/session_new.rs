//! ACP `session/new` (`requests.rs`): start a chat here, or on the peer it names.

use super::*;

pub(super) async fn new(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: Value,
    fixed_id: Option<String>,
) -> Result<Value, RpcError> {
    // A peer name in _meta.acpmux.peer creates the session on that daemon.
    if let Some(peer_name) = mux_meta(&params).and_then(|m| m.get("peer")).and_then(Value::as_str)
        && !peer_name.is_empty()
    {
        return new_on_peer(hub, conn, &params, peer_name).await;
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
    // A create sent again after a restart cut its reply (`hub/create_key.rs`): the
    // session the first one made answers it, before admission or a worktree runs again.
    // The local socket's only: a key proves nothing about who sent it.
    let create_key = match conn.origin {
        Origin::Local => crate::hub::create_key::requested(meta)?,
        _ => None,
    };
    if let Some(key) = create_key.as_deref()
        && let Some(s) = hub.created_with_key(key).await
    {
        attach(hub, conn, &s.id);
        if super::ephemeral::requested(&params) {
            heap(|| super::ephemeral::own(hub, conn, &s)).await;
        }
        let meta = s.meta();
        let mut summary = hub.session_summary(&s);
        summary.set(crate::hub::create_key::REPLAYED, Value::Bool(true));
        if meta.stop_condition.is_some() {
            summary.set(crate::hub::stop_condition::FIELD, Value::Bool(true));
        }
        return Ok(json!({
            "sessionId": s.id,
            "modes": crate::hub::permission_modes::of_session(&meta),
            "configOptions": meta.config_options,
            "_meta": {"acpmux": summary},
        }));
    }
    let adopt = crate::adopt::AdoptRequest::from_meta(meta).map_err(RpcError::invalid_params)?;
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
    // A start that must ask before each change or not start (`hub/require_asking.rs`).
    if crate::hub::require_asking::asked(meta) {
        hub.check_require_asking(
            pick("harness"),
            pick("preset"),
            pick("model"),
            cwd.as_deref(),
            policy,
            meta,
            adopting,
        )
        .await?;
    }
    let mut env = crate::session_env::parse(meta)?;
    // A chat started from another Mac follows that Mac's answer (`cmux_tools_answer.rs`).
    if let Some(answer) = crate::hub::cmux_tools_answer::asked(conn.auth, &params) {
        env.insert(crate::hub::cmux_tools_answer::TOOLS_ANSWER_ENV.to_owned(), answer.to_owned());
    }
    if fixed_id.is_some()
        && let Some(ceiling) = meta.and_then(|meta| meta.get("workflowAllowedTools"))
    {
        let ceiling: Option<Vec<String>> =
            serde_json::from_value(ceiling.clone()).map_err(|_| {
                RpcError::invalid_params("allowedTools must be a list of tool names or null")
            })?;
        if let Some(ceiling) = ceiling {
            if ceiling.iter().any(|name| {
                name.is_empty() || !name.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'_')
            }) {
                return Err(RpcError::invalid_params("allowedTools contains an invalid tool name"));
            }
            env.insert(crate::agent_tools::MCP_TOOLS_ENV.into(), ceiling.join(","));
        }
    }
    // One-shot hooks must not detach background work that outlives the run.
    // This session-only value reaches the harness before its first spawn;
    // forks/handoffs do not copy session_env, and the launcher scrubs the
    // daemon's inherited ACPMUX_* values before applying it.
    if !adopting && super::ephemeral::requested(&params) {
        env.insert("ACPMUX_SESSION_EPHEMERAL".into(), "1".into());
    }
    let route = pick("route");
    if let Some(r) = &route
        && !crate::routes::is_route_id(r)
    {
        return Err(RpcError::invalid_params(format!("route {r:?} is not a route id")));
    }
    // The owner's Cloud credential (`agent_credentials.rs`): this socket's, never an agent's.
    let credential = crate::agent_credentials::requested(meta)?;
    if credential.is_some() {
        crate::agent_credentials::admit(conn.origin == Origin::Local, conn.caller())?;
    }
    let disallowed_tools = disallowed_tools(meta)?;
    let additional_directories = crate::hub::additional_dirs::requested(&params).await?;
    let stop_condition = crate::hub::stop_condition::requested(meta)?;
    // Read-only work in a folder not trusted (`hub/restricted.rs`): review, or narrower.
    let restricted = crate::hub::restricted::requested(meta)?;
    let policy = if restricted { crate::hub::restricted::start_policy(policy)? } else { policy };
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
    let (asked_policy, agent) = (policy.is_some(), conn.caller().filter(|_| !conn.is_person()));
    // A new session needs room on this host (`hub/admission.rs`); an adopt that
    // never forks is not checked. Before the worktree, so a refusal makes none;
    // counted until the create ends.
    let who = who(conn);
    let mut admitted = match &adopt {
        Some(a) if a.if_live != crate::adopt::IfLive::Fork => None,
        _ => Some(hub.admit_new(ask(conn, &params, &who)).await?),
    };
    // The session this one takes over from: its harness is kept (`requests/successor.rs`).
    let succ = successor::find(hub, conn, &params, lineage.as_ref(), adopting).await?;
    let copy = succ.as_ref().and_then(|s| s.copy.clone()).unwrap_or_default();
    // A fleet hold lets only its allowlist start, unless the person asks (`hub/session_hold.rs`).
    if !adopting
        && let Some(refusal) =
            hub.fleet_hold_refuses_new(pick("name").as_deref(), person_asks(conn))
    {
        return Err(refusal);
    }
    // No room here and a peer has some: it starts there (`hub/admission_redirect.rs`).
    // A fixed id, an adopt or a successor is this daemon's own; a start that fails
    // there starts here, warned (no start is dropped for a cap).
    if let Some(placed) = admitted
        .as_mut()
        .filter(|_| fixed_id.is_none() && !adopting && succ.is_none())
        .and_then(|a| a.placed.take())
    {
        use crate::hub::admission_redirect as redirect;
        let p = redirect::forwarded(&params, &placed);
        match Box::pin(new_on_peer(hub, conn, &p, &placed.host)).await {
            Ok(result) => {
                redirect::log("redirected", placed.reason, Some(&placed.host), None);
                return Ok(redirect::answer(result, &placed));
            }
            Err(e) => {
                let host = Some(placed.host.as_str());
                redirect::log(
                    "local_forward_failed",
                    placed.reason,
                    host,
                    Some(e.message.as_str()),
                );
                if let Some(a) = admitted.as_mut() {
                    let failed = redirect::forward_failed(&placed, &e.message);
                    let mut w = a.warning.take().unwrap_or_else(|| json!({}));
                    let text = match w.get("warning").and_then(Value::as_str) {
                        Some(cap) => format!("{cap} {failed}"),
                        None => failed,
                    };
                    w.set("warning", json!(text));
                    w.set("placeFailed", json!(placed.host));
                    a.warning = Some(w);
                }
            }
        }
    }
    // It starts here in a filler's room: the filler is hibernated (`free_filler`).
    if let Some((filler, reason)) = admitted.as_mut().and_then(|a| a.freed.take()) {
        crate::hub::admission_redirect::free_filler(hub.clone(), filler, reason);
    }
    // After the request checks above, so a request they refuse makes no worktree.
    let worktree = super::new_worktree::ensure(conn.origin, meta, &mut cwd).await?;
    let workspace_id = crate::session_env::workspace_id(meta, &env)?;
    // Who creates it (`hub/created_by.rs`), from what this connection proved.
    let created_by = (!adopting).then(|| {
        hub.creator_of(crate::hub::created_by::Creator {
            person: person_asks(conn),
            caller: conn.caller(),
            control: super::remote_guard::proven_control(conn.origin, conn.auth),
            meta,
            workspace: workspace_id.clone(),
        })
    });
    // The owner's own daemon starts this machine's own chat, not a remote chain
    // (`remote_guard::owner_control`, cmux#50026): no remote start rule, no asking-mode
    // settle, the mode it asks as this machine's own start. A VM-boundary start stays one.
    let remote_start = conn.origin.web_class()
        && (!super::remote_guard::owner_control(conn.origin, conn.auth, &params)
            || crate::hub::vm_boundary::asked(
                conn.auth,
                super::remote_guard::control_of(conn.origin, conn.auth, &params),
                &params,
            ));
    let req = crate::hub::NewRequest {
        harness: copy.harness.or_else(|| pick("harness")),
        preset: copy.preset.or_else(|| pick("preset")),
        name: pick("name"),
        suffix_taken_name: pick("ifNameTaken").as_deref() == Some(crate::hub::SUFFIX_TAKEN_NAME),
        cwd,
        policy,
        model: copy.model.or_else(|| pick("model")),
        effort: copy.effort.or_else(|| pick("effort")),
        adopt,
        workspace_id,
        env,
        // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
        remote: remote_start,
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
        created_by,
        disallowed_tools,
        checked_cwd: None,
        additional_directories,
        stop_condition,
        restricted,
        person: person_asks(conn),
        wait_start: asks_to_wait_on_its_harness(conn, &params),
        // Purged by its creator right after its work (the Chief compactor's nodes): its
        // prompts' bodies are not kept (`hub/ephemeral.rs`). An `ephemeral` run keeps
        // them, so a failed first send can still be resent.
        throwaway: !adopting
            && mux_meta(&params).and_then(|m| m.get("throwaway")).and_then(Value::as_bool)
                == Some(true),
        require_asking: crate::hub::require_asking::asked(meta),
        credential,
        create_key,
    };
    let s = match &admitted {
        Some(admitted) => heap(|| admitted.run(hub.new_session_with_id(req, fixed_id))).await?,
        None => heap(|| hub.new_session_with_id(req, fixed_id)).await?,
    };
    // This connection's own new session: what its `_acpmux/side` may tag (the tour's task).
    conn.note_created(&s.id);
    if let Some(tags) = meta.and_then(|m| m.get("tags")).and_then(Value::as_object)
        && !tags.is_empty()
    {
        hub.set_tags(&s, Some(tags), &[], None);
    }
    if remote_start {
        let peer = super::remote_guard::settles_as_peer(conn.origin, conn.auth, &params);
        let cloud_mobile = super::remote_guard::cloud_mobile(&params);
        // The VM boundary its caller asked for (`hub/vm_boundary.rs`): a
        // session the owner's peer daemon starts with no policy runs
        // approve-all, as vmHost's did. Web clients still ask. Before the
        // mode settles, so a Codex chat there settles in full access
        // (`policy_mode.rs` `bridge_settle_modes`), not the asking mode a
        // narrower policy needs.
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
            heap(|| hub.grant_vm_host_approve_all(&s)).await;
        }
        heap(|| super::remote_guard::settle_web_session_mode(hub, &s, peer, cloud_mobile)).await?;
    } else {
        heap(|| hub.start_in_mode(conn.is_person(), conn.caller(), &params, &s, adopting)).await?;
    }
    attach(hub, conn, &s.id);
    if !adopting && let Some(parent) = &lane_parent {
        hub.lane_link(parent, &s.id, super::lane_parent::asked_to_report(&params));
    }
    // An adopted id may name a chat that already exists: never tied to this connection.
    if !adopting && super::ephemeral::requested(&params) {
        heap(|| super::ephemeral::own(hub, conn, &s)).await;
    }
    let meta = s.meta();
    let mut summary = hub.session_summary(&s);
    if let Some(w) = worktree {
        summary.set("worktree", w);
    }
    // A taken name kept with a suffix (`ifNameTaken`): the caller hears the name asked
    // for beside the one it got (`name`).
    if let Some(asked) = pick("name").filter(|n| *n != meta.name) {
        summary.set("requestedName", Value::String(asked));
    }
    // Started past the lane cap: the caller hears it (`hub/admission.rs`).
    if let Some(w) = admitted.as_ref().and_then(|a| a.warning.clone()) {
        summary.set("admission", w);
    }
    successor::warn(hub, succ.as_ref(), &s, &mut summary).await;
    // The stop condition it keeps (`hub/stop_condition.rs`): a caller that asked for one
    // and does not see it here knows its agent can stop at any turn end.
    if meta.stop_condition.is_some() {
        summary.set(crate::hub::stop_condition::FIELD, Value::Bool(true));
    }
    // Read-only in a folder not trusted (`hub/restricted.rs`).
    if meta.restricted {
        summary.set(crate::hub::restricted::FIELD, Value::Bool(true));
    }
    Ok(json!({
        "sessionId": s.id,
        "modes": crate::hub::permission_modes::of_session(&meta),
        "configOptions": meta.config_options,
        "_meta": {"acpmux": summary},
    }))
}

/// `session/new` on the peer `peer_name` (`_meta.acpmux.peer`), for a caller's
/// own `peer` and for a create admission placed there (`hub/admission_redirect.rs`).
async fn new_on_peer(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
    peer_name: &str,
) -> Result<Value, RpcError> {
    // A credential is for an agent on this machine only: never sent on to a peer.
    if mux_meta(params).and_then(|m| m.get(crate::agent_credentials::FIELD)).is_some() {
        return Err(RpcError::invalid_params(
            "credentials start an agent on this machine only, never on a peer",
        ));
    }
    // A machine only the mesh hub reaches starts it through the hub's start control
    // (`mesh_control_send.rs`), as `acpmux session start --machine` does, so a placed
    // `new` lands there instead of being refused as no peer.
    if hub.peer_by_name(peer_name).is_none()
        && conn.origin == Origin::Local
        && hub.mesh.get().is_some()
        && hub.mesh_book_has_host(peer_name)
        && !super::trust_gate::gated(conn.origin, params)
    {
        return super::mesh_control_send::start_through_hub(hub, conn, params, peer_name).await;
    }
    let peer = hub.peer_by_name(peer_name).ok_or_else(|| RpcError::no_peer(peer_name))?;
    // A new chat started while the peer's link is coming back (a network that just returned)
    // waits for it, as a prompt does (`wait_for_prompt_link`), instead of being refused in a few
    // ms as not sent: its ask makes the next attempt come within a second (`peer_wanted.rs`).
    // Before the feature checks below: a link that is down lists no features. A peer down past
    // its outage window, or whose login was refused, is refused at once by the request, as before.
    if !peer.ready() && peer.reconnects_soon() {
        tokio::select! {
            _ = super::peer_forward::await_link(&peer, super::peer_forward::PROMPT_LINK_WAIT) => {}
            () = conn.closed() => {
                return Err(RpcError::internal("the client closed the connection"));
            }
        }
    }
    if super::trust_gate::gated(conn.origin, params) && !peer.supports_trust_gate() {
        return Err(super::trust_gate::peer_unsupported(&peer.name));
    }
    let mut p = params.clone();
    super::peer_forward::strip_new_meta(&mut p);
    // The chat there follows this Mac's answer to cmux's tools (`cmux_tools_answer.rs`).
    let answer =
        crate::hub::cmux_tools_answer::here_for(crate::user_settings::text().as_deref(), &p);
    crate::hub::cmux_tools_answer::stamp(&mut p, answer);
    super::remote_guard::mark_forwarded(conn.origin, conn.auth, params, &mut p);
    // An approved no-prompt preset's chat runs unattended there (`unattended_presets.rs`).
    let unattended = hub.forward_unattended_preset(conn.caller(), &peer.name, &mut p).await?;
    // A full-access starter's chat runs in full access there too, and the person's
    // own start at the person's start level (`hub/full_access_children.rs`).
    let carried = hub.forward_start_policy(person_start(conn, params), conn.caller(), &mut p).await;
    crate::hub::merge_mux_meta(&mut p, created_by_stamp(hub, conn, params));
    // This caller's own opt-out for its remote chains there (`hub/vm_boundary.rs`),
    // for the person's own clients here only (`vm_boundary::owner`): a saved
    // `vmBoundary`, or a dedicated agent VM of this caller's own fleet registry
    // (`hub/agent_vm.rs`).
    if crate::hub::vm_boundary::owner(
        conn.auth,
        super::remote_guard::control_of(conn.origin, conn.auth, params),
        params,
    ) && (peer.vm_boundary() || crate::hub::agent_vm::registry_agent_vm(&peer.name, &peer.url))
    {
        crate::hub::merge_mux_meta(&mut p, json!({crate::hub::vm_boundary::FIELD: true}));
    }
    if let Some((name, digest)) = &unattended {
        hub.unattended_preset_holds(name, digest).await?;
    }
    // A peer that takes no full access from this machine still starts the person's
    // own chat, asking, as before the start level was carried (`Carried::Person`).
    let asking = (carried == crate::hub::full_access_children::Carried::Person)
        .then(|| crate::hub::full_access_children::without_carried_policy(&p));
    let mut result = match super::remote_guard::hint::new_on(&peer, params, p).await {
        Err(e)
            if asking.is_some()
                && e.data.as_ref().is_some_and(|d| d.get("fullAccessRefusedBy").is_some()) =>
        {
            let asking = asking.unwrap_or_default();
            super::remote_guard::hint::new_on(&peer, params, asking).await?
        }
        r => r?,
    };
    if let Some(approved) = &unattended {
        let id = result.get("sessionId").and_then(Value::as_str);
        hub.log_unattended_start(approved, &peer.name, conn.caller(), id);
    }
    if let Some(id) = result.get("sessionId").and_then(Value::as_str) {
        view::subscribe_remote(hub, conn, id, None);
        peer.mark_attached(id);
    }
    if let Some(obj) = result.as_object_mut() {
        obj.insert("peer".into(), Value::String(peer.name.clone()));
    }
    Ok(result)
}
