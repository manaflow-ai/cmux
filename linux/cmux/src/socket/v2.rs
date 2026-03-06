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
        "workspace.new" | "workspace.create" => handle_workspace_new(id, &req.params, state),
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

        _ => {
            let method_display = if req.method.len() > 200 {
                // Truncate at a char boundary to avoid panic on multi-byte UTF-8
                let mut end = 200;
                while end > 0 && !req.method.is_char_boundary(end) {
                    end -= 1;
                }
                &req.method[..end]
            } else {
                &req.method
            };
            Response::error(
                id,
                "unknown_method",
                &format!("Unknown method: {}", method_display),
            )
        }
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
        "workspace.new",      // alias: workspace.create
        "workspace.create",
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
        // surface.send_input and notification.create are recognized but not yet
        // implemented — omitted from capabilities until functional (Phase 0/3).
    ];
    Response::success(id, serde_json::json!({"methods": methods}))
}

// -----------------------------------------------------------------------
// Workspace handlers
// -----------------------------------------------------------------------

fn handle_workspace_list(id: Value, state: &Arc<SharedState>) -> Response {
    // Collect workspace data under lock, then release before JSON serialization
    let (ws_data, selected) = {
        let tm = state.lock_tab_manager();
        let selected = tm.selected_index();
        let data: Vec<(usize, String, String, String, usize)> = tm
            .iter()
            .enumerate()
            .map(|(i, ws)| {
                (
                    i,
                    ws.id.to_string(),
                    ws.display_title().to_string(),
                    ws.current_directory.clone(),
                    ws.panels.len(),
                )
            })
            .collect();
        (data, selected)
    }; // MutexGuard dropped

    let workspaces: Vec<Value> = ws_data
        .into_iter()
        .map(|(i, id_str, title, directory, panel_count)| {
            serde_json::json!({
                "index": i,
                "id": id_str,
                "title": title,
                "directory": directory,
                "panel_count": panel_count,
                "selected": selected == Some(i),
            })
        })
        .collect();

    Response::success(id, serde_json::json!({"workspaces": workspaces}))
}

fn handle_workspace_new(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let directory = params.get("directory").and_then(|v| v.as_str())
        .map(|s| crate::model::workspace::truncate_str(s, 4096));
    let title = params.get("title").and_then(|v| v.as_str())
        .map(|s| crate::model::workspace::truncate_str(s, 1024));

    let mut ws = if let Some(dir) = directory {
        Workspace::with_directory(dir)
    } else {
        Workspace::new()
    };

    if let Some(t) = title {
        ws.custom_title = Some(t.to_string());
    }

    let ws_id = ws.id;
    state.lock_tab_manager().add_workspace(ws);

    Response::success(id, serde_json::json!({"workspace_id": ws_id.to_string()}))
}

fn handle_workspace_select(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let index = params.get("index").and_then(|v| v.as_u64()).and_then(|v| usize::try_from(v).ok());
    let ws_id = params
        .get("workspace_id")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());

    let mut tm = state.lock_tab_manager();

    let selected = if let Some(idx) = index {
        tm.select(idx)
    } else if let Some(wid) = ws_id {
        tm.select_by_id(wid)
    } else {
        return Response::error(id, "invalid_params", "Provide 'index' or 'workspace_id'");
    };

    if selected {
        Response::success(id, serde_json::json!({"selected": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_next(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let wrap = params.get("wrap").and_then(|v| v.as_bool()).unwrap_or(true);
    state.lock_tab_manager().select_next(wrap);
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_previous(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let wrap = params.get("wrap").and_then(|v| v.as_bool()).unwrap_or(true);
    state.lock_tab_manager().select_previous(wrap);
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_last(id: Value, state: &Arc<SharedState>) -> Response {
    state.lock_tab_manager().select_last();
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_close(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let index = params.get("index").and_then(|v| v.as_u64()).and_then(|v| usize::try_from(v).ok());
    let ws_id = params
        .get("workspace_id")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());

    let mut tm = state.lock_tab_manager();

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
        .get("workspace_id")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let key = params.get("key").and_then(|v| v.as_str());
    let value = params.get("value").and_then(|v| v.as_str());
    let icon = params.get("icon").and_then(|v| v.as_str());
    let color = params.get("color").and_then(|v| v.as_str());

    let (Some(key), Some(value)) = (key, value) else {
        return Response::error(id, "invalid_params", "Provide 'key' and 'value'");
    };

    let mut tm = state.lock_tab_manager();
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
        .get("workspace_id")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let branch = params.get("branch").and_then(|v| v.as_str());
    let is_dirty = params.get("is_dirty").and_then(|v| v.as_bool()).unwrap_or(false);

    let Some(branch) = branch else {
        return Response::error(id, "invalid_params", "Provide 'branch'");
    };
    let branch = crate::model::workspace::truncate_str(branch, 256);

    let mut tm = state.lock_tab_manager();
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
        .get("workspace_id")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let value = params.get("value").and_then(|v| v.as_f64());
    let label = params.get("label").and_then(|v| v.as_str())
        .map(|s| crate::model::workspace::truncate_str(s, 1024));

    // Validate progress value before acquiring lock
    if let Some(value) = value {
        if !value.is_finite() || value < 0.0 || value > 1.0 {
            return Response::error(
                id,
                "invalid_params",
                "Progress value must be a finite number between 0.0 and 1.0",
            );
        }
    }

    let mut tm = state.lock_tab_manager();
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
        .get("workspace_id")
        .and_then(|v| v.as_str())
        .and_then(|s| uuid::Uuid::parse_str(s).ok());
    let message = params.get("message").and_then(|v| v.as_str());
    let level = params.get("level").and_then(|v| v.as_str()).unwrap_or("info");
    let source = params.get("source").and_then(|v| v.as_str());

    let Some(message) = message else {
        return Response::error(id, "invalid_params", "Provide 'message'");
    };

    // level/source are truncated inside append_log for defense-in-depth

    let mut tm = state.lock_tab_manager();
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

    let mut tm = state.lock_tab_manager();
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

fn handle_surface_send_input(id: Value, _params: &Value, _state: &Arc<SharedState>) -> Response {
    // TODO: Forward to ghostty surface via GTK main thread (requires Phase 0 ghostty integration)
    Response::error(
        id,
        "not_implemented",
        "surface.send_input is not yet implemented (requires ghostty integration)",
    )
}

// -----------------------------------------------------------------------
// Notification handlers
// -----------------------------------------------------------------------

fn handle_notification_create(id: Value, params: &Value, _state: &Arc<SharedState>) -> Response {
    let title = params.get("title").and_then(|v| v.as_str()).unwrap_or("cmux");
    let body = params.get("body").and_then(|v| v.as_str()).unwrap_or("");

    // TODO: Add to notification store + send desktop notification (Phase 3)
    tracing::info!("Notification (stub): {} - {}", title, body);

    Response::error(
        id,
        "not_implemented",
        "notification.create is not yet implemented (Phase 3)",
    )
}
