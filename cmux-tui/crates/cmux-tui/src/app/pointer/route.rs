//! The rendered pointer frame: per-frame hit and pane routes, pointer route
//! identity, and the machine pointer context the replay path checks for
//! staleness.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use cmux_tui_core::{PaneId, Rect, SurfaceId, SurfaceKind, TerminalPointerSnapshot, WorkspaceId};
use crossterm::event::MouseEvent;
use ghostty_vt::TerminalPointerSemanticSnapshot;

use crate::app::layout::{Hit, OmnibarHit, RailKind};
use crate::app::menu::{MenuItem, menu_scrollbar_track};
use crate::app::overlays::PromptTarget;
use crate::app::pointer::{
    MenuPointerRegion, PairingPointerRegion, PaneContentGeneration, PanePointerRegion,
    PromptPointerRegion,
};
use crate::machine::{
    MachineKey, MachineSnapshot, ManagedMachineDescriptor, ProviderPresentation,
    WorkspaceCreationPolicy,
};

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::app) struct RenderedMenuLevel {
    pub(in crate::app) rect: Rect,
    pub(in crate::app) scroll_offset: usize,
    pub(in crate::app) items: Arc<[MenuItem]>,
    pub(in crate::app) resources: Arc<[Option<MenuActionResource>]>,
}

impl RenderedMenuLevel {
    pub(in crate::app) fn scrollbar_track(&self) -> Option<Rect> {
        menu_scrollbar_track(self.rect, self.items.len())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::app) enum MenuActionResource {
    Surface(SurfaceId),
    StatusMessage(String),
    MachineCreationSource(String),
    MachineConnectionTarget(String),
    SidebarProfile(String),
    SidebarView { profile: String, view: String },
    ManagedWorkspace { machine: MachineKey, id: String, version: u64 },
    ProviderScope { machine: Option<MachineKey>, id: String },
    ProviderAction { machine: Option<MachineKey>, id: String },
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::app) struct MachinePointerContext {
    pub(in crate::app) snapshot: MachineSnapshot,
    pub(in crate::app) provider: Option<ProviderPresentation>,
    pub(in crate::app) workspace_creation: Option<WorkspaceCreationPolicy>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::app) struct MachinePointerTarget {
    pub(in crate::app) context: Arc<MachinePointerContext>,
    pub(in crate::app) machine: MachineKey,
    pub(in crate::app) managed: Option<ManagedMachineDescriptor>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::app) enum PointerHitIdentity {
    MachineContext(Arc<MachinePointerContext>),
    Machine(MachinePointerTarget),
    RecoverableWorkspace(String),
    SidebarFile(PathBuf),
    SidebarFilter(PathBuf),
    NewScreen(WorkspaceId),
    Tab(SurfaceId),
}

#[derive(Clone, Debug, PartialEq)]
pub(in crate::app) struct RenderedHitRoute {
    pub(in crate::app) rect: Rect,
    pub(in crate::app) hit: Hit,
    pub(in crate::app) identity: Option<Arc<PointerHitIdentity>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::app) struct RenderedPaneRoute {
    pub(in crate::app) pane: PaneId,
    pub(in crate::app) surface: SurfaceId,
    pub(in crate::app) kind: Option<SurfaceKind>,
    pub(in crate::app) rect: Rect,
    pub(in crate::app) bar: Option<Rect>,
    pub(in crate::app) omnibar: Option<Rect>,
    pub(in crate::app) omnibar_source_x: u16,
    pub(in crate::app) content: Rect,
    pub(in crate::app) content_source_x: u16,
    pub(in crate::app) track: Option<Rect>,
    pub(in crate::app) terminal_input: Option<Rect>,
}

#[derive(Clone, Debug, PartialEq)]
pub(in crate::app) enum PointerRouteIdentity {
    Pairing {
        request: u64,
        rect: Rect,
        approve: Rect,
        deny: Rect,
        region: PairingPointerRegion,
    },
    Prompt {
        target: PromptTarget,
        rect: Rect,
        input: Rect,
        clear: Rect,
        ok: Rect,
        cancel: Rect,
        region: PromptPointerRegion,
    },
    Menu {
        levels: Arc<[RenderedMenuLevel]>,
        region: MenuPointerRegion,
        resource: Option<MenuActionResource>,
    },
    Omnibar {
        pane: RenderedPaneRoute,
        rect: Rect,
        hit: OmnibarHit,
        column: u16,
        row: u16,
    },
    SidebarPlugin {
        rect: Rect,
        surface: Option<SurfaceId>,
        column: u16,
        row: u16,
    },
    Rail {
        kind: RailKind,
        rect: Rect,
        column: u16,
        row: u16,
    },
    Hit {
        rect: Rect,
        hit: Hit,
        identity: Option<Arc<PointerHitIdentity>>,
        column: u16,
        row: u16,
    },
    Pane {
        pane: RenderedPaneRoute,
        region: PanePointerRegion,
    },
    Outside,
}

impl PointerRouteIdentity {
    pub(in crate::app) fn browser_content_generation(&self) -> Option<(SurfaceId, Option<u64>)> {
        match self {
            Self::Pane {
                pane,
                region: PanePointerRegion::BrowserCell { content_generation, .. },
            } => Some((pane.surface, *content_generation)),
            _ => None,
        }
    }

