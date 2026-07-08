//! Read-only tree snapshots shared by the renderer and input handling,
//! plus the JSON parser for the remote `list-workspaces` shape.

use std::collections::HashMap;

use mux_core::{
    assign_short_ids, BrowserSource, Node, PaneId, ScreenId, SplitDir, State, SurfaceId,
    SurfaceKind, SurfaceNotification, WorkspaceId,
};
use serde_json::Value;

#[derive(Clone, Default)]
pub struct TreeView {
    pub workspaces: Vec<WorkspaceView>,
    pub active_workspace: usize,
}

#[derive(Clone)]
pub struct WorkspaceView {
    pub id: WorkspaceId,
    pub short_id: String,
    pub name: String,
    pub screens: Vec<ScreenView>,
    pub active_screen: usize,
}

#[derive(Clone)]
pub struct ScreenView {
    pub id: ScreenId,
    #[allow(dead_code)]
    pub short_id: String,
    /// User-assigned name, if any (display falls back to the number).
    pub name: Option<String>,
    pub layout: Node,
    pub active_pane: PaneId,
    pub panes: Vec<PaneView>,
}

#[derive(Clone)]
pub struct PaneView {
    pub id: PaneId,
    pub short_id: String,
    /// User-assigned name, if any (display falls back to the active
    /// tab's title).
    pub name: Option<String>,
    pub tabs: Vec<TabView>,
    pub active_tab: usize,
}

#[derive(Clone)]
pub struct TabView {
    pub surface: SurfaceId,
    pub short_id: String,
    pub name: Option<String>,
    pub title: String,
    pub kind: SurfaceKind,
    pub browser_source: Option<BrowserSource>,
    pub browser_frames_stalled: bool,
    pub notification: Option<TabNotificationView>,
}

#[derive(Clone, Copy)]
pub struct TabNotificationView {
    pub unread: bool,
    pub level: &'static str,
}

impl TreeView {
    pub fn active_workspace(&self) -> Option<&WorkspaceView> {
        self.workspaces.get(self.active_workspace)
    }

    /// The active screen of the active workspace.
    pub fn active_screen(&self) -> Option<&ScreenView> {
        self.active_workspace()?.active_screen_ref()
    }

    pub fn pane(&self, id: PaneId) -> Option<&PaneView> {
        self.workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .find(|p| p.id == id)
    }

    /// The active surface of the active pane of the active screen.
    pub fn active_surface(&self) -> Option<SurfaceId> {
        let screen = self.active_screen()?;
        screen.pane(screen.active_pane)?.active_surface()
    }

    pub fn surface_kind(&self, id: SurfaceId) -> SurfaceKind {
        self.workspaces
            .iter()
            .flat_map(|ws| ws.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == id)
            .map(|tab| tab.kind)
            .unwrap_or(SurfaceKind::Pty)
    }
}

impl WorkspaceView {
    pub fn active_screen_ref(&self) -> Option<&ScreenView> {
        self.screens.get(self.active_screen)
    }
}

impl ScreenView {
    pub fn pane(&self, id: PaneId) -> Option<&PaneView> {
        self.panes.iter().find(|p| p.id == id)
    }

    /// Display name: the user-assigned name, else "screen N" by position.
    pub fn display_name(&self, index: usize) -> String {
        match self.name.as_deref() {
            Some(name) if !name.is_empty() => name.to_string(),
            _ => format!("{}", index + 1),
        }
    }
}

impl PaneView {
    pub fn active_surface(&self) -> Option<SurfaceId> {
        self.tabs.get(self.active_tab).map(|t| t.surface)
    }

    /// Display name: the user-assigned name, else the active tab's
    /// process title, else "shell".
    pub fn display_name(&self) -> &str {
        if let Some(name) = self.name.as_deref() {
            if !name.is_empty() {
                return name;
            }
        }
        self.tabs
            .get(self.active_tab)
            .map(|t| if t.title.is_empty() { "shell" } else { t.title.as_str() })
            .unwrap_or("shell")
    }
}

pub fn tree_from_state_with_notifications(
    state: &State,
    notifications: &HashMap<SurfaceId, SurfaceNotification>,
) -> TreeView {
    let ids = state
        .workspaces
        .iter()
        .flat_map(|ws| {
            let mut ids = vec![ws.id];
            for screen in &ws.screens {
                ids.push(screen.id);
                screen.root.pane_ids(&mut ids);
            }
            ids
        })
        .chain(state.surfaces.keys().copied());
    let short_ids = assign_short_ids(ids);
    let pane_view = |id: &PaneId| {
        state.panes.get(id).map(|pane| PaneView {
            id: pane.id,
            short_id: short_ids.get(&pane.id).cloned().unwrap_or_default(),
            name: pane.name.clone(),
            active_tab: pane.active_tab,
            tabs: pane
                .tabs
                .iter()
                .map(|sid| TabView {
                    surface: *sid,
                    short_id: short_ids.get(sid).cloned().unwrap_or_default(),
                    name: state.surfaces.get(sid).and_then(|s| s.name()),
                    title: state.surfaces.get(sid).map(|s| s.title()).unwrap_or_default(),
                    kind: state.surfaces.get(sid).map(|s| s.kind()).unwrap_or(SurfaceKind::Pty),
                    browser_source: state.surfaces.get(sid).and_then(|s| s.browser_source()),
                    browser_frames_stalled: state
                        .surfaces
                        .get(sid)
                        .and_then(|s| s.browser_frames_stalled())
                        .unwrap_or(false),
                    notification: notifications.get(sid).map(|notification| TabNotificationView {
                        unread: notification.unread,
                        level: notification.level.as_str(),
                    }),
                })
                .collect(),
        })
    };
    TreeView {
        active_workspace: state.active_workspace,
        workspaces: state
            .workspaces
            .iter()
            .map(|ws| WorkspaceView {
                id: ws.id,
                short_id: short_ids.get(&ws.id).cloned().unwrap_or_default(),
                name: ws.name.clone(),
                active_screen: ws.active_screen,
                screens: ws
                    .screens
                    .iter()
                    .map(|screen| {
                        let mut pane_ids = Vec::new();
                        screen.root.pane_ids(&mut pane_ids);
                        ScreenView {
                            id: screen.id,
                            short_id: short_ids.get(&screen.id).cloned().unwrap_or_default(),
                            name: screen.name.clone(),
                            layout: screen.root.clone(),
                            active_pane: screen.active_pane,
                            panes: pane_ids.iter().filter_map(pane_view).collect(),
                        }
                    })
                    .collect(),
            })
            .collect(),
    }
}

