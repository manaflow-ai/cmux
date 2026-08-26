//! Read-only tree snapshots shared by the renderer and input handling,
//! plus the JSON parser for the remote `list-workspaces` shape.

use std::collections::{BTreeMap, HashMap, HashSet};

use cmux_tui_core::resource::{
    BrowserPublicId, ContentPublicId, PanePublicId, ScreenPublicId, TabPublicId, TerminalPublicId,
    WorkspacePublicId,
};
use cmux_tui_core::{
    BrowserSource, MAX_VIEWPORT_PANE_WIDTH, MIN_VIEWPORT_PANE_WIDTH, Node, PaneId,
    ResourceSelectors, ScreenId, SplitDir, SplitId, State, SurfaceId, SurfaceKind,
    SurfaceNotification, WorkspaceId, assign_short_ids,
};
use serde_json::Value;

#[derive(Clone, Default)]
pub struct TreeView {
    pub workspaces: Vec<WorkspaceView>,
    #[allow(dead_code)]
    pub workspace_revision: u64,
    pub pane_revision: Option<u64>,
    pub active_workspace: usize,
}

#[derive(Clone)]
pub struct WorkspaceView {
    pub id: WorkspaceId,
    pub resource_id: Option<WorkspacePublicId>,
    #[allow(dead_code)]
    pub key: String,
    pub short_id: String,
    pub name: String,
    pub screens: Vec<ScreenView>,
    pub active_screen: usize,
}

#[derive(Clone)]
pub struct ScreenView {
    pub id: ScreenId,
    pub resource_id: Option<ScreenPublicId>,
    #[allow(dead_code)]
    pub short_id: String,
    /// User-assigned name, if any (display falls back to the number).
    pub name: Option<String>,
    pub layout: Node,
    pub active_pane: PaneId,
    pub zoomed_pane: Option<PaneId>,
    pub viewport_base_width: Option<f32>,
    pub viewport_splits: BTreeMap<SplitId, f32>,
    pub panes: Vec<PaneView>,
}

#[derive(Clone)]
pub struct PaneView {
    pub id: PaneId,
    pub resource_id: Option<PanePublicId>,
    pub short_id: String,
    /// User-assigned name, if any (display falls back to the active
    /// tab's title).
    pub name: Option<String>,
    pub tabs: Vec<TabView>,
    pub active_tab: usize,
    pub focused_at: u64,
}

#[derive(Clone)]
pub struct TabView {
    pub surface: SurfaceId,
    pub public_id: Option<TabPublicId>,
    pub content_id: Option<ContentPublicId>,
    pub terminal_id: Option<TerminalPublicId>,
    pub short_id: String,
    pub name: Option<String>,
    pub title: String,
    pub kind: SurfaceKind,
    pub browser_source: Option<BrowserSource>,
    pub browser_frames_stalled: bool,
    pub supports_clear_history_key_fallback: bool,
    pub notification: Option<TabNotificationView>,
}

#[derive(Clone, Copy)]
pub struct TabNotificationView {
    pub unread: bool,
    pub level: &'static str,
}

impl TreeView {
    /// Remove pane tabs that cannot be backed by an attached surface.
    ///
    /// Remote tree snapshots and surface detach events travel on separate
    /// streams. Applying this filter before publishing a snapshot keeps the
    /// renderer from observing a tab whose surface has already been removed.
    pub fn retain_surfaces(&mut self, surfaces: &HashSet<SurfaceId>) {
        for workspace in &mut self.workspaces {
            for screen in &mut workspace.screens {
                for pane in &mut screen.panes {
                    pane.tabs.retain(|tab| surfaces.contains(&tab.surface));
                    pane.active_tab = pane.active_tab.min(pane.tabs.len().saturating_sub(1));
                }
            }
        }
    }

    /// Retain the server's authoritative tab topology, removing only tabs
    /// with explicit detach/retire evidence. The local surface mirror is a
    /// lazy cache and can be empty during startup or reconnect.
    pub fn retain_not_retired(&mut self, retired: &HashSet<SurfaceId>) {
        for workspace in &mut self.workspaces {
            for screen in &mut workspace.screens {
                for pane in &mut screen.panes {
                    let active_surface = pane.tabs.get(pane.active_tab).map(|tab| tab.surface);
                    pane.tabs.retain(|tab| !retired.contains(&tab.surface));
                    pane.active_tab = active_surface
                        .and_then(|surface| pane.tabs.iter().position(|tab| tab.surface == surface))
                        .unwrap_or_else(|| pane.active_tab.min(pane.tabs.len().saturating_sub(1)));
                }
            }
        }
    }

