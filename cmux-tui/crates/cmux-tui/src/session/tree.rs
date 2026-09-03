//! Read-only tree snapshots shared by the renderer and input handling,
//! plus the JSON parser for the remote `list-workspaces` shape.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::OnceLock;

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
    workspaces: Vec<WorkspaceView>,
    #[allow(dead_code)]
    pub workspace_revision: u64,
    pub pane_revision: Option<u64>,
    pub active_workspace: usize,
    #[doc(hidden)]
    pub(crate) location_index: OnceLock<TreeLocationIndex>,
}

#[derive(Clone, Default)]
pub(crate) struct TreeLocationIndex {
    panes: HashMap<PaneId, PaneLocation>,
    surfaces: HashMap<SurfaceId, SurfaceLocation>,
}

#[derive(Clone, Copy)]
struct PaneLocation {
    workspace_index: usize,
    screen_index: usize,
    pane_index: usize,
    workspace_id: WorkspaceId,
    previous_workspace: Option<WorkspaceId>,
    screen_id: ScreenId,
    previous_screen: Option<ScreenId>,
    previous_pane: Option<PaneId>,
}

#[derive(Clone, Copy)]
struct SurfaceLocation {
    workspace_index: usize,
    screen_index: usize,
    pane_index: usize,
    tab_index: usize,
    workspace_id: WorkspaceId,
    previous_workspace: Option<WorkspaceId>,
    screen_id: ScreenId,
    previous_screen: Option<ScreenId>,
    pane_id: PaneId,
    previous_pane: Option<PaneId>,
    previous_tab: Option<SurfaceId>,
}

impl TreeLocationIndex {
    fn build(tree: &TreeView) -> Self {
        let mut index = Self::default();
        for (workspace_index, workspace) in tree.workspaces.iter().enumerate() {
            for (screen_index, screen) in workspace.screens.iter().enumerate() {
                for (pane_index, pane) in screen.panes.iter().enumerate() {
                    index.panes.entry(pane.id).or_insert(PaneLocation {
                        workspace_index,
                        screen_index,
                        pane_index,
                        workspace_id: workspace.id,
                        previous_workspace: workspace_index
                            .checked_sub(1)
                            .and_then(|index| tree.workspaces.get(index))
                            .map(|workspace| workspace.id),
                        screen_id: screen.id,
                        previous_screen: screen_index
                            .checked_sub(1)
                            .and_then(|index| workspace.screens.get(index))
                            .map(|screen| screen.id),
                        previous_pane: pane_index
                            .checked_sub(1)
                            .and_then(|index| screen.panes.get(index))
                            .map(|pane| pane.id),
                    });
                    for (tab_index, tab) in pane.tabs.iter().enumerate() {
                        // The previous scans selected the first duplicate in tree order.
                        index.surfaces.entry(tab.surface).or_insert(SurfaceLocation {
                            workspace_index,
                            screen_index,
                            pane_index,
                            tab_index,
                            workspace_id: workspace.id,
                            previous_workspace: workspace_index
                                .checked_sub(1)
                                .and_then(|index| tree.workspaces.get(index))
                                .map(|workspace| workspace.id),
                            screen_id: screen.id,
                            previous_screen: screen_index
                                .checked_sub(1)
                                .and_then(|index| workspace.screens.get(index))
                                .map(|screen| screen.id),
                            pane_id: pane.id,
                            previous_pane: pane_index
                                .checked_sub(1)
                                .and_then(|index| screen.panes.get(index))
                                .map(|pane| pane.id),
                            previous_tab: tab_index
                                .checked_sub(1)
                                .and_then(|index| pane.tabs.get(index))
                                .map(|tab| tab.surface),
                        });
                    }
                }
            }
        }
        index
    }
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
    pub(crate) fn from_parts(
        workspaces: Vec<WorkspaceView>,
        workspace_revision: u64,
        pane_revision: Option<u64>,
        active_workspace: usize,
    ) -> Self {
        Self {
            workspaces,
            workspace_revision,
            pane_revision,
            active_workspace,
            location_index: OnceLock::new(),
        }
    }

