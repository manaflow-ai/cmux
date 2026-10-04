//! Request and notification handlers for one client connection.

use super::*;

/// Subscribe the connection to a session and, when that is new, count it
/// as attached (remote sessions are not counted; their host does that).
fn attach(hub: &Hub, conn: &Conn, id: &str) {
    if conn.subscribe(id)
        && let Ok(s) = hub.resolve(id)
    {
        hub.attach_count(&s, 1);
    }
}

pub(super) async fn handle_notification(hub: &Arc<Hub>, conn: &Arc<Conn>, m: &str, params: Value) {
    match m {
        method::SESSION_CANCEL => {
            if let Ok(key) = session_key(&params) {
                if let Ok(s) = hub.resolve(key) {
                    if let Err(e) = hub.cancel(&s).await {
                        tracing::debug!(conn = %conn.id, "cancel: {e}");
                    }
                } else if let Some((peer, id, _)) = hub.resolve_remote(key) {
                    let _ = peer.notify(method::SESSION_CANCEL, json!({"sessionId": id})).await;
                }
            }
        }
        method::CANCEL_REQUEST => {}
        _ => tracing::debug!(conn = %conn.id, "ignored notification {m}"),
    }
}

const SESSION_SCOPED_EXCLUDED: &[&str] = &[
    method::INITIALIZE,
    method::AUTHENTICATE,
    method::SESSION_NEW,
    method::SESSION_LIST,
    method::MUX_STATUS,
    method::MUX_SESSIONS,
    method::MUX_HARNESSES,
    method::MUX_RELOAD_CONFIG,
    method::MUX_WATCH,
    method::MUX_WARM,
    method::MUX_IMPORT,
    method::MUX_SHUTDOWN,
    method::MUX_HANDOFF_PREPARE,
    method::MUX_HANDOFF_GET,
    method::MUX_HANDOFF_DRAFT,
    method::MUX_HANDOFF_START,
    method::MUX_HANDOFF_DISCARD,
    "_acpmux/peers",
    "_acpmux/models",
    "_acpmux/peer_add",
    "_acpmux/peer_remove",
    "_acpmux/peer_reconnect",
];

