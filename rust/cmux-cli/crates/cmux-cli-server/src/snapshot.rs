//! JSON-on-disk snapshot of the daemon's workspace structure.
//!
//! Environment and live shell state aren't captured. On restore each tab
//! re-exec's the configured shell in the recorded cwd. Snapshots carry a
//! bounded PTY replay buffer so graphical clients can redraw the last visible
//! terminal state while fresh shells start. Proper scrollback persistence lives
//! behind the M6 disk-spill work.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub version: u32,
    pub active_workspace: usize,
    pub workspaces: Vec<WorkspaceSnapshot>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub native_windows: Vec<NativeWindowSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NativeWindowSnapshot {
    pub external_window_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_workspace_external_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_workspace_index: Option<usize>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub workspace_external_ids: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub workspace_indexes: Vec<usize>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub latest_submitted_message: Option<String>,
    /// New model: each workspace owns multiple spaces.
    #[serde(default)]
    pub active_space: usize,
    #[serde(default)]
    pub spaces: Vec<SpaceSnapshot>,
    /// Legacy v1 field from the pre-space model. When `spaces` is empty we
    /// restore one implicit space from these fields.
    #[serde(default)]
    pub active_tab: usize,
    /// Legacy v1 field from the pre-space model.
    #[serde(default)]
    pub tabs: Vec<TabSnapshot>,
    /// Legacy v1 field from the pre-panel split model. New snapshots use
    /// `spaces[*].panel_tree`; this remains so older snapshots still
    /// deserialize.
    #[serde(default)]
    pub split_direction: Option<String>,
    /// Legacy v1 field from the pre-panel split model.
    #[serde(default = "default_ratio")]
    pub first_split_ratio_permille: u16,
    /// Preferred active panel for legacy/non-client command paths.
    #[serde(default)]
    pub active_panel: Option<u64>,
    /// Recursive panel tree. Leaf panels own tab indexes into `tabs`.
    #[serde(default)]
    pub panel_tree: Option<PanelSnapshot>,
    /// Pinned workspaces don't auto-close when their last tab
    /// exits; a fresh shell is spawned instead so the workspace
    /// persists across `exit` / `C-d` cycles.
    #[serde(default)]
    pub pinned: bool,
    /// Optional `#RRGGBB` color tint for the workspace's sidebar
    /// row.
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_status_json: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub remote_config_json: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub status_entries: Vec<SnapshotSidebarStatusEntry>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub metadata_blocks: Vec<SnapshotSidebarMetadataBlock>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub log_entries: Vec<SnapshotSidebarLogEntry>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub progress: Option<SnapshotSidebarProgressState>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotSidebarStatusEntry {
    pub key: String,
    pub value: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default)]
    pub priority: i32,
    #[serde(default = "default_sidebar_metadata_format")]
    pub format: String,
    #[serde(default)]
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotSidebarMetadataBlock {
    pub key: String,
    pub markdown: String,
    #[serde(default)]
    pub priority: i32,
    #[serde(default)]
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotSidebarLogEntry {
    pub message: String,
    #[serde(default = "default_sidebar_log_level")]
    pub level: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
    #[serde(default)]
    pub updated_at_ms: u64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SnapshotSidebarProgressState {
    pub value: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

fn default_sidebar_metadata_format() -> String {
    "plain".to_string()
}

fn default_sidebar_log_level() -> String {
    "info".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpaceSnapshot {
    pub title: String,
    pub active_tab: usize,
    pub tabs: Vec<TabSnapshot>,
    #[serde(default)]
    pub active_panel: Option<u64>,
    #[serde(default)]
    pub panel_tree: Option<PanelSnapshot>,
}

fn default_ratio() -> u16 {
    500
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TabSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub external_id: Option<String>,
    #[serde(default)]
    pub kind: SnapshotTabKind,
    pub title: String,
    pub cwd: Option<PathBuf>,
    #[serde(default)]
    pub explicit_title: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub pinned: bool,
    #[serde(default, skip_serializing_if = "is_false")]
    pub has_activity: bool,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub bell_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<SnapshotGitBranch>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<SnapshotPullRequest>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tty_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shell_state: Option<String>,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub ports_kick_generation: u64,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub listening_ports: Vec<u16>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub pty_replay_base64: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub browser: Option<BrowserSnapshot>,
}

fn is_false(value: &bool) -> bool {
    !*value
}

fn is_zero_u64(value: &u64) -> bool {
    *value == 0
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum SnapshotTabKind {
    #[default]
    Terminal,
    Browser,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotGitBranch {
    pub branch: String,
    #[serde(default)]
    pub is_dirty: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotPullRequest {
    pub number: u64,
    pub label: String,
    pub url: String,
    pub status: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub is_stale: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct BrowserSnapshot {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url_string: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile_id: Option<String>,
    #[serde(default)]
    pub should_render_webview: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page_zoom: Option<f64>,
    #[serde(default)]
    pub developer_tools_visible: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub back_history_url_strings: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub forward_history_url_strings: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proxy: Option<BrowserProxySnapshot>,
    #[serde(default, skip_serializing_if = "is_zero_u64")]
    pub reload_generation: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrowserProxySnapshot {
    pub host: String,
    pub port: u16,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum PanelSnapshot {
    Leaf {
        id: u64,
        active_tab: Option<usize>,
        tabs: Vec<usize>,
    },
    Split {
        direction: String,
        #[serde(default = "default_ratio")]
        ratio_permille: u16,
        first: Box<PanelSnapshot>,
        second: Box<PanelSnapshot>,
    },
}

/// Read a snapshot from disk. Returns `None` on any error (missing file,
/// parse failure, version mismatch) because a snapshot is best-effort
/// convenience; we never want a corrupt snapshot to break startup.
#[must_use]
pub fn load(path: &Path) -> Option<Snapshot> {
    let bytes = std::fs::read(path).ok()?;
    let snap: Snapshot = serde_json::from_slice(&bytes).ok()?;
    if snap.version != 1 {
        return None;
    }
    Some(snap)
}

/// Write a snapshot to disk, creating parent directories as needed.
pub fn save(path: &Path, snap: &Snapshot) -> anyhow::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let json = serde_json::to_vec_pretty(snap)?;
    // Atomic rename via a tempfile in the same directory.
    let tmp = path.with_extension("json.tmp");
    std::fs::write(&tmp, json)?;
    std::fs::rename(tmp, path)?;
    save_native_windows_sidecar(path, &snap.native_windows)?;
    Ok(())
}

fn save_native_windows_sidecar(
    snapshot_path: &Path,
    native_windows: &[NativeWindowSnapshot],
) -> anyhow::Result<()> {
    let Some(parent) = snapshot_path.parent() else {
        return Ok(());
    };
    let path = parent.join("native-windows.json");
    let tmp = parent.join("native-windows.json.tmp");
    let json = serde_json::to_vec_pretty(native_windows)?;
    std::fs::write(&tmp, json)?;
    std::fs::rename(tmp, path)?;
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DesktopSessionImportStatus {
    Imported,
    AlreadyImported,
    SourceMissing,
    SourceInvalid,
    CmxSnapshotExists,
    NoWorkspaces,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopSessionImportResult {
    pub status: DesktopSessionImportStatus,
    pub marker_path: PathBuf,
    pub snapshot_path: PathBuf,
    pub imported_workspaces: usize,
    pub imported_terminals: usize,
    pub message: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct DesktopSessionImportMarker {
    version: u32,
    status: String,
    imported_at_unix_ms: u64,
    source_path: String,
    source_fingerprint: String,
    source_size_bytes: usize,
    source_backup_path: Option<PathBuf>,
    snapshot_path: PathBuf,
    imported_workspaces: usize,
    imported_terminals: usize,
    message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DesktopAppSessionSnapshot {
    version: i64,
    #[serde(default)]
    windows: Vec<DesktopWindowSnapshot>,
}

#[derive(Debug, Deserialize)]
struct DesktopWindowSnapshot {
    #[serde(rename = "tabManager")]
    tab_manager: DesktopTabManagerSnapshot,
}

#[derive(Debug, Deserialize)]
struct DesktopTabManagerSnapshot {
    #[serde(rename = "selectedWorkspaceIndex")]
    selected_workspace_index: Option<usize>,
    #[serde(default)]
    workspaces: Vec<DesktopWorkspaceSnapshot>,
}

#[derive(Debug, Deserialize)]
struct DesktopWorkspaceSnapshot {
    #[serde(rename = "processTitle")]
    process_title: String,
    #[serde(rename = "customTitle")]
    custom_title: Option<String>,
    #[serde(default, rename = "customDescription")]
    custom_description: Option<String>,
    #[serde(rename = "customColor")]
    custom_color: Option<String>,
    #[serde(rename = "isPinned", default)]
    is_pinned: bool,
    #[serde(rename = "currentDirectory")]
    current_directory: String,
    #[serde(rename = "focusedPanelId")]
    focused_panel_id: Option<String>,
    layout: DesktopWorkspaceLayoutSnapshot,
    #[serde(default)]
    panels: Vec<DesktopPanelSnapshot>,
}

#[derive(Debug, Deserialize)]
struct DesktopPanelSnapshot {
    id: String,
    #[serde(rename = "type")]
    panel_type: String,
    title: Option<String>,
    #[serde(rename = "customTitle")]
    custom_title: Option<String>,
    directory: Option<String>,
    #[serde(default, rename = "isManuallyUnread")]
    is_manually_unread: bool,
    terminal: Option<DesktopTerminalPanelSnapshot>,
    browser: Option<DesktopBrowserPanelSnapshot>,
}

#[derive(Debug, Deserialize)]
struct DesktopTerminalPanelSnapshot {
    #[serde(rename = "workingDirectory")]
    working_directory: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DesktopBrowserPanelSnapshot {
    #[serde(rename = "urlString")]
    url_string: Option<String>,
    #[serde(rename = "profileID")]
    profile_id: Option<String>,
    #[serde(rename = "shouldRenderWebView", default)]
    should_render_webview: bool,
    #[serde(rename = "pageZoom")]
    page_zoom: Option<f64>,
    #[serde(rename = "developerToolsVisible", default)]
    developer_tools_visible: bool,
    #[serde(rename = "backHistoryURLStrings", default)]
    back_history_url_strings: Option<Vec<String>>,
    #[serde(rename = "forwardHistoryURLStrings", default)]
    forward_history_url_strings: Option<Vec<String>>,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum DesktopWorkspaceLayoutSnapshot {
    Pane {
        pane: DesktopPaneLayoutSnapshot,
    },
    Split {
        split: Box<DesktopSplitLayoutSnapshot>,
    },
}

#[derive(Debug, Deserialize)]
struct DesktopPaneLayoutSnapshot {
    #[serde(rename = "panelIds", default)]
    panel_ids: Vec<String>,
    #[serde(rename = "selectedPanelId")]
    selected_panel_id: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DesktopSplitLayoutSnapshot {
    orientation: String,
    #[serde(rename = "dividerPosition")]
    divider_position: f64,
    first: Box<DesktopWorkspaceLayoutSnapshot>,
    second: Box<DesktopWorkspaceLayoutSnapshot>,
}

struct DesktopWorkspaceImport {
    snapshot: WorkspaceSnapshot,
    terminal_count: usize,
}

struct DesktopWorkspaceLayoutImport {
    node: Option<PanelSnapshot>,
    leaf_id_by_panel_id: HashMap<String, u64>,
    first_active_tab: Option<usize>,
}

/// Import the macOS Swift session snapshot into cmx's structure snapshot.
///
/// The import is intentionally one-way: once the marker exists, future calls do
/// not re-read or overwrite Rust state. This keeps the old Swift store from
/// becoming a hidden dual-write participant during the desktop cutover.
pub fn import_desktop_session_snapshot(
    source_path: &Path,
    snapshot_path: &Path,
    state_dir: Option<&Path>,
) -> Result<DesktopSessionImportResult> {
    let marker_path = desktop_session_import_marker_path(snapshot_path, state_dir);
    if marker_path.exists() {
        return Ok(import_result(
            DesktopSessionImportStatus::AlreadyImported,
            marker_path,
            snapshot_path.to_path_buf(),
            0,
            0,
            None,
        ));
    }

    let source_bytes = match std::fs::read(source_path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok(import_result(
                DesktopSessionImportStatus::SourceMissing,
                marker_path,
                snapshot_path.to_path_buf(),
                0,
                0,
                None,
            ));
        }
        Err(error) => {
            return Ok(import_result(
                DesktopSessionImportStatus::SourceInvalid,
                marker_path,
                snapshot_path.to_path_buf(),
                0,
                0,
                Some(error.to_string()),
            ));
        }
    };

    let fingerprint = desktop_session_source_fingerprint(&source_bytes);
    let backup_path = desktop_session_import_backup_path(snapshot_path, state_dir);

    if snapshot_path.exists() {
        write_desktop_session_import_marker(
            &marker_path,
            DesktopSessionImportMarker {
                version: 1,
                status: "skipped_existing_cmx_snapshot".to_string(),
                imported_at_unix_ms: unix_millis_now(),
                source_path: source_path.display().to_string(),
                source_fingerprint: fingerprint,
                source_size_bytes: source_bytes.len(),
                source_backup_path: None,
                snapshot_path: snapshot_path.to_path_buf(),
                imported_workspaces: 0,
                imported_terminals: 0,
                message: Some(
                    "cmx snapshot already exists; preserving Rust-owned state".to_string(),
                ),
            },
        )?;
        return Ok(import_result(
            DesktopSessionImportStatus::CmxSnapshotExists,
            marker_path,
            snapshot_path.to_path_buf(),
            0,
            0,
            None,
        ));
    }

    let desktop_snapshot: DesktopAppSessionSnapshot = match serde_json::from_slice(&source_bytes) {
        Ok(snapshot) => snapshot,
        Err(error) => {
            return Ok(import_result(
                DesktopSessionImportStatus::SourceInvalid,
                marker_path,
                snapshot_path.to_path_buf(),
                0,
                0,
                Some(error.to_string()),
            ));
        }
    };

    let (snapshot, imported_terminals) = match convert_desktop_session_snapshot(&desktop_snapshot) {
        Some(converted) => converted,
        None => {
            write_desktop_session_import_marker(
                &marker_path,
                DesktopSessionImportMarker {
                    version: 1,
                    status: "no_workspaces".to_string(),
                    imported_at_unix_ms: unix_millis_now(),
                    source_path: source_path.display().to_string(),
                    source_fingerprint: fingerprint,
                    source_size_bytes: source_bytes.len(),
                    source_backup_path: None,
                    snapshot_path: snapshot_path.to_path_buf(),
                    imported_workspaces: 0,
                    imported_terminals: 0,
                    message: Some(
                        "Swift desktop session snapshot contained no importable workspaces"
                            .to_string(),
                    ),
                },
            )?;
            return Ok(import_result(
                DesktopSessionImportStatus::NoWorkspaces,
                marker_path,
                snapshot_path.to_path_buf(),
                0,
                0,
                None,
            ));
        }
    };

    if let Some(parent) = backup_path.parent() {
        std::fs::create_dir_all(parent).with_context(|| {
            format!(
                "create desktop import backup directory {}",
                parent.display()
            )
        })?;
    }
    std::fs::write(&backup_path, &source_bytes).with_context(|| {
        format!(
            "write desktop import source backup {}",
            backup_path.display()
        )
    })?;
    save(snapshot_path, &snapshot)
        .with_context(|| format!("write imported cmx snapshot {}", snapshot_path.display()))?;
    write_desktop_session_import_marker(
        &marker_path,
        DesktopSessionImportMarker {
            version: 1,
            status: "imported".to_string(),
            imported_at_unix_ms: unix_millis_now(),
            source_path: source_path.display().to_string(),
            source_fingerprint: fingerprint,
            source_size_bytes: source_bytes.len(),
            source_backup_path: Some(backup_path),
            snapshot_path: snapshot_path.to_path_buf(),
            imported_workspaces: snapshot.workspaces.len(),
            imported_terminals,
            message: Some(format!(
                "imported Swift desktop session schema v{} into cmx",
                desktop_snapshot.version
            )),
        },
    )?;

    Ok(import_result(
        DesktopSessionImportStatus::Imported,
        marker_path,
        snapshot_path.to_path_buf(),
        snapshot.workspaces.len(),
        imported_terminals,
        None,
    ))
}

fn import_result(
    status: DesktopSessionImportStatus,
    marker_path: PathBuf,
    snapshot_path: PathBuf,
    imported_workspaces: usize,
    imported_terminals: usize,
    message: Option<String>,
) -> DesktopSessionImportResult {
    DesktopSessionImportResult {
        status,
        marker_path,
        snapshot_path,
        imported_workspaces,
        imported_terminals,
        message,
    }
}

fn desktop_session_import_marker_path(snapshot_path: &Path, state_dir: Option<&Path>) -> PathBuf {
    state_dir
        .map(Path::to_path_buf)
        .or_else(|| snapshot_path.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("desktop-session-import.json")
}

fn desktop_session_import_backup_path(snapshot_path: &Path, state_dir: Option<&Path>) -> PathBuf {
    state_dir
        .map(Path::to_path_buf)
        .or_else(|| snapshot_path.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
        .join("desktop-session-import-source.json")
}

fn write_desktop_session_import_marker(
    marker_path: &Path,
    marker: DesktopSessionImportMarker,
) -> Result<()> {
    if let Some(parent) = marker_path.parent() {
        std::fs::create_dir_all(parent).with_context(|| {
            format!(
                "create desktop import marker directory {}",
                parent.display()
            )
        })?;
    }
    let json = serde_json::to_vec_pretty(&marker)?;
    let tmp = marker_path.with_extension("json.tmp");
    std::fs::write(&tmp, json)
        .with_context(|| format!("write desktop import marker temp {}", tmp.display()))?;
    std::fs::rename(&tmp, marker_path)
        .with_context(|| format!("rename desktop import marker {}", marker_path.display()))?;
    Ok(())
}

fn convert_desktop_session_snapshot(
    desktop_snapshot: &DesktopAppSessionSnapshot,
) -> Option<(Snapshot, usize)> {
    let mut workspaces = Vec::new();
    let mut native_windows = Vec::new();
    let mut active_workspace = 0usize;
    let mut did_select_active = false;
    let mut imported_terminals = 0usize;

    for (window_index, window) in desktop_snapshot.windows.iter().enumerate() {
        let selected_index = window.tab_manager.selected_workspace_index;
        let first_workspace_index = workspaces.len();
        let mut selected_workspace_index = None;
        for (index, workspace) in window.tab_manager.workspaces.iter().enumerate() {
            let global_workspace_index = workspaces.len();
            if !did_select_active && selected_index == Some(index) {
                active_workspace = global_workspace_index;
                did_select_active = true;
            }
            if selected_index.unwrap_or(0) == index {
                selected_workspace_index = Some(global_workspace_index);
            }
            let imported = convert_desktop_workspace_snapshot(workspace);
            imported_terminals += imported.terminal_count;
            workspaces.push(imported.snapshot);
        }
        if first_workspace_index < workspaces.len() {
            native_windows.push(NativeWindowSnapshot {
                external_window_id: cmx_external_uuid(3, window_index as u64),
                active_workspace_external_id: None,
                active_workspace_index: Some(
                    selected_workspace_index.unwrap_or(first_workspace_index),
                ),
                workspace_external_ids: Vec::new(),
                workspace_indexes: (first_workspace_index..workspaces.len()).collect(),
            });
        }
    }

    if workspaces.is_empty() {
        return None;
    }

    Some((
        Snapshot {
            version: 1,
            active_workspace,
            workspaces,
            native_windows,
        },
        imported_terminals,
    ))
}

fn cmx_external_uuid(namespace: u16, id: u64) -> String {
    let high = (id >> 52) & 0x0fff;
    let middle = (id >> 40) & 0x0fff;
    let low = id & 0x00ff_ffff_ffff;
    format!("c0de{namespace:04x}-c0de-4{high:03x}-8{middle:03x}-{low:012x}")
}

fn convert_desktop_workspace_snapshot(
    workspace: &DesktopWorkspaceSnapshot,
) -> DesktopWorkspaceImport {
    let mut tabs = Vec::new();
    let mut tab_index_by_panel_id = HashMap::new();
    for panel in &workspace.panels {
        match panel.panel_type.as_str() {
            "terminal" => {
                let tab_index = tabs.len();
                tab_index_by_panel_id.insert(panel.id.clone(), tab_index);
                let title = desktop_panel_title(panel);
                tabs.push(TabSnapshot {
                    external_id: clean_desktop_string(Some(panel.id.as_str())),
                    kind: SnapshotTabKind::Terminal,
                    title: title.clone().unwrap_or_else(|| "sh".to_string()),
                    cwd: desktop_panel_cwd(panel, workspace).map(PathBuf::from),
                    explicit_title: title.is_some(),
                    pinned: false,
                    has_activity: panel.is_manually_unread,
                    bell_count: 0,
                    git_branch: None,
                    pull_request: None,
                    tty_name: None,
                    shell_state: None,
                    ports_kick_generation: 0,
                    listening_ports: Vec::new(),
                    pty_replay_base64: Vec::new(),
                    browser: None,
                });
            }
            "browser" => {
                let tab_index = tabs.len();
                tab_index_by_panel_id.insert(panel.id.clone(), tab_index);
                let browser = browser_snapshot_from_desktop_panel(panel);
                let title = desktop_panel_title(panel)
                    .or_else(|| browser.as_ref().and_then(|snapshot| snapshot.title.clone()))
                    .or_else(|| {
                        browser
                            .as_ref()
                            .and_then(|snapshot| snapshot.url_string.clone())
                    })
                    .unwrap_or_else(|| "Browser".to_string());
                tabs.push(TabSnapshot {
                    external_id: clean_desktop_string(Some(panel.id.as_str())),
                    kind: SnapshotTabKind::Browser,
                    title,
                    cwd: None,
                    explicit_title: panel
                        .custom_title
                        .as_ref()
                        .is_some_and(|title| clean_desktop_string(Some(title.as_str())).is_some()),
                    pinned: false,
                    has_activity: panel.is_manually_unread,
                    bell_count: 0,
                    git_branch: None,
                    pull_request: None,
                    tty_name: None,
                    shell_state: None,
                    ports_kick_generation: 0,
                    listening_ports: Vec::new(),
                    pty_replay_base64: Vec::new(),
                    browser,
                });
            }
            _ => {}
        }
    }

    let terminal_count = tabs
        .iter()
        .filter(|tab| tab.kind == SnapshotTabKind::Terminal)
        .count();
    if tabs.is_empty() {
        tabs.push(TabSnapshot {
            external_id: None,
            kind: SnapshotTabKind::Terminal,
            title: "sh".to_string(),
            cwd: clean_desktop_string(Some(workspace.current_directory.as_str()))
                .map(PathBuf::from),
            explicit_title: false,
            pinned: false,
            has_activity: false,
            bell_count: 0,
            git_branch: None,
            pull_request: None,
            tty_name: None,
            shell_state: None,
            ports_kick_generation: 0,
            listening_ports: Vec::new(),
            pty_replay_base64: Vec::new(),
            browser: None,
        });
    }

    let layout_import = convert_desktop_workspace_layout(&workspace.layout, &tab_index_by_panel_id);
    let active_tab = workspace
        .focused_panel_id
        .as_ref()
        .and_then(|panel_id| tab_index_by_panel_id.get(panel_id).copied())
        .or(layout_import.first_active_tab)
        .unwrap_or(0)
        .min(tabs.len().saturating_sub(1));
    let active_panel = workspace
        .focused_panel_id
        .as_ref()
        .and_then(|panel_id| layout_import.leaf_id_by_panel_id.get(panel_id).copied())
        .or_else(|| first_panel_id(layout_import.node.as_ref()));
    let panel_tree = layout_import.node.or_else(|| {
        Some(PanelSnapshot::Leaf {
            id: 0,
            active_tab: Some(active_tab),
            tabs: (0..tabs.len()).collect(),
        })
    });

    DesktopWorkspaceImport {
        snapshot: WorkspaceSnapshot {
            external_id: None,
            title: clean_desktop_string(workspace.custom_title.as_deref())
                .or_else(|| clean_desktop_string(Some(workspace.process_title.as_str())))
                .unwrap_or_else(|| "main".to_string()),
            description: clean_desktop_string(workspace.custom_description.as_deref()),
            latest_submitted_message: None,
            active_space: 0,
            spaces: vec![SpaceSnapshot {
                title: "space-1".to_string(),
                active_tab,
                tabs,
                active_panel,
                panel_tree,
            }],
            active_tab,
            tabs: Vec::new(),
            split_direction: None,
            first_split_ratio_permille: 500,
            active_panel,
            panel_tree: None,
            pinned: workspace.is_pinned,
            color: clean_desktop_string(workspace.custom_color.as_deref()),
            remote_status_json: None,
            remote_config_json: None,
            status_entries: Vec::new(),
            metadata_blocks: Vec::new(),
            log_entries: Vec::new(),
            progress: None,
        },
        terminal_count,
    }
}

fn desktop_panel_title(panel: &DesktopPanelSnapshot) -> Option<String> {
    clean_desktop_string(panel.custom_title.as_deref())
        .or_else(|| clean_desktop_string(panel.title.as_deref()))
}

fn browser_snapshot_from_desktop_panel(panel: &DesktopPanelSnapshot) -> Option<BrowserSnapshot> {
    let browser = panel.browser.as_ref()?;
    let url_string = clean_desktop_string(browser.url_string.as_deref());
    let title = desktop_panel_title(panel);
    Some(BrowserSnapshot {
        url_string,
        title,
        profile_id: clean_desktop_string(browser.profile_id.as_deref()),
        should_render_webview: browser.should_render_webview,
        page_zoom: browser
            .page_zoom
            .filter(|value| value.is_finite() && *value > 0.0),
        developer_tools_visible: browser.developer_tools_visible,
        back_history_url_strings: clean_desktop_strings(
            browser.back_history_url_strings.as_deref().unwrap_or(&[]),
        ),
        forward_history_url_strings: clean_desktop_strings(
            browser
                .forward_history_url_strings
                .as_deref()
                .unwrap_or(&[]),
        ),
        proxy: None,
        reload_generation: 0,
    })
}

fn clean_desktop_strings(values: &[String]) -> Vec<String> {
    values
        .iter()
        .filter_map(|value| clean_desktop_string(Some(value.as_str())))
        .collect()
}

fn desktop_panel_cwd(
    panel: &DesktopPanelSnapshot,
    workspace: &DesktopWorkspaceSnapshot,
) -> Option<String> {
    panel
        .terminal
        .as_ref()
        .and_then(|terminal| clean_desktop_string(terminal.working_directory.as_deref()))
        .or_else(|| clean_desktop_string(panel.directory.as_deref()))
        .or_else(|| clean_desktop_string(Some(workspace.current_directory.as_str())))
}

fn convert_desktop_workspace_layout(
    layout: &DesktopWorkspaceLayoutSnapshot,
    tab_index_by_panel_id: &HashMap<String, usize>,
) -> DesktopWorkspaceLayoutImport {
    let mut leaf_id_by_panel_id = HashMap::new();
    let mut next_panel_id = 0u64;
    let node = convert_desktop_layout_node(
        layout,
        tab_index_by_panel_id,
        &mut leaf_id_by_panel_id,
        &mut next_panel_id,
    );
    let first_active_tab = first_active_tab_index(node.as_ref());
    DesktopWorkspaceLayoutImport {
        node,
        leaf_id_by_panel_id,
        first_active_tab,
    }
}

fn convert_desktop_layout_node(
    layout: &DesktopWorkspaceLayoutSnapshot,
    tab_index_by_panel_id: &HashMap<String, usize>,
    leaf_id_by_panel_id: &mut HashMap<String, u64>,
    next_panel_id: &mut u64,
) -> Option<PanelSnapshot> {
    match layout {
        DesktopWorkspaceLayoutSnapshot::Pane { pane } => {
            let tabs = pane
                .panel_ids
                .iter()
                .filter_map(|panel_id| tab_index_by_panel_id.get(panel_id).copied())
                .collect::<Vec<_>>();
            if tabs.is_empty() {
                return None;
            }
            let id = *next_panel_id;
            *next_panel_id = (*next_panel_id).saturating_add(1);
            for panel_id in &pane.panel_ids {
                if tab_index_by_panel_id.contains_key(panel_id) {
                    leaf_id_by_panel_id.insert(panel_id.clone(), id);
                }
            }
            let active_tab = pane
                .selected_panel_id
                .as_ref()
                .and_then(|panel_id| tab_index_by_panel_id.get(panel_id).copied())
                .filter(|tab| tabs.contains(tab))
                .or_else(|| tabs.first().copied());
            Some(PanelSnapshot::Leaf {
                id,
                active_tab,
                tabs,
            })
        }
        DesktopWorkspaceLayoutSnapshot::Split { split } => {
            let first = convert_desktop_layout_node(
                &split.first,
                tab_index_by_panel_id,
                leaf_id_by_panel_id,
                next_panel_id,
            );
            let second = convert_desktop_layout_node(
                &split.second,
                tab_index_by_panel_id,
                leaf_id_by_panel_id,
                next_panel_id,
            );
            match (first, second) {
                (Some(first), Some(second)) => Some(PanelSnapshot::Split {
                    direction: match split.orientation.as_str() {
                        "vertical" => "vertical".to_string(),
                        _ => "horizontal".to_string(),
                    },
                    ratio_permille: divider_position_to_permille(split.divider_position),
                    first: Box::new(first),
                    second: Box::new(second),
                }),
                (Some(node), None) | (None, Some(node)) => Some(node),
                (None, None) => None,
            }
        }
    }
}

fn clean_desktop_string(value: Option<&str>) -> Option<String> {
    let value = value?.trim();
    if value.is_empty() {
        None
    } else {
        Some(value.to_string())
    }
}

fn divider_position_to_permille(value: f64) -> u16 {
    if !value.is_finite() {
        return 500;
    }
    ((value * 1000.0).round() as i64).clamp(100, 900) as u16
}

fn first_panel_id(node: Option<&PanelSnapshot>) -> Option<u64> {
    match node? {
        PanelSnapshot::Leaf { id, .. } => Some(*id),
        PanelSnapshot::Split { first, second, .. } => {
            first_panel_id(Some(first)).or_else(|| first_panel_id(Some(second)))
        }
    }
}

fn first_active_tab_index(node: Option<&PanelSnapshot>) -> Option<usize> {
    match node? {
        PanelSnapshot::Leaf {
            active_tab, tabs, ..
        } => active_tab.or_else(|| tabs.first().copied()),
        PanelSnapshot::Split { first, second, .. } => {
            first_active_tab_index(Some(first)).or_else(|| first_active_tab_index(Some(second)))
        }
    }
}

fn desktop_session_source_fingerprint(bytes: &[u8]) -> String {
    const FNV_OFFSET_BASIS: u64 = 0xcbf29ce484222325;
    const FNV_PRIME: u64 = 0x100000001b3;
    let mut hash = FNV_OFFSET_BASIS;
    for byte in bytes {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(FNV_PRIME);
    }
    format!("fnv1a64:{hash:016x}")
}

fn unix_millis_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_snapshot() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("snap.json");
        let snap = Snapshot {
            version: 1,
            active_workspace: 0,
            workspaces: vec![WorkspaceSnapshot {
                external_id: Some("c0de0001-c0de-4000-8000-000000000000".into()),
                title: "main".into(),
                description: Some("Imported description".into()),
                latest_submitted_message: Some("Do the thing".into()),
                active_space: 0,
                spaces: vec![SpaceSnapshot {
                    title: "space-1".into(),
                    active_tab: 1,
                    tabs: vec![
                        TabSnapshot {
                            external_id: Some("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".into()),
                            kind: SnapshotTabKind::Terminal,
                            title: "one".into(),
                            cwd: Some(PathBuf::from("/tmp")),
                            explicit_title: false,
                            has_activity: true,
                            bell_count: 2,
                            git_branch: Some(SnapshotGitBranch {
                                branch: "main".into(),
                                is_dirty: true,
                            }),
                            pull_request: Some(SnapshotPullRequest {
                                number: 42,
                                label: "PR".into(),
                                url: "https://example.com/pull/42".into(),
                                status: "open".into(),
                                branch: Some("main".into()),
                                is_stale: false,
                            }),
                            tty_name: Some("ttys001".into()),
                            shell_state: Some("prompt".into()),
                            ports_kick_generation: 1,
                            listening_ports: vec![3000],
                            pty_replay_base64: vec!["aGVsbG8=".into()],
                            browser: None,
                        },
                        TabSnapshot {
                            external_id: Some("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb".into()),
                            kind: SnapshotTabKind::Terminal,
                            title: "two".into(),
                            cwd: None,
                            explicit_title: true,
                            has_activity: false,
                            bell_count: 0,
                            git_branch: None,
                            pull_request: None,
                            tty_name: None,
                            shell_state: None,
                            ports_kick_generation: 0,
                            listening_ports: Vec::new(),
                            pty_replay_base64: Vec::new(),
                            browser: None,
                        },
                    ],
                    active_panel: None,
                    panel_tree: None,
                }],
                active_tab: 1,
                tabs: vec![
                    TabSnapshot {
                        external_id: Some("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".into()),
                        kind: SnapshotTabKind::Terminal,
                        title: "one".into(),
                        cwd: Some(PathBuf::from("/tmp")),
                        explicit_title: false,
                        has_activity: true,
                        bell_count: 2,
                        git_branch: Some(SnapshotGitBranch {
                            branch: "main".into(),
                            is_dirty: true,
                        }),
                        pull_request: Some(SnapshotPullRequest {
                            number: 42,
                            label: "PR".into(),
                            url: "https://example.com/pull/42".into(),
                            status: "open".into(),
                            branch: Some("main".into()),
                            is_stale: false,
                        }),
                        tty_name: Some("ttys001".into()),
                        shell_state: Some("prompt".into()),
                        ports_kick_generation: 1,
                        listening_ports: vec![3000],
                        pty_replay_base64: Vec::new(),
                        browser: None,
                    },
                    TabSnapshot {
                        external_id: Some("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb".into()),
                        kind: SnapshotTabKind::Terminal,
                        title: "two".into(),
                        cwd: None,
                        explicit_title: true,
                        has_activity: false,
                        bell_count: 0,
                        git_branch: None,
                        pull_request: None,
                        tty_name: None,
                        shell_state: None,
                        ports_kick_generation: 0,
                        listening_ports: Vec::new(),
                        pty_replay_base64: Vec::new(),
                        browser: None,
                    },
                ],
                split_direction: None,
                first_split_ratio_permille: 500,
                active_panel: None,
                panel_tree: None,
                pinned: false,
                color: None,
                remote_status_json: Some("{\"enabled\":true,\"state\":\"connected\"}".into()),
                remote_config_json: Some("{\"transport\":\"ssh\",\"destination\":\"host\"}".into()),
                status_entries: vec![SnapshotSidebarStatusEntry {
                    key: "build".into(),
                    value: "running".into(),
                    icon: Some("hammer".into()),
                    color: Some("#00ff00".into()),
                    url: Some("https://example.com".into()),
                    priority: 1,
                    format: "plain".into(),
                    updated_at_ms: 123,
                }],
                metadata_blocks: Vec::new(),
                log_entries: vec![SnapshotSidebarLogEntry {
                    message: "hello".into(),
                    level: "info".into(),
                    source: None,
                    updated_at_ms: 124,
                }],
                progress: Some(SnapshotSidebarProgressState {
                    value: 0.5,
                    label: Some("Half".into()),
                }),
            }],
            native_windows: Vec::new(),
        };
        save(&path, &snap).unwrap();
        let got = load(&path).unwrap();
        assert_eq!(got.version, 1);
        assert_eq!(got.active_workspace, 0);
        assert_eq!(got.workspaces.len(), 1);
        assert_eq!(got.workspaces[0].spaces.len(), 1);
        assert_eq!(got.workspaces[0].spaces[0].tabs.len(), 2);
        assert_eq!(got.workspaces[0].spaces[0].tabs[0].title, "one");
        assert_eq!(
            got.workspaces[0].spaces[0].tabs[0].pty_replay_base64,
            vec!["aGVsbG8=".to_string()]
        );
        assert!(got.workspaces[0].spaces[0].tabs[0].has_activity);
        assert_eq!(got.workspaces[0].spaces[0].tabs[0].bell_count, 2);
        assert_eq!(
            got.workspaces[0].remote_status_json.as_deref(),
            Some("{\"enabled\":true,\"state\":\"connected\"}")
        );
        assert_eq!(
            got.workspaces[0].remote_config_json.as_deref(),
            Some("{\"transport\":\"ssh\",\"destination\":\"host\"}")
        );
        assert_eq!(got.workspaces[0].status_entries[0].key, "build");
        assert_eq!(got.workspaces[0].log_entries[0].message, "hello");
        assert_eq!(
            got.workspaces[0]
                .progress
                .as_ref()
                .unwrap()
                .label
                .as_deref(),
            Some("Half")
        );
    }

    #[test]
    fn load_missing_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        assert!(load(&dir.path().join("nope.json")).is_none());
    }

    #[test]
    fn load_rejects_wrong_version() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("snap.json");
        std::fs::write(
            &path,
            br#"{"version": 999, "active_workspace": 0, "workspaces": []}"#,
        )
        .unwrap();
        assert!(load(&path).is_none());
    }

    #[test]
    fn import_desktop_session_marks_empty_valid_source_once() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("swift-session.json");
        let state_dir = dir.path().join("cmx-state");
        let snapshot_path = state_dir.join("snapshot.json");
        std::fs::write(&source, br#"{"version": 1, "createdAt": 1, "windows": []}"#).unwrap();

        let first =
            import_desktop_session_snapshot(&source, &snapshot_path, Some(&state_dir)).unwrap();
        assert_eq!(first.status, DesktopSessionImportStatus::NoWorkspaces);
        assert_eq!(first.imported_workspaces, 0);
        assert_eq!(first.imported_terminals, 0);
        assert!(!snapshot_path.exists());

        let marker_path = state_dir.join("desktop-session-import.json");
        let marker: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&marker_path).unwrap()).unwrap();
        assert_eq!(marker["status"].as_str(), Some("no_workspaces"));
        assert_eq!(marker["imported_workspaces"].as_u64(), Some(0));
        assert_eq!(marker["imported_terminals"].as_u64(), Some(0));

        let second =
            import_desktop_session_snapshot(&source, &snapshot_path, Some(&state_dir)).unwrap();
        assert_eq!(second.status, DesktopSessionImportStatus::AlreadyImported);
    }

    #[test]
    fn import_desktop_session_preserves_existing_cmx_snapshot_and_writes_skip_marker() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("swift-session.json");
        let state_dir = dir.path().join("cmx-state");
        let snapshot_path = state_dir.join("snapshot.json");
        std::fs::create_dir_all(&state_dir).unwrap();
        std::fs::write(&source, br#"{"version": 1, "createdAt": 1, "windows": []}"#).unwrap();
        let existing_snapshot = br#"{"cmx":"authoritative"}"#;
        std::fs::write(&snapshot_path, existing_snapshot).unwrap();

        let result =
            import_desktop_session_snapshot(&source, &snapshot_path, Some(&state_dir)).unwrap();
        assert_eq!(result.status, DesktopSessionImportStatus::CmxSnapshotExists);
        assert_eq!(result.imported_workspaces, 0);
        assert_eq!(result.imported_terminals, 0);
        assert_eq!(std::fs::read(&snapshot_path).unwrap(), existing_snapshot);
        assert!(
            !state_dir
                .join("desktop-session-import-source.json")
                .exists()
        );

        let marker_path = state_dir.join("desktop-session-import.json");
        let marker: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&marker_path).unwrap()).unwrap();
        assert_eq!(
            marker["status"].as_str(),
            Some("skipped_existing_cmx_snapshot")
        );
        assert_eq!(marker["imported_workspaces"].as_u64(), Some(0));
        assert_eq!(marker["imported_terminals"].as_u64(), Some(0));
        assert!(marker["source_backup_path"].is_null());

        let second =
            import_desktop_session_snapshot(&source, &snapshot_path, Some(&state_dir)).unwrap();
        assert_eq!(second.status, DesktopSessionImportStatus::AlreadyImported);
    }

    #[test]
    fn import_desktop_session_converts_terminal_split_once() {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("swift-session.json");
        let state_dir = dir.path().join("cmx-state");
        let snapshot_path = state_dir.join("snapshot.json");
        std::fs::write(
            &source,
            r##"{
              "version": 1,
              "createdAt": 1,
              "windows": [
                {
                  "tabManager": {
                    "selectedWorkspaceIndex": 0,
                    "workspaces": [
                      {
                        "processTitle": "Terminal 1",
                        "customTitle": "Imported",
                        "customDescription": "Imported description",
                        "customColor": "#336699",
                        "isPinned": true,
                        "terminalScrollBarHidden": false,
                        "currentDirectory": "/tmp/project",
                        "focusedPanelId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                        "layout": {
                          "type": "split",
                          "split": {
                            "orientation": "horizontal",
                            "dividerPosition": 0.42,
                            "first": {
                              "type": "pane",
                              "pane": {
                                "panelIds": ["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"],
                                "selectedPanelId": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
                              }
                            },
                            "second": {
                              "type": "pane",
                              "pane": {
                                "panelIds": [
                                  "cccccccc-cccc-cccc-cccc-cccccccccccc",
                                  "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
                                ],
                                "selectedPanelId": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
                              }
                            }
                          }
                        },
                        "panels": [
                          {
                            "id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
                            "type": "terminal",
                            "title": "left",
                            "customTitle": null,
                            "directory": "/tmp/left",
                            "isPinned": false,
                            "isManuallyUnread": true,
                            "listeningPorts": [],
                            "terminal": { "workingDirectory": "/tmp/left" }
                          },
                          {
                            "id": "cccccccc-cccc-cccc-cccc-cccccccccccc",
                            "type": "browser",
                            "title": "browser",
                            "customTitle": null,
                            "directory": null,
                            "isPinned": false,
                            "isManuallyUnread": false,
                            "listeningPorts": [],
                            "browser": {
                              "urlString": "https://example.com",
                              "profileID": "52B43C05-4A1D-45D3-8FD5-9EF94952E445",
                              "shouldRenderWebView": true,
                              "pageZoom": 1,
                              "developerToolsVisible": false,
                              "backHistoryURLStrings": ["https://example.com/docs"],
                              "forwardHistoryURLStrings": []
                            }
                          },
                          {
                            "id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                            "type": "terminal",
                            "title": "right",
                            "customTitle": "Right Custom",
                            "directory": "/tmp/right",
                            "isPinned": false,
                            "isManuallyUnread": false,
                            "listeningPorts": [],
                            "terminal": { "workingDirectory": "/tmp/right" }
                          }
                        ],
                        "statusEntries": [],
                        "logEntries": []
                      }
                    ]
                  },
                  "sidebar": { "isVisible": true, "selection": "tabs", "width": 200 }
                }
              ]
            }"##,
        )
        .unwrap();

        let result =
            import_desktop_session_snapshot(&source, &snapshot_path, Some(&state_dir)).unwrap();
        assert_eq!(result.status, DesktopSessionImportStatus::Imported);
        assert_eq!(result.imported_workspaces, 1);
        assert_eq!(result.imported_terminals, 2);
        assert!(state_dir.join("desktop-session-import.json").exists());
        assert!(
            state_dir
                .join("desktop-session-import-source.json")
                .exists()
        );

        let imported = load(&snapshot_path).unwrap();
        assert_eq!(imported.active_workspace, 0);
        assert_eq!(imported.workspaces.len(), 1);
        let workspace = &imported.workspaces[0];
        assert_eq!(workspace.title, "Imported");
        assert_eq!(
            workspace.description.as_deref(),
            Some("Imported description")
        );
        assert!(workspace.pinned);
        assert_eq!(workspace.color.as_deref(), Some("#336699"));
        assert_eq!(workspace.spaces.len(), 1);
        let space = &workspace.spaces[0];
        assert_eq!(space.active_tab, 2);
        assert_eq!(space.tabs.len(), 3);
        assert_eq!(
            space.tabs[0].cwd.as_deref(),
            Some(std::path::Path::new("/tmp/left"))
        );
        assert!(space.tabs[0].has_activity);
        assert_eq!(space.tabs[1].kind, SnapshotTabKind::Browser);
        assert_eq!(space.tabs[1].title, "browser");
        assert_eq!(
            space.tabs[1]
                .browser
                .as_ref()
                .and_then(|browser| browser.url_string.as_deref()),
            Some("https://example.com")
        );
        assert_eq!(
            space.tabs[1]
                .browser
                .as_ref()
                .and_then(|browser| browser.profile_id.as_deref()),
            Some("52B43C05-4A1D-45D3-8FD5-9EF94952E445")
        );
        assert_eq!(space.tabs[2].title, "Right Custom");
        assert_eq!(space.active_panel, Some(1));
        match space.panel_tree.as_ref().unwrap() {
            PanelSnapshot::Split {
                direction,
                ratio_permille,
                first,
                second,
            } => {
                assert_eq!(direction, "horizontal");
                assert_eq!(*ratio_permille, 420);
                assert!(matches!(**first, PanelSnapshot::Leaf { id: 0, .. }));
                assert!(matches!(**second, PanelSnapshot::Leaf { id: 1, .. }));
            }
            other => panic!("expected split panel tree, got {other:?}"),
        }

        let second =
            import_desktop_session_snapshot(&source, &snapshot_path, Some(&state_dir)).unwrap();
        assert_eq!(second.status, DesktopSessionImportStatus::AlreadyImported);
    }
}