    /// Retain the server's authoritative tab topology, removing only tabs
    /// with explicit detach/retire evidence. The local surface mirror is a
    /// lazy cache and can be empty during startup or reconnect.
    pub fn retain_not_retired(&mut self, retired: &HashSet<SurfaceId>) {
        self.invalidate_location_index();
        for workspace in &mut self.workspaces {
            for screen in &mut workspace.screens {
                for pane in &mut screen.panes {
                    let old_active_tab = pane.active_tab;
                    let active_surface = pane.tabs.get(old_active_tab).map(|tab| tab.surface);
                    let mut retained_index = 0;
                    let mut active_index = None;
                    pane.tabs.retain(|tab| {
                        if retired.contains(&tab.surface) {
                            return false;
                        }
                        if active_index.is_none() && active_surface == Some(tab.surface) {
                            active_index = Some(retained_index);
                        }
                        retained_index += 1;
                        true
                    });
                    pane.active_tab = active_index
                        .unwrap_or_else(|| old_active_tab.min(pane.tabs.len().saturating_sub(1)));
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

    /// Update focus state without invalidating topology locations.
    pub(crate) fn set_active_screen(
        &mut self,
        workspace_index: usize,
        screen_index: usize,
    ) -> bool {
        let Some(workspace) = self.workspaces.get_mut(workspace_index) else { return false };
        if screen_index >= workspace.screens.len() {
            return false;
        }
        workspace.active_screen = screen_index;
        true
    }

    /// Update focus state without invalidating topology locations.
    pub(crate) fn set_active_pane(
        &mut self,
        workspace_index: usize,
        screen_index: usize,
        pane_id: PaneId,
    ) -> bool {
        let Some(screen) = self
            .workspaces
            .get_mut(workspace_index)
            .and_then(|workspace| workspace.screens.get_mut(screen_index))
        else {
            return false;
        };
        if !screen.panes.iter().any(|pane| pane.id == pane_id) {
            return false;
        }
        screen.active_pane = pane_id;
        true
    }

    /// Update focus state without invalidating topology locations.
    pub(crate) fn set_active_tab(
        &mut self,
        workspace_index: usize,
        screen_index: usize,
        pane_id: PaneId,
        tab_index: usize,
    ) -> bool {
        let Some(pane) = self
            .workspaces
            .get_mut(workspace_index)
            .and_then(|workspace| workspace.screens.get_mut(screen_index))
            .and_then(|screen| screen.panes.iter_mut().find(|pane| pane.id == pane_id))
        else {
            return false;
        };
        if tab_index >= pane.tabs.len() {
            return false;
        }
        pane.active_tab = tab_index;
        true
    }

    /// Update focus state without invalidating topology locations.
    pub(crate) fn set_pane_active_tab(&mut self, pane_id: PaneId, tab_index: usize) -> bool {
        let Some((workspace_index, screen_index, pane_index)) = self.pane_location(pane_id) else {
            return false;
        };
        let Some(pane) = self
            .workspaces
            .get_mut(workspace_index)
            .and_then(|workspace| workspace.screens.get_mut(screen_index))
            .and_then(|screen| screen.panes.get_mut(pane_index))
        else {
            return false;
        };
        if pane.id != pane_id || tab_index >= pane.tabs.len() {
            return false;
        }
        pane.active_tab = tab_index;
        true
    }

    pub fn active_workspace_mut(&mut self) -> Option<&mut WorkspaceView> {
        self.invalidate_location_index();
        self.workspaces.get_mut(self.active_workspace)
    }

    pub fn active_workspace_mut_screen(&mut self) -> Option<&mut ScreenView> {
        self.invalidate_location_index();
        let workspace = self.workspaces.get_mut(self.active_workspace)?;
        workspace.screens.get_mut(workspace.active_screen)
    }

    /// The active screen of the active workspace.
    pub fn active_screen(&self) -> Option<&ScreenView> {
        self.active_workspace()?.active_screen_ref()
    }

    pub fn pane(&self, id: PaneId) -> Option<&PaneView> {
        let (workspace_index, screen_index, pane_index) = self.pane_location(id)?;
        self.workspaces
            .get(workspace_index)?
            .screens
            .get(screen_index)?
            .panes
            .get(pane_index)
            .filter(|pane| pane.id == id)
    }

    pub fn pane_mut(&mut self, id: PaneId) -> Option<&mut PaneView> {
        self.invalidate_location_index();
        self.workspaces
            .iter_mut()
            .flat_map(|workspace| workspace.screens.iter_mut())
            .flat_map(|screen| screen.panes.iter_mut())
            .find(|pane| pane.id == id)
    }

    pub fn surface(&self, id: SurfaceId) -> Option<&TabView> {
        let (workspace_index, screen_index, pane_index, tab_index) = self.surface_location(id)?;
        self.workspaces
            .get(workspace_index)?
            .screens
            .get(screen_index)?
            .panes
            .get(pane_index)?
            .tabs
            .get(tab_index)
            .filter(|tab| tab.surface == id)
    }

    pub(crate) fn update_surface_title(&mut self, id: SurfaceId, title: &str) -> bool {
        let (workspace_index, screen_index, pane_index, tab_index) = match self.surface_location(id)
        {
            Some(location) => location,
            None => return false,
        };
        self.update_surface_title_at(
            id,
            [workspace_index, screen_index, pane_index, tab_index],
            title,
        )
        .is_some()
    }

    pub(crate) fn update_surface_title_at(
        &mut self,
        id: SurfaceId,
        [workspace_index, screen_index, pane_index, tab_index]: [usize; 4],
        title: &str,
    ) -> Option<bool> {
        let Some(tab) = self
            .workspaces
            .get_mut(workspace_index)
            .and_then(|workspace| workspace.screens.get_mut(screen_index))
            .and_then(|screen| screen.panes.get_mut(pane_index))
            .and_then(|pane| pane.tabs.get_mut(tab_index))
        else {
            return None;
        };
        if tab.surface != id {
            return None;
        }
        let changed = tab.title != title;
        if changed {
            tab.title = title.to_owned();
        }
        Some(changed)
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
        let Some((workspace_index, screen_index, pane_index, tab_index)) =
            self.surface_location(id)
        else {
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
        self.surface(id).map(|tab| tab.kind).unwrap_or(SurfaceKind::Pty)
    }

    fn location_index(&self) -> &TreeLocationIndex {
        self.location_index.get_or_init(|| TreeLocationIndex::build(self))
    }

    /// Mutably access the workspace topology and invalidate cached locations.
    /// Callers must use this guard before changing workspaces, screens, panes,
    /// or tabs so indexed lookups rebuild against the new topology.
    pub(crate) fn workspaces_mut(&mut self) -> &mut Vec<WorkspaceView> {
        self.invalidate_location_index();
        &mut self.workspaces
    }

    pub(crate) fn workspaces(&self) -> &[WorkspaceView] {
        &self.workspaces
    }

    fn pane_location(&self, id: PaneId) -> Option<(usize, usize, usize)> {
        let location = self.location_index().panes.get(&id)?;
        let workspace_index = location.workspace_index;
        let screen_index = location.screen_index;
        let pane_index = location.pane_index;
        let workspace = self.workspaces.get(workspace_index)?;
        if workspace.id != location.workspace_id
            || (workspace_index > 0
                && self.workspaces.get(workspace_index - 1).map(|workspace| workspace.id)
                    != location.previous_workspace)
        {
            return None;
        }
        let screen = workspace.screens.get(screen_index)?;
        if screen.id != location.screen_id
            || (screen_index > 0
                && workspace.screens.get(screen_index - 1).map(|screen| screen.id)
                    != location.previous_screen)
        {
            return None;
        }
        screen.panes.get(pane_index).filter(|pane| pane.id == id)?;
        if pane_index > 0
            && screen.panes.get(pane_index - 1).map(|pane| pane.id) != location.previous_pane
        {
            return None;
        }
        Some((workspace_index, screen_index, pane_index))
    }

    fn surface_location(&self, id: SurfaceId) -> Option<(usize, usize, usize, usize)> {
        let location = self.location_index().surfaces.get(&id)?;
        let workspace_index = location.workspace_index;
        let screen_index = location.screen_index;
        let pane_index = location.pane_index;
        let tab_index = location.tab_index;
        let workspace = self.workspaces.get(workspace_index)?;
        if workspace.id != location.workspace_id
            || (workspace_index > 0
                && self.workspaces.get(workspace_index - 1).map(|workspace| workspace.id)
                    != location.previous_workspace)
        {
            return None;
        }
        let screen = workspace.screens.get(screen_index)?;
        if screen.id != location.screen_id
            || (screen_index > 0
                && workspace.screens.get(screen_index - 1).map(|screen| screen.id)
                    != location.previous_screen)
        {
            return None;
        }
        let pane = screen.panes.get(pane_index)?;
        if pane.id != location.pane_id
            || (pane_index > 0
                && screen.panes.get(pane_index - 1).map(|pane| pane.id) != location.previous_pane)
        {
            return None;
        }
        pane.tabs.get(tab_index).filter(|tab| tab.surface == id)?;
        if tab_index > 0
            && pane.tabs.get(tab_index - 1).map(|tab| tab.surface) != location.previous_tab
        {
            return None;
        }
        Some((workspace_index, screen_index, pane_index, tab_index))
    }

    pub(crate) fn invalidate_location_index(&mut self) {
        self.location_index = OnceLock::new();
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
        location_index: OnceLock::new(),
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
    let raw_active_tab = value
        .get("active_tab")
        .and_then(Value::as_u64)
        .and_then(|value| usize::try_from(value).ok());
    let active_tab_is_declared = value.get("active_tab").is_some();
    let mut active_tab = None;
    Some(PaneView {
        id: value.get("id")?.as_u64()?,
        resource_id: value
            .get("resource_id")
            .and_then(Value::as_str)
            .and_then(|value| PanePublicId::parse(value.to_string()).ok()),
        short_id: value.get("short_id").and_then(|v| v.as_str()).unwrap_or_default().to_string(),
        name: value.get("name").and_then(|v| v.as_str()).map(|s| s.to_string()),
        focused_at: value.get("focused_at").and_then(|v| v.as_u64()).unwrap_or(0),
        tabs: value
            .get("tabs")
            .and_then(|v| v.as_array())
            .map(|tabs| {
                let mut compact_index = 0;
                tabs.iter()
                    .enumerate()
                    .filter_map(|(raw_index, tab)| {
                        let parsed = Some(TabView {
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
                        })?;
                        if raw_active_tab == Some(raw_index) {
                            active_tab = Some(compact_index);
                        }
                        compact_index += 1;
                        Some(parsed)
                    })
                    .collect()
            })
            .unwrap_or_default(),
        active_tab: active_tab
            .unwrap_or_else(|| if active_tab_is_declared { usize::MAX } else { 0 }),
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
            let mut active_screen = None;
            let mut active_screen_is_invalid = false;
            for screen in screens {
                let is_active = screen.get("active").and_then(|v| v.as_bool()) == Some(true);
                match parse_screen(screen, capabilities) {
                    Some(parsed) => {
                        if is_active {
                            active_screen = Some(view.screens.len());
                            active_screen_is_invalid = false;
                        }
                        view.screens.push(parsed);
                    }
                    None => {
                        if is_active {
                            active_screen = None;
                            active_screen_is_invalid = true;
                        }
                    }
                }
            }
            view.active_screen = active_screen
                .unwrap_or_else(|| if active_screen_is_invalid { usize::MAX } else { 0 });
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
    fn retain_not_retired_keeps_tabs_when_local_catalog_is_empty() {
        // The fixture must be a COMPLETE tree: parse_tree drops
        // underspecified workspaces/screens, and this test shipped with a
        // minimal shape that parsed to an empty tree (the panic was masked
        // in CI by a clippy failure earlier in the same job).
        let mut tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1, "active": true,
                "screens": [{
                    "id": 2, "active": true, "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{"id": 3, "active_tab": 1, "tabs": [
                        {"surface": 7, "title": "a"},
                        {"surface": 8, "title": "b"}
                    ]}]
                }]
            }]
        }));
        tree.retain_not_retired(&HashSet::new());
        let pane = &tree.workspaces[0].screens[0].panes[0];
        assert_eq!(pane.tabs.len(), 2);
        assert_eq!(pane.active_tab, 1);
    }

