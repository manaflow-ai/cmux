//! Committing the rendered pointer frame: pointer hit identity, menu action
//! resources, rendered menu and pane routes, and the frame commit that the
//! replay path checks against.

use std::sync::Arc;

use crate::app::layout::{Hit, PaneArea, RailKind, SidebarActionTarget};
use crate::app::pointer::route::{
    MachinePointerContext, MachinePointerTarget, MenuActionResource, PointerHitIdentity,
    RenderedHitRoute, RenderedMenuLevel, RenderedPaneRoute, RenderedPointerFrame,
};
use crate::app::{App, MenuAction, RenderAction};
use crate::sidebar_projection::ProjectionTarget;

impl App {
    pub(super) fn mark_pointer_route_for_rebuild(&mut self, action: RenderAction) {
        self.pointer_route_phase = self.pointer_route_phase.with_action(action);
    }

    fn refresh_machine_pointer_context(&mut self) -> Option<Arc<MachinePointerContext>> {
        let Some(ui) = self.machine_ui.as_ref() else {
            self.machine_pointer_context_cache = None;
            return None;
        };
        let matches_live = self.machine_pointer_context_cache.as_ref().is_some_and(|context| {
            context.snapshot == ui.snapshot
                && context.provider == ui.provider
                && context.workspace_creation == ui.workspace_creation_policy()
        });
        if !matches_live {
            self.machine_pointer_context_cache = Some(Arc::new(MachinePointerContext {
                snapshot: ui.snapshot.clone(),
                provider: ui.provider.clone(),
                workspace_creation: ui.workspace_creation_policy(),
            }));
        }
        self.machine_pointer_context_cache.clone()
    }

    fn pointer_hit_identity(
        &self,
        hit: Hit,
        machine_context: Option<&Arc<MachinePointerContext>>,
    ) -> Option<PointerHitIdentity> {
        match hit {
            Hit::NewVm
            | Hit::ConnectMachine
            | Hit::CreateWorkspace { .. }
            | Hit::SidebarAction { action: SidebarActionTarget::CreateWorkspace(_), .. } => {
                machine_context.cloned().map(PointerHitIdentity::MachineContext)
            }
            Hit::Machine { key, .. } => machine_context.cloned().map(|context| {
                PointerHitIdentity::Machine(MachinePointerTarget {
                    context,
                    machine: key,
                    managed: self
                        .machine_ui
                        .as_ref()
                        .and_then(|ui| ui.managed_machine(key))
                        .cloned(),
                })
            }),
            Hit::RecoverableWorkspace { index } => self
                .machine_ui
                .as_ref()
                .and_then(|ui| ui.recoverable_workspaces().get(index).copied())
                .map(|workspace| PointerHitIdentity::RecoverableWorkspace(workspace.id.clone())),
            Hit::SidebarFile { index } => self
                .sidebar_files
                .visible_entry(index)
                .map(|entry| PointerHitIdentity::SidebarFile(entry.path.clone())),
            Hit::SidebarFilterInput => Some(PointerHitIdentity::SidebarFilter(
                self.sidebar_files.current_dir().to_path_buf(),
            )),
            Hit::NewScreen => self
                .tree
                .active_workspace()
                .map(|workspace| PointerHitIdentity::NewScreen(workspace.id)),
            Hit::Tab { pane, index } => self
                .tree
                .pane(pane)
                .and_then(|pane| pane.tabs.get(index))
                .map(|tab| PointerHitIdentity::Tab(tab.surface)),
            Hit::SidebarTab { surface, .. } => Some(PointerHitIdentity::Tab(surface)),
            Hit::ProjectionRow { target: ProjectionTarget::Surface { surface, .. }, .. } => {
                Some(PointerHitIdentity::Tab(surface))
            }
            Hit::Workspace { .. }
            | Hit::ProjectionRow { .. }
            | Hit::ProjectionToggle { .. }
            | Hit::RailPad(_)
            | Hit::SidebarAction { .. }
            | Hit::ScreenEntry { .. }
            | Hit::StatusMessage
            | Hit::CopyStatusMessage
            | Hit::NewTab { .. }
            | Hit::Clients { .. }
            | Hit::Scrollbar { .. }
            | Hit::HorizontalScrollbar { .. }
            | Hit::WorkspaceScrollbar { .. }
            | Hit::RailResize(_)
            | Hit::PaneResize { .. }
            | Hit::TabScroll { .. } => None,
        }
    }

