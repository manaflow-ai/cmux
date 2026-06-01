//! Session store — reads and writes session snapshots to XDG_DATA_HOME.

use std::fs::OpenOptions;
use std::io::Write;
use std::path::Path;
use std::path::PathBuf;

use std::os::unix::fs::OpenOptionsExt;
use std::os::unix::fs::PermissionsExt;

use crate::app::lock_or_recover;
use crate::session::snapshot::*;

/// Get the session file path: ~/.local/share/cmux/session.json
fn session_path() -> PathBuf {
    let data_dir = dirs::data_dir()
        .or_else(|| dirs::home_dir().map(|home| home.join(".local/share")))
        .unwrap_or_else(|| std::env::temp_dir().join(format!("cmux-{}", unsafe { libc::getuid() })))
        .join("cmux");
    data_dir.join("session.json")
}

/// Save a session snapshot to disk.
pub fn save_session(snapshot: &AppSessionSnapshot) -> anyhow::Result<()> {
    let path = session_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
        std::fs::set_permissions(parent, std::fs::Permissions::from_mode(0o700))?;
    }

    let json = serde_json::to_string_pretty(snapshot)?;
    write_atomic(&path, json.as_bytes())?;

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
    let snapshot: AppSessionSnapshot = match serde_json::from_str(&json) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            tracing::warn!(
                "Corrupt session file at {}, ignoring: {}",
                path.display(),
                error
            );
            let backup = path.with_extension("json.corrupt");
            let _ = std::fs::rename(&path, &backup);
            return Ok(None);
        }
    };

    tracing::debug!("Session loaded from {}", path.display());
    Ok(Some(snapshot))
}

fn write_atomic(path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let tmp_path = path.with_extension(format!("json.tmp.{}", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(&tmp_path)?;
    file.write_all(bytes)?;
    file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    file.sync_all()?;
    std::fs::rename(&tmp_path, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp_path);
    })?;
    Ok(())
}

/// Create a snapshot from the current application state.
pub fn create_snapshot(state: &crate::app::AppState) -> AppSessionSnapshot {
    let tm = lock_or_recover(&state.shared.tab_manager);
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
