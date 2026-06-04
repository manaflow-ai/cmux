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

use crate::app::{lock_or_recover, SharedState, UiEvent};
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
            return Response::error(Value::Null, "parse_error", &format!("Invalid JSON: {}", e));
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
        "workspace.create" => handle_workspace_create(id, &req.params, state),
        "workspace.select" => handle_workspace_select(id, &req.params, state),
        "workspace.next" => handle_workspace_next(id, &req.params, state),
        "workspace.previous" => handle_workspace_previous(id, &req.params, state),
        "workspace.last" => handle_workspace_last(id, state),
        "workspace.latest_unread" => handle_workspace_latest_unread(id, state),
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
            &format!(
                "Unknown method: {}",
                crate::model::workspace::truncate_str(&req.method, 200)
            ),
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
        "workspace.create",
        "workspace.select",
        "workspace.next",
        "workspace.previous",
        "workspace.last",
        "workspace.latest_unread",
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
    let tm = lock_or_recover(&state.tab_manager);
    let workspaces: Vec<Value> = tm
        .iter()
        .enumerate()
        .map(|(i, ws)| {
            let selected = tm.selected_index() == Some(i);
            serde_json::json!({
                "index": i,
                "id": ws.id.to_string(),
                "title": ws.display_title(),
                "directory": ws.current_directory,
                "panel_count": ws.panels.len(),
                "unread_count": ws.unread_count,
                "latest_notification": ws.latest_notification,
                "attention_panel_id": ws.attention_panel_id.map(|id| id.to_string()),
                "selected": selected,
                "is_selected": selected,
            })
        })
        .collect();

    Response::success(id, serde_json::json!({"workspaces": workspaces}))
}

fn handle_workspace_new(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    create_workspace(id, params, state, false)
}

fn handle_workspace_create(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    create_workspace(id, params, state, true)
}

fn create_workspace(
    id: Value,
    params: &Value,
    state: &Arc<SharedState>,
    preserve_selection: bool,
) -> Response {
    let directory = params
        .get("directory")
        .or_else(|| params.get("cwd"))
        .and_then(|v| v.as_str())
        .map(|s| crate::model::workspace::truncate_str(s, 4096));
    let title = params
        .get("title")
        .and_then(|v| v.as_str())
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
    let mut tab_manager = lock_or_recover(&state.tab_manager);
    let previously_selected = if preserve_selection {
        tab_manager.selected_id()
    } else {
        None
    };
    tab_manager.add_workspace(ws);
    if let Some(selected_id) = previously_selected {
        let _ = tab_manager.select_by_id(selected_id);
    }
    drop(tab_manager);
    state.notify_ui_refresh();

    Response::success(
        id,
        serde_json::json!({
            "workspace_id": ws_id.to_string(),
            "workspace": ws_id.to_string()
        }),
    )
}