    pub(super) fn menu_action_resource(&self, action: MenuAction) -> Option<MenuActionResource> {
        match action {
            MenuAction::RenameSurface(surface) | MenuAction::MoveTabToWorkspace { surface, .. } => {
                Some(MenuActionResource::Surface(surface))
            }
            MenuAction::CopyStatusMessage => {
                self.status_message.clone().map(MenuActionResource::StatusMessage)
            }
            MenuAction::BrowserBack(pane)
            | MenuAction::BrowserForward(pane)
            | MenuAction::BrowserReload(pane)
            | MenuAction::BrowserEditUrl(pane)
            | MenuAction::BrowserCopyUrl(pane)
            | MenuAction::BrowserActivate(pane)
            | MenuAction::RenameTab(pane)
            | MenuAction::CopyTabId(pane)
            | MenuAction::CloseTab(pane) => self
                .tree
                .pane(pane)
                .and_then(|pane| pane.active_surface())
                .map(MenuActionResource::Surface),
            MenuAction::RestoreManagedWorkspace(index)
            | MenuAction::PurgeManagedWorkspace(index) => {
                let machine = self.machine_ui.as_ref()?.snapshot.active?;
                self.machine_ui.as_ref()?.recoverable_workspaces().get(index).map(|workspace| {
                    MenuActionResource::ManagedWorkspace {
                        machine,
                        id: workspace.id.clone(),
                        version: workspace.version,
                    }
                })
            }
            MenuAction::SelectProviderScope(index) => {
                let ui = self.machine_ui.as_ref()?;
                ui.provider.as_ref()?.scopes.get(index).map(|scope| {
                    MenuActionResource::ProviderScope {
                        machine: ui.snapshot.active,
                        id: scope.id.clone(),
                    }
                })
            }
            MenuAction::InvokeProviderAction(index) => {
                let ui = self.machine_ui.as_ref()?;
                ui.provider.as_ref()?.actions.get(index).map(|action| {
                    MenuActionResource::ProviderAction {
                        machine: ui.snapshot.active,
                        id: action.id.clone(),
                    }
                })
            }
            MenuAction::CreateMachineFrom(index) => self
                .machine_ui
                .as_ref()?
                .creation_sources
                .get(index)
                .map(|source| MenuActionResource::MachineCreationSource(source.id.clone())),
            MenuAction::ConnectMachineTarget(index) => {
                self.machine_ui.as_ref()?.connection_targets.get(index).map(|target| {
                    MenuActionResource::MachineConnectionTarget(target.target.clone())
                })
            }
            MenuAction::ActivateSidebarProfile(index) => self
                .config
                .sidebar
                .profiles
                .get(index)
                .map(|profile| MenuActionResource::SidebarProfile(profile.id.clone())),
            MenuAction::SetSidebarViewVisible { view, .. } => {
                self.config.sidebar.views.get(view).map(|view| MenuActionResource::SidebarView {
                    profile: self.config.sidebar.active_profile.clone(),
                    view: view.id.clone(),
                })
            }
            _ => None,
        }
    }

    fn rendered_menu_snapshot(&self, reuse_owners: bool) -> Option<Arc<[RenderedMenuLevel]>> {
        let menu = self.menu.as_ref()?;
        if reuse_owners
            && let Some(rendered) = self.rendered_pointer_frame.menu.as_ref()
            && rendered.len() == menu.levels.len()
            && rendered.iter().zip(&menu.levels).all(|(rendered, live)| {
                rendered.rect == live.rect
                    && rendered.scroll_offset == live.scroll_offset
                    && Arc::ptr_eq(&rendered.items, &live.items)
            })
        {
            return Some(rendered.clone());
        }
        Some(Arc::from(
            menu.levels
                .iter()
                .map(|level| RenderedMenuLevel {
                    rect: level.rect,
                    scroll_offset: level.scroll_offset,
                    items: level.items.clone(),
                    resources: level
                        .items
                        .iter()
                        .map(|item| {
                            item.action().and_then(|action| {
                                menu.captured_resource(action)
                                    .unwrap_or_else(|| self.menu_action_resource(action))
                            })
                        })
                        .collect::<Vec<_>>()
                        .into(),
                })
                .collect::<Vec<_>>(),
        ))
    }

    fn rendered_pane_route(&self, area: &PaneArea) -> RenderedPaneRoute {
        RenderedPaneRoute {
            pane: area.pane,
            surface: area.surface,
            kind: self.surface_kind(area.surface),
            rect: area.rect,
            bar: area.bar,
            omnibar: area.omnibar,
            omnibar_source_x: area.omnibar_source_x(),
            content: area.content,
            content_source_x: area.content_source_x(),
            track: area.track,
            terminal_input: self.terminal_input_rect(area),
        }
    }

    pub(super) fn commit_rendered_pointer_frame(&mut self) {
        self.commit_rendered_pointer_frame_for(RenderAction::Draw);
    }

