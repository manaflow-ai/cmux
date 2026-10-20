//! Hosting of the search-everything index (`search-v1`,
//! crate::search_everything): created on the first terminal output or
//! query, stopped at shutdown.

use std::collections::HashMap;

use cmux_search::{Kind, NameDoc, Query, SearchResult, TargetContext};

use std::sync::Arc;
use std::sync::atomic::Ordering;

use super::Mux;
use crate::resource::TerminalPublicId;
use crate::search_everything::{ModelSnapshot, SearchEverything, SearchEverythingStats};
use crate::shell_history::FinishedCommand;
use crate::{Surface, SurfaceId};

impl Mux {
    /// The service, started on first use.
    pub(crate) fn search_everything_service(self: &Arc<Self>) -> &SearchEverything {
        self.search_everything.get_or_init(|| {
            SearchEverything::start(Arc::downgrade(self), self.search_index_directory())
        })
    }

    fn search_index_directory(&self) -> Option<std::path::PathBuf> {
        self.session_state_directory().map(|directory| directory.join("search").join("v1"))
    }

    /// Terminal `surface` had output: the PTY reader hot path, one set
    /// insert (and a channel send on the first output since the last read).
    pub(crate) fn note_search_output(self: &Arc<Self>, surface: SurfaceId) {
        if self.shutting_down.load(Ordering::Acquire) {
            return;
        }
        self.search_everything_service().note_output(surface);
    }

    pub(crate) fn note_search_commands(
        self: &Arc<Self>,
        terminal: &TerminalPublicId,
        commands: &[FinishedCommand],
    ) {
        if commands.is_empty() || self.shutting_down.load(Ordering::Acquire) {
            return;
        }
        self.search_everything_service().note_commands(terminal.to_string(), commands.to_vec());
    }

    /// The tree changed: resync names, context and focus, when the index
    /// runs (it starts on the first output or query, and syncs then).
    pub(crate) fn note_search_tree(&self) {
        if let Some(service) = self.search_everything.get() {
            service.note_tree();
        }
    }

    /// One ranked query over names and content. Without a workspace in
    /// `query`, the focused workspace ranks higher.
    pub fn search_everything(self: &Arc<Self>, query: &Query) -> SearchResult {
        let service = self.search_everything_service();
        if query.workspace_id.is_some() {
            return service.search(query);
        }
        let mut query = query.clone();
        query.workspace_id = self.focused_workspace_public_id();
        service.search(&query)
    }

    fn focused_workspace_public_id(&self) -> Option<String> {
        let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state
            .workspaces
            .get(state.active_workspace)
            .map(|workspace| workspace.public_id.to_string())
    }

    /// The user opened a hit that jumps to `target`.
    pub fn search_everything_opened(self: &Arc<Self>, target: &str) {
        self.search_everything_service().record_open(target, crate::history_ops::now_ms());
    }

    pub fn search_everything_stats(self: &Arc<Self>) -> SearchEverythingStats {
        self.search_everything_service().stats()
    }

    /// Stops the worker and saves the index (shutdown).
    pub(crate) fn stop_search_everything(&self) {
        if let Some(service) = self.search_everything.get() {
            service.stop();
        }
    }

