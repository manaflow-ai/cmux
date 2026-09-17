//! Request and notification handlers for one client connection.

use super::*;

pub(super) async fn handle_notification(hub: &Arc<Hub>, conn: &Arc<Conn>, m: &str, params: Value) {
    match m {
        method::SESSION_CANCEL => {
            if let Ok(key) = session_key(&params) {
                if let Ok(s) = hub.resolve(key) {
                    if let Err(e) = hub.cancel(&s).await {
                        tracing::warn!(conn = %conn.id, "cancel failed: {e}");
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
    method::MUX_AGENTS,
    method::MUX_WATCH,
    method::MUX_IMPORT,
    method::MUX_SHUTDOWN,
    "_acpmux/peers",
    "_acpmux/models",
    "_acpmux/peer_add",
    "_acpmux/peer_remove",
];

pub(super) async fn handle_request(hub: &Arc<Hub>, conn: &Arc<Conn>, m: &str, params: Value) -> Result<Value, RpcError> {
    // A session that lives on a peer: forward the whole request there.
    if !SESSION_SCOPED_EXCLUDED.contains(&m) {
        if let Ok(key) = session_key(&params) {
            if hub.resolve(key).is_err() {
                if let Some((peer, id, _)) = hub.resolve_remote(key) {
                    let mut p = if params.is_null() { json!({}) } else { params.clone() };
                    if let Some(obj) = p.as_object_mut() {
                        obj.remove("session");
                        obj.remove("name");
                        obj.insert("sessionId".into(), Value::String(id.clone()));
                    }
                    if matches!(m, method::MUX_ATTACH | method::SESSION_PROMPT | method::SESSION_LOAD | method::SESSION_RESUME | method::SESSION_FORK) {
                        conn.subscribe(&id);
                        if peer.mark_attached(&id) && m != method::MUX_ATTACH {
                            let _ = peer.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await;
                        }
                    }
                    let mut result = peer.request(m, p).await?;
                    if m == method::SESSION_FORK {
                        if let Some(new_id) = result.get("sessionId").and_then(Value::as_str) {
                            conn.subscribe(new_id);
                            peer.mark_attached(new_id);
                        }
                    }
                    if let Some(obj) = result.as_object_mut() {
                        obj.insert("peer".into(), Value::String(peer.name.clone()));
                    }
                    return Ok(result);
                }
            }
        }
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
                "_meta": {"acpmux": {"version": VERSION, "extensions": [
                    method::MUX_STATUS, method::MUX_SESSIONS, method::MUX_AGENTS, method::MUX_ATTACH,
                    method::MUX_DETACH, method::MUX_WATCH, method::MUX_RENAME, method::MUX_KILL,
                    method::MUX_INFO, method::MUX_EVENTS, method::MUX_PERMISSION_RESPOND,
                    method::MUX_SET_POLICY, method::MUX_EXPORT, method::MUX_IMPORT, method::MUX_SHUTDOWN,
                ]}}
            }))
        }
        method::AUTHENTICATE => Ok(json!({})),
        method::SESSION_NEW => {
            // A peer name in _meta.acpmux.peer creates the session on that daemon.
            if let Some(peer_name) = mux_meta(&params).and_then(|m| m.get("peer")).and_then(Value::as_str) {
                if !peer_name.is_empty() {
                    let peer = hub.peer_by_name(peer_name).ok_or_else(|| RpcError::not_found(format!("no peer {peer_name:?}")))?;
                    let mut p = params.clone();
                    if let Some(m) = p.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
                        m.remove("peer");
                    }
                    let mut result = peer.request(method::SESSION_NEW, p).await?;
                    if let Some(id) = result.get("sessionId").and_then(Value::as_str) {
                        conn.subscribe(id);
                        peer.mark_attached(id);
                    }
                    if let Some(obj) = result.as_object_mut() {
                        obj.insert("peer".into(), Value::String(peer.name.clone()));
                    }
                    return Ok(result);
                }
            }
            let cwd = str_param(&params, "cwd").map(PathBuf::from).unwrap_or_else(|| std::env::current_dir().unwrap_or_default());
            let meta = mux_meta(&params);
            let agent = meta
                .and_then(|m| m.get("agent"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| params.get("agent").and_then(Value::as_str).map(str::to_owned));
            let agent = match agent {
                Some(a) => a,
                None => hub
                    .config
                    .read()
                    .await
                    .default_agent
                    .clone()
                    .ok_or_else(|| RpcError::invalid_params("no agents configured; add one to config.json"))?,
            };
            let name = meta
                .and_then(|m| m.get("name"))
                .and_then(Value::as_str)
                .map(str::to_owned)
                .or_else(|| params.get("name").and_then(Value::as_str).map(str::to_owned));
            let policy = meta
                .and_then(|m| m.get("policy"))
                .and_then(Value::as_str)
                .or_else(|| params.get("policy").and_then(Value::as_str))
                .map(|p| p.parse::<PermissionPolicy>().map_err(RpcError::invalid_params))
                .transpose()?;
            let s = hub.new_session(&agent, name, cwd, policy).await?;
            conn.subscribe(&s.id);
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
            conn.subscribe(&s.id);
            // Replay history as ACP updates, then answer.
            let events = hub.events(&s.id, 0, 100_000).map_err(|e| RpcError::internal(e.to_string()))?;
            for rec in events {
                if rec.dir == "mux" && rec.kind == "user_message" {
                    let text = rec.msg.get("text").and_then(Value::as_str).unwrap_or("");
                    conn.send(&Message::notification(
                        method::SESSION_UPDATE,
                        json!({"sessionId": s.id, "update": {"sessionUpdate": "user_message_chunk", "content": {"type": "text", "text": text}}, "_meta": {"acpmux": {"seq": rec.seq, "at": rec.at, "replay": true}}}),
                    ));
                } else if rec.dir == "in" && !rec.kind.ends_with(".replay") {
                    if rec.msg.get("method").and_then(Value::as_str) == Some(method::SESSION_UPDATE) {
                        let mut p = rec.msg.get("params").cloned().unwrap_or(json!({}));
                        p["sessionId"] = Value::String(s.id.clone());
                        p["_meta"] = json!({"acpmux": {"seq": rec.seq, "at": rec.at, "replay": true}});
                        conn.send(&Message::notification(method::SESSION_UPDATE, p));
                    }
                }
            }
            let meta = s.meta();
            Ok(json!({"modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(&s)}}))
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
            conn.subscribe(&s.id);
            let blocks = params
                .get("prompt")
                .and_then(Value::as_array)
                .cloned()
                .or_else(|| params.get("text").and_then(Value::as_str).map(|t| vec![json!({"type": "text", "text": t})]))
                .ok_or_else(|| RpcError::invalid_params("prompt must be an array of content blocks"))?;
            let steer = mux_meta(&params)
                .and_then(|m| m.get("steer"))
                .and_then(Value::as_bool)
                .or_else(|| params.get("steer").and_then(Value::as_bool))
                .unwrap_or(false);
            hub.prompt(&s, blocks, &conn.label(), steer).await
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
            conn.subscribe(&new.id);
            let meta = new.meta();
            Ok(json!({"sessionId": new.id, "modes": meta.modes, "configOptions": meta.config_options, "_meta": {"acpmux": hub.session_summary(&new)}}))
        }
        method::SESSION_SET_MODE => {
            let s = hub.resolve(session_key(&params)?)?;
            let mode = str_param(&params, "modeId").ok_or_else(|| RpcError::invalid_params("modeId is required"))?;
            hub.set_mode(&s, mode).await
        }
        method::SESSION_SET_CONFIG_OPTION => {
            let s = hub.resolve(session_key(&params)?)?;
            let id = str_param(&params, "configId").ok_or_else(|| RpcError::invalid_params("configId is required"))?;
            let value = params.get("value").cloned().ok_or_else(|| RpcError::invalid_params("value is required"))?;
            hub.set_config(&s, id, value).await
        }
        method::SESSION_SET_MODEL => {
            let s = hub.resolve(session_key(&params)?)?;
            let model = str_param(&params, "modelId").ok_or_else(|| RpcError::invalid_params("modelId is required"))?;
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
        "_acpmux/peers" => Ok(json!({"peers": hub.peers()})),
        "_acpmux/models" => {
            let mut cat = hub.models_catalog().await;
            // Remote harnesses, labelled peer/agent, from each connected peer.
            for peer in hub.connected_peers() {
                if let Ok(remote) = peer.request("_acpmux/models", json!({})).await {
                    if let Some(hs) = remote.get("harnesses").and_then(Value::as_array) {
                        for h in hs {
                            let mut h = h.clone();
                            let agent = h.get("agent").and_then(Value::as_str).unwrap_or("").to_owned();
                            h["agent"] = Value::String(format!("{}/{}", peer.name, agent));
                            h["peer"] = Value::String(peer.name.clone());
                            h["isDefault"] = Value::Bool(false);
                            if let Some(arr) = cat.get_mut("harnesses").and_then(Value::as_array_mut) {
                                arr.push(h);
                            }
                        }
                    }
                }
            }
            Ok(cat)
        }
        "_acpmux/peer_add" => {
            let name = str_param(&params, "name").ok_or_else(|| RpcError::invalid_params("name is required"))?;
            let url = str_param(&params, "url").ok_or_else(|| RpcError::invalid_params("url is required"))?;
            let token = str_param(&params, "token").map(str::to_owned);
            hub.add_peer(name, url, token).await?;
            Ok(json!({"peers": hub.peers()}))
        }
        "_acpmux/peer_remove" => {
            let name = str_param(&params, "name").ok_or_else(|| RpcError::invalid_params("name is required"))?;
            hub.remove_peer(name).await?;
            Ok(json!({"peers": hub.peers()}))
        }
        method::MUX_AGENTS => {
            let cfg = hub.config.read().await;
            Ok(json!({"agents": cfg.agents, "defaultAgent": cfg.default_agent}))
        }
        method::MUX_INFO => {
            let s = hub.resolve(session_key(&params)?)?;
            Ok(hub.session_detail(&s))
        }
        method::MUX_ATTACH => {
            let s = hub.resolve(session_key(&params)?)?;
            conn.subscribe(&s.id);
            let after = params.get("afterSeq").and_then(Value::as_u64);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(2000) as usize;
            let detail = hub.session_detail(&s);
            let events = match after {
                Some(a) => hub.events(&s.id, a, limit).map_err(|e| RpcError::internal(e.to_string()))?,
                None => {
                    // Last `limit` records.
                    let last = s.meta().last_seq;
                    let from = last.saturating_sub(limit as u64);
                    hub.events(&s.id, from, limit).map_err(|e| RpcError::internal(e.to_string()))?
                }
            };
            let events: Vec<Value> = events.iter().map(|r| event_value(&s.id, r)).collect();
            Ok(json!({"session": detail, "events": events}))
        }
        method::MUX_DETACH => {
            let s = hub.resolve(session_key(&params)?)?;
            conn.subs.lock().unwrap().remove(&s.id);
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
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(5000) as usize;
            let events = hub.events(&s.id, after, limit).map_err(|e| RpcError::internal(e.to_string()))?;
            Ok(json!({"events": events.iter().map(|r| event_value(&s.id, r)).collect::<Vec<_>>()}))
        }
        method::MUX_RENAME => {
            let s = hub.resolve(session_key(&params)?)?;
            let name = str_param(&params, "newName").or_else(|| str_param(&params, "to")).ok_or_else(|| RpcError::invalid_params("newName is required"))?;
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
        method::MUX_PERMISSION_RESPOND => {
            let s = hub.resolve(session_key(&params)?)?;
            let pid = str_param(&params, "permissionId").ok_or_else(|| RpcError::invalid_params("permissionId is required"))?;
            let option = str_param(&params, "optionId").map(str::to_owned);
            let answers = params.get("answers").cloned();
            hub.respond_permission(&s, pid, option, answers)?;
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
            let dest = str_param(&params, "dest").map(PathBuf::from).unwrap_or_else(|| crate::config::home().join("bundles"));
            let path = hub.export(&s, &dest).map_err(|e| RpcError::internal(e.to_string()))?;
            Ok(json!({"path": path}))
        }
        method::MUX_IMPORT => {
            let path = str_param(&params, "path").map(PathBuf::from).ok_or_else(|| RpcError::invalid_params("path is required"))?;
            let name = str_param(&params, "name").map(str::to_owned);
            let s = hub.import(&path, name).await?;
            conn.subscribe(&s.id);
            Ok(hub.session_summary(&s))
        }
        method::MUX_SHUTDOWN => {
            hub.shutdown.notify_waiters();
            hub.shutdown.notify_one();
            Ok(json!({}))
        }
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