    pub(in crate::app) fn terminal_pointer_snapshot(
        &self,
    ) -> Option<(SurfaceId, Rect, Option<TerminalPointerSnapshot>)> {
        match self {
            Self::Pane {
                pane,
                region: PanePointerRegion::TerminalCell { semantics, content_generation, .. },
            } => Some((
                pane.surface,
                pane.terminal_input?,
                semantics.zip(*content_generation).map(|(semantics, content_generation)| {
                    TerminalPointerSnapshot { semantics, content_generation }
                }),
            )),
            _ => None,
        }
    }

    /// A press that opens the cmux-owned context menu never enters the pane's
    /// application, so the surface's content generation and encoder semantics
    /// are not part of that press's route identity. Only the geometry (which
    /// pane, which region) decides where the menu opens.
    pub(in crate::app) fn normalized_for_cmux_menu(mut self) -> Self {
        if let Self::Pane { region, .. } = &mut self {
            match region {
                PanePointerRegion::TerminalCell { semantics, content_generation, .. } => {
                    *semantics = None;
                    *content_generation = None;
                }
                PanePointerRegion::BrowserCell { content_generation, .. } => {
                    *content_generation = None;
                }
                PanePointerRegion::ContentPadding | PanePointerRegion::Chrome => {}
            }
        }
        self
    }
}

#[derive(Clone, Default)]
pub(in crate::app) struct RenderedPointerFrame {
    pub(in crate::app) pairing: Option<(u64, Rect, Rect, Rect)>,
    pub(in crate::app) prompt: Option<(PromptTarget, Rect, Rect, Rect, Rect, Rect)>,
    pub(in crate::app) menu: Option<Arc<[RenderedMenuLevel]>>,
    pub(in crate::app) omnibar: Option<(PaneId, SurfaceId)>,
    pub(in crate::app) sidebar_plugin: Option<(Rect, Option<SurfaceId>)>,
    pub(in crate::app) machine_rail: Option<Rect>,
    pub(in crate::app) workspace_rail: Option<Rect>,
    pub(in crate::app) tabs_rail: Option<Rect>,
    pub(in crate::app) projection_rails: Arc<[(RailKind, Rect)]>,
    pub(in crate::app) hits: Arc<[RenderedHitRoute]>,
    pub(in crate::app) panes: Arc<[RenderedPaneRoute]>,
    pub(in crate::app) terminal_pointer_semantics:
        Arc<HashMap<SurfaceId, TerminalPointerSemanticSnapshot>>,
    pub(in crate::app) pane_content_generations: Arc<HashMap<SurfaceId, PaneContentGeneration>>,
    pub(in crate::app) machine_context: Option<Arc<MachinePointerContext>>,
    pub(in crate::app) pointer_map_generation: u64,
}

impl RenderedPointerFrame {
    pub(in crate::app) fn route_for_mouse(&self, mouse: &MouseEvent) -> PointerRouteIdentity {
        let (x, y) = (mouse.column, mouse.row);
        if let Some((request, rect, approve, deny)) = self.pairing {
            let region = if approve.contains(x, y) {
                PairingPointerRegion::Approve
            } else if deny.contains(x, y) {
                PairingPointerRegion::Deny
            } else if rect.contains(x, y) {
                PairingPointerRegion::Dialog
            } else {
                PairingPointerRegion::Outside
            };
            return PointerRouteIdentity::Pairing { request, rect, approve, deny, region };
        }
        if let Some((target, rect, input, clear, ok, cancel)) = self.prompt {
            let region = if ok.contains(x, y) {
                PromptPointerRegion::Ok
            } else if clear.contains(x, y) {
                PromptPointerRegion::Clear
            } else if input.contains(x, y) {
                PromptPointerRegion::Input
            } else if cancel.contains(x, y) {
                PromptPointerRegion::Cancel
            } else if rect.contains(x, y) {
                PromptPointerRegion::Dialog
            } else {
                PromptPointerRegion::Outside
            };
            return PointerRouteIdentity::Prompt { target, rect, input, clear, ok, cancel, region };
        }
        if let Some(levels) = &self.menu {
            let (region, resource) = levels
                .iter()
                .enumerate()
                .rev()
                .find(|(_, level)| level.rect.contains(x, y))
                .map_or((MenuPointerRegion::Outside, None), |(depth, level)| {
                    if level.scrollbar_track().is_some_and(|track| track.contains(x, y)) {
                        return (MenuPointerRegion::Scrollbar { depth }, None);
                    }
                    let right = level.rect.x + level.rect.width.saturating_sub(1);
                    let bottom = level.rect.y + level.rect.height.saturating_sub(1);
                    if x == level.rect.x || y == level.rect.y || x == right || y == bottom {
                        return (MenuPointerRegion::Chrome { depth }, None);
                    }
                    let index = level.scroll_offset + (y - level.rect.y - 1) as usize;
                    level.items.get(index).filter(|item| item.selectable()).map_or(
                        (MenuPointerRegion::Chrome { depth }, None),
                        |_| {
                            (
                                MenuPointerRegion::Item { depth, index },
                                level.resources.get(index).cloned().flatten(),
                            )
                        },
                    )
                });
            return PointerRouteIdentity::Menu { levels: levels.clone(), region, resource };
        }
        for pane in self.panes.iter() {
            let Some(rect) = pane.omnibar else { continue };
            if pane.kind != Some(SurfaceKind::Browser) {
                continue;
            }
            let editing = self.omnibar.is_some_and(|(editing_pane, surface)| {
                editing_pane == pane.pane && surface == pane.surface
            });
            if let Some(hit) = crate::ui::omnibar::hit(rect, pane.omnibar_source_x, x, y, editing) {
                return PointerRouteIdentity::Omnibar {
                    pane: *pane,
                    rect,
                    hit,
                    column: x.saturating_sub(rect.x),
                    row: y.saturating_sub(rect.y),
                };
            }
        }
        if let Some((rect, surface)) = self.sidebar_plugin.filter(|(rect, _)| rect.contains(x, y)) {
            return PointerRouteIdentity::SidebarPlugin {
                rect,
                surface,
                column: x.saturating_sub(rect.x),
                row: y.saturating_sub(rect.y),
            };
        }
        if let Some(route) = self.hits.iter().find(|route| route.rect.contains(x, y)) {
            return PointerRouteIdentity::Hit {
                rect: route.rect,
                hit: route.hit,
                identity: route.identity.clone(),
                column: x.saturating_sub(route.rect.x),
                row: y.saturating_sub(route.rect.y),
            };
        }
        for (kind, rect) in [
            (RailKind::Machine, self.machine_rail),
            (RailKind::Workspace, self.workspace_rail),
            (RailKind::Tabs, self.tabs_rail),
        ] {
            if let Some(rect) = rect.filter(|rect| rect.contains(x, y)) {
                return PointerRouteIdentity::Rail {
                    kind,
                    rect,
                    column: x.saturating_sub(rect.x),
                    row: y.saturating_sub(rect.y),
                };
            }
        }
        if let Some((kind, rect)) =
            self.projection_rails.iter().copied().find(|(_, rect)| rect.contains(x, y))
            && !self.panes.iter().any(|pane| pane.content.contains(x, y))
        {
            return PointerRouteIdentity::Rail {
                kind,
                rect,
                column: x.saturating_sub(rect.x),
                row: y.saturating_sub(rect.y),
            };
        }
        if let Some(pane) = self.panes.iter().find(|pane| pane.rect.contains(x, y)) {
            let region = if pane.content.contains(x, y) {
                match pane.kind {
                    Some(SurfaceKind::Browser) => PanePointerRegion::BrowserCell {
                        column: pane
                            .content_source_x
                            .saturating_add(x.saturating_sub(pane.content.x)),
                        row: y.saturating_sub(pane.content.y),
                        content_generation: self
                            .pane_content_generations
                            .get(&pane.surface)
                            .and_then(|generation| match generation {
                                PaneContentGeneration::Browser(generation) => Some(*generation),
                                PaneContentGeneration::Terminal(_) => None,
                            }),
                    },
                    Some(SurfaceKind::Pty)
                        if pane.terminal_input.is_some_and(|rect| rect.contains(x, y)) =>
                    {
                        let input = pane.terminal_input.unwrap();
                        let semantics = self.terminal_pointer_semantics.get(&pane.surface).copied();
                        PanePointerRegion::TerminalCell {
                            column: pane.content_source_x.saturating_add(x.saturating_sub(input.x)),
                            row: y.saturating_sub(input.y),
                            semantics,
                            content_generation: self
                                .pane_content_generations
                                .get(&pane.surface)
                                .and_then(|generation| match generation {
                                    PaneContentGeneration::Terminal(generation) => {
                                        Some(*generation)
                                    }
                                    PaneContentGeneration::Browser(_) => None,
                                }),
                        }
                    }
                    Some(SurfaceKind::Pty) | None => PanePointerRegion::ContentPadding,
                }
            } else {
                PanePointerRegion::Chrome
            };
            return PointerRouteIdentity::Pane { pane: *pane, region };
        }
        PointerRouteIdentity::Outside
    }
}
