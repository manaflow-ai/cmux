//! JSON-on-disk snapshot of the daemon's workspace structure.
//!
//! Scrollback, environment, and live shell state aren't captured. On restore
//! each tab re-exec's the configured shell in the recorded cwd. This is a
//! structure-only snapshot; proper scrollback persistence lives behind the
//! M6 disk-spill work.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Snapshot {
    pub version: u32,
    pub active_workspace: usize,
    pub workspaces: Vec<WorkspaceSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceSnapshot {
    pub title: String,
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
    pub title: String,
    pub cwd: Option<PathBuf>,
    #[serde(default)]
    pub explicit_title: bool,
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
    Ok(())
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
                title: "main".into(),
                active_space: 0,
                spaces: vec![SpaceSnapshot {
                    title: "space-1".into(),
                    active_tab: 1,
                    tabs: vec![
                        TabSnapshot {
                            title: "one".into(),
                            cwd: Some(PathBuf::from("/tmp")),
                            explicit_title: false,
                        },
                        TabSnapshot {
                            title: "two".into(),
                            cwd: None,
                            explicit_title: true,
                        },
                    ],
                    active_panel: None,
                    panel_tree: None,
                }],
                active_tab: 1,
                tabs: vec![
                    TabSnapshot {
                        title: "one".into(),
                        cwd: Some(PathBuf::from("/tmp")),
                        explicit_title: false,
                    },
                    TabSnapshot {
                        title: "two".into(),
                        cwd: None,
                        explicit_title: true,
                    },
                ],
                split_direction: None,
                first_split_ratio_permille: 500,
                active_panel: None,
                panel_tree: None,
                pinned: false,
                color: None,
            }],
        };
        save(&path, &snap).unwrap();
        let got = load(&path).unwrap();
        assert_eq!(got.version, 1);
        assert_eq!(got.active_workspace, 0);
        assert_eq!(got.workspaces.len(), 1);
        assert_eq!(got.workspaces[0].spaces.len(), 1);
        assert_eq!(got.workspaces[0].spaces[0].tabs.len(), 2);
        assert_eq!(got.workspaces[0].spaces[0].tabs[0].title, "one");
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
}