pub(super) async fn handle_request(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: Value,
) -> Result<Value, RpcError> {
    // A session that lives on a peer: forward the whole request there.
    if !SESSION_SCOPED_EXCLUDED.contains(&m)
        && let Ok(key) = session_key(&params)
        && hub.resolve(key).is_err()
        && let Some((peer, id, _)) = hub.resolve_remote(key)
    {
        let mut p = if params.is_null() { json!({}) } else { params.clone() };
        if let Some(obj) = p.as_object_mut() {
            obj.remove("session");
            obj.remove("name");
            obj.insert("sessionId".into(), Value::String(id.clone()));
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
                conn.subscribe_with(&id, SubOpts { event_stream, filter });
            } else {
                attach(hub, conn, &id);
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
            attach(hub, conn, new_id);
            peer.mark_attached(new_id);
        }
        if m == method::MUX_KILL && params.get("purge").and_then(Value::as_bool).unwrap_or(false) {
            hub.forget_remote(&id);
        }
        if let Some(obj) = result.as_object_mut() {
            obj.insert("peer".into(), Value::String(peer.name.clone()));
        }
        return Ok(result);
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
                "_meta": {"acpmux": {"version": VERSION, "build": crate::hub::BUILD, "extensions": [
                    method::MUX_STATUS, method::MUX_SESSIONS, method::MUX_HARNESSES, method::MUX_RELOAD_CONFIG, method::MUX_ATTACH, method::MUX_WARM,
                    method::MUX_DETACH, method::MUX_WATCH, method::MUX_RENAME, method::MUX_KILL,
                    method::MUX_INFO, method::MUX_EVENTS, method::MUX_PERMISSION_RESPOND,
                    method::MUX_SET_POLICY, method::MUX_EXPORT, method::MUX_IMPORT, method::MUX_SHUTDOWN,
                ], "operations": crate::hub::HANDOFF_OPERATIONS.iter().chain(crate::hub::PERMISSION_GROUP_OPERATIONS.iter()).collect::<Vec<_>>(), "handoff": {"maxCapsuleBytes": crate::hub::MAX_CAPSULE_BYTES},
                "features": ["promptAccepted", "turnIds", "eventPaging", "eventKinds", "eventStream", "cancelRequest", "messageSuperseded", "turnErrorText", "permissionGroups"]}}
            }))
        }
        method::AUTHENTICATE => Ok(json!({})),
        method::SESSION_NEW => {
            // A peer name in _meta.acpmux.peer creates the session on that daemon.
            if let Some(peer_name) =
                mux_meta(&params).and_then(|m| m.get("peer")).and_then(Value::as_str)
                && !peer_name.is_empty()
            {
                let peer = hub
                    .peer_by_name(peer_name)
                    .ok_or_else(|| RpcError::not_found(format!("no peer {peer_name:?}")))?;
                let mut p = params.clone();
                if let Some(m) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
                    m.remove("peer");
                }
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
            let cwd = str_param(&params, "cwd").map(PathBuf::from);
            let meta = mux_meta(&params);
            let adopt =
                crate::adopt::AdoptRequest::from_meta(meta).map_err(RpcError::invalid_params)?;
            let pick = |key: &str| {
                meta.and_then(|m| m.get(key))
                    .and_then(Value::as_str)
                    .map(str::to_owned)
                    .or_else(|| params.get(key).and_then(Value::as_str).map(str::to_owned))
            };
            let policy = pick("policy")
                .map(|p| p.parse::<PermissionPolicy>().map_err(RpcError::invalid_params))
                .transpose()?;
            let req = crate::hub::NewRequest {
                harness: pick("harness"),
                preset: pick("preset"),
                name: pick("name"),
                cwd,
                policy,
                model: pick("model"),
                effort: pick("effort"),
                adopt,
                remote: conn.origin == Origin::Web,
            };
            let s = hub.new_session(req).await?;
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
            let s = hub.resolve(session_key(&params)?)?;
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
            let s = hub.resolve(session_key(&params)?)?;
            attach(hub, conn, &s.id);
            let blocks = params
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
            let steer = mux_meta(&params)
                .and_then(|m| m.get("steer"))
                .and_then(Value::as_bool)
                .or_else(|| params.get("steer").and_then(Value::as_bool))
                .unwrap_or(false);
            let prompt_id = mux_meta(&params)
                .and_then(|m| m.get("promptId"))
                .and_then(Value::as_str)
                .filter(|p| !p.is_empty())
                .map(str::to_owned);
            let resend = mux_meta(&params)
                .and_then(|m| m.get("resend"))
                .and_then(Value::as_bool)
                .unwrap_or(false);
            let notify = conn.clone();
            let opts = crate::hub::PromptOptions {
                prompt_id,
                on_accepted: Some(Box::new(move |v| {
                    notify.send(&Message::notification(method::MUX_PROMPT_ACCEPTED, v))
                })),
                resend,
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
            let s = hub.resolve(session_key(&params)?)?;
            let cwd = str_param(&params, "cwd").map(PathBuf::from);
            let name = mux_meta(&params)
                .and_then(|m| m.get("name"))
                .and_then(Value::as_str)
                .or_else(|| params.get("name").and_then(Value::as_str))
                .map(str::to_owned);
            let new = hub.fork(&s, name, cwd).await?;
            attach(hub, conn, &new.id);
            let meta = new.meta();
            Ok(
                json!({"sessionId": new.id, "modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(&new)}}),
            )
        }
        method::SESSION_SET_MODE => {
            let s = hub.resolve(session_key(&params)?)?;
            let mode = str_param(&params, "modeId")
                .ok_or_else(|| RpcError::invalid_params("modeId is required"))?;
            hub.set_mode(&s, mode).await
        }
        method::SESSION_SET_CONFIG_OPTION => {
            let s = hub.resolve(session_key(&params)?)?;
            let id = str_param(&params, "configId")
                .ok_or_else(|| RpcError::invalid_params("configId is required"))?;
            let value = params
                .get("value")
                .cloned()
                .ok_or_else(|| RpcError::invalid_params("value is required"))?;
            hub.set_config(&s, id, value).await
        }
        method::SESSION_SET_MODEL => {
            let s = hub.resolve(session_key(&params)?)?;
            let model = str_param(&params, "modelId")
                .ok_or_else(|| RpcError::invalid_params("modelId is required"))?;
            hub.set_model(&s, model).await
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
        method::MUX_STATUS => Ok(hub.status().await),
        method::MUX_SESSIONS => Ok(json!({"sessions": hub.all_session_summaries()})),
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
        "_acpmux/peer_add" => {
            let name = str_param(&params, "name")
                .ok_or_else(|| RpcError::invalid_params("name is required"))?;
            let url = str_param(&params, "url")
                .ok_or_else(|| RpcError::invalid_params("url is required"))?;
            let token = str_param(&params, "token").map(str::to_owned);
            let wait = params.get("wait").and_then(Value::as_bool).unwrap_or(false);
            hub.add_peer(name, url, token, wait).await?;
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
        method::MUX_HARNESSES => {
            let cfg = hub.config.read().await;
            let mut agents = serde_json::Map::new();
            for (name, p) in &cfg.harnesses {
                let mut v = serde_json::to_value(p).unwrap_or(Value::Null);
                if let Some(o) = v.as_object_mut() {
                    o.insert("family".into(), json!(crate::config::derive_family(name, p)));
                    if let Some(r) = cfg.unavailable.get(name) {
                        o.insert("unavailable".into(), json!(r));
                    }
                    if let Some(r) = hub.probe_errors.lock().unwrap().get(name) {
                        o.insert("probeError".into(), json!(r));
                    }
                    let d = cfg.defaults_for(name);
                    if !d.is_empty() {
                        o.insert("defaults".into(), json!(d));
                    }
                }
                agents.insert(name.clone(), v);
            }
            Ok(
                json!({"harnesses": agents, "defaultHarness": cfg.default_harness, "families": cfg.families(), "defaults": cfg.defaults, "presets": cfg.presets}),
            )
        }
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
        // Read or change presets: {name?, set?: {harness, model, effort, policy, env, args}, clear?: bool}.
        method::MUX_PRESETS => {
            let name = str_param(&params, "name").map(str::to_owned);
            let set = params.get("set").filter(|v| v.is_object());
            let clear = params.get("clear").and_then(Value::as_bool).unwrap_or(false);
            if set.is_some() || clear {
                let name = name.clone().ok_or_else(|| {
                    RpcError::invalid_params("name is required to change a preset")
                })?;
                let mut cfg = hub.config.write().await;
                // REMOTE-FLOOR v3: a remote-origin client builds its settings
                // from scratch, so it never sets, changes or clears a preset
                // that shapes the harness command line (args, systemPrompt).
                let remote = conn.origin == Origin::Web;
                if remote
                    && (cfg.presets.get(&name).is_some_and(|p| p.shapes_command())
                        || set.is_some_and(|s| {
                            ["args", "systemPrompt"]
                                .iter()
                                .any(|k| s.get(*k).is_some_and(|v| !v.is_null()))
                        }))
                {
                    return Err(RpcError::invalid_params(format!(
                        "preset {name:?}: args and systemPrompt are set only over the local socket; a remote-origin connection builds its settings from scratch"
                    )));
                }
                let presets_dir = cfg.presets_dir();
                // The new system prompt text, written once the set is valid.
                let mut new_prompt: Option<Option<String>> = None;
                if clear {
                    cfg.presets.remove(&name);
                    if let Some(dir) = &presets_dir {
                        crate::config::remove_preset_dir(dir, &name).map_err(|e| {
                            RpcError::internal(format!("remove preset directory: {e}"))
                        })?;
                    }
                } else if let Some(set) = set {
                    let obj = set.as_object().unwrap();
                    let mut merged = cfg.presets.get(&name).cloned();
                    let harness = obj
                        .get("harness")
                        .and_then(Value::as_str)
                        .map(str::to_owned)
                        .or_else(|| merged.as_ref().map(|p| p.harness.clone()))
                        .ok_or_else(|| {
                            RpcError::invalid_params("a preset needs harness=FAMILY-or-PROFILE")
                        })?;
                    cfg.resolve_harness(&harness).map_err(RpcError::invalid_params)?;
                    let p = merged.get_or_insert_with(|| crate::config::Preset {
                        harness: harness.clone(),
                        model: None,
                        effort: None,
                        policy: None,
                        env: std::collections::BTreeMap::new(),
                        args: Vec::new(),
                        system_prompt_sha256: None,
                        description: None,
                    });
                    p.harness = harness;
                    for (k, v) in obj {
                        match (k.as_str(), v) {
                            ("harness", _) => {}
                            ("model", Value::Null) => p.model = None,
                            ("model", Value::String(m)) => p.model = Some(m.clone()),
                            ("effort", Value::Null) => p.effort = None,
                            ("effort", Value::String(e)) => p.effort = Some(e.clone()),
                            ("policy", Value::Null) => p.policy = None,
                            ("policy", Value::String(pol)) => {
                                p.policy = Some(
                                    pol.parse::<PermissionPolicy>()
                                        .map_err(RpcError::invalid_params)?,
                                )
                            }
                            ("description", Value::Null) => p.description = None,
                            ("description", Value::String(d)) => p.description = Some(d.clone()),
                            ("systemPrompt", Value::Null) => new_prompt = Some(None),
                            ("systemPrompt", Value::String(text)) => {
                                new_prompt = Some(Some(text.clone()))
                            }
                            ("systemPrompt", _) => {
                                return Err(RpcError::invalid_params(
                                    "systemPrompt must be the prompt's text (a string) or null",
                                ));
                            }
                            ("args", Value::Null) => p.args.clear(),
                            ("args", v) => {
                                p.args = crate::config::parse_preset_args(v)
                                    .map_err(RpcError::invalid_params)?
                            }
                            ("env", Value::Null) => p.env.clear(),
                            ("env", Value::Object(map)) => {
                                for (ek, ev) in map {
                                    match ev {
                                        Value::Null => {
                                            p.env.remove(ek);
                                        }
                                        Value::String(s) => {
                                            p.env.insert(ek.clone(), s.clone());
                                        }
                                        _ => {
                                            return Err(RpcError::invalid_params(format!(
                                                "env.{ek} must be a string"
                                            )));
                                        }
                                    }
                                }
                            }
                            (other, _) => {
                                return Err(RpcError::invalid_params(format!(
                                    "unknown preset key {other:?}; use harness, model, effort, policy, env, args, systemPrompt, description"
                                )));
                            }
                        }
                    }
                    let mut p = merged.unwrap();
                    // Checked against the profile the preset resolves to now.
                    let profile =
                        cfg.resolve_harness(&p.harness).map_err(RpcError::invalid_params)?;
                    let kind = cfg.harnesses[&profile].kind;
                    crate::config::check_preset_args(kind, &p.args)
                        .map_err(RpcError::invalid_params)?;
                    let keeps_prompt =
                        p.system_prompt_sha256.is_some() && !matches!(new_prompt, Some(None));
                    if (matches!(new_prompt, Some(Some(_))) || keeps_prompt)
                        && kind != crate::config::HarnessKind::ClaudeStdio
                    {
                        return Err(RpcError::invalid_params(
                            "systemPrompt: only Claude Code harnesses take a system prompt file",
                        ));
                    }
                    match new_prompt {
                        Some(Some(text)) => {
                            crate::config::check_preset_dir_name(&name)
                                .map_err(RpcError::invalid_params)?;
                            let dir = presets_dir.as_ref().ok_or_else(|| {
                                RpcError::invalid_params(
                                    "systemPrompt: this daemon has no state directory for preset files",
                                )
                            })?;
                            let sha = crate::config::write_system_prompt(dir, &name, &text)
                                .map_err(|e| {
                                    RpcError::internal(format!("write the system prompt file: {e}"))
                                })?;
                            p.system_prompt_sha256 = Some(sha);
                        }
                        Some(None) => {
                            p.system_prompt_sha256 = None;
                            if let Some(dir) = &presets_dir {
                                crate::config::remove_preset_dir(dir, &name).map_err(|e| {
                                    RpcError::internal(format!("remove preset directory: {e}"))
                                })?;
                            }
                        }
                        None => {}
                    }
                    cfg.presets.insert(name.clone(), p);
                }
                if let Err(e) = cfg.save() {
                    return Err(RpcError::internal(format!("save config: {e}")));
                }
            }
            let cfg = hub.config.read().await;
            let view = |n: &str, p: &crate::config::Preset| {
                let (profile, error) = match cfg.resolve_harness(&p.harness) {
                    Ok(x) => (Some(x), None),
                    Err(e) => (None, Some(e)),
                };
                json!({"name": n, "harness": p.harness, "profile": profile, "error": error, "model": p.model, "effort": p.effort, "policy": p.policy, "env": p.env, "args": p.args, "systemPromptSha256": p.system_prompt_sha256, "description": p.description})
            };
            match name {
                Some(n) if !clear => cfg
                    .presets
                    .get(&n)
                    .map(|p| view(&n, p))
                    .ok_or_else(|| RpcError::not_found(format!("no preset {n:?}"))),
                _ => Ok(
                    json!({"presets": cfg.presets.iter().map(|(n, p)| view(n, p)).collect::<Vec<_>>()}),
                ),
            }
        }
        method::MUX_INFO => {
            let s = hub.resolve(session_key(&params)?)?;
            Ok(hub.session_detail(&s))
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
        method::ACP_TRUST_GET | method::ACP_TRUST_SET => {
            let cwd = params.get("cwd").and_then(Value::as_str).unwrap_or_default().to_owned();
            let level = params.get("level").and_then(Value::as_str).map(str::to_owned);
            let setting = m == method::ACP_TRUST_SET;
            // Small files, read and written off the runtime threads.
            let reply = tokio::task::spawn_blocking(move || {
                let paths = crate::trust::Paths::current()
                    .ok_or_else(|| crate::trust::Failure::Record("no home directory".into()))?;
                if setting {
                    crate::trust::set(&paths, &cwd, level.as_deref().unwrap_or_default())
                } else {
                    crate::trust::get(&paths, &cwd)
                }
            })
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?;
            reply.map_err(|failure| match failure {
                crate::trust::Failure::Invalid(message) => RpcError::invalid_params(message),
                crate::trust::Failure::Record(message) => RpcError::internal(message),
            })
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
            if conn.subscribe_with(&s.id, SubOpts { event_stream, filter: filter.clone() }) {
                hub.attach_count(&s, 1);
            }
            let after = params.get("afterSeq").and_then(Value::as_u64);
            let before = params.get("beforeSeq").and_then(Value::as_u64);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(2000) as usize;
            let detail = hub.session_detail(&s);
            // afterSeq alone pages forward (oldest first); otherwise the page
            // is the newest `limit` records before beforeSeq (or the end).
            let newest = after.is_none() || before.is_some();
            let page = hub
                .events_page(&s.id, after.unwrap_or(0), before, limit, newest, &filter)
                .map_err(|e| RpcError::internal(e.to_string()))?;
            let events: Vec<Value> = page.events.iter().map(|r| event_value(&s.id, r)).collect();
            Ok(
                json!({"session": detail, "events": events, "hasMore": page.has_more, "lastSeq": s.meta().last_seq}),
            )
        }
        method::MUX_DETACH => {
            let s = hub.resolve(session_key(&params)?)?;
            if conn.unsubscribe(&s.id) {
                hub.attach_count(&s, -1);
            }
            Ok(json!({}))
        }
        method::MUX_WATCH => {
            let on = params.get("enabled").and_then(Value::as_bool).unwrap_or(true);
            conn.watch_all.store(on, Ordering::SeqCst);
            Ok(json!({"sessions": hub.all_session_summaries()}))
        }
        method::MUX_EVENTS => {
            let s = hub.resolve(session_key(&params)?)?;
            let after = params.get("afterSeq").and_then(Value::as_u64).unwrap_or(0);
            let before = params.get("beforeSeq").and_then(Value::as_u64);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(5000) as usize;
            let filter = crate::hub::EventFilter::parse(params.get("kinds"))?;
            let last = s.meta().last_seq;
            if after > last {
                return Err(RpcError::invalid_params(format!(
                    "cursor_future: afterSeq {after} is beyond the last event {last}"
                )));
            }
            // beforeSeq pages backwards: the newest `limit` records before it.
            let page = hub
                .events_page(&s.id, after, before, limit, before.is_some(), &filter)
                .map_err(|e| RpcError::internal(e.to_string()))?;
            Ok(json!({
                "events": page.events.iter().map(|r| event_value(&s.id, r)).collect::<Vec<_>>(),
                "hasMore": page.has_more,
                "lastSeq": last,
            }))
        }
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
        method::MUX_PERMISSION_GROUPS => {
            let s = hub.resolve(session_key(&params)?)?;
            hub.permission_groups(&s, &params)
        }
        method::MUX_PERMISSION_GROUP_RESPOND => {
            let s = hub.resolve(session_key(&params)?)?;
            hub.respond_permission_group(&s, params).await
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
            hub.respond_permission(&s, pid, option, answers).await?;
            Ok(json!({}))
        }
        method::MUX_SET_POLICY => {
            let s = hub.resolve(session_key(&params)?)?;
            let policy: PermissionPolicy = str_param(&params, "policy")
                .ok_or_else(|| RpcError::invalid_params("policy is required"))?
                .parse()
                .map_err(RpcError::invalid_params)?;
            hub.set_policy(&s, policy).await;
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
                hub.end_agents_at_shutdown(keep.clone());
            }
            hub.shutdown.notify_waiters();
            hub.shutdown.notify_one();
            let kept = if end_agents {
                keep.iter().filter(|id| hub.resolve(id).is_ok()).count()
            } else {
                0
            };
            Ok(json!({"endAgents": end_agents, "keptSessions": kept}))
        }
        method::MUX_HANDOFF_PREPARE => hub.handoff_prepare(&params).await,
        method::MUX_HANDOFF_GET => hub.handoff_get(&params),
        method::MUX_HANDOFF_DRAFT => hub.handoff_draft(&params).await,
        method::MUX_HANDOFF_START => hub.handoff_start(&params).await,
        method::MUX_HANDOFF_DISCARD => hub.handoff_discard(&params).await,
        // Anything else that names a session goes to the agent untouched.
        other => {
            if let Ok(key) = session_key(&params) {
                let s = hub.resolve(key)?;
                return hub.forward(&s, other, params).await;
            }
            Err(RpcError::method_not_found(other))
        }
    }
}