    pub fn session_resource_selectors() -> ResourceSelectors {
        ResourceSelectors {
            machine: Some("current".to_string()),
            session: Some("current".to_string()),
            ..ResourceSelectors::default()
        }
    }

    pub fn resource_selectors_for_workspace(
        &self,
        workspace: Option<WorkspaceId>,
    ) -> Option<ResourceSelectors> {
        let workspace = match workspace {
            Some(id) => self.workspaces.iter().find(|workspace| workspace.id == id)?,
            None => self.active_workspace()?,
        };
        Some(ResourceSelectors {
            workspace: Some(workspace.resource_id.as_ref()?.to_string()),
            ..Self::session_resource_selectors()
        })
    }

    pub fn resource_selectors_for_pane(&self, pane: Option<PaneId>) -> Option<ResourceSelectors> {
        let pane = pane.or_else(|| self.active_screen().map(|screen| screen.active_pane))?;
        for workspace in &self.workspaces {
            for screen in &workspace.screens {
                let Some(pane) = screen.panes.iter().find(|candidate| candidate.id == pane) else {
                    continue;
                };
                return Some(ResourceSelectors {
                    workspace: Some(workspace.resource_id.as_ref()?.to_string()),
                    screen: Some(screen.resource_id.as_ref()?.to_string()),
                    pane: Some(pane.resource_id.as_ref()?.to_string()),
                    ..Self::session_resource_selectors()
                });
            }
        }
        None
    }

    pub fn active_workspace(&self) -> Option<&WorkspaceView> {
        self.workspaces.get(self.active_workspace)
    }

    pub fn active_workspace_mut(&mut self) -> Option<&mut WorkspaceView> {
        self.workspaces.get_mut(self.active_workspace)
    }

    pub fn active_workspace_mut_screen(&mut self) -> Option<&mut ScreenView> {
        let workspace = self.workspaces.get_mut(self.active_workspace)?;
        workspace.screens.get_mut(workspace.active_screen)
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

    pub fn pane_mut(&mut self, id: PaneId) -> Option<&mut PaneView> {
        self.workspaces
            .iter_mut()
            .flat_map(|workspace| workspace.screens.iter_mut())
            .flat_map(|screen| screen.panes.iter_mut())
            .find(|pane| pane.id == id)
    }

    pub fn surface(&self, id: SurfaceId) -> Option<&TabView> {
        self.workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.surface == id)
    }

    /// Resolve the stable public terminal identity to the current internal
    /// surface slot used by the renderer and filtered event subscription.
    pub fn resolve_terminal(&self, terminal_id: &TerminalPublicId) -> Option<SurfaceId> {
        self.workspaces
            .iter()
            .flat_map(|workspace| workspace.screens.iter())
            .flat_map(|screen| screen.panes.iter())
            .flat_map(|pane| pane.tabs.iter())
            .find(|tab| tab.terminal_id.as_ref() == Some(terminal_id))
            .map(|tab| tab.surface)
    }

    /// Select the workspace, screen, pane, and tab containing a surface.
    /// Single-surface clients reapply this to every remote tree snapshot so
    /// unrelated focus changes cannot move them to another terminal.
    pub fn select_surface(&mut self, id: SurfaceId) -> bool {
        let location =
            self.workspaces.iter().enumerate().find_map(|(workspace_index, workspace)| {
                workspace.screens.iter().enumerate().find_map(|(screen_index, screen)| {
                    screen.panes.iter().enumerate().find_map(|(pane_index, pane)| {
                        pane.tabs
                            .iter()
                            .position(|tab| tab.surface == id)
                            .map(|tab_index| (workspace_index, screen_index, pane_index, tab_index))
                    })
                })
            });
        let Some((workspace_index, screen_index, pane_index, tab_index)) = location else {
            return false;
        };
        self.active_workspace = workspace_index;
        let workspace = &mut self.workspaces[workspace_index];
        workspace.active_screen = screen_index;
        let screen = &mut workspace.screens[screen_index];
        screen.active_pane = screen.panes[pane_index].id;
        screen.panes[pane_index].active_tab = tab_index;
        true
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
        self.panes.iter().find(|pane| pane.id == id)
    }

