//! Atomic durable/in-memory projection for protocol-v1 resource mutations.
//!
//! A caller prepares a [`StatePatch`] without changing the live mux. The
//! matching targeted [`ResourcePatch`] commits first, then applying the state
//! patch is a single infallible swap. A crash can therefore expose either the
//! old state or the committed durable state, which startup restores.

use std::collections::{HashMap, HashSet};

use anyhow::Context;

use crate::model::{Node, State};
use crate::resource::{
    BrowserPublicId, ContentPublicId, PanePublicId, SplitPublicId, TabPublicId, TerminalPublicId,
    WorkspacePublicId,
};
use crate::workspace_registry::{
    RegistryLayoutNode, RegistryPane, RegistryScreen, RegistrySnapshot, RegistryTab,
    RegistryTerminal, RegistryViewport, RegistryViewportColumn, RegistryWorkspace, ResourceChange,
    ResourcePatch, ResourceTopologySnapshot, WorkspaceRegistry,
};
use crate::{SplitDir, SplitId};

/// Fully prepared in-memory state. Construction may allocate and fail;
/// application after the durable commit cannot.
pub(crate) struct StatePatch {
    next: State,
}

impl StatePatch {
    pub(crate) fn prepare(current: &State) -> Self {
        Self { next: current.clone() }
    }

    pub(crate) fn state(&self) -> &State {
        &self.next
    }

    pub(crate) fn state_mut(&mut self) -> &mut State {
        &mut self.next
    }

    pub(crate) fn apply(mut self, target: &mut State, revision: u64) {
        self.next.resource_revision = revision;
        *target = self.next;
    }
}

pub(crate) struct ProjectedResourceState {
    pub(crate) workspaces: Vec<RegistryWorkspace>,
    pub(crate) active_workspace: Option<WorkspacePublicId>,
    pub(crate) active_screens: HashMap<WorkspacePublicId, Option<crate::resource::ScreenPublicId>>,
    pub(crate) screens: Vec<RegistryScreen>,
    pub(crate) panes: Vec<RegistryPane>,
    pub(crate) tabs: Vec<RegistryTab>,
    pub(crate) terminals: HashMap<TerminalPublicId, RegistryTerminal>,
    pub(crate) browsers: HashMap<BrowserPublicId, String>,
}

/// Allocate public split identities while the state is still only a prepared
/// copy. All other public identities are assigned at object construction.
pub(crate) fn ensure_split_public_ids(state: &mut State) -> anyhow::Result<()> {
    let mut live = HashSet::new();
    for workspace in &state.workspaces {
        for screen in &workspace.screens {
            collect_node_splits(&screen.root, &mut live);
            for column in &screen.layout_columns {
                live.insert(column.id);
                collect_node_splits(&column.root, &mut live);
            }
        }
    }
    for split in live {
        if state.resource_indexes.split_ids.contains_key(&split) {
            continue;
        }
        let public_id = SplitPublicId::random()?;
        state.resource_indexes.splits.insert(public_id.clone(), split);
        state.resource_indexes.split_ids.insert(split, public_id);
    }
    Ok(())
}

fn collect_node_splits(node: &Node, output: &mut HashSet<SplitId>) {
    match node {
        Node::Leaf(_) | Node::Stack { .. } => {}
        Node::Split { id, a, b, .. } => {
            output.insert(*id);
            collect_node_splits(a, output);
            collect_node_splits(b, output);
        }
    }
}