fn parse_layout(value: &Value) -> Option<Node> {
    match value.get("type")?.as_str()? {
        "leaf" => Some(Node::Leaf(value.get("pane")?.as_u64()?)),
        "split" => {
            let dir = match value.get("dir")?.as_str()? {
                "right" => SplitDir::Right,
                "down" => SplitDir::Down,
                _ => return None,
            };
            Some(Node::Split {
                dir,
                ratio: value.get("ratio")?.as_f64()? as f32,
                a: Box::new(parse_layout(value.get("a")?)?),
                b: Box::new(parse_layout(value.get("b")?)?),
            })
        }
        _ => None,
    }
}

fn parse_pane(value: &Value) -> Option<PaneView> {
    Some(PaneView {
        id: value.get("id")?.as_u64()?,
        short_id: value.get("short_id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        name: value.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()),
        active_tab: value.get("active_tab").and_then(|v| v.as_u64()).unwrap_or(0) as usize,
        tabs: value
            .get("tabs")
            .and_then(|v| v.as_array())
            .map(|tabs| {
                tabs.iter()
                    .filter_map(|tab| {
                        Some(TabView {
                            surface: tab.get("surface")?.as_u64()?,
                            short_id: tab
                                .get("short_id")
                                .and_then(|v| v.as_str())
                                .unwrap_or_default()
                                .to_string(),
                            name: tab.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()),
                            title: tab
                                .get("title")
                                .and_then(|v| v.as_str())
                                .unwrap_or_default()
                                .to_string(),
                            kind: match tab.get("kind").and_then(|v| v.as_str()) {
                                Some("browser") => SurfaceKind::Browser,
                                _ => SurfaceKind::Pty,
                            },
                            browser_source: match tab.get("browser_source").and_then(|v| v.as_str())
                            {
                                Some("external") => Some(BrowserSource::External),
                                Some("launched") => Some(BrowserSource::Launched),
                                _ => None,
                            },
                            browser_frames_stalled: tab
                                .get("browser_frames_stalled")
                                .and_then(|v| v.as_bool())
                                .unwrap_or(false),
                            notification: tab.get("notification").and_then(parse_notification),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
    })
}

fn parse_notification(value: &Value) -> Option<TabNotificationView> {
    let level = match value.get("level").and_then(|v| v.as_str()).unwrap_or("info") {
        "warning" => "warning",
        "error" => "error",
        _ => "info",
    };
    Some(TabNotificationView {
        unread: value.get("unread").and_then(|v| v.as_bool()).unwrap_or(false),
        level,
    })
}

fn parse_screen(value: &Value) -> Option<ScreenView> {
    Some(ScreenView {
        id: value.get("id")?.as_u64()?,
        short_id: value.get("short_id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        name: value.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()),
        layout: value.get("layout").and_then(parse_layout)?,
        active_pane: value.get("active_pane").and_then(|v| v.as_u64()).unwrap_or(0),
        panes: value
            .get("panes")
            .and_then(|v| v.as_array())
            .map(|panes| panes.iter().filter_map(parse_pane).collect())
            .unwrap_or_default(),
    })
}

/// Parse the remote `list-workspaces` response.
pub fn parse_tree(data: &Value) -> TreeView {
    let mut tree = TreeView::default();
    let Some(workspaces) = data.get("workspaces").and_then(|v| v.as_array()) else {
        return tree;
    };
    for (i, ws) in workspaces.iter().enumerate() {
        if ws.get("active").and_then(|v| v.as_bool()) == Some(true) {
            tree.active_workspace = i;
        }
        let mut view = WorkspaceView {
            id: ws.get("id").and_then(|v| v.as_u64()).unwrap_or(0),
            short_id: ws.get("short_id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
            name: ws.get("name").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
            screens: Vec::new(),
            active_screen: 0,
        };
        if let Some(screens) = ws.get("screens").and_then(|v| v.as_array()) {
            for (s, screen) in screens.iter().enumerate() {
                if screen.get("active").and_then(|v| v.as_bool()) == Some(true) {
                    view.active_screen = s;
                }
                if let Some(parsed) = parse_screen(screen) {
                    view.screens.push(parsed);
                }
            }
        }
        tree.workspaces.push(view);
    }
    tree
}