fn handle_workspace_select(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let index = match parse_usize_param(&id, params, "index") {
        Ok(index) => index,
        Err(response) => return response,
    };
    let ws_id = match parse_workspace_param(params) {
        Ok(v) => v,
        Err(()) => return Response::error(id, "invalid_params", "Invalid workspace UUID"),
    };

    let mut tm = lock_or_recover(&state.tab_manager);

    let selected = if let Some(idx) = index {
        tm.select(idx)
    } else if let Some(wid) = ws_id {
        tm.select_by_id(wid)
    } else {
        return Response::error(
            id,
            "invalid_params",
            "Provide 'index' or 'workspace'/'workspace_id'",
        );
    };

    if selected {
        let selected_workspace = tm.selected_id();
        drop(tm);
        if let Some(workspace_id) = selected_workspace {
            mark_workspace_read(state, workspace_id);
        }
        state.notify_ui_refresh();
        Response::success(id, serde_json::json!({"selected": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_next(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let wrap = params.get("wrap").and_then(|v| v.as_bool()).unwrap_or(true);
    let selected_workspace = {
        let mut tm = lock_or_recover(&state.tab_manager);
        tm.select_next(wrap);
        tm.selected_id()
    };
    if let Some(workspace_id) = selected_workspace {
        mark_workspace_read(state, workspace_id);
    }
    state.notify_ui_refresh();
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_previous(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let wrap = params.get("wrap").and_then(|v| v.as_bool()).unwrap_or(true);
    let selected_workspace = {
        let mut tm = lock_or_recover(&state.tab_manager);
        tm.select_previous(wrap);
        tm.selected_id()
    };
    if let Some(workspace_id) = selected_workspace {
        mark_workspace_read(state, workspace_id);
    }
    state.notify_ui_refresh();
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_last(id: Value, state: &Arc<SharedState>) -> Response {
    let selected_workspace = {
        let mut tm = lock_or_recover(&state.tab_manager);
        tm.select_last();
        tm.selected_id()
    };
    if let Some(workspace_id) = selected_workspace {
        mark_workspace_read(state, workspace_id);
    }
    state.notify_ui_refresh();
    Response::success(id, serde_json::json!({"ok": true}))
}

fn handle_workspace_latest_unread(id: Value, state: &Arc<SharedState>) -> Response {
    let selected_workspace = {
        let mut tm = lock_or_recover(&state.tab_manager);
        tm.select_latest_unread()
    };

    if let Some(workspace_id) = selected_workspace {
        mark_workspace_read(state, workspace_id);
        state.notify_ui_refresh();
        Response::success(
            id,
            serde_json::json!({
                "workspace_id": workspace_id.to_string(),
                "workspace": workspace_id.to_string(),
                "selected": true
            }),
        )
    } else {
        Response::error(id, "not_found", "No unread workspace")
    }
}

fn handle_workspace_close(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let index = match parse_usize_param(&id, params, "index") {
        Ok(index) => index,
        Err(response) => return response,
    };
    let ws_id = match parse_workspace_param(params) {
        Ok(v) => v,
        Err(()) => return Response::error(id, "invalid_params", "Invalid workspace UUID"),
    };

    let removed = {
        let mut tm = lock_or_recover(&state.tab_manager);
        if let Some(idx) = index {
            tm.remove(idx).is_some()
        } else if let Some(wid) = ws_id {
            tm.remove_by_id(wid).is_some()
        } else if let Some(idx) = tm.selected_index() {
            tm.remove(idx).is_some()
        } else {
            false
        }
    };

    if removed {
        state.notify_ui_refresh();
        Response::success(id, serde_json::json!({"closed": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_set_status(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = match parse_workspace_param(params) {
        Ok(v) => v,
        Err(()) => return Response::error(id, "invalid_params", "Invalid workspace UUID"),
    };
    let key = params.get("key").and_then(|v| v.as_str());
    let value = params.get("value").and_then(|v| v.as_str());
    let icon = params.get("icon").and_then(|v| v.as_str());
    let color = params.get("color").and_then(|v| v.as_str());

    let (Some(key), Some(value)) = (key, value) else {
        return Response::error(id, "invalid_params", "Provide 'key' and 'value'");
    };

    let updated = {
        let mut tm = lock_or_recover(&state.tab_manager);
        let ws = if let Some(wid) = ws_id {
            tm.workspace_mut(wid)
        } else {
            tm.selected_mut()
        };

        if let Some(ws) = ws {
            ws.set_status(key, value, icon, color);
            true
        } else {
            false
        }
    };

    if updated {
        state.notify_ui_refresh();
        Response::success(id, serde_json::json!({"ok": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_report_git(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = match parse_workspace_param(params) {
        Ok(v) => v,
        Err(()) => return Response::error(id, "invalid_params", "Invalid workspace UUID"),
    };
    let branch = params.get("branch").and_then(|v| v.as_str());
    let is_dirty = params
        .get("is_dirty")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);

    let Some(branch) = branch else {
        return Response::error(id, "invalid_params", "Provide 'branch'");
    };

    let updated = {
        let mut tm = lock_or_recover(&state.tab_manager);
        let ws = if let Some(wid) = ws_id {
            tm.workspace_mut(wid)
        } else {
            tm.selected_mut()
        };

        if let Some(ws) = ws {
            ws.git_branch = Some(crate::model::panel::GitBranch {
                branch: crate::model::workspace::truncate_str(branch, 256).to_string(),
                is_dirty,
            });
            true
        } else {
            false
        }
    };

    if updated {
        state.notify_ui_refresh();
        Response::success(id, serde_json::json!({"ok": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_set_progress(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = match parse_workspace_param(params) {
        Ok(v) => v,
        Err(()) => return Response::error(id, "invalid_params", "Invalid workspace UUID"),
    };
    let value = params.get("value").and_then(|v| v.as_f64());
    let label = params.get("label").and_then(|v| v.as_str());

    let updated = {
        let mut tm = lock_or_recover(&state.tab_manager);
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
            true
        } else {
            false
        }
    };

    if updated {
        state.notify_ui_refresh();
        Response::success(id, serde_json::json!({"ok": true}))
    } else {
        Response::error(id, "not_found", "Workspace not found")
    }
}

fn handle_workspace_append_log(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let ws_id = match parse_workspace_param(params) {
        Ok(v) => v,
        Err(()) => return Response::error(id, "invalid_params", "Invalid workspace UUID"),
    };
    let message = params.get("message").and_then(|v| v.as_str());
    let level = params
        .get("level")
        .and_then(|v| v.as_str())
        .unwrap_or("info");
    let source = params.get("source").and_then(|v| v.as_str());

    let Some(message) = message else {
        return Response::error(id, "invalid_params", "Provide 'message'");
    };

    let updated = {
        let mut tm = lock_or_recover(&state.tab_manager);
        let ws = if let Some(wid) = ws_id {
            tm.workspace_mut(wid)
        } else {
            tm.selected_mut()
        };

        if let Some(ws) = ws {
            ws.append_log(message, level, source);
            true
        } else {
            false
        }
    };

    if updated {
        state.notify_ui_refresh();
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

    let mut tm = lock_or_recover(&state.tab_manager);
    if let Some(ws) = tm.selected_mut() {
        let panel_id = ws.split(orientation, PanelType::Terminal);
        drop(tm);
        state.notify_ui_refresh();
        Response::success(id, serde_json::json!({"panel_id": panel_id.to_string()}))
    } else {
        Response::error(id, "not_found", "No workspace selected")
    }
}

// -----------------------------------------------------------------------
// Surface handlers
// -----------------------------------------------------------------------

fn handle_surface_send_input(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let Some(input) = params.get("input").and_then(|v| v.as_str()) else {
        return Response::error(id, "invalid_params", "Provide 'input'");
    };
    // Limit input size to prevent unbounded memory growth via the channel
    let input = crate::model::workspace::truncate_str(input, 128 * 1024);

    let explicit_panel_id = match params.get("surface").or_else(|| params.get("panel")) {
        Some(v) => {
            let Some(s) = v.as_str() else {
                return Response::error(id, "invalid_params", "surface/panel must be a string");
            };
            match uuid::Uuid::parse_str(s) {
                Ok(uuid) => Some(uuid),
                Err(_) => {
                    return Response::error(
                        id,
                        "invalid_params",
                        "Invalid surface/panel UUID format",
                    )
                }
            }
        }
        None => None,
    };

    let panel_id = {
        let tab_manager = lock_or_recover(&state.tab_manager);
        if let Some(panel_id) = explicit_panel_id {
            if tab_manager.find_workspace_with_panel(panel_id).is_none() {
                return Response::error(id, "not_found", "Surface not found");
            }
            panel_id
        } else if let Some(workspace) = tab_manager.selected() {
            let Some(panel_id) = workspace
                .focused_panel_id
                .or_else(|| workspace.panel_ids().into_iter().next())
            else {
                return Response::error(id, "not_found", "No focused surface");
            };
            panel_id
        } else {
            return Response::error(id, "not_found", "No workspace selected");
        }
    };

    if !state.send_ui_event(UiEvent::SendInput {
        panel_id,
        text: input.to_string(),
    }) {
        return Response::error(id, "not_ready", "UI is not ready");
    }

    Response::success(
        id,
        serde_json::json!({
            "sent": true,
            "surface": panel_id.to_string(),
        }),
    )
}

// -----------------------------------------------------------------------
// Notification handlers
// -----------------------------------------------------------------------

fn handle_notification_create(id: Value, params: &Value, state: &Arc<SharedState>) -> Response {
    let title = crate::model::workspace::truncate_str(
        params
            .get("title")
            .and_then(|v| v.as_str())
            .unwrap_or("cmux"),
        1024,
    );
    let body = crate::model::workspace::truncate_str(
        params.get("body").and_then(|v| v.as_str()).unwrap_or(""),
        8192,
    );
    let workspace_id = match parse_workspace_param(params) {
        Ok(v) => v,
        Err(()) => return Response::error(id, "invalid_params", "Invalid workspace UUID"),
    };
    let panel_id = match params.get("surface").or_else(|| params.get("panel")) {
        Some(v) => {
            let Some(s) = v.as_str() else {
                return Response::error(id, "invalid_params", "surface/panel must be a string");
            };
            match uuid::Uuid::parse_str(s) {
                Ok(uuid) => Some(uuid),
                Err(_) => {
                    return Response::error(
                        id,
                        "invalid_params",
                        "Invalid surface/panel UUID format",
                    )
                }
            }
        }
        None => None,
    };
    let send_desktop = params
        .get("send_desktop")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);

    let target = {
        let mut tm = lock_or_recover(&state.tab_manager);
        let target_workspace_id = if let Some(workspace_id) = workspace_id {
            if tm.workspace(workspace_id).is_some() {
                Some(workspace_id)
            } else {
                return Response::error(id, "not_found", "Workspace not found");
            }
        } else if let Some(panel_id) = panel_id {
            tm.find_workspace_with_panel(panel_id).map(|ws| ws.id)
        } else {
            tm.selected_id()
        };

        let Some(target_workspace_id) = target_workspace_id else {
            return Response::error(id, "not_found", "No workspace selected");
        };

        let workspace = tm.workspace_mut(target_workspace_id).unwrap();
        let resolved_panel_id = panel_id.filter(|id| workspace.panels.contains_key(id));
        workspace.record_notification(title, body, resolved_panel_id);
        (target_workspace_id, resolved_panel_id)
    };

    let (target_workspace_id, resolved_panel_id) = target;
    lock_or_recover(&state.notifications).add(
        title,
        body,
        Some(target_workspace_id),
        resolved_panel_id,
        send_desktop,
    );
    state.notify_ui_refresh();

    Response::success(
        id,
        serde_json::json!({
            "notified": true,
            "workspace": target_workspace_id.to_string(),
            "workspace_id": target_workspace_id.to_string(),
            "surface": resolved_panel_id.map(|panel_id| panel_id.to_string()),
        }),
    )
}

fn mark_workspace_read(state: &Arc<SharedState>, workspace_id: uuid::Uuid) {
    lock_or_recover(&state.notifications).mark_workspace_read(workspace_id);

    if let Some(workspace) = lock_or_recover(&state.tab_manager).workspace_mut(workspace_id) {
        workspace.mark_notifications_read();
    }
}

/// Parse a workspace UUID from `workspace` or `workspace_id` params.
/// Returns `Err(())` if the key exists but the value is not a valid UUID.
/// Returns `Ok(None)` if neither key is present.
fn parse_workspace_param(params: &Value) -> Result<Option<uuid::Uuid>, ()> {
    let val = params
        .get("workspace")
        .or_else(|| params.get("workspace_id"));
    match val {
        Some(v) => match v.as_str().map(uuid::Uuid::parse_str) {
            Some(Ok(id)) => Ok(Some(id)),
            _ => Err(()),
        },
        None => Ok(None),
    }
}

fn parse_usize_param(id: &Value, params: &Value, key: &str) -> Result<Option<usize>, Response> {
    match params.get(key) {
        Some(v) => match v.as_u64() {
            Some(value) => usize::try_from(value).map(Some).map_err(|_| {
                Response::error(
                    id.clone(),
                    "invalid_params",
                    &format!("'{key}' is out of range"),
                )
            }),
            None => Err(Response::error(
                id.clone(),
                "invalid_params",
                &format!("'{key}' must be a non-negative integer"),
            )),
        },
        None => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_notification_create_updates_workspace_attention() {
        let state = Arc::new(SharedState::new());
        let (workspace_id, panel_id) = {
            let tab_manager = lock_or_recover(&state.tab_manager);
            let workspace = tab_manager.selected().unwrap();
            (workspace.id, workspace.focused_panel_id.unwrap())
        };

        let request = serde_json::json!({
            "id": 1,
            "method": "notification.create",
            "params": {
                "title": "Codex",
                "body": "Waiting for input",
                "workspace": workspace_id.to_string(),
                "surface": panel_id.to_string(),
                "send_desktop": false
            }
        });

        let response = dispatch(&request.to_string(), &state);
        assert!(response.ok);

        let tab_manager = lock_or_recover(&state.tab_manager);
        let workspace = tab_manager.workspace(workspace_id).unwrap();
        assert_eq!(workspace.unread_count, 1);
        assert_eq!(
            workspace.latest_notification.as_deref(),
            Some("Codex: Waiting for input")
        );
        assert_eq!(workspace.attention_panel_id, Some(panel_id));
    }

    #[test]
    fn test_workspace_latest_unread_selects_newest_workspace() {
        let state = Arc::new(SharedState::new());
        let workspace_one_id = lock_or_recover(&state.tab_manager).selected_id().unwrap();

        let new_workspace_request = serde_json::json!({
            "id": 1,
            "method": "workspace.new",
            "params": {
                "title": "Second"
            }
        });
        let response = dispatch(&new_workspace_request.to_string(), &state);
        assert!(response.ok);

        let workspace_two_id = lock_or_recover(&state.tab_manager).selected_id().unwrap();

        let first_notification = serde_json::json!({
            "id": 2,
            "method": "notification.create",
            "params": {
                "title": "Claude Code",
                "body": "Needs approval",
                "workspace": workspace_one_id.to_string(),
                "send_desktop": false
            }
        });
        assert!(dispatch(&first_notification.to_string(), &state).ok);

        std::thread::sleep(std::time::Duration::from_millis(1));

        let second_notification = serde_json::json!({
            "id": 3,
            "method": "notification.create",
            "params": {
                "title": "Codex",
                "body": "Waiting for input",
                "workspace": workspace_two_id.to_string(),
                "send_desktop": false
            }
        });
        assert!(dispatch(&second_notification.to_string(), &state).ok);

        let latest_unread = serde_json::json!({
            "id": 4,
            "method": "workspace.latest_unread",
            "params": {}
        });
        let response = dispatch(&latest_unread.to_string(), &state);
        assert!(response.ok);

        let tab_manager = lock_or_recover(&state.tab_manager);
        assert_eq!(tab_manager.selected_id(), Some(workspace_two_id));
        assert_eq!(
            tab_manager
                .workspace(workspace_two_id)
                .unwrap()
                .unread_count,
            0
        );
        assert_eq!(
            tab_manager
                .workspace(workspace_one_id)
                .unwrap()
                .unread_count,
            1
        );
    }

    #[test]
    fn test_surface_send_input_dispatches_ui_event() {
        let state = Arc::new(SharedState::new());
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel();
        state.install_ui_event_sender(tx);

        let panel_id = {
            let tab_manager = lock_or_recover(&state.tab_manager);
            tab_manager.selected().unwrap().focused_panel_id.unwrap()
        };

        let request = serde_json::json!({
            "id": 1,
            "method": "surface.send_input",
            "params": {
                "surface": panel_id.to_string(),
                "input": "ls\n"
            }
        });

        let response = dispatch(&request.to_string(), &state);
        assert!(response.ok);

        let event = rx.try_recv().expect("expected a UI event");
        match event {
            UiEvent::SendInput {
                panel_id: actual,
                text,
            } => {
                assert_eq!(actual, panel_id);
                assert_eq!(text, "ls\n");
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }

    #[test]
    fn test_workspace_create_alias_and_legacy_response_field() {
        let state = Arc::new(SharedState::new());
        let selected_before = lock_or_recover(&state.tab_manager).selected_id();

        let response = dispatch(
            r#"{"id":1,"method":"workspace.create","params":{"title":"Legacy"}}"#,
            &state,
        );

        assert!(response.ok);
        let result = response.result.unwrap();
        let workspace_id = result
            .get("workspace_id")
            .and_then(|v| v.as_str())
            .expect("legacy workspace_id should be present");
        assert_eq!(
            result.get("workspace").and_then(|v| v.as_str()),
            Some(workspace_id)
        );
        assert_eq!(
            lock_or_recover(&state.tab_manager).selected_id(),
            selected_before
        );
    }

    #[test]
    fn test_workspace_list_keeps_selected_alias() {
        let state = Arc::new(SharedState::new());

        let response = dispatch(r#"{"id":1,"method":"workspace.list","params":{}}"#, &state);

        assert!(response.ok);
        let result = response.result.unwrap();
        let workspaces = result["workspaces"].as_array().expect("workspaces array");
        let first = &workspaces[0];
        assert_eq!(first.get("selected").and_then(|v| v.as_bool()), Some(true));
        assert_eq!(
            first.get("is_selected").and_then(|v| v.as_bool()),
            Some(true)
        );
    }

    #[test]
    fn test_workspace_select_accepts_legacy_workspace_id_param() {
        let state = Arc::new(SharedState::new());
        let workspace_id = lock_or_recover(&state.tab_manager).selected_id().unwrap();

        let response = dispatch(
            &serde_json::json!({
                "id": 1,
                "method": "workspace.select",
                "params": {
                    "workspace_id": workspace_id.to_string()
                }
            })
            .to_string(),
            &state,
        );

        assert!(response.ok);
        assert_eq!(
            lock_or_recover(&state.tab_manager).selected_id(),
            Some(workspace_id)
        );
    }

    #[test]
    fn test_workspace_create_accepts_legacy_cwd_param() {
        let state = Arc::new(SharedState::new());

        let response = dispatch(
            r#"{"id":1,"method":"workspace.create","params":{"cwd":"/tmp/cmux-legacy"}}"#,
            &state,
        );

        assert!(response.ok);
        let workspace_id = response.result.as_ref().unwrap()["workspace_id"]
            .as_str()
            .expect("workspace_id should be present");
        let workspace_id = uuid::Uuid::parse_str(workspace_id).expect("valid uuid");

        let tab_manager = lock_or_recover(&state.tab_manager);
        let workspace = tab_manager
            .workspace(workspace_id)
            .expect("workspace should exist");
        assert_eq!(workspace.current_directory, "/tmp/cmux-legacy");
    }
}