pub(crate) fn project_resource_state(
    state: &State,
    session: &str,
    registry: &WorkspaceRegistry,
) -> anyhow::Result<ProjectedResourceState> {
    let workspaces = state
        .workspaces
        .iter()
        .map(|workspace| RegistryWorkspace {
            id: workspace.id,
            public_id: workspace.public_id.clone(),
            key: workspace.key.clone(),
            name: workspace.name.clone(),
            group_key: session.to_string(),
        })
        .collect::<Vec<_>>();
    let active_workspace =
        state.workspaces.get(state.active_workspace).map(|workspace| workspace.public_id.clone());
    let mut active_screens = HashMap::new();
    let mut screens = Vec::new();
    let mut panes = Vec::new();
    let mut tabs = Vec::new();
    let mut terminals = HashMap::new();
    let mut browsers = HashMap::new();

    for workspace in &state.workspaces {
        active_screens.insert(
            workspace.public_id.clone(),
            workspace.screens.get(workspace.active_screen).map(|screen| screen.public_id.clone()),
        );
        for (screen_position, screen) in workspace.screens.iter().enumerate() {
            let layout = project_node(state, &screen.root)?;
            let viewport = if screen.layout_columns.is_empty() {
                RegistryViewport::default()
            } else {
                RegistryViewport {
                    base_width: screen.viewport_base_width,
                    columns: screen
                        .layout_columns
                        .iter()
                        .map(|column| {
                            Ok(RegistryViewportColumn {
                                id: split_public_id(state, column.id)?,
                                width: column.width,
                                layout: project_node(state, &column.root)?,
                                auto_layout: column
                                    .zellij_auto_layout
                                    .as_ref()
                                    .map(|order| project_pane_order(state, order))
                                    .transpose()?,
                            })
                        })
                        .collect::<anyhow::Result<Vec<_>>>()?,
                }
            };
            screens.push(RegistryScreen {
                public_id: screen.public_id.clone(),
                workspace_id: workspace.public_id.clone(),
                position: screen_position,
                name: screen.name.clone(),
                layout,
                active_pane: pane_public_id(state, screen.active_pane)?,
                zoomed_pane: screen
                    .zoomed_pane
                    .map(|pane| pane_public_id(state, pane))
                    .transpose()?,
                auto_layout: screen
                    .zellij_auto_layout
                    .as_ref()
                    .map(|order| project_pane_order(state, order))
                    .transpose()?,
                viewport,
            });
            for pane_slot in screen.root.pane_ids_vec() {
                let pane = state.panes.get(&pane_slot).with_context(|| {
                    format!("screen {} references missing pane {pane_slot}", screen.id)
                })?;
                let active_tab = pane
                    .tabs
                    .get(pane.active_tab)
                    .map(|surface| tab_public_id(state, *surface))
                    .transpose()?;
                panes.push(RegistryPane {
                    public_id: pane.public_id.clone(),
                    screen_id: screen.public_id.clone(),
                    name: pane.name.clone(),
                    active_tab,
                    creation_ordinal: pane.id,
                });
                for (position, surface_id) in pane.tabs.iter().copied().enumerate() {
                    let surface = state.surfaces.get(&surface_id).with_context(|| {
                        format!("pane {} references missing surface {surface_id}", pane.id)
                    })?;
                    let identity = surface.resource_identity().with_context(|| {
                        format!("surface {surface_id} has no public resource identity")
                    })?;
                    let (browser_url, terminal_id) = match &identity.content_id {
                        ContentPublicId::Terminal(public_id) => {
                            let host = surface.terminal_host_identity().with_context(|| {
                                format!("terminal surface {surface_id} has no host identity")
                            })?;
                            let terminal = registry
                                .terminal_record(&host.terminal_id)?
                                .with_context(|| {
                                    format!(
                                        "terminal {} is missing its durable host row",
                                        host.terminal_id
                                    )
                                })?;
                            terminals.insert(public_id.clone(), terminal);
                            (None, Some(host.terminal_id))
                        }
                        ContentPublicId::Browser(public_id) => {
                            let url = surface.browser_url().unwrap_or_else(|| "about:blank".into());
                            browsers.insert(public_id.clone(), url.clone());
                            (Some(url), None)
                        }
                    };
                    tabs.push(RegistryTab {
                        public_id: identity.tab_id.clone(),
                        pane_id: pane.public_id.clone(),
                        position,
                        content_id: identity.content_id.clone(),
                        name: surface.name(),
                        browser_url,
                        terminal_id,
                    });
                }
            }
        }
    }

    Ok(ProjectedResourceState {
        workspaces,
        active_workspace,
        active_screens,
        screens,
        panes,
        tabs,
        terminals,
        browsers,
    })
}

fn project_node(state: &State, node: &Node) -> anyhow::Result<RegistryLayoutNode> {
    Ok(match node {
        Node::Leaf(pane) => RegistryLayoutNode::Leaf { pane: pane_public_id(state, *pane)? },
        Node::Split { id, dir, ratio, a, b } => RegistryLayoutNode::Split {
            split: split_public_id(state, *id)?,
            direction: match dir {
                SplitDir::Right => "right",
                SplitDir::Down => "down",
            }
            .into(),
            ratio: *ratio,
            first: Box::new(project_node(state, a)?),
            second: Box::new(project_node(state, b)?),
        },
        Node::Stack { panes, expanded } => RegistryLayoutNode::Stack {
            panes: project_pane_order(state, panes.as_slice())?,
            expanded: pane_public_id(state, *expanded)?,
        },
    })
}

fn project_pane_order(state: &State, panes: &[crate::PaneId]) -> anyhow::Result<Vec<PanePublicId>> {
    panes.iter().map(|pane| pane_public_id(state, *pane)).collect()
}