    /// Display name: the user-assigned name, else its zero-based position.
    pub fn display_name(&self, index: usize) -> String {
        match self.name.as_deref() {
            Some(name) if !name.is_empty() => name.to_string(),
            _ => format!("{index}"),
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
        if let Some(name) = self.name.as_deref()
            && !name.is_empty()
        {
            return name;
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
            resource_id: Some(pane.public_id.clone()),
            short_id: short_ids.get(&pane.id).cloned().unwrap_or_default(),
            name: pane.name.clone(),
            active_tab: pane.active_tab,
            focused_at: pane.focused_at,
            tabs: pane
                .tabs
                .iter()
                .map(|sid| TabView {
                    surface: *sid,
                    public_id: state
                        .surfaces
                        .get(sid)
                        .and_then(|surface| surface.resource_identity())
                        .map(|identity| identity.tab_id.clone()),
                    content_id: state
                        .surfaces
                        .get(sid)
                        .and_then(|surface| surface.resource_identity())
                        .map(|identity| identity.content_id.clone()),
                    terminal_id: state
                        .surfaces
                        .get(sid)
                        .and_then(|surface| surface.resource_identity())
                        .and_then(|identity| match &identity.content_id {
                            ContentPublicId::Terminal(id) => Some(id.clone()),
                            ContentPublicId::Browser(_) => None,
                        }),
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
                    supports_clear_history_key_fallback: state
                        .surfaces
                        .get(sid)
                        .is_some_and(|surface| surface.supports_clear_history_key_fallback()),
                    notification: notifications.get(sid).map(|notification| TabNotificationView {
                        unread: notification.unread,
                        level: notification.level.as_str(),
                    }),
                })
                .collect(),
        })
    };
    TreeView {
        workspace_revision: state.workspace_revision,
        pane_revision: Some(state.pane_revision),
        active_workspace: state.active_workspace,
        workspaces: state
            .workspaces
            .iter()
            .map(|ws| WorkspaceView {
                id: ws.id,
                resource_id: Some(ws.public_id.clone()),
                key: ws.key.clone(),
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
                            resource_id: Some(screen.public_id.clone()),
                            short_id: short_ids.get(&screen.id).cloned().unwrap_or_default(),
                            name: screen.name.clone(),
                            layout: screen.root.clone(),
                            active_pane: screen.active_pane,
                            zoomed_pane: screen.zoomed_pane,
                            viewport_base_width: screen.viewport_base_width,
                            viewport_splits: screen.viewport_splits.clone(),
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
                id: value.get("split")?.as_u64()?,
                dir,
                ratio: value.get("ratio")?.as_f64()? as f32,
                a: Box::new(parse_layout(value.get("a")?)?),
                b: Box::new(parse_layout(value.get("b")?)?),
            })
        }
        "stack" => {
            let panes = value
                .get("panes")?
                .as_array()?
                .iter()
                .map(Value::as_u64)
                .collect::<Option<Vec<_>>>()?;
            let expanded = value.get("expanded")?.as_u64()?;
            Node::stack_with_expanded(panes, expanded)
        }
        _ => None,
    }
}

