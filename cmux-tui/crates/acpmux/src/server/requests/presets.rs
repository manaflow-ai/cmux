//! The presets request (`_acpmux/presets`): read or change presets,
//! `{name?, set?: {harness, model, effort, policy, env, args}, clear?: bool}`.

use super::*;

/// Read or change presets: {name?, set?: {harness, model, effort, policy, env, args, mode}, clear?: bool,
/// approveMode?: bool} (`approveMode: true` is the person's own, `hub/person.rs` (b)).
pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    let name = str_param(params, "name").map(str::to_owned);
    let approve = params.get("approveMode").and_then(Value::as_bool);
    let no_fields = json!({});
    let set =
        params.get("set").filter(|v| v.is_object()).or(approve.is_some().then_some(&no_fields));
    let clear = params.get("clear").and_then(Value::as_bool).unwrap_or(false);
    if set.is_some() || clear {
        let name = name
            .clone()
            .ok_or_else(|| RpcError::invalid_params("name is required to change a preset"))?;
        let mut cfg = hub.config.write().await;
        // REMOTE-FLOOR v3: a remote-origin client builds its settings
        // from scratch, so it never sets, changes or clears a preset
        // that shapes the harness command line (args, systemPrompt).
        // LocalApp = same-user secret, equal to the unix socket for STARTING presets; writes stay unix-socket only.
        let remote = conn.origin != Origin::Local;
        if remote
            && (cfg.presets.get(&name).is_some_and(|p| p.shapes_command())
                || set.is_some_and(|s| {
                    ["args", "systemPrompt"].iter().any(|k| s.get(*k).is_some_and(|v| !v.is_null()))
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
                crate::config::remove_preset_dir(dir, &name)
                    .map_err(|e| RpcError::internal(format!("remove preset directory: {e}")))?;
            }
        } else if let Some(set) = set {
            let Some(obj) = set.as_object() else {
                return Err(RpcError::invalid_params("preset: set must be an object"));
            };
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
                mode: None,
                mode_approval: None,
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
                            pol.parse::<PermissionPolicy>().map_err(RpcError::invalid_params)?,
                        )
                    }
                    ("mode", Value::Null) => p.mode = None,
                    ("mode", Value::String(m)) => p.mode = Some(m.clone()),
                    ("mode", _) => {
                        return Err(RpcError::invalid_params(
                            "mode must be a mode id (a string) or null",
                        ));
                    }
                    ("description", Value::Null) => p.description = None,
                    ("description", Value::String(d)) => p.description = Some(d.clone()),
                    ("systemPrompt", Value::Null) => new_prompt = Some(None),
                    ("systemPrompt", Value::String(text)) => new_prompt = Some(Some(text.clone())),
                    ("systemPrompt", _) => {
                        return Err(RpcError::invalid_params(
                            "systemPrompt must be the prompt's text (a string) or null",
                        ));
                    }
                    ("args", Value::Null) => p.args.clear(),
                    ("args", v) => {
                        p.args =
                            crate::config::parse_preset_args(v).map_err(RpcError::invalid_params)?
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
                            "unknown preset key {other:?}; use harness, model, effort, policy, env, args, systemPrompt, description, mode"
                        )));
                    }
                }
            }
            // `merged` was filled above (`get_or_insert_with`).
            let Some(mut p) = merged else {
                return Err(RpcError::internal("preset: nothing to save"));
            };
            // Checked against the profile the preset resolves to now.
            let profile = cfg.resolve_harness(&p.harness).map_err(RpcError::invalid_params)?;
            let Some(kind) = cfg.harnesses.get(&profile).map(|h| h.kind) else {
                return Err(RpcError::invalid_params(format!(
                    "unknown harness profile {profile:?}"
                )));
            };
            // A built-in Chief preset without a client env gets its
            // env from the definition (`config/chief_builtins.rs`),
            // whoever installs it; a client env is the person's
            // (`hub/person.rs` refused it from anyone else).
            if let Some(builtin) = crate::config::chief_builtins::parse(&name)
                && obj.get("env").is_none()
            {
                let family = cfg
                    .harnesses
                    .get(&profile)
                    .map(|h| crate::config::derive_family(&profile, h))
                    .unwrap_or_default();
                p.env = crate::config::chief_builtins::env(
                    &builtin,
                    &family,
                    &crate::config::chief_builtins::Context::current(),
                )
                .map_err(RpcError::invalid_params)?;
            }
            crate::config::check_preset_args(kind, &p.args).map_err(RpcError::invalid_params)?;
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
                    let sha =
                        crate::config::write_system_prompt(dir, &name, &text).map_err(|e| {
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
            // The person's approval binds these contents (`hub/person.rs` (b)).
            p.apply_mode_approval(approve).map_err(RpcError::invalid_params)?;
            cfg.presets.insert(name.clone(), p);
        }
        if let Err(e) = hub.save_config(&cfg) {
            return Err(RpcError::internal(format!("save config: {e}")));
        }
    }
    let cfg = hub.config.read().await;
    let view = |n: &str, p: &crate::config::Preset| {
        let (profile, error) = match cfg.resolve_harness(&p.harness) {
            Ok(x) => (Some(x), None),
            Err(e) => (None, Some(e)),
        };
        json!({"name": n, "harness": p.harness, "profile": profile, "error": error, "model": p.model, "effort": p.effort, "policy": p.policy, "env": p.env, "args": p.args, "systemPromptSha256": p.system_prompt_sha256, "description": p.description, "mode": p.mode, "modeApproved": p.mode_approved()})
    };
    match name {
        Some(n) if !clear => cfg
            .presets
            .get(&n)
            .map(|p| view(&n, p))
            .ok_or_else(|| RpcError::not_found(format!("no preset {n:?}"))),
        _ => {
            Ok(json!({"presets": cfg.presets.iter().map(|(n, p)| view(n, p)).collect::<Vec<_>>()}))
        }
    }
}