fn pane_public_id(state: &State, pane: crate::PaneId) -> anyhow::Result<PanePublicId> {
    state
        .resource_indexes
        .pane_ids
        .get(&pane)
        .cloned()
        .with_context(|| format!("pane {pane} has no public identity"))
}

fn tab_public_id(state: &State, surface: crate::SurfaceId) -> anyhow::Result<TabPublicId> {
    state
        .resource_indexes
        .tab_ids
        .get(&surface)
        .cloned()
        .or_else(|| {
            state
                .surfaces
                .get(&surface)
                .and_then(|surface| surface.resource_identity())
                .map(|identity| identity.tab_id.clone())
        })
        .with_context(|| format!("surface {surface} has no public tab identity"))
}

fn split_public_id(state: &State, split: SplitId) -> anyhow::Result<SplitPublicId> {
    state
        .resource_indexes
        .split_ids
        .get(&split)
        .cloned()
        .with_context(|| format!("split {split} has no public identity"))
}

/// Build the smallest patch that converts the durable topology to `desired`.
/// Parent tombstones deliberately omit redundant descendant tombstones.
pub(crate) fn diff_resource_projection(
    current_workspaces: &RegistrySnapshot,
    current: &ResourceTopologySnapshot,
    desired: &ProjectedResourceState,
    registry: &WorkspaceRegistry,
    force_if_unchanged: Option<ResourceChange>,
) -> anyhow::Result<ResourcePatch> {
    let mut changes = Vec::new();
    let current_workspace_positions = current_workspaces
        .workspaces
        .iter()
        .enumerate()
        .map(|(position, workspace)| (workspace.public_id.clone(), (position, workspace)))
        .collect::<HashMap<_, _>>();
    let current_active_screens = current.active_screens.iter().cloned().collect::<HashMap<_, _>>();
    let desired_workspace_ids =
        desired.workspaces.iter().map(|workspace| workspace.public_id.clone()).collect::<Vec<_>>();
    let desired_workspace_set = desired_workspace_ids.iter().cloned().collect::<HashSet<_>>();
    let closing_workspaces = current_workspaces
        .workspaces
        .iter()
        .filter(|workspace| !desired_workspace_set.contains(&workspace.public_id))
        .map(|workspace| workspace.public_id.clone())
        .collect::<HashSet<_>>();

    for (position, workspace) in desired.workspaces.iter().enumerate() {
        let active_screen = desired.active_screens.get(&workspace.public_id).cloned().flatten();
        let unchanged = current_workspace_positions.get(&workspace.public_id).is_some_and(
            |(old_position, old)| {
                *old_position == position
                    && *old == workspace
                    && current_active_screens.get(&workspace.public_id).cloned().flatten()
                        == active_screen
            },
        );
        if !unchanged {
            changes.push(ResourceChange::UpsertWorkspace {
                workspace: workspace.clone(),
                position,
                active_screen,
            });
        }
    }
    for workspace in &closing_workspaces {
        changes.push(ResourceChange::TombstoneWorkspace { workspace_id: workspace.clone() });
    }
    let current_workspace_ids = current_workspaces
        .workspaces
        .iter()
        .map(|workspace| workspace.public_id.clone())
        .collect::<Vec<_>>();
    if current_workspace_ids != desired_workspace_ids {
        changes.push(ResourceChange::SetWorkspaceOrder {
            workspace_ids: desired_workspace_ids.clone(),
        });
    }
    if current.active_workspace != desired.active_workspace {
        changes.push(ResourceChange::SetActiveWorkspace {
            workspace_id: desired.active_workspace.clone(),
        });
    }

    let current_screens = current
        .screens
        .iter()
        .map(|screen| (screen.public_id.clone(), screen))
        .collect::<HashMap<_, _>>();
    let desired_screens = desired
        .screens
        .iter()
        .map(|screen| (screen.public_id.clone(), screen))
        .collect::<HashMap<_, _>>();
    let closing_screens = current
        .screens
        .iter()
        .filter(|screen| {
            !closing_workspaces.contains(&screen.workspace_id)
                && !desired_screens.contains_key(&screen.public_id)
        })
        .map(|screen| screen.public_id.clone())
        .collect::<HashSet<_>>();
    for screen in &desired.screens {
        if current_screens.get(&screen.public_id).copied() != Some(screen) {
            changes.push(ResourceChange::UpsertScreen(screen.clone()));
        }
    }
    for screen in &closing_screens {
        changes.push(ResourceChange::TombstoneScreen { screen_id: screen.clone() });
    }
    for workspace in &desired.workspaces {
        let current_order = current
            .screens
            .iter()
            .filter(|screen| screen.workspace_id == workspace.public_id)
            .map(|screen| screen.public_id.clone())
            .collect::<Vec<_>>();
        let desired_order = desired
            .screens
            .iter()
            .filter(|screen| screen.workspace_id == workspace.public_id)
            .map(|screen| screen.public_id.clone())
            .collect::<Vec<_>>();
        if current_order != desired_order {
            changes.push(ResourceChange::SetScreenOrder {
                workspace_id: workspace.public_id.clone(),
                screen_ids: desired_order,
            });
        }
    }

    let current_panes =
        current.panes.iter().map(|pane| (pane.public_id.clone(), pane)).collect::<HashMap<_, _>>();
    let desired_panes =
        desired.panes.iter().map(|pane| (pane.public_id.clone(), pane)).collect::<HashMap<_, _>>();
    let closing_panes = current
        .panes
        .iter()
        .filter(|pane| {
            !closing_screens.contains(&pane.screen_id)
                && current_screens
                    .get(&pane.screen_id)
                    .is_none_or(|screen| !closing_workspaces.contains(&screen.workspace_id))
                && !desired_panes.contains_key(&pane.public_id)
        })
        .map(|pane| pane.public_id.clone())
        .collect::<HashSet<_>>();
    for pane in &desired.panes {
        if current_panes.get(&pane.public_id).copied() != Some(pane) {
            changes.push(ResourceChange::UpsertPane(pane.clone()));
        }
    }
    for pane in &closing_panes {
        changes.push(ResourceChange::TombstonePane { pane_id: pane.clone() });
    }

    let current_tabs =
        current.tabs.iter().map(|tab| (tab.public_id.clone(), tab)).collect::<HashMap<_, _>>();
    let desired_tabs =
        desired.tabs.iter().map(|tab| (tab.public_id.clone(), tab)).collect::<HashMap<_, _>>();
    for (public_id, terminal) in &desired.terminals {
        let stored_host = registry.terminal_host_id(public_id)?;
        let stored = stored_host
            .as_deref()
            .map(|host| registry.terminal_record(host))
            .transpose()?
            .flatten();
        if stored_host.as_deref() != Some(terminal.terminal_id.as_str())
            || stored.as_ref() != Some(terminal)
        {
            changes.push(ResourceChange::UpsertTerminal {
                public_id: public_id.clone(),
                terminal: terminal.clone(),
            });
        }
    }
    for (public_id, url) in &desired.browsers {
        let stored_url = current.tabs.iter().find_map(|tab| {
            (tab.content_id == ContentPublicId::Browser(public_id.clone()))
                .then(|| tab.browser_url.clone())
                .flatten()
        });
        if stored_url.as_deref() != Some(url.as_str()) {
            changes.push(ResourceChange::UpsertBrowser {
                public_id: public_id.clone(),
                url: url.clone(),
            });
        }
    }
    for tab in &desired.tabs {
        if current_tabs.get(&tab.public_id).copied() != Some(tab) {
            changes.push(ResourceChange::UpsertTab(tab.clone()));
        }
    }
    for tab in &current.tabs {
        let pane_closes = closing_panes.contains(&tab.pane_id)
            || current_panes.get(&tab.pane_id).is_some_and(|pane| {
                closing_screens.contains(&pane.screen_id)
                    || current_screens
                        .get(&pane.screen_id)
                        .is_some_and(|screen| closing_workspaces.contains(&screen.workspace_id))
            });
        if !pane_closes && !desired_tabs.contains_key(&tab.public_id) {
            changes.push(ResourceChange::TombstoneTab { tab_id: tab.public_id.clone() });
        }
    }
    for pane in &desired.panes {
        let current_order = current
            .tabs
            .iter()
            .filter(|tab| tab.pane_id == pane.public_id)
            .map(|tab| tab.public_id.clone())
            .collect::<Vec<_>>();
        let desired_order = desired
            .tabs
            .iter()
            .filter(|tab| tab.pane_id == pane.public_id)
            .map(|tab| tab.public_id.clone())
            .collect::<Vec<_>>();
        if current_order != desired_order {
            changes.push(ResourceChange::SetTabOrder {
                pane_id: pane.public_id.clone(),
                tab_ids: desired_order,
            });
        }
    }

    if changes.is_empty()
        && let Some(force) = force_if_unchanged
    {
        changes.push(force);
    }
    anyhow::ensure!(!changes.is_empty(), "resource mutation produced no durable change");
    Ok(ResourcePatch { changes })
}
