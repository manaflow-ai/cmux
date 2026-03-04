//! Session store — reads and writes session snapshots to XDG_DATA_HOME.

use std::path::PathBuf;

use crate::session::snapshot::*;

/// Get the session file path: ~/.local/share/cmux/session.json
fn session_path() -> PathBuf {
    let data_dir = dirs::data_dir()
        .unwrap_or_else(|| PathBuf::from("~/.local/share"))
        .join("cmux");
    data_dir.join("session.json")
}

/// Save a session snapshot to disk.
pub fn save_session(snapshot: &AppSessionSnapshot) -> anyhow::Result<()> {
    let path = session_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    let json = serde_json::to_string_pretty(snapshot)?;
    std::fs::write(&path, json)?;

    tracing::debug!("Session saved to {}", path.display());
    Ok(())
}

/// Load a session snapshot from disk.
pub fn load_session() -> anyhow::Result<Option<AppSessionSnapshot>> {
    let path = session_path();
    if !path.exists() {
        return Ok(None);
    }

    let json = std::fs::read_to_string(&path)?;
    let snapshot: AppSessionSnapshot = serde_json::from_str(&json)?;

    tracing::debug!("Session loaded from {}", path.display());
    Ok(Some(snapshot))
}

/// Create a snapshot from the current application state.
pub fn create_snapshot(state: &crate::app::AppState) -> AppSessionSnapshot {
    let tm = state.tab_manager.borrow();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    let workspaces: Vec<SessionWorkspaceSnapshot> = tm
        .iter()
        .map(|ws| {
            let panels: Vec<SessionPanelSnapshot> = ws
                .panels
                .values()
                .map(SessionPanelSnapshot::from_panel)
                .collect();

            SessionWorkspaceSnapshot {
                process_title: ws.process_title.clone(),
                custom_title: ws.custom_title.clone(),
                custom_color: ws.custom_color.clone(),
                is_pinned: ws.is_pinned,
                current_directory: ws.current_directory.clone(),
                focused_panel_id: ws.focused_panel_id,
                layout: SessionWorkspaceLayoutSnapshot::from_layout(&ws.layout),
                panels,
                status_entries: ws.status_entries.clone(),
                log_entries: ws.log_entries.clone(),
                progress: ws.progress.clone(),
                git_branch: ws.git_branch.clone(),
            }
        })
        .collect();

    AppSessionSnapshot {
        version: 1,
        created_at: now,
        windows: vec![SessionWindowSnapshot {
            frame: None,
            tab_manager: SessionTabManagerSnapshot {
                selected_workspace_index: tm.selected_index(),
                workspaces,
            },
            sidebar: SessionSidebarSnapshot {
                is_visible: true,
                selection: "tabs".to_string(),
                width: None,
            },
        }],
    }
}