    /// Names, ranking context and focus of the live tree: read under the
    /// state lock, then titles, folders and git branches after it is
    /// released (the search worker calls this, never a reader loop).
    pub(crate) fn search_model_snapshot(&self, now_ms: i64) -> ModelSnapshot {
        let decorations = self.tree_decorations();
        let groups: HashMap<&str, &str> = decorations
            .presentation
            .groups
            .iter()
            .map(|group| (group.id.as_str(), group.name.as_str()))
            .collect();
        let mut snapshot = ModelSnapshot::default();
        let mut tabs: Vec<(Arc<Surface>, String, TargetContext)> = Vec::new();
        {
            let state = self.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            for (workspace_index, workspace) in state.workspaces.iter().enumerate() {
                let workspace_id = workspace.public_id.to_string();
                let group = decorations
                    .presentation
                    .workspaces
                    .get(&workspace.key)
                    .and_then(|record| record.group.as_deref())
                    .and_then(|group| groups.get(group).copied())
                    .unwrap_or_default()
                    .to_owned();
                let base = TargetContext {
                    workspace_id: workspace_id.clone(),
                    workspace: workspace.name.clone(),
                    group: group.clone(),
                    ..TargetContext::default()
                };
                snapshot.names.push(NameDoc {
                    key: workspace_id.clone(),
                    kind: Kind::Workspace,
                    target: workspace_id.clone(),
                    title: workspace.name.clone(),
                    subtitle: group.clone(),
                    at_ms: now_ms,
                });
                snapshot.contexts.push((workspace_id.clone(), base.clone()));
                let focused_workspace = workspace_index == state.active_workspace;
                if focused_workspace {
                    snapshot.focus.push(workspace_id.clone());
                }
                for (screen_index, screen) in workspace.screens.iter().enumerate() {
                    let focused_screen =
                        focused_workspace && screen_index == workspace.active_screen;
                    let screen_id = screen.public_id.to_string();
                    if let Some(name) = screen.name.as_ref().filter(|name| !name.is_empty()) {
                        snapshot.names.push(NameDoc {
                            key: screen_id.clone(),
                            kind: Kind::Workspace,
                            target: screen_id.clone(),
                            title: name.clone(),
                            subtitle: workspace.name.clone(),
                            at_ms: now_ms,
                        });
                    }
                    if focused_screen {
                        snapshot.focus.push(screen_id);
                    }
                    for pane_id in screen.root.pane_ids_vec() {
                        let Some(pane) = state.panes.get(&pane_id) else { continue };
                        let focused_pane = focused_screen && pane_id == screen.active_pane;
                        let pane_public = pane.public_id.to_string();
                        let mut pane_context = base.clone();
                        if let Some(name) = pane.name.as_ref().filter(|name| !name.is_empty()) {
                            pane_context.title = name.clone();
                            snapshot.names.push(NameDoc {
                                key: pane_public.clone(),
                                kind: Kind::Pane,
                                target: pane_public.clone(),
                                title: name.clone(),
                                subtitle: workspace.name.clone(),
                                at_ms: now_ms,
                            });
                        }
                        snapshot.contexts.push((pane_public.clone(), pane_context));
                        if focused_pane {
                            snapshot.focus.push(pane_public);
                        }
                        for (tab_index, tab) in pane.tabs.iter().enumerate() {
                            let Some(surface) = state.surfaces.get(tab) else { continue };
                            let mut context = base.clone();
                            if let Some(directory) = decorations.directories.get(tab) {
                                context.cwd = directory.cwd.clone().unwrap_or_default();
                                context.branch = directory.git_branch.clone().unwrap_or_default();
                            }
                            if focused_pane && tab_index == pane.active_tab {
                                if let Some(identity) = surface.resource_identity() {
                                    snapshot.focus.push(identity.tab_id.to_string());
                                }
                                if let Some(terminal) = surface.terminal_public_id() {
                                    snapshot.focus.push(terminal.to_string());
                                }
                            }
                            tabs.push((surface.clone(), workspace.name.clone(), context));
                        }
                    }
                }
            }
        }
        for (surface, workspace, mut context) in tabs {
            let title =
                surface.name().filter(|name| !name.is_empty()).unwrap_or_else(|| surface.title());
            context.title = title.clone();
            if let Some(terminal) = surface.terminal_public_id() {
                snapshot.contexts.push((terminal.to_string(), context.clone()));
            }
            let Some(identity) = surface.resource_identity() else { continue };
            let tab_id = identity.tab_id.to_string();
            snapshot.contexts.push((tab_id.clone(), context));
            if title.is_empty() {
                continue;
            }
            snapshot.names.push(NameDoc {
                key: tab_id.clone(),
                kind: Kind::Tab,
                target: tab_id,
                title,
                subtitle: workspace,
                at_ms: now_ms,
            });
        }
        snapshot
    }
}
