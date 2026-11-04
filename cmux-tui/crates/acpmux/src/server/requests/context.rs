//! Context viewer and cmux-added context override requests.
use super::*;
use std::path::Path;

fn project_path(value: Option<&Value>, fallback: &Path) -> Result<std::path::PathBuf, RpcError> {
    let raw = value.and_then(Value::as_str).unwrap_or_else(|| fallback.to_str().unwrap_or(""));
    if raw.is_empty() {
        return Err(RpcError::invalid_params("cwd is required for a project override"));
    }
    let path = std::fs::canonicalize(raw)
        .map_err(|e| RpcError::invalid_params(format!("cwd must be an existing directory: {e}")))?;
    if !path.is_dir() {
        return Err(RpcError::invalid_params("cwd must be a directory"));
    }
    Ok(path)
}

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method_name: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let session = hub.resolve_told(super::session_key(params)?, conn.origin == Origin::Local)?;
    if method_name == method::MUX_CONTEXT_OVERRIDE {
        if conn.origin.web_class() {
            return Err(RpcError::invalid_params(
                "context overrides are available only to local clients",
            ));
        }
        let scope = params
            .get("scope")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("scope must be user or project"))?;
        let part_id = params.get("partId").and_then(Value::as_str);
        if let Some(part_id) = part_id {
            if part_id != "cmux-system-prompt" {
                return Err(RpcError::invalid_params("unknown context part"));
            }
        }
        let text = match params.get("text") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(text.clone()),
            Some(_) => return Err(RpcError::invalid_params("text must be a string or null")),
        };
        let cwd =
            if scope == "project" { Some(project_path(None, &session.meta().cwd)?) } else { None };
        let mut cfg = hub.config.write().await;
        let previous = cfg.context_overrides.clone();
        let previous_presets = cfg.presets.clone();
        if part_id.is_some() {
            let preset_name = session
                .meta()
                .preset
                .clone()
                .ok_or_else(|| RpcError::invalid_params("context part requires a preset"))?;
            let preset = cfg
                .presets
                .get_mut(&preset_name)
                .ok_or_else(|| RpcError::invalid_params("preset not found"))?;
            match scope {
                "user" => preset.context_user = text,
                "project" => {
                    let key = crate::config::ContextOverrides::project_key(cwd.as_deref().unwrap());
                    if let Some(text) = text {
                        preset.context_project.insert(key, text);
                    } else {
                        preset.context_project.remove(&key);
                    }
                }
                _ => return Err(RpcError::invalid_params("scope must be user or project")),
            }
        } else {
            cfg.context_overrides
                .set(scope, cwd.as_deref(), text)
                .map_err(RpcError::invalid_params)?;
        }
        if let Err(e) = cfg.save() {
            cfg.context_overrides = previous;
            cfg.presets = previous_presets;
            return Err(RpcError::internal(format!("save context override: {e}")));
        }
    }
    let meta = session.meta();
    let cfg = hub.config.read().await;
    let mut inventory = crate::context_inventory::inventory(&meta, &cfg);
    // Remote viewers may inspect harness-reported counts, but never receive cmux-owned
    // prompt text or the saved override contents over a WebSocket/peer link.
    if conn.origin.web_class() {
        inventory.can_edit_overrides = false;
        for part in &mut inventory.parts {
            part.text = None;
            if part.source == "memory" || part.source.starts_with("memory-") {
                part.label = "Memory source".into();
            }
        }
        inventory.overrides.project_key.clear();
        inventory.overrides.cwd.clear();
        inventory.overrides.user = None;
        inventory.overrides.project = None;
        inventory.overrides.default_text = None;
        inventory.overrides.parts.clear();
    }
    Ok(serde_json::to_value(inventory).unwrap_or(Value::Null))
}
