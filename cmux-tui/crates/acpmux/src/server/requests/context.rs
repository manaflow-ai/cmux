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
        let scope = params.get("scope").and_then(Value::as_str).unwrap_or("user");
        let text = match params.get("text") {
            None | Some(Value::Null) => None,
            Some(Value::String(text)) => Some(text.clone()),
            Some(_) => return Err(RpcError::invalid_params("text must be a string or null")),
        };
        let cwd = if scope == "project" {
            Some(project_path(params.get("cwd"), &session.meta().cwd)?)
        } else {
            None
        };
        let mut cfg = hub.config.write().await;
        let previous = cfg.context_overrides.clone();
        match params.get("partId") {
            None | Some(Value::Null) => cfg.context_overrides.set(scope, cwd.as_deref(), text),
            Some(Value::String(id)) if id == "cmux-system-prompt" => {
                let meta = session.meta();
                if !crate::context_inventory::preset_is_editable(&meta, &cfg) {
                    return Err(RpcError::invalid_params(
                        "this session has no editable local preset system prompt",
                    ));
                }
                cfg.context_overrides.set_preset(
                    meta.preset.as_deref().unwrap_or_default(),
                    scope,
                    cwd.as_deref(),
                    text,
                )
            }
            _ => return Err(RpcError::invalid_params("unknown editable context partId")),
        }
        .map_err(RpcError::invalid_params)?;
        if let Err(e) = cfg.save() {
            cfg.context_overrides = previous;
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
        }
        inventory.overrides.project_key.clear();
        inventory.overrides.cwd.clear();
        inventory.overrides.default_text = None;
        inventory.overrides.user = None;
        inventory.overrides.project = None;
        inventory.overrides.parts.clear();
    }
    Ok(serde_json::to_value(inventory).unwrap_or(Value::Null))
}