    pub(super) fn commit_rendered_pointer_frame_for(&mut self, action: RenderAction) {
        if self.outer_size.0 == 0 || self.outer_size.1 == 0 {
            self.rendered_pointer_frame = RenderedPointerFrame::default();
            return;
        }
        let pairing = self
            .pairing_dialog
            .as_ref()
            .map(|dialog| (dialog.challenge.id, dialog.rect, dialog.approve, dialog.deny));
        let prompt = self.prompt.as_ref().map(|prompt| {
            (prompt.target, prompt.rect, prompt.input_rect, prompt.clear, prompt.ok, prompt.cancel)
        });
        let omnibar = self.omnibar.as_ref().map(|state| (state.pane, state.surface));
        let sidebar_plugin = (self.config.sidebar.plugin.is_some() && self.sidebar_visible)
            .then(|| (self.sidebar_plugin_rect(), self.sidebar_plugin_surface));
        let machine_rail = self.sidebar_layout.machine;
        let workspace_rail = self.sidebar_layout.workspace;
        let tabs_rail = self.sidebar_layout.tabs;
        let projection_rails = self
            .sidebar_layout
            .ordered
            .iter()
            .filter_map(|placement| match placement.kind {
                RailKind::Projection(_) => Some((placement.kind, placement.rect)),
                _ => None,
            })
            .collect::<Vec<_>>()
            .into();
        let pointer_map_generation = self.session.pointer_map_generation();
        let reuse_owners = action == RenderAction::Paint
            && self.rendered_pointer_frame.pointer_map_generation == pointer_map_generation;
        let machine_context = if reuse_owners {
            self.rendered_pointer_frame.machine_context.clone()
        } else {
            self.refresh_machine_pointer_context()
        };
        let menu = self.rendered_menu_snapshot(reuse_owners);
        let panes_match = self.rendered_pointer_frame.panes.len() == self.pane_areas.len()
            && self
                .rendered_pointer_frame
                .panes
                .iter()
                .zip(&self.pane_areas)
                .all(|(rendered, area)| *rendered == self.rendered_pane_route(area));
        let panes = if panes_match {
            self.rendered_pointer_frame.panes.clone()
        } else {
            self.pane_areas
                .iter()
                .map(|area| self.rendered_pane_route(area))
                .collect::<Vec<_>>()
                .into()
        };
        let hits_match = reuse_owners
            && self.rendered_pointer_frame.hits.len() == self.hits.len()
            && self
                .rendered_pointer_frame
                .hits
                .iter()
                .zip(&self.hits)
                .all(|(rendered, (rect, hit))| rendered.rect == *rect && rendered.hit == *hit);
        let hits = if hits_match {
            self.rendered_pointer_frame.hits.clone()
        } else {
            self.hits
                .iter()
                .enumerate()
                .map(|(index, (rect, hit))| {
                    let reused_identity = reuse_owners
                        .then(|| {
                            self.rendered_pointer_frame
                                .hits
                                .get(index)
                                .filter(|rendered| rendered.hit == *hit)
                                .and_then(|rendered| rendered.identity.clone())
                        })
                        .flatten();
                    RenderedHitRoute {
                        rect: *rect,
                        hit: *hit,
                        identity: reused_identity.or_else(|| {
                            self.pointer_hit_identity(*hit, machine_context.as_ref()).map(Arc::new)
                        }),
                    }
                })
                .collect::<Vec<_>>()
                .into()
        };
        let terminal_pointer_semantics = if *self.rendered_pointer_frame.terminal_pointer_semantics
            == self.rendered_terminal_pointer_semantics
        {
            self.rendered_pointer_frame.terminal_pointer_semantics.clone()
        } else {
            Arc::new(self.rendered_terminal_pointer_semantics.clone())
        };
        let pane_content_generations = if *self.rendered_pointer_frame.pane_content_generations
            == self.rendered_pane_content_generations
        {
            self.rendered_pointer_frame.pane_content_generations.clone()
        } else {
            Arc::new(self.rendered_pane_content_generations.clone())
        };
        self.rendered_pointer_frame = RenderedPointerFrame {
            pairing,
            prompt,
            menu,
            omnibar,
            sidebar_plugin,
            machine_rail,
            workspace_rail,
            tabs_rail,
            projection_rails,
            hits,
            panes,
            terminal_pointer_semantics,
            pane_content_generations,
            machine_context,
            pointer_map_generation,
        };
    }

    pub(super) fn pairing_identity_matches_rendered_frame(&self) -> bool {
        self.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id)
            == self.rendered_pointer_frame.pairing.as_ref().map(|pairing| pairing.0)
    }
}