    #[test]
    fn parser_reindexes_active_screen_after_dropping_malformed_screens() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [
                    {"active": false},
                    {
                        "id": 2,
                        "active": true,
                        "active_pane": 3,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": []
                    }
                ]
            }]
        }));

        assert_eq!(tree.workspaces[0].screens.len(), 1);
        assert_eq!(tree.workspaces[0].active_screen, 0);
        assert_eq!(tree.active_screen().map(|screen| screen.id), Some(2));
    }

    #[test]
    fn parser_fails_closed_when_active_screen_is_malformed() {
        let tree = parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [
                    {
                        "id": 2,
                        "active": false,
                        "active_pane": 3,
                        "layout": {"type": "leaf", "pane": 3},
                        "panes": []
                    },
                    {"active": true}
                ]
            }]
        }));

        assert_eq!(tree.workspaces[0].screens.len(), 1);
        assert!(tree.active_screen().is_none());
    }

    fn tree_with_tabs(active_tab: usize, surfaces: &[SurfaceId]) -> TreeView {
        let tabs = surfaces
            .iter()
            .map(|surface| json!({"surface": surface, "title": "tab"}))
            .collect::<Vec<_>>();
        parse_tree(&json!({
            "workspaces": [{
                "id": 1, "active": true,
                "screens": [{
                    "id": 2, "active": true, "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{"id": 3, "active_tab": active_tab, "tabs": tabs}]
                }]
            }]
        }))
    }

    #[test]
    fn retain_not_retired_reindexes_active_tab_after_leading_retire() {
        let mut tree = tree_with_tabs(2, &[7, 8, 9]);
        tree.retain_not_retired(&HashSet::from([7]));

        let pane = &tree.workspaces[0].screens[0].panes[0];
        assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![8, 9]);
        assert_eq!(pane.active_tab, 1);
    }

    #[test]
    fn retain_not_retired_clamps_when_active_tab_is_retired() {
        let mut tree = tree_with_tabs(1, &[7, 8]);
        tree.retain_not_retired(&HashSet::from([8]));

        let pane = &tree.workspaces[0].screens[0].panes[0];
        assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![7]);
        assert_eq!(pane.active_tab, 0);
    }

    #[test]
    fn retain_not_retired_clamps_out_of_range_active_tab() {
        let mut tree = tree_with_tabs(9, &[7, 8]);
        tree.retain_not_retired(&HashSet::new());

        let pane = &tree.workspaces[0].screens[0].panes[0];
        assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![7, 8]);
        assert_eq!(pane.active_tab, 1);
    }

    #[test]
    fn retain_not_retired_uses_first_duplicate_surface_match() {
        let mut tree = tree_with_tabs(1, &[7, 7, 8]);
        tree.retain_not_retired(&HashSet::new());

        let pane = &tree.workspaces[0].screens[0].panes[0];
        assert_eq!(pane.tabs.iter().map(|tab| tab.surface).collect::<Vec<_>>(), vec![7, 7, 8]);
        assert_eq!(pane.active_tab, 0);
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
    fn surface_and_pane_lookup_keep_first_match_after_tree_mutation() {
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
                            {"surface": 7, "title": "first"},
                            {"surface": 8, "title": "retained"}
                        ]
                    }]
                }]
            }, {
                "id": 4,
                "screens": [{
                    "id": 5,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "tabs": [{"surface": 7, "title": "duplicate"}]
                    }]
                }]
            }]
        }));

        assert_eq!(tree.surface(7).map(|tab| tab.title.as_str()), Some("first"));
        assert_eq!(tree.pane(3).map(|pane| pane.tabs[0].title.as_str()), Some("first"));
        tree.active_workspace = 1;
        assert!(tree.select_surface(7));
        assert_eq!(tree.active_workspace, 0);
        assert_eq!(tree.active_surface(), Some(7));

        tree.retain_not_retired(&HashSet::from([7]));
        assert!(tree.surface(7).is_none());
        assert_eq!(tree.surface(8).map(|tab| tab.title.as_str()), Some("retained"));
        assert!(tree.pane(3).is_some());
    }

    #[test]
    fn indexed_lookup_fails_closed_after_internal_topology_mutation() {
        let tree = || {
            parse_tree(&json!({
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
                                {"surface": 7, "title": "first"},
                                {"surface": 8, "title": "retained"}
                            ]
                        }]
                    }]
                }]
            }))
        };

        let mut appended = tree();
        assert!(appended.surface(7).is_some());
        let tab = appended.workspaces[0].screens[0].panes[0].tabs[0].clone();
        appended.workspaces[0].screens[0].panes[0].tabs.push(tab);
        assert!(appended.surface(7).is_some());

        let mut inserted = tree();
        assert!(inserted.surface(8).is_some());
        let tab = inserted.workspaces[0].screens[0].panes[0].tabs[0].clone();
        inserted.workspaces[0].screens[0].panes[0].tabs.insert(0, tab);
        assert!(inserted.surface(8).is_none());
        assert!(!inserted.select_surface(8));

        let mut removed = tree();
        assert!(removed.surface(8).is_some());
        removed.workspaces[0].screens[0].panes[0].tabs.remove(0);
        assert!(removed.surface(8).is_none());
        assert!(!removed.select_surface(8));

        let mut replaced = tree();
        assert!(replaced.surface(8).is_some());
        replaced.workspaces[0].screens[0].panes[0].tabs[0].surface = 8;
        assert!(replaced.surface(8).is_none());
        assert!(!replaced.select_surface(8));
    }

    #[test]
    fn topology_mutation_guard_invalidates_index_before_nested_mutation() {
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
                            {"surface": 7, "title": "first"},
                            {"surface": 8, "title": "retained"}
                        ]
                    }]
                }]
            }]
        }));

        assert_eq!(tree.surface(8).map(|tab| tab.title.as_str()), Some("retained"));
        let mut inserted = tree.workspaces_mut()[0].screens[0].panes[0].tabs[0].clone();
        inserted.title = "inserted".to_string();
        tree.workspaces_mut()[0].screens[0].panes[0].tabs.insert(0, inserted);

        assert_eq!(tree.surface(8).map(|tab| tab.title.as_str()), Some("retained"));
        assert_eq!(tree.surface(7).map(|tab| tab.title.as_str()), Some("inserted"));
        assert!(tree.select_surface(8));
    }

    #[test]
    fn title_updates_reuse_the_existing_location_index() {
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
                        "tabs": [{"surface": 7, "title": "first"}]
                    }]
                }]
            }]
        }));

        let index_before = tree.location_index() as *const TreeLocationIndex;
        assert!(tree.update_surface_title(7, "renamed"));
        let index_after = tree.location_index() as *const TreeLocationIndex;

        assert!(std::ptr::eq(index_before, index_after));
        assert_eq!(tree.surface(7).map(|tab| tab.title.as_str()), Some("renamed"));
    }

    #[test]
    fn focus_updates_reuse_the_existing_location_index() {
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
                        "tabs": [{"surface": 7, "title": "first"}]
                    }]
                }]
            }]
        }));

        let index_before = tree.location_index() as *const TreeLocationIndex;
        assert!(tree.set_active_screen(0, 0));
        assert!(tree.set_active_pane(0, 0, 3));
        assert!(tree.set_active_tab(0, 0, 3, 0));
        assert!(tree.set_pane_active_tab(3, 0));
        let index_after = tree.location_index() as *const TreeLocationIndex;

        assert!(std::ptr::eq(index_before, index_after));
        assert_eq!(tree.active_surface(), Some(7));
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
    fn pane_parser_reindexes_active_tab_after_dropping_malformed_tabs() {
        let pane = parse_pane(&json!({
            "id": 3,
            "active_tab": 1,
            "tabs": [
                {"title": "malformed"},
                {"surface": 5, "title": "active"}
            ]
        }))
        .unwrap();

        assert_eq!(pane.tabs.len(), 1);
        assert_eq!(pane.active_tab, 0);
        assert_eq!(pane.active_surface(), Some(5));
    }

    #[test]
    fn pane_parser_fails_closed_when_active_tab_is_out_of_range() {
        let pane = parse_pane(&json!({
            "id": 3,
            "active_tab": 9,
            "tabs": [{"surface": 5, "title": "only"}]
        }))
        .unwrap();

        assert_eq!(pane.active_tab, usize::MAX);
        assert_eq!(pane.active_surface(), None);
    }

    #[test]
    fn pane_parser_fails_closed_when_active_tab_value_is_malformed() {
        let pane = parse_pane(&json!({
            "id": 3,
            "active_tab": "invalid",
            "tabs": [{"surface": 5, "title": "only"}]
        }))
        .unwrap();

        assert_eq!(pane.active_tab, usize::MAX);
        assert_eq!(pane.active_surface(), None);
    }

    #[test]
    fn pane_parser_fails_closed_when_active_tab_is_malformed() {
        let pane = parse_pane(&json!({
            "id": 3,
            "active_tab": 1,
            "tabs": [
                {"surface": 5, "title": "first"},
                {"title": "malformed"},
                {"surface": 6, "title": "third"}
            ]
        }))
        .unwrap();

        assert_eq!(pane.tabs.len(), 2);
        assert_eq!(pane.active_tab, usize::MAX);
        assert_eq!(pane.active_surface(), None);
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
