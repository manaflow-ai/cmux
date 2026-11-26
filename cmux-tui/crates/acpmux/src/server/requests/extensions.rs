//! The acpmux extension methods (`_acpmux/*` and the like) of `requests.rs`'s dispatch, after
//! the ACP methods it answers itself, in the order they match.

use super::*;

pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
    resolved: Option<Arc<crate::hub::Session>>,
) -> Result<Value, RpcError> {
    match m {
        // ------------------------------------------------ acpmux extensions
        method::MUX_TAILNET_START
        | method::MUX_TAILNET_LOGIN
        | method::MUX_TAILNET_STATE
        | method::MUX_TAILNET_LOGOUT
        | method::MUX_TAILNET_JOIN => {
            if conn.origin.web_class() || !conn.is_person() {
                return Err(crate::hub::person::person_required(
                    "controlling this daemon's embedded tailnet",
                ));
            }
            #[cfg(all(unix, feature = "tailnet"))]
            {
                let controller = hub.tailnet_controller();
                let snapshot = match m {
                    // The params carry the key: parsed here, never logged or echoed.
                    method::MUX_TAILNET_JOIN => {
                        let plan = crate::tailnet::embedded_join::JoinParams::from_value(&params)
                            .and_then(crate::tailnet::embedded_join::JoinParams::plan)
                            .map_err(RpcError::invalid_params)?;
                        controller.join(plan).await
                    }
                    method::MUX_TAILNET_START => controller.start().await,
                    method::MUX_TAILNET_LOGIN => controller.login().await,
                    method::MUX_TAILNET_LOGOUT => controller.logout().await,
                    // MUX_TAILNET_STATE, the one method left from the arm above.
                    _ => Ok(controller.snapshot()),
                }
                .map_err(RpcError::internal)?;
                let mut reply = snapshot.to_json(true);
                // Which tailnet the node joined (`join`, no secret); absent for the default sign-in.
                if let Some(profile) = controller.join_profile() {
                    reply["join"] = profile.to_json();
                }
                Ok(reply)
            }
            #[cfg(not(all(unix, feature = "tailnet")))]
            {
                Err(RpcError::new(-32000, "tailnet support is not built")
                    .with_data(json!({"reason": "not_built"})))
            }
        }
        // The stable tailnet node's placements: the local app (or CLI) says where each
        // workspace runs; the front reads the table at each new connection.
        method::MUX_TAILNET_PLACEMENT => {
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) {
                return Err(RpcError::invalid_params(
                    "only the local app or unix socket may move tailnet placements",
                ));
            }
            let message: cmux_tailnet_front::PlacementMessage = serde_json::from_value(params)
                .map_err(|e| RpcError::invalid_params(format!("placement: {e}")))?;
            let applied = hub.tailnet_placements.apply(&message);
            let reply = cmux_tailnet_front::PlacementReply::from(&applied);
            serde_json::to_value(reply).map_err(|e| RpcError::internal(e.to_string()))
        }
        method::MUX_STATUS => Ok(hub.status().await),
        // The felt-latency histograms (`cmux-felt`): names and numbers only, but this machine's
        // own clients only, like the perf watch beside it.
        method::MUX_FELT_SNAPSHOT => {
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) {
                return Err(RpcError::invalid_params(
                    "only the local app or unix socket may read the felt latency",
                ));
            }
            Ok(cmux_felt::snapshot())
        }
        // Each caller's requests and bytes over a recent window (`caller_stats.rs`): this
        // machine's own clients only. It names local pids and sessions.
        method::MUX_CALLERS => {
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) {
                return Err(RpcError::invalid_params(
                    "only the local app or unix socket may read the caller stats",
                ));
            }
            Ok(crate::caller_stats::global().report(&params))
        }
        // The live perf commentator (`perf_watch.rs`): this machine's own clients only. It names
        // chats and clients, and `on` writes its tail file.
        method::MUX_PERF => {
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) {
                return Err(RpcError::invalid_params(
                    "only the local app or unix socket may use the perf watch",
                ));
            }
            crate::perf_watch::handle(&params).await
        }
        method::MUX_SESSIONS => {
            // `usage: true` (`ls --wide`, `--json`): each chat's usage as its harness recorded it
            // (`hub/usage_view.rs` `read_usage_for_list`); else rows carry the last pass's.
            if params.get("usage") == Some(&Value::Bool(true)) {
                hub.read_usage_for_list().await;
            }
            super::list_reply::sessions(hub, conn, &params).await
        }
        method::MUX_USAGE => {
            // The same usage read `_acpmux/sessions {usage: true}` makes (the cached stats at once,
            // a pass behind them), then only the stats (`hub/usage_answer.rs`).
            hub.read_usage_for_list().await;
            let known = match params.get("known") {
                None | Some(Value::Null) => None,
                Some(Value::String(known)) => Some(known.as_str()),
                Some(_) => return Err(RpcError::invalid_params("known must be a string")),
            };
            Ok(hub.usage_answer(known, conn.origin == super::Origin::Peer))
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
            let warmed = heap(|| hub.warm_sessions(&requested, limit, web, owner)).await;
            Ok(json!({"warmed": warmed}))
        }
        method::MUX_PREWARM => {
            // A Cloud machine's first home chat folder, warm before the chat exists
            // (`hub/pool/reserved.rs`): this machine's own socket only.
            if params.get("reserveHome").and_then(Value::as_bool) == Some(true) {
                if conn.origin != Origin::Local {
                    return Err(RpcError::invalid_params(
                        "reserveHome is asked on this machine's own socket only",
                    ));
                }
                let wait = params.get("wait").and_then(Value::as_bool) == Some(true);
                // The harnesses and models the person set up (personal spares, ask-30d56720f6).
                let shapes = crate::hub::parse_home_shapes(params.get("shapes"))?;
                return heap(|| hub.reserve_home_warm(wait, shapes)).await;
            }
            let s = |k: &str| params.get(k).and_then(Value::as_str).map(str::to_owned);
            // A Cloud chat's coming start (cmux#45953): its owner credential, from this machine's
            // own socket only, as `session/new` takes one; never from an agent's connection.
            let credential = crate::agent_credentials::requested(Some(&params))?;
            if credential.is_some() {
                crate::agent_credentials::admit(conn.origin == Origin::Local, conn.caller())?;
            }
            let shape = crate::hub::PrewarmShape {
                model: s("model").filter(|m| (1..=200).contains(&m.len())),
                workspace_id: s("workspaceId").filter(|w| (1..=128).contains(&w.len())),
                credential,
            };
            let request = crate::hub::PrewarmRequest {
                harness: s("harness"),
                preset: s("preset"),
                cwd: s("cwd").map(PathBuf::from),
                wait: params.get("wait").and_then(Value::as_bool) == Some(true),
                release: params.get("release").and_then(Value::as_bool) == Some(true),
                // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
                remote: conn.origin.web_class(),
                trust_gate: super::trust_gate::gated(conn.origin, &params),
                trust_web: super::trust_gate::for_web(conn.origin, &params),
                shape,
            };
            heap(|| hub.prewarm(request)).await
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
            // deny-all and review are lockdowns: every chat without a policy of its own follows
            // them (`hub/policy_mode.rs`).
            if matches!(policy, PermissionPolicy::DenyAll | PermissionPolicy::Review) {
                hub.follow_default_policy().await;
            } else if policy == PermissionPolicy::ApproveAll {
                hub.approve_pending_default_tools().await;
            }
            Ok(json!({"policy":policy.to_string()}))
        }
        "_acpmux/peers" => Ok(json!({"peers": hub.peers()})),
        "_acpmux/host_overload" => Ok(crate::host_overload::current().to_json()),
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
        // A machine started from an older disk takes back what its owner's daemon kept of a
        // chat (`hub/journal_restore.rs`): that daemon's peer link, proven by this launch's peer
        // token, or this machine's socket. A paired client device is served as Peer too, with
        // its own credential: it may drive chats, never write their history.
        "_acpmux/journal_restore" | "_acpmux/attachments_held"
            if !matches!(
                (conn.origin, conn.auth),
                (Origin::Peer, ConnAuth::PeerToken) | (Origin::Local, ConnAuth::LocalSocket)
            ) =>
        {
            Err(RpcError::invalid_params(
                "_acpmux/journal_restore and _acpmux/attachments_held answer the owner's peer link and the unix socket only",
            ))
        }
        "_acpmux/journal_restore" => hub.journal_restore(&params).await,
        "_acpmux/attachments_held" => hub.attachments_held(&params).await,
        "_acpmux/peer_snapshots_clear" if conn.origin != Origin::Local => Err(
            RpcError::invalid_params("peer snapshots clear requires this machine's unix socket"),
        ),
        "_acpmux/peer_snapshots_clear" => {
            let hub = hub.clone();
            tokio::task::spawn_blocking(move || hub.clear_peer_snapshots())
                .await
                .map_err(|e| RpcError::internal(e.to_string()))?
        }
        // Names every machine and its numbers: this machine's own clients only, its unix socket
        // and the app's own pane (the composer's Auto row and busy chip), never the Web or a peer.
        "_acpmux/place" if !matches!(conn.origin, Origin::Local | Origin::LocalApp) => {
            Err(RpcError::invalid_params(
                "_acpmux/place answers on this machine's unix socket and the app's own pane only",
            ))
        }
        "_acpmux/place" => Ok(super::place::place(hub, &params).await),
        // Moves a chat from the place menu (`place_set.rs`): this machine's own clients only.
        "_acpmux/place_set" | "_acpmux/place_undo" | "_acpmux/place_get"
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) =>
        {
            Err(RpcError::invalid_params(
                "_acpmux/place_set, place_undo and place_get answer on this machine's unix socket and the app's own pane only",
            ))
        }
        "_acpmux/place_set" => super::place_set::set(hub, &params).await,
        "_acpmux/place_undo" => super::place_set::undo(hub, &params).await,
        "_acpmux/place_get" => super::place_set::get(hub, &params).await,
        // A new chat's place mode and where it starts with it (`chat_place.rs`): the composer's
        // place picker and chip, on the same sockets `_acpmux/place` answers on.
        "_acpmux/chat_place" | "_acpmux/chat_place_set"
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) =>
        {
            Err(RpcError::invalid_params(
                "_acpmux/chat_place answers on this machine's unix socket and the app's own pane only",
            ))
        }
        "_acpmux/chat_place" => Ok(super::chat_place::read(hub, &params).await),
        "_acpmux/chat_place_set" => super::chat_place::set(hub, &params).await,
        // Where a new Auto chat runs, from this machine's budget: the same clients as
        // `_acpmux/place` (its reason names this machine's numbers).
        method::MUX_PLACE_CHAT if !matches!(conn.origin, Origin::Local | Origin::LocalApp) => {
            Err(RpcError::invalid_params(
                "_acpmux/place_chat answers on this machine's unix socket and the app's own pane only",
            ))
        }
        method::MUX_PLACE_CHAT => Ok(super::place::place_chat(&params).await),
        "_acpmux/move_targets" if conn.origin != Origin::Local => Err(RpcError::invalid_params(
            "_acpmux/move_targets answers on this machine's unix socket only",
        )),
        "_acpmux/move_targets" => Ok(super::move_targets::targets(hub, &params)),
        "_acpmux/directories" => {
            let home = dirs::home_dir().unwrap_or_default();
            let base = str_param(&params, "cwd").map(PathBuf::from).unwrap_or_else(|| home.clone());
            let value = str_param(&params, "path").unwrap_or("");
            let path = crate::directory_input::resolve(&base, value, &home, None)
                .map_err(|e| RpcError::invalid_params(e.to_string()))?;
            let result = tokio::task::spawn_blocking(move || -> Result<Value, std::io::Error> {
                let path = std::fs::canonicalize(path)?;
                if !path.is_dir() { return Err(std::io::Error::other("not a directory")); }
                let children = crate::directory_input::children(&path);
                Ok(json!({"path": path, "parent": path.parent(), "home": home, "directories": children}))
            }).await.map_err(|e| RpcError::internal(e.to_string()))?.map_err(|e| RpcError::invalid_params(e.to_string()))?;
            Ok(result)
        }
        "_acpmux/models" => {
            // A starting daemon answers once its disk lists are served (`wait_model_caches`).
            hub.wait_model_caches().await;
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
            } else {
                // An old live list is probed again behind this answer (`hub/live_ages.rs`).
                hub.revalidate_live_models().await;
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
        method::MUX_MACHINE_INFO => {
            let s = hub.resolve(session_key(&params)?)?;
            if conn.caller() != Some(s.id.as_str()) && !conn.is_person() {
                return Err(RpcError::invalid_params(
                    "machine_info is available only to the calling agent",
                ));
            }
            // The capability snapshot reads the session's event log for secret status. Keep
            // that potentially whole-log scan off the async request dispatcher.
            let hub = Arc::clone(hub);
            tokio::task::spawn_blocking(move || hub.machine_info(&s))
                .await
                .map_err(|e| RpcError::internal(format!("machine info stopped: {e}")))
        }
        method::MUX_CONTEXT | method::MUX_CONTEXT_OVERRIDE => {
            context::handle(hub, conn, m, &params).await
        }
        method::MUX_INFO => info::info(hub, conn, &params).await,
        method::MUX_SESSION_RESYNC => super::session_patch::resync(hub, conn, &params),
        method::MUX_PAUSED_FILES => super::paused_files::handle(hub, conn, &params).await,
        method::MUX_SESSION_FILES => {
            super::session_files::require_local(conn.origin)?;
            let s = hub.resolve(session_key(&params)?)?;
            Ok(super::session_files::describe(hub, &s))
        }
        method::MUX_WAIT if params.get("until") == Some(&json!(["promptOutcome"])) => {
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let prompt_id = str_param(&params, "promptId")
                .filter(|id| !id.is_empty())
                .ok_or_else(|| RpcError::invalid_params("promptId is required"))?;
            tokio::select! {
                result = hub.prompt_outcome(&s, prompt_id) => result,
                () = conn.closed() => Err(RpcError::internal("the client closed the connection")),
            }
        }
        // A caller that left (its CLI was killed) waits no more: its wait would mark the turn it
        // waited for read (`lane_report_reads.rs`), and nobody reads its answer.
        method::MUX_WAIT => tokio::select! {
            result = wait::wait(hub, &params, conn.caller()) => result,
            () = conn.closed() => Err(RpcError::internal("the client closed the connection")),
        },
        method::MUX_WATCH_ADD | method::MUX_WATCH_LS | method::MUX_WATCH_RM => {
            watches::handle(hub, conn, m, &params).await
        }
        method::MUX_SCHEMA => {
            Ok(serde_json::from_str(&crate::schema::SCHEMA.inflate()).unwrap_or(Value::Null))
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
        method::MUX_SESSION_SEARCH => {
            let s = hub.resolve(session_key(&params)?)?;
            let query = crate::session_search::Query::from_params(&params)
                .map_err(RpcError::invalid_params)?;
            // A first search of a long log reads it whole: off the runtime.
            let hub = Arc::clone(hub);
            tokio::task::spawn_blocking(move || hub.session_search(&s.id, &query))
                .await
                .map_err(|e| RpcError::internal(format!("session search stopped: {e}")))?
        }
        // What a chat said and did is its person's (C5): the local socket and the app only.
        method::MUX_REVIEW_BRIEF => {
            if !matches!(conn.origin, Origin::Local | Origin::LocalApp) {
                return Err(RpcError::method_not_found(method::MUX_REVIEW_BRIEF));
            }
            let s = hub.resolve(session_key(&params)?)?;
            let root = params.get("root").and_then(Value::as_str).map(str::to_owned);
            // A chat's first brief reads its log: off the runtime.
            let hub = Arc::clone(hub);
            tokio::task::spawn_blocking(move || hub.review_brief(&s, root.as_deref()))
                .await
                .map_err(|e| RpcError::internal(format!("review brief stopped: {e}")))?
        }
        m if composer::handles(m) => heap(|| composer::handle(hub, conn, m, &params)).await,
        // Only the person writes the library: an agent's or a remote client's save could
        // replace a prompt the person types, or shadow one from `agentPane.savedPrompts`.
        method::MUX_PROMPTS_SAVE | method::MUX_PROMPTS_DELETE if !conn.is_person() => {
            Err(crate::hub::person::person_required("changing saved prompts"))
        }
        method::MUX_STASH_LIST
        | method::MUX_STASH_PUSH
        | method::MUX_STASH_GET
        | method::MUX_STASH_DROP
        | method::MUX_STASH_MOVE => {
            // A stashed draft is the person's unsent text and chips: the person's composer only.
            if !conn.is_person() {
                return Err(crate::hub::person::person_required("the composer's stashed drafts"));
            }
            let (m, params) = (m.to_owned(), params.clone());
            tokio::task::spawn_blocking(move || crate::stash::handle(&m, &params))
                .await
                .map_err(|e| RpcError::internal(format!("the stash stopped: {e}")))?
        }
        method::MUX_PROMPTS_LIST | method::MUX_PROMPTS_SAVE | method::MUX_PROMPTS_DELETE => {
            let (m, params) = (m.to_owned(), params.clone());
            tokio::task::spawn_blocking(move || crate::prompts::handle(&m, &params))
                .await
                .map_err(|e| RpcError::internal(format!("saved prompts stopped: {e}")))?
        }
        method::MUX_TAG => {
            let s = hub.resolve(session_key(&params)?)?;
            let remove: Vec<String> = params
                .get("remove")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            // Only `acpmux register` marks a chat registered (`hub/register.rs`), and the daemon's
            // own record decides it; the tag shows it, so no client sets or removes it.
            let set = params.get("set").and_then(Value::as_object);
            if set.is_some_and(|m| m.contains_key(crate::hub::register::REGISTERED_TAG))
                || remove.iter().any(|k| k == crate::hub::register::REGISTERED_TAG)
            {
                return Err(RpcError::invalid_params(format!(
                    "{} is set only by `acpmux register`",
                    crate::hub::register::REGISTERED_TAG
                ))
                .with_data(json!({"reason": "tag.reserved"})));
            }
            hub.set_tags_answered(
                &s,
                set,
                &remove,
                params.get("ttlSeconds").and_then(Value::as_u64),
            )?;
            Ok(hub.session_summary(&s))
        }
        method::MUX_DETACH_PARENT => super::lane_parent::detach(hub, &params),
        // One tag with one value, so a page relay can allow it without
        // reading tag names (`_acpmux/tag` may set any tag).
        // An `opId` runs it once (`hub/op_once.rs`): a resend after a lost reply answers the
        // first result and writes nothing, so a late resend never undoes a later unarchive.
        method::MUX_ARCHIVE => {
            hub.op_once
                .run(m, &params, || async {
                    let s = hub.resolve(session_key(&params)?)?;
                    let archived =
                        params.get("archived").and_then(Value::as_bool).ok_or_else(|| {
                            RpcError::invalid_params("archived must be true or false")
                        })?;
                    // `hub/inactive_archive.rs`: nothing logged when nothing changes (an unarchive of a
                    // chat that is not archived); `changed` says which.
                    let changed = hub.set_archived(&s, archived, false)?;
                    let mut summary = hub.session_summary(&s);
                    if let Some(obj) = summary.as_object_mut() {
                        obj.insert("changed".into(), Value::Bool(changed));
                    }
                    Ok(summary)
                })
                .await
        }
        // A true archive: the chat's log goes into one compressed file (`hub/cold_archive.rs`).
        method::MUX_COLD_ARCHIVE => {
            // Local only, as `_acpmux/retention` (`server/worktrees.rs`): it rewrites the disk.
            if conn.origin.web_class() {
                return Err(RpcError::method_not_found(&format!(
                    "{} (not served to a remote WebSocket connection or a peer)",
                    method::MUX_COLD_ARCHIVE
                )));
            }
            let s = hub.resolve(session_key(&params)?)?;
            let archived = params
                .get("archived")
                .and_then(Value::as_bool)
                .ok_or_else(|| RpcError::invalid_params("archived must be true or false"))?;
            hub.cold_archive_request(s, archived).await
        }
        // Auto mode (`auto_session/surface.rs`): the chat's own machine switches it and settles
        // its kept changes, and only for the person (`auto_gate.rs`).
        method::MUX_AUTO_SESSION_SET
        | method::MUX_AUTO_SESSION_MOVE
        | method::MUX_CHAT_MOVE
        | method::MUX_AUTO_SESSION_LEFTOVER
        | method::MUX_AUTO_SESSION_WAKE
        | method::MUX_AUTO_SESSION_TRANSCRIPT => {
            // On the heap (`heap_future.rs`): this function's frame keeps one pointer for it.
            heap(|| super::auto_gate::request(hub, conn, m, &params)).await
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
            // A fork of the chat, or a session this same connection just made with `session/new`
            // (the repo tour's task, which has no parent): never a session someone else made.
            hub.mark_side(&s, &chat, conn.created_here(&s.id))?;
            Ok(hub.session_summary(&s))
        }
        method::MUX_HARNESS_ENABLE => {
            super::harness_enable::handle(hub, conn.origin, &params).await
        }
        name if super::agent_login::METHODS.contains(&name) => {
            super::agent_login::handle(hub, conn, name, &params).await
        }
        name if super::harness_admin::METHODS.contains(&name) => {
            heap(|| super::harness_admin::handle(hub, conn.origin, name, &params)).await
        }
        method::MUX_ROUTE_LIST
        | method::MUX_ROUTE_SHOW
        | method::MUX_ROUTE_ADD
        | method::MUX_ROUTE_EDIT
        | method::MUX_ROUTE_REMOVE
        | method::MUX_ROUTE_RESTORE
        | method::MUX_ROUTE_TEST
        | method::MUX_ROUTE_DEFAULT_SET
        | method::MUX_CHAT_ROUTE_SET => {
            let reply = heap(|| super::routes::handle(hub, conn.origin, m, &params)).await;
            if reply.is_ok() && super::connections::changes_connections(m) {
                super::connections::announce_later(hub);
            }
            reply
        }
        name if super::account_sign_in::METHODS.contains(&name) => {
            heap(|| super::account_sign_in::handle(hub, conn, name, &params)).await
        }
        method::MUX_ACCOUNTS | method::MUX_ACCOUNT_SET | method::MUX_ACCOUNT_USAGE => {
            let reply = heap(|| super::accounts::handle(hub, conn.origin, m, &params)).await;
            if reply.is_ok() && super::connections::changes_connections(m) {
                super::connections::announce_later(hub);
            }
            reply
        }
        name if super::connections::METHODS.contains(&name) => {
            // A connection's token goes to the person's app, never to an agent acpmux runs: only a
            // connection that proved the person reads one (`connections::reads_token`).
            if super::connections::reads_token(name) && !conn.is_person() {
                return Err(conn.person_only("reading a connection's token"));
            }
            heap(|| super::connections::handle(hub, conn.origin, name, &params)).await
        }
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
            let origin = cmux_cloud_client::backend::platform_origin_env()
                .ok_or_else(|| RpcError::invalid_params("Cloud platform is not configured"))?;
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
        method::MUX_INBOX_SUBSCRIPTION_SET
        | method::MUX_INBOX_SUBSCRIPTION_REMOVE
        | method::MUX_INBOX_SUBSCRIPTIONS => {
            let s = hub.resolve(session_key(&params)?)?;
            // A binding belongs to the resolved recipient.  The person's connection may manage
            // it, or the recipient's own agent may manage its own threads; no other session may
            // claim an owner by putting a different id in the request.
            // The app's own pane (`person_asks`) is the person too: it never sends
            // `_acpmux/person_prove`, so a gate on `is_person` alone refused the pane's held
            // messages panel ("Couldn't read the held messages", Leo 2026-11-22).
            let person = person_asks(conn) || (conn.origin == Origin::Local && !conn.agent_side());
            if !person && conn.caller() != Some(s.id.as_str()) {
                let other = RpcError::invalid_params(
                    "inbox_subscription.other_session: only the person or the chat's own agent manages its bindings",
                )
                .with_data(json!({"reason": "inbox_subscription.other_session"}));
                return Err(conn.refusal("managing another chat's inbox subscription", other));
            }
            // Include records still held during a deferred append and journal records after a
            // restart, using the same session-scoped load path as the inbox itself.
            hub.session_log(&s).await;
            let thread = || {
                params
                    .get("threadId")
                    .and_then(Value::as_str)
                    .filter(|v| !v.is_empty())
                    .ok_or_else(|| RpcError::invalid_params("threadId is required"))
            };
            match m {
                method::MUX_INBOX_SUBSCRIPTION_SET => hub.set_inbox_subscription(&s, thread()?),
                method::MUX_INBOX_SUBSCRIPTION_REMOVE => {
                    hub.remove_inbox_subscription(&s, thread()?)
                }
                _ => hub.inbox_subscriptions(&s),
            }
        }
        method::MUX_INBOX_THREADS | method::MUX_INBOX_THREAD | method::MUX_INBOX_REPLY => {
            let s = hub.resolve(session_key(&params)?)?;
            // The person's, or the chat's own agent's: no other session reads or answers for it.
            // An old acpmux CLI or an agent's shell that declared no terminal is an agent's too
            // (`cli_caller.rs`).
            // The app's own pane (`person_asks`) is the person too: it never sends
            // `_acpmux/person_prove`, so a gate on `is_person` alone refused the pane's held
            // messages panel ("Couldn't read the held messages", Leo 2026-11-22).
            let person = person_asks(conn) || (conn.origin == Origin::Local && !conn.agent_side());
            if !person && conn.caller() != Some(s.id.as_str()) {
                let other = RpcError::invalid_params(
                    "inbox.other_session: only the person or the chat's own agent reads its inbox",
                )
                .with_data(json!({"reason": "inbox.other_session"}));
                return Err(conn.refusal("reading another chat's inbox", other));
            }
            // Its inbox is restored from its log (`restore_queue`): read once that load is done.
            hub.session_log(&s).await;
            let text_of = |k: &str| params.get(k).and_then(Value::as_str).filter(|v| !v.is_empty());
            let thread = || {
                text_of("threadId").ok_or_else(|| RpcError::invalid_params("threadId is required"))
            };
            match m {
                method::MUX_INBOX_THREADS if params.get("search").is_some() => {
                    let query = text_of("search")
                        .ok_or_else(|| RpcError::invalid_params("search needs text"))?;
                    let needle = crate::chats::search::Needle::parse(query)
                        .map_err(RpcError::invalid_params)?;
                    let before = params.get("before").and_then(Value::as_u64);
                    let hub = Arc::clone(hub);
                    tokio::task::spawn_blocking(move || hub.search_held_inbox(&s, &needle, before))
                        .await
                        .map_err(|e| RpcError::internal(format!("inbox search stopped: {e}")))?
                }
                method::MUX_INBOX_THREADS => {
                    // Its held count reads the surge journal's tail from the log.
                    let hub = Arc::clone(hub);
                    tokio::task::spawn_blocking(move || Ok(hub.inbox_threads(&s)))
                        .await
                        .map_err(|e| RpcError::internal(format!("inbox listing stopped: {e}")))?
                }
                method::MUX_INBOX_THREAD => {
                    let mark = params.get("markRead").and_then(Value::as_bool).unwrap_or(false);
                    let (hub, thread) = (Arc::clone(hub), thread()?.to_owned());
                    // Held messages that left memory are read from the log (`inbox_surge.rs`).
                    tokio::task::spawn_blocking(move || hub.inbox_thread_whole(&s, &thread, mark))
                        .await
                        .map_err(|e| RpcError::internal(format!("inbox read stopped: {e}")))?
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
                // So is an old acpmux CLI or a shell that declared no terminal (`cli_caller.rs`).
                if !conn.is_person() && (conn.origin != Origin::Local || conn.agent_side()) {
                    return Err(conn.person_only("changing a session's turn cap"));
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
        method::MUX_ATTACH => attach::attach(hub, conn, params).await,
        method::MUX_DETACH => {
            view::detach(hub, conn, &*hub.resolve(session_key(&params)?)?);
            Ok(json!({}))
        }
        method::MUX_VIEW => {
            let done = view::view(hub, conn, &params)?;
            // Showing a hibernated chat wakes its agent, unless an earlier daemon hibernated it
            // (`hub/idle.rs` `wake_for`).
            // The person's own view only: an authored one is a collaborator's presence.
            if params.get("visible").and_then(Value::as_bool) == Some(true)
                && crate::author::author(&params).ok().flatten().is_none()
                && let Ok(session) = hub.resolve(session_key(&params)?)
            {
                hub.wake_for(&session, super::trust_gate::for_web(conn.origin, &params), "click");
                if person_asks(conn) {
                    hub.release_session_hold_for_person(&session);
                }
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
        method::MUX_HERE_BEAT => {
            if view::a_link(conn) {
                return Err(crate::hub::presence::peer_unsupported());
            }
            Ok(serde_json::to_value(hub.here_beat(&params)?).unwrap_or_default())
        }
        method::MUX_HERE => {
            if view::a_link(conn) {
                return Err(crate::hub::presence::peer_unsupported());
            }
            Ok(serde_json::to_value(hub.here_now(&params)?).unwrap_or_default())
        }
        method::MUX_SYNC_PULL => {
            Ok(serde_json::to_value(hub.sync_pull(&params)?).unwrap_or_default())
        }
        method::MUX_SYNC_PUSH => {
            // A mesh link renames only through `mesh_read.rs`'s checked path, not a merge; the
            // person's own peer daemon (its peer token) pushes their offline edits on connect.
            if view::a_link(conn) && !(conn.origin == Origin::Peer && conn.auth.peer_daemon()) {
                return Err(crate::hub::presence::peer_unsupported());
            }
            Ok(serde_json::to_value(hub.sync_push(&params).await?).unwrap_or_default())
        }
        method::MUX_MARK_UNREAD => {
            let done = view::mark_unread(hub, &params)?;
            synced_mark(hub, &params, false);
            Ok(done)
        }
        method::MUX_MARK_READ => {
            let done = view::mark_read(hub, &params)?;
            synced_mark(hub, &params, true);
            Ok(done)
        }
        method::MUX_SEEN => view::seen(hub, &params),
        method::MUX_PIN => {
            let p: crate::protocol::events::PinParams = serde_json::from_value(params.clone())
                .map_err(|e| RpcError::invalid_params(format!("_acpmux/pin: {e}")))?;
            let s = hub.resolve(&p.session_id)?;
            hub.set_pinned(&s, p.pinned)?;
            Ok(hub.session_summary(&s))
        }
        method::MUX_APP_REPLY => super::app_reply::check(hub, conn, &params),
        method::MUX_HARNESS_INVENTORY_WATCH => super::inventory_watch::handle(hub, conn, &params),
        // A lending Mac counts once this answer is queued (`server/mod.rs`, `github_owner.rs`).
        super::controls::METHOD => super::controls::handle(hub, conn, &params),
        method::MUX_WATCH => super::list_reply::watch(hub, conn, &params).await,
        method::MUX_EVENTS | method::MUX_ATTACHMENT => {
            // A client reading a chat's records again lost some of its stream (a host left frames
            // out): its next chunk goes whole, a template it can rebuild from (`chunk_deltas.rs`).
            if m == method::MUX_EVENTS
                && conn.chunk_deltas.enabled()
                && let Ok(key) = session_key(&params)
                && let Ok(s) = hub.resolve(key)
            {
                conn.chunk_deltas.forget(&s.id);
            }
            // A page reads the log from disk: off the runtime's workers (`qos::off_worker`).
            crate::qos::off_worker(|| events::handle(hub, m, &params, conn.caller()))
        }
        // A read, for whoever may read the log, as `_acpmux/attachment`.
        method::MUX_TURN_SHOTS => {
            let s = hub.resolve(session_key(&params)?)?;
            let turn = str_param(&params, "turnId")
                .ok_or_else(|| RpcError::invalid_params("turnId is required"))?;
            Ok(crate::hub::turn_shots::turn_shots(&s.id, turn).await)
        }
        // A read, for whoever may read the log; `look` captures the page now (the `look` tool).
        method::MUX_TURN_FRAMES => {
            let s = hub.resolve(session_key(&params)?)?;
            if params.get("look").and_then(Value::as_bool) == Some(true) {
                return Ok(crate::hub::turn_frames::look(&s.id).await);
            }
            Ok(crate::hub::turn_frames::turn_frames(&s.id, &params).await)
        }
        // The person's own click on a wrap-up card (`customize_run.rs`): an allowlisted
        // `cmux customize` argv, no shell. Never offered to a read-only connection. Only the
        // person runs it: a connection that proved it is the person, or this host's app pane,
        // whose host admits it only with a click's gesture ticket (`gesture_rules`, policy.json).
        // An agent, a peer or a remote writable client never starts a build here.
        method::MUX_CUSTOMIZE_RUN => {
            if !person_asks(conn) {
                return Err(conn.person_only("running cmux customize"));
            }
            crate::customize_run::run(&params).await.map_err(RpcError::invalid_params)
        }
        // A read, for whoever may read the log, as `_acpmux/events` (`hub/queue_text.rs`).
        method::MUX_QUEUE_TEXT => Box::pin(queue_text(hub, &params)).await,
        method::MUX_ROWS => Box::pin(rows(hub, conn, &params)).await,
        method::MUX_MAIL_SEND
        | method::MUX_MAIL_READ
        | method::MUX_MAIL_WAIT
        | method::MUX_MAIL_ACK => mailbox::handle(hub, conn, m, &params).await,
        method::MUX_TEAM_SEND
        | method::MUX_TEAM_INBOX
        | method::MUX_TEAM_READ
        | method::MUX_TEAM_ACK
        | method::MUX_TEAM_LISTEN => super::team::handle(hub, conn, m, &params).await,
        method::MUX_REGISTER => {
            // Only a process of this machine, by the pid the kernel gave at accept: the session
            // registered is the one that process runs under, never one it names.
            let pid = match (conn.origin, conn.socket_peer) {
                (super::Origin::Local, crate::sender_harness::SocketPeer::Pid(pid)) => pid,
                _ => {
                    return Err(RpcError::invalid_params(
                        "register is taken only from this machine's unix socket",
                    )
                    .with_data(json!({"reason": "register.origin_refused"})));
                }
            };
            let req = crate::hub::register::RegisterRequest::from_params(&params)?;
            hub.register_caller(pid, req).await
        }
        method::MUX_INBOX_RELAY => {
            // As register: the session served is the one the kernel's pid runs under.
            let pid = match (conn.origin, conn.socket_peer) {
                (super::Origin::Local, crate::sender_harness::SocketPeer::Pid(pid)) => pid,
                _ => {
                    return Err(RpcError::invalid_params(
                        "an inbox relay is taken only from this machine's unix socket",
                    )
                    .with_data(json!({"reason": "inbox_relay.origin_refused"})));
                }
            };
            let home = hub.harness_homes().claude;
            crate::claude_inbox_relay::poll(pid, home, &params, conn.ended.subscribe()).await
        }
        method::MUX_SUCCEED => {
            let s = hub.resolve(session_key(&params)?)?;
            let names: Vec<String> = params
                .get("names")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            hub.succeed(&s, &names)
        }
        method::MUX_ROLE => {
            let op = params.get("op").and_then(Value::as_str).unwrap_or("ls");
            if op == "ls" {
                return Ok(hub.roles_list());
            }
            let s = hub.resolve(session_key(&params)?)?;
            let address = params.get("address").and_then(Value::as_str).unwrap_or_default();
            match op {
                "claim" => hub.claim_role(&s, address),
                "release" => hub.release_role(&s, address),
                other => Err(RpcError::invalid_params(format!(
                    "op {other:?}: give claim, release or ls"
                ))),
            }
        }
        // An `opId` runs it once, as `_acpmux/archive` (`hub/op_once.rs`).
        method::MUX_RENAME => hub.op_once.run(m, &params, || rename(hub, &params)).await,
        method::MUX_KEEP => {
            let id = str_param(&params, "sessionId")
                .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
            super::ephemeral::keep(conn, id)?;
            Ok(json!({"sessionId": id, "ephemeral": false}))
        }
        method::MUX_KILL => {
            // Cancel on a fork still being made, or made and not yet answered: its request's
            // token names it (`hub/fork_cancel.rs`).
            if params.get("cancelFork").and_then(Value::as_bool) == Some(true)
                && let Some(token) = params.get("cancelToken").and_then(Value::as_str)
            {
                return Ok(json!({"cancelled": hub.cancel_pending_fork(token).await?}));
            }
            let s = hub.resolve(session_key(&params)?)?;
            // A Fork Conversation the person cancelled before using it (`hub/fork_cancel.rs`).
            if params.get("cancelFork").and_then(Value::as_bool) == Some(true) {
                heap(|| hub.cancel_fork(&s)).await?;
                return Ok(json!({"sessionId": s.id, "purged": true}));
            }
            let purge = params.get("purge").and_then(Value::as_bool).unwrap_or(false);
            // `ifIdle`: refused unless idle, checked under the turn lock (`stop_if_idle.rs`).
            let condition = crate::hub::stop_if_idle::StopCondition::from_params(&params)?;
            // Who asked, and the `reason`/`outcome` it gave (`close_why.rs`): recorded, never
            // refused.
            let why = crate::close_why::CloseWhy::from_params(conn.close_actor(&s.id), &params);
            heap(|| hub.stop_why(&s, purge, condition, why)).await?;
            Ok(json!({"sessionId": s.id, "purged": purge}))
        }
        // Hibernate an idle session now, or start a hibernated one's agent now (`hub/pause.rs`).
        method::MUX_PAUSE => {
            let s = hub.resolve(session_key(&params)?)?;
            heap(|| hub.pause(&s)).await
        }
        method::MUX_WAKE => {
            let s = hub.resolve(session_key(&params)?)?;
            heap(|| hub.wake(&s)).await
        }
        // Hold a chat, or release it; set or read the fleet hold (`hub/session_hold.rs`).
        method::MUX_SESSION_HOLD => {
            let s = hub.resolve(session_key(&params)?)?;
            let held = params.get("held").and_then(Value::as_bool).unwrap_or(true);
            heap(|| hub.set_session_hold(&s, held)).await
        }
        method::MUX_FLEET_HOLD => hub.set_fleet_hold(&params),
        method::MUX_WATCH_TAKE_OVER => super::chats::watch_take_over(hub, &params).await,
        method::MUX_RELEASE_TO_WATCH => {
            super::chats::release_to_watch(hub, &params, conn.origin, conn.socket_peer).await
        }
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
            let device = super::remote_guard::sending_device(conn, &params);
            let gated = super::trust_gate::gated(conn.origin, &params);
            hub.queue_edit(&s, &params, control, gated, device.as_deref()).await
        }
        m if queued::handles(m) => queued::handle(hub, conn, m, &params).await,
        method::MUX_SEND_QUEUE | method::MUX_SEND_STATUS => {
            heap(|| super::outbox::handle(hub, conn, m, &params)).await
        }
        method::MUX_SESSION_AUTH => heap(|| super::session_auth::handle(hub, conn, params)).await,
        method::MUX_PROMPT_WITHDRAW
        | method::MUX_AGENT_PAIR_RESUME
        | method::MUX_AGENT_HOLD
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
            let device = super::remote_guard::sending_device(conn, &params);
            hub.respond_permission_group(&s, params, control, conn.is_person(), device.as_deref())
                .await
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
            // A notification's one-tap choice (`hub/ask_choices.rs`): the option and answers it
            // stands for, then the same answer and checks.
            // One that is not a string is refused, never read as no choice (a cancel).
            if let Some(choice) = params.get("choiceId").filter(|v| !v.is_null()) {
                let choice = choice
                    .as_str()
                    .ok_or_else(|| RpcError::invalid_params("choiceId must be a string"))?;
                let answered = answers.as_ref().is_some_and(|a| !a.is_null());
                if option.is_some() || answered || annotations.is_some() {
                    return Err(RpcError::invalid_params(
                        "choiceId goes alone: no optionId, answers or annotations beside it",
                    ));
                }
                hub.respond_choice(&s, pid, choice, answered_by, answerer, control).await?;
                return Ok(json!({}));
            }
            // "Fork first" (`fork_risky.rs`): the app forked this machine; only the person's
            // allow may name the copy as the step's checkpoint.
            let checkpoint = match params.get("forkCheckpoint").filter(|v| !v.is_null()) {
                Some(carried) => {
                    if !conn.is_person() {
                        return Err(RpcError::invalid_params(crate::hub::person::REASON));
                    }
                    Some(hub.fork_checkpoint(&s, pid, option.as_deref(), carried)?)
                }
                None => None,
            };
            // The paired machine that answers, for D13 (`Hub::local_claude_refusal`).
            let device = super::remote_guard::sending_device(conn, &params);
            answerer.device = device.as_deref();
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
            Ok(checkpoint.map_or_else(|| json!({}), |c| json!({"forkCheckpoint": c})))
        }
        method::MUX_SET_POLICY => {
            // The chat a proved raise was checked for (`hub/person/policy_grant.rs`).
            let s = resolved_session(hub, resolved.as_ref(), &params)?;
            let policy: PermissionPolicy = str_param(&params, "policy")
                .ok_or_else(|| RpcError::invalid_params("policy is required"))?
                .parse()
                .map_err(RpcError::invalid_params)?;
            refuse_full_access_policy(hub, Some(policy))?;
            crate::hub::restricted::refuse_widening(&s.meta(), policy)?;
            heap(|| hub.set_policy_unless_moving(&s, policy)).await?;
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
            let s = heap(|| hub.import(&path, name)).await?;
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
        method::MUX_UPLOADS_KEEP => crate::hub::file_uploads::handle_keep(hub, params).await,
        // Every Claude workflow of this daemon's chats.
        method::MUX_WORKFLOWS => crate::hub::workflow_index::handle(hub, &params),
        // A chat's media, from this connection's handles; a peer's chat went there.
        method::MUX_MEDIA_OPEN | method::MUX_MEDIA_RANGE => {
            crate::hub::media_read::handle(hub, &conn.media, m, &params).await
        }
        // A chat's subagents, running and lately ended, from its subagent tree.
        method::MUX_SUBAGENT_LIST => crate::hub::subagent_list::handle(hub, &params),
        // A subagent's transcript, read from the files Claude Code writes for the chat.
        method::MUX_SUBAGENT_TRANSCRIPT => {
            heap(|| crate::hub::subagent_transcript::handle(hub, &params)).await
        }
        // A chat's older turns, read from its Claude Code transcript (`hub/native_history.rs`).
        method::MUX_NATIVE_HISTORY => crate::hub::native_history::handle(hub, &params).await,
        method::MUX_SHUTDOWN => shutdown::shutdown(hub, conn, params).await,
        method::MUX_HANDOFF_PREPARE => {
            heap(|| hub.handoff_prepare(&params, conn.origin.web_class())).await
        }
        method::MUX_HANDOFF_GET => hub.handoff_get(&params),
        method::MUX_HANDOFF_DRAFT => hub.handoff_draft(&params).await,
        method::MUX_HANDOFF_START => {
            let control = super::remote_guard::control_of(conn.origin, conn.auth, &params);
            // Its first prompt is the person's only by the same proof as a prompt's.
            let sender = (!person_admitted(conn, &params))
                .then(|| crate::prompt_provenance::HandoffSender { transport: transport_of(conn) });
            hub.handoff_start(&params, control, sender).await
        }
        method::MUX_HANDOFF_DISCARD => heap(|| hub.handoff_discard(&params)).await,
        // Anything else that names a session goes to the agent untouched, from the unix
        // socket (the app: only a subagent stop); it may spawn or read (`remote_guard.rs`).
        other => {
            let key = session_key(&params).map_err(|_| match other {
                method::MUX_SUBAGENT_STOP | method::MUX_STEER_WITHDRAW | method::MUX_STEP_NOW => {
                    RpcError::invalid_params("sessionId is required")
                }
                _ => RpcError::method_not_found(other),
            })?;
            if !super::remote_guard::forwards(conn.origin, other) {
                return Err(RpcError::invalid_params(format!(
                    "{other} is passed to the harness only from the local unix socket"
                )));
            }
            let s = hub.resolve(key)?;
            crate::hub::person::harness_forward_check(conn.is_person(), other)?;
            heap(|| hub.forward(&s, other, params)).await
        }
    }
}
