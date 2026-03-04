//! v2 JSON protocol dispatch.
//!
//! Request format:
//! ```json
//! {"id": "1", "method": "workspace.list", "params": {}}
//! ```
//!
//! Response format:
//! ```json
//! {"id": "1", "ok": true, "result": {...}}
//! ```

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::app::SharedState;
use crate::model::panel::SplitOrientation;
use crate::model::PanelType;
use crate::model::Workspace;

/// V2 protocol request.
#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

/// V2 protocol response.
#[derive(Debug, Serialize)]
pub struct Response {
    pub id: Value,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ErrorInfo>,
}

#[derive(Debug, Serialize)]
pub struct ErrorInfo {
    pub code: String,
    pub message: String,
}

impl Response {
    fn success(id: Value, result: Value) -> Self {
        Self {
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    fn error(id: Value, code: &str, message: &str) -> Self {
        Self {
            id,
            ok: false,
            result: None,
            error: Some(ErrorInfo {
                code: code.to_string(),
                message: message.to_string(),
            }),
        }
    }
}

/// Parse and dispatch a v2 request. Returns the response.
pub fn dispatch(json_line: &str, state: &Arc<SharedState>) -> Response {
    let req: Request = match serde_json::from_str(json_line) {
        Ok(r) => r,
        Err(e) => {
            return Response::error(
                Value::Null,
                "parse_error",
                &format!("Invalid JSON: {}", e),
            );
        }
    };

    let id = req.id.clone();

    match req.method.as_str() {
        // System
        "system.ping" => Response::success(id, serde_json::json!({"pong": true})),
        "system.capabilities" => handle_capabilities(id),

        // Workspace commands
        "workspace.list" => handle_workspace_list(id, state),
        "workspace.new" => handle_workspace_new(id, &req.params, state),
        "workspace.select" => handle_workspace_select(id, &req.params, state),
        "workspace.next" => handle_workspace_next(id, &req.params, state),
        "workspace.previous" => handle_workspace_previous(id, &req.params, state),
        "workspace.last" => handle_workspace_last(id, state),
        "workspace.close" => handle_workspace_close(id, &req.params, state),
        "workspace.set_status" => handle_workspace_set_status(id, &req.params, state),
        "workspace.report_git_branch" => handle_workspace_report_git(id, &req.params, state),
        "workspace.set_progress" => handle_workspace_set_progress(id, &req.params, state),
        "workspace.append_log" => handle_workspace_append_log(id, &req.params, state),

        // Pane commands
        "pane.new" => handle_pane_new(id, &req.params, state),

        // Surface commands
        "surface.send_input" => handle_surface_send_input(id, &req.params, state),

        // Notification commands
        "notification.create" => handle_notification_create(id, &req.params, state),

        _ => Response::error(
            id,
            "unknown_method",
            &format!("Unknown method: {}", req.method),
        ),
    }
}

// -----------------------------------------------------------------------
// System handlers
// -----------------------------------------------------------------------

fn handle_capabilities(id: Value) -> Response {
    let methods = vec![
        "system.ping",
        "system.capabilities",
        "workspace.list",
        "workspace.new",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.close",
        "workspace.set_status",
        "workspace.report_git_branch",
        "workspace.set_progress",
        "workspace.append_log",
        "pane.new",
        "surface.send_input",
        "notification.create",
    ];
    Response::success(id, serde_json::json!({"methods": methods}))
}

// -----------------------------------------------------------------------
// Workspace handlers
// -----------------------------------------------------------------------

fn handle_workspace_list(id: Value, state: &Arc<SharedState>) -> Response {
    let tm = state.tab_manager.lock().unwrap();
    let workspaces: Vec<Value> = tm
        .iter()
        .enumerate()
        .map(|(i, ws)| {
            serde_json::json!({
                "index": i,
                "id": ws.id.to_string(),
                "title": ws.display_title(),
                "directory": ws.current_directory,
                "panel_count": ws.panels.len(),
                "is_selected": tm.selected_index() == Some(i),
            })
        })
        .collect();

    Response::success(id, serde_json::json!({"workspaces": workspaces}))
}

fn handle_workspace_new(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let directory = params.get("directory").and_then(|v| v.as_str());
    let title = params.get("title").and_then(|v| v.as_str());

    let mut ws = if let Some(dir) = directory {
        Workspace::with_directory(dir)
    } else {
        Workspace::new()
    };

    if let Some(t) = title {
        ws.custom_title = Some(t.to_string());
    }

    let ws_id = ws.id;
    state.tab_manager.lock().unwrap().add_workspace(ws);

    Response::success(id, serde_json::json!({"workspace": ws_id.to_string()}))
}

fn handle_workspace_select(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let index = params.get("index").and_then(|v| v.as_u64()).map(|v| v as usize);
    let ws_id = params
        .get("workspace")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());

    let mut tm = state.tab_manager.lock().unwrap();

    let selected = if let Some(idx) = index {
        tm.select(idx)
    } else if let Some(wid) = ws_id {
        tm.select_by_id(wid)
    } else {
        return Response::error(id, "invalid_params", "Provide 'index' or 'workspace'");
    };

    if selected {
        Response::success(id, serde_json::json!({"selected": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_next(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let wrap = params.get("wrap").and_then(|v| v.as_bool()).unwrap_or(true);
    state.tab_manager.lock().unwrap().select_next(wrap);
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_previous(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let wrap = params.get("wrap").and_then(|v| v.as_bool()).unwrap_or(true);
    state.tab_manager.lock().unwrap().select_previous(wrap);
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_last(id: Value, state: &Arc<SharedState>) -> Response {
    state.tab_manager.lock().unwrap().select_last();
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_close(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let index = params.get("index").and_then(|v| v.as_u64()).map(|v| v as usize);
    let ws_id = params
        .get("workspace")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());

    let mut tm = state.tab_manager.lock().unwrap();

    let removed = if let Some(idx) = index {
        tm.remove(idx).is_some()
    } else if let Some(wid) = ws_id {
        tm.remove_by_id(wid).is_some()
    } else if let Some(idx) = tm.selected_index() {
        tm.remove(idx).is_some()
    } else {
        false
    };

    if removed {
        Response::success(id, serde_json::json!({"closed": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_set_status(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = params
        .get("workspace")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let key = params.get("key").and_then(|v| v.as_str());
    let value = params.get("value").and_then(|v| v.as_str());
    let icon = params.get("icon").and_then(|v| v.as_str());
    let color = params.get("color").and_then(|v| v.as_str());

    let (Some(key), Some(value)) = (key, value) else {
        return Response::error(id, "invalid_params", "Provide 'key' and 'value'");
    };

    let mut tm = state.tab_manager.lock().unwrap();
    let ws = if let Some(wid) = ws_id {
        tm.workspace_mut(wid)
    } else {
        tm.selected_mut()
    };

    if let Some(ws) = ws {
        ws.set_status(key, value, icon, color);
        Response::success(id, serde_json::json!({"ok": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_report_git(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = params
        .get("workspace")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let branch = params.get("branch").and_then(|v| v.as_str());
    let is_dirty = params.get("is_dirty").and_then(|v| v.as_bool()).unwrap_or(false);

    let Some(branch) = branch else {
        return Response::error(id, "invalid_params", "Provide 'branch'");
    };

    let mut tm = state.tab_manager.lock().unwrap();
    let ws = if let Some(wid) = ws_id {
        tm.workspace_mut(wid)
    } else {
        tm.selected_mut()
    };

    if let Some(ws) = ws {
        ws.git_branch = Some(crate::model::panel::GitBranch {
            branch: branch.to_string(),
            is_dirty,
        });
        Response::success(id, serde_json::json!({"ok": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_set_progress(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = params
        .get("workspace")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let value = params.get("value").and_then(|v| v.as_f64());
    let label = params.get("label").and_then(|v| v.as_str());

    let mut tm = state.tab_manager.lock().unwrap();
    let ws = if let Some(wid) = ws_id {
        tm.workspace_mut(wid)
    } else {
        tm.selected_mut()
    };

    if let Some(ws) = ws {
        if let Some(value) = value {
            ws.progress = Some(crate::model::workspace::Progress {
                value,
                label: label.map(|s| s.to_string()),
            });
        } else {
            ws.progress = None;
        }
        Response::success(id, serde_json::json!({"ok": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_append_log(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = params
        .get("workspace")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let message = params.get("message").and_then(|v| v.as_str());
    let level = params.get("level").and_then(|v| v.as_str()).unwrap_or("info");
    let source = params.get("source").and_then(|v| v.as_str());

    let Some(message) = message else {
        return Response::error(id, "invalid_params", "Provide 'message'");
    };

    let mut tm = state.tab_manager.lock().unwrap();
    let ws = if let Some(wid) = ws_id {
        tm.workspace_mut(wid)
    } else {
        tm.selected_mut()
    };

    if let Some(ws) = ws {
        ws.append_log(message, level, source);
        Response::success(id, serde_json::json!({"ok": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

// -----------------------------------------------------------------------
// Pane handlers
// -----------------------------------------------------------------------

fn handle_pane_new(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let orientation = match params.get("orientation").and_then(|v| v.as_str()) {
        Some("horizontal") => SplitOrientation::Horizontal,
        Some("vertical") => SplitOrientation::Vertical,
        _ => SplitOrientation::Horizontal,
    };

    let mut tm = state.tab_manager.lock().unwrap();
    if let Some(ws) = tm.selected_mut() {
        let panel_id = ws.split(orientation, PanelType::Terminal);
        Response::success(id, serde_json::json!({"panel_id": panel_id.to_string()}))
    } else {
        Response::error(id, "not_found", "No workspace selected")
    }
}

// -----------------------------------------------------------------------
// Surface handlers
// -----------------------------------------------------------------------

fn handle_surface_send_input(id: Value, params: &Value, _state: &Arc<SharedState>) -> Response {
    let _input = params.get("input").and_then(|v| v.as_str());
    let _surface = params.get("surface").and_then(|v| v.as_str());

    // TODO: Forward to ghostty surface via GTK main thread (Phase 2 integration)
    Response::success(id, serde_json::json!({"sent": true}))
}

// -----------------------------------------------------------------------
// Notification handlers
// -----------------------------------------------------------------------

fn handle_notification_create(id: Value, params: &Value, _state: &Arc<SharedState>) -> Response {
    let title = params.get("title").and_then(|v| v.as_str()).unwrap_or("cmux");
    let body = params.get("body").and_then(|v| v.as_str()).unwrap_or("");

    // TODO: Add to notification store + send desktop notification (Phase 3)
    tracing::info!("Notification: {} - {}", title, body);

    Response::success(id, serde_json::json!({"notified": true}))
}
