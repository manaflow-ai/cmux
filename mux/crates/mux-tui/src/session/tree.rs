//! Read-only tree snapshots shared by the renderer and input handling,
//! plus the JSON parser for the remote `list-workspaces` shape.

use mux_core::{Node, PaneId, ScreenId, SplitDir, State, SurfaceId, WorkspaceId};
use serde_json::Value;

#[derive(Clone, Default)]
pub struct TreeView {
    pub workspaces: Vec<WorkspaceView>,
    pub active_workspace: usize,
}

#[derive(Clone)]
pub struct WorkspaceView {
    pub id: WorkspaceId,
    pub name: String,
    pub screens: Vec<ScreenView>,
    pub active_screen: usize,
}

#[derive(Clone)]
pub struct ScreenView {
    pub id: ScreenId,
    /// User-assigned name, if any (display falls back to the number).
    pub name: Option<String>,
    pub layout: Node,
    pub active_pane: PaneId,
    pub panes: Vec<PaneView>,
}

#[derive(Clone)]
pub struct PaneView {
    pub id: PaneId,
    /// User-assigned name, if any (display falls back to the active
    /// tab's title).
    pub name: Option<String>,
    pub tabs: Vec<TabView>,
    pub active_tab: usize,
}

#[derive(Clone)]
pub struct TabView {
    pub surface: SurfaceId,
    pub title: String,
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

    /// Display name: the user-assigned name, else the active tab title,
    /// else "shell".
    pub fn display_name(&self) -> &str {
        if let Some(name) = self.name.as_deref() {
            if !name.is_empty() {
                return name;
            }
        }
        self.tabs.get(self.active_tab).map(|t| t.display_title()).unwrap_or("shell")
    }
}

impl TabView {
    pub fn display_title(&self) -> &str {
        if self.title.is_empty() {
            "shell"
        } else {
            &self.title
        }
    }
}

/// Snapshot a local mux state into a TreeView.
pub fn tree_from_state(state: &State) -> TreeView {
    let pane_view = |id: &PaneId| {
        state.panes.get(id).map(|pane| PaneView {
            id: pane.id,
            name: pane.name.clone(),
            active_tab: pane.active_tab,
            tabs: pane
                .tabs
                .iter()
                .map(|sid| TabView {
                    surface: *sid,
                    title: state.surfaces.get(sid).map(|s| s.title()).unwrap_or_default(),
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
                            title: tab
                                .get("title")
                                .and_then(|v| v.as_str())
                                .unwrap_or_default()
                                .to_string(),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default(),
    })
}

fn parse_screen(value: &Value) -> Option<ScreenView> {
    Some(ScreenView {
        id: value.get("id")?.as_u64()?,
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
