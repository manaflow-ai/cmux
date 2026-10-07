//! Session and prewarm request dispatch kept out of the main request router.

use super::*;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    let result = match m {
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
                // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
                remote: conn.origin.web_class(),
            };
            let s = hub.new_session(req).await?;
            if conn.origin.web_class() {
                super::remote_guard::settle_web_session_mode(hub, &s).await?;
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
                control: super::remote_guard::control_of(conn.origin, &params),
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
        method::MUX_WEB_MODES => hub.web_modes_view(&params),
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
            })
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
        _ => return None,
    };
    Some(result)
}
