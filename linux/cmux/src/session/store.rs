//! Session store — reads and writes session snapshots to XDG_DATA_HOME.

use std::path::PathBuf;

use crate::session::snapshot::*;

/// Get the session file path: ~/.local/share/cmux/session.json
fn session_path() -> PathBuf {
    let data_dir = dirs::data_dir()
        .or_else(|| dirs::home_dir().map(|h| h.join(".local/share")))
        .unwrap_or_else(|| {
            let uid = unsafe { libc::getuid() };
            PathBuf::from(format!("/tmp/cmux-{}", uid))
        })
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
    // Atomic write: write to tmp file then rename to prevent corruption on crash
    let tmp_path = path.with_extension("json.tmp");
    std::fs::write(&tmp_path, json)?;
    std::fs::rename(&tmp_path, &path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp_path);
    })?;

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
    match serde_json::from_str::<AppSessionSnapshot>(&json) {
        Ok(snapshot) => {
            tracing::debug!("Session loaded from {}", path.display());
            Ok(Some(snapshot))
        }
        Err(e) => {
            tracing::warn!("Corrupt session file at {}, ignoring: {}", path.display(), e);
            let backup = path.with_extension("json.corrupt");
            let _ = std::fs::rename(&path, &backup);
            Ok(None)
        }
    }
}

/// Create a snapshot from the current application state.
///
/// Minimizes lock scope: clones workspace data under lock, then builds
/// the snapshot structures after releasing the mutex.
pub fn create_snapshot(state: &crate::app::AppState) -> AppSessionSnapshot {
    // Clone workspace data under lock, then release immediately
    let (workspace_data, selected_index) = {
        let tm = state.tab_manager();
        let data: Vec<_> = tm.iter().cloned().collect();
        let idx = tm.selected_index();
        (data, idx)
    }; // MutexGuard dropped here

    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64();

    let workspaces: Vec<SessionWorkspaceSnapshot> = workspace_data
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
                selected_workspace_index: selected_index,
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