fn parse_pane(value: &Value) -> Option<PaneView> {
    Some(PaneView {
        id: value.get("id")?.as_u64()?,
        resource_id: value
            .get("resource_id")
            .and_then(Value::as_str)
            .and_then(|value| PanePublicId::parse(value.to_string()).ok()),
        short_id: value.get("short_id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        name: value.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()),
        active_tab: value.get("active_tab").and_then(|v| v.as_u64()).unwrap_or(0) as usize,
        focused_at: value.get("focused_at").and_then(|v| v.as_u64()).unwrap_or(0),
        tabs: value
            .get("tabs")
            .and_then(|v| v.as_array())
            .map(|tabs| {
                tabs.iter()
                    .filter_map(|tab| {
                        Some(TabView {
                            surface: tab.get("surface")?.as_u64()?,
                            public_id: tab
                                .get("tab_resource_id")
                                .and_then(Value::as_str)
                                .and_then(|value| TabPublicId::parse(value.to_string()).ok()),
                            content_id: tab
                                .get("content_resource_id")
                                .and_then(Value::as_str)
                                .and_then(|value| {
                                    TerminalPublicId::parse(value.to_string())
                                        .map(ContentPublicId::Terminal)
                                        .or_else(|_| {
                                            BrowserPublicId::parse(value.to_string())
                                                .map(ContentPublicId::Browser)
                                        })
                                        .ok()
                                }),
                            terminal_id: tab
                                .get("terminal_resource_id")
                                .and_then(Value::as_str)
                                .and_then(|value| TerminalPublicId::parse(value.to_string()).ok()),
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
                            supports_clear_history_key_fallback: tab
                                .get("supports_clear_history_key_fallback")
                                .and_then(Value::as_bool)
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

#[derive(Clone, Copy, Default)]
pub(super) struct TreeCapabilities {
    pub viewport_splits: bool,
    pub viewport_column_resize: bool,
}

fn parse_screen(value: &Value, capabilities: TreeCapabilities) -> Option<ScreenView> {
    Some(ScreenView {
        id: value.get("id")?.as_u64()?,
        resource_id: value
            .get("resource_id")
            .and_then(Value::as_str)
            .and_then(|value| ScreenPublicId::parse(value.to_string()).ok()),
        short_id: value.get("short_id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        name: value.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()),
        layout: value.get("layout").and_then(parse_layout)?,
        active_pane: value.get("active_pane").and_then(|v| v.as_u64()).unwrap_or(0),
        zoomed_pane: value.get("zoomed_pane").and_then(|v| v.as_u64()),
        viewport_base_width: if capabilities.viewport_column_resize {
            value
                .get("viewport_base_width")
                .and_then(Value::as_f64)
                .filter(|width| {
                    (f64::from(MIN_VIEWPORT_PANE_WIDTH)..=f64::from(MAX_VIEWPORT_PANE_WIDTH))
                        .contains(width)
                })
                .map(|width| width as f32)
        } else {
            None
        },
        viewport_splits: if capabilities.viewport_splits {
            value
                .get("viewport_splits")
                .and_then(Value::as_array)
                .map(|splits| {
                    splits
                        .iter()
                        .filter_map(|value| {
                            let split = value.get("split")?.as_u64()?;
                            let width = value.get("width")?.as_f64()?;
                            (f64::from(MIN_VIEWPORT_PANE_WIDTH)
                                ..=f64::from(MAX_VIEWPORT_PANE_WIDTH))
                                .contains(&width)
                                .then_some((split, width as f32))
                        })
                        .collect()
                })
                .unwrap_or_default()
        } else {
            BTreeMap::new()
        },
        panes: value
            .get("panes")
            .and_then(|v| v.as_array())
            .map(|panes| panes.iter().filter_map(parse_pane).collect())
            .unwrap_or_default(),
    })
}

/// Parse the remote `list-workspaces` response.
#[cfg(test)]
pub fn parse_tree(data: &Value) -> TreeView {
    parse_tree_with_capabilities(data, TreeCapabilities::default())
}

pub(super) fn parse_tree_with_capabilities(
    data: &Value,
    capabilities: TreeCapabilities,
) -> TreeView {
    let mut tree = TreeView {
        workspace_revision: data
            .get("workspace_revision")
            .and_then(Value::as_u64)
            .unwrap_or_default(),
        pane_revision: data.get("pane_revision").and_then(Value::as_u64),
        ..TreeView::default()
    };
    let Some(workspaces) = data.get("workspaces").and_then(|v| v.as_array()) else {
        return tree;
    };
    for (i, ws) in workspaces.iter().enumerate() {
        if ws.get("active").and_then(|v| v.as_bool()) == Some(true) {
            tree.active_workspace = i;
        }
        let mut view = WorkspaceView {
            id: ws.get("id").and_then(|v| v.as_u64()).unwrap_or(0),
            resource_id: ws
                .get("resource_id")
                .and_then(Value::as_str)
                .and_then(|value| WorkspacePublicId::parse(value.to_string()).ok()),
            key: ws.get("key").and_then(Value::as_str).unwrap_or_default().to_string(),
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
                if let Some(parsed) = parse_screen(screen, capabilities) {
                    view.screens.push(parsed);
                }
            }
        }
        tree.workspaces.push(view);
    }
    tree
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn unnamed_screens_use_zero_based_display_names() {
        let screen = ScreenView {
            id: 1,
            resource_id: None,
            short_id: "1".to_string(),
            name: None,
            layout: Node::Leaf(1),
            active_pane: 1,
            zoomed_pane: None,
            viewport_base_width: None,
            viewport_splits: BTreeMap::new(),
            panes: Vec::new(),
        };

        assert_eq!(screen.display_name(0), "0");
        assert_eq!(screen.display_name(9), "9");
    }

    #[test]
    fn retain_surfaces_drops_missing_tabs_and_clamps_active_index() {
        let mut tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1, "active": true,
                "screens": [{
                    "id": 2, "active": true, "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{"id": 3, "active_tab": 1, "tabs": [
                        {"surface": 7, "title": "gone"},
                        {"surface": 8, "title": "kept"}
                    ]}]
                }]
            }]
        }));

        tree.retain_surfaces(&HashSet::from([8]));

        let pane = &tree.workspaces[0].screens[0].panes[0];
        assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![8]);
        assert_eq!(pane.active_tab, 0);
    }

    #[test]
    fn retain_not_retired_keeps_tabs_when_local_catalog_is_empty() {
        let mut tree = parse_tree(
            &json!({"workspaces":[{"id":1,"screens":[{"id":2,"panes":[{"id":3,"tabs":[{"surface":7},{"surface":8}],"active_tab":1}]}]}]}),
        );
        tree.retain_not_retired(&HashSet::new());
        assert_eq!(tree.workspaces[0].screens[0].panes[0].tabs.len(), 2);
    }

    #[test]
    fn protocol_v8_parser_preserves_split_ids() {
        let tree = parse_tree_with_capabilities(
            &json!({
                "workspaces": [{
                    "id": 1,
                    "name": "one",
                    "active": true,
                    "screens": [{
                        "id": 2,
                        "active": true,
                        "active_pane": 3,
                        "layout": {
                            "type": "split",
                            "split": 9,
                            "dir": "right",
                            "ratio": 0.5,
                            "a": {"type": "leaf", "pane": 3},
                            "b": {"type": "leaf", "pane": 4}
                        },
                        "viewport_splits": [{"split": 9, "width": 0.6666667}],
                        "panes": []
                    }]
                }]
            }),
            TreeCapabilities { viewport_splits: true, viewport_column_resize: false },
        );

        let Node::Split { id, .. } = &tree.workspaces[0].screens[0].layout else {
            panic!("layout should be split");
        };
        assert_eq!(*id, 9);
        assert_eq!(tree.workspaces[0].screens[0].viewport_splits.get(&9), Some(&(2.0 / 3.0)));
    }

    #[test]
    fn parser_ignores_out_of_range_viewport_widths() {
        let tree = parse_tree_with_capabilities(
            &json!({
                "workspaces": [{
                    "id": 1,
                    "active": true,
                    "screens": [{
                        "id": 2,
                        "active": true,
                        "active_pane": 3,
                        "layout": {"type": "leaf", "pane": 3},
                        "viewport_base_width": 1.1,
                        "viewport_splits": [
                            {"split": 8, "width": 0.09},
                            {"split": 9, "width": 0.5},
                            {"split": 10, "width": 1.01}
                        ],
                        "panes": []
                    }]
                }]
            }),
            TreeCapabilities { viewport_splits: true, viewport_column_resize: true },
        );

        let screen = &tree.workspaces[0].screens[0];
        assert_eq!(screen.viewport_base_width, None);
        assert_eq!(screen.viewport_splits, BTreeMap::from([(9, 0.5)]));
    }

    #[test]
    fn parser_ignores_viewport_metadata_without_capabilities() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "viewport_base_width": 0.8,
                    "viewport_splits": [{"split": 9, "width": 0.5}],
                    "panes": []
                }]
            }]
        }));

        let screen = &tree.workspaces[0].screens[0];
        assert_eq!(screen.viewport_base_width, None);
        assert!(screen.viewport_splits.is_empty());
    }

    #[test]
    fn parser_builds_stable_resource_selectors_for_creation_receipts() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "resource_id": "ws_00000000000000000000000000000001",
                "active": true,
                "screens": [{
                    "id": 2,
                    "resource_id": "screen_00000000000000000000000000000002",
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "resource_id": "pane_00000000000000000000000000000003",
                        "tabs": []
                    }]
                }]
            }]
        }));

        assert_eq!(
            tree.resource_selectors_for_pane(Some(3)),
            Some(ResourceSelectors {
                machine: Some("current".to_string()),
                session: Some("current".to_string()),
                workspace: Some("ws_00000000000000000000000000000001".to_string()),
                screen: Some("screen_00000000000000000000000000000002".to_string()),
                pane: Some("pane_00000000000000000000000000000003".to_string()),
                ..ResourceSelectors::default()
            })
        );
    }

    #[test]
    fn protocol_v9_parser_preserves_stack_expansion() {
        let layout = parse_layout(&json!({
            "type": "stack",
            "panes": [3, 4, 5],
            "expanded": 4
        }))
        .unwrap();

        assert!(matches!(layout, Node::Stack { expanded: 4, .. }));
    }

    #[test]
    fn resolving_terminal_and_selecting_surface_update_the_full_active_path() {
        let mut tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "active_tab": 0,
                        "tabs": [
                            {
                                "surface": 4,
                                "terminal_resource_id": "term_00000000000000000000000000000004"
                            },
                            {
                                "surface": 5,
                                "terminal_resource_id": "term_00000000000000000000000000000005"
                            }
                        ]
                    }]
                }]
            }]
        }));

        let terminal = TerminalPublicId::parse("term_00000000000000000000000000000005").unwrap();
        assert_eq!(tree.resolve_terminal(&terminal), Some(5));
        assert!(tree.select_surface(5));
        assert_eq!(tree.active_surface(), Some(5));
        assert!(!tree.select_surface(99));
    }

    #[test]
    fn terminal_resolution_ignores_internal_ids_and_browser_tabs() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "active_tab": 0,
                        "tabs": [
                            {
                                "surface": 10,
                                "short_id": "term_0000000000000000000000000000000a",
                                "kind": "browser"
                            }
                        ]
                    }]
                }]
            }]
        }));
        let id = TerminalPublicId::parse("term_0000000000000000000000000000000a").unwrap();
        assert_eq!(tree.resolve_terminal(&id), None);
    }

    #[test]
    fn pane_parser_preserves_authoritative_focus_recency() {
        let pane = parse_pane(&json!({
            "id": 3,
            "focused_at": 42,
            "tabs": []
        }))
        .unwrap();

        assert_eq!(pane.focused_at, 42);
    }

    #[test]
    fn tree_parser_defaults_and_preserves_pane_revision() {
        assert_eq!(parse_tree(&json!({"workspaces": []})).pane_revision, None);
        assert_eq!(
            parse_tree(&json!({"pane_revision": 7, "workspaces": []})).pane_revision,
            Some(7)
        );
    }

    #[test]
    fn tree_parser_defaults_clear_fallback_support_to_false() {
        let pane = parse_pane(&json!({
            "id": 3,
            "tabs": [
                {"surface": 4},
                {"surface": 5, "supports_clear_history_key_fallback": true}
            ]
        }))
        .unwrap();

        assert!(!pane.tabs[0].supports_clear_history_key_fallback);
        assert!(pane.tabs[1].supports_clear_history_key_fallback);
    }

    #[test]
    fn tree_parser_preserves_browser_source_and_rejects_unknown_values() {
        let pane = parse_pane(&json!({
            "id": 3,
            "tabs": [
                {"surface": 4, "kind": "browser", "browser_source": "external"},
                {"surface": 5, "kind": "browser", "browser_source": "launched"},
                {"surface": 6, "kind": "browser", "browser_source": "remote"}
            ]
        }))
        .unwrap();

        assert_eq!(pane.tabs[0].browser_source, Some(BrowserSource::External));
        assert_eq!(pane.tabs[1].browser_source, Some(BrowserSource::Launched));
        assert_eq!(pane.tabs[2].browser_source, None);
    }
}
