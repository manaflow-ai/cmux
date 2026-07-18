//! Connection-owned, presentation-local state.
//!
//! A socket connection may represent several windows. Each window gets a
//! presentation whose navigation and viewport placeholders are independent
//! from canonical mux topology and from the connection's other windows.

use std::collections::BTreeMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::{
    PaneId, PaneUuid, PresentationId, ScreenId, ScreenUuid, State, SurfaceId, SurfaceUuid,
    WorkspaceId, WorkspaceUuid,
};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresentationView {
    /// Protocol-v7 numeric workspace handle.
    #[serde(default)]
    pub workspace: Option<WorkspaceId>,
    #[serde(default)]
    pub workspace_uuid: Option<WorkspaceUuid>,
    /// Protocol-v7 numeric screen handle.
    #[serde(default)]
    pub screen: Option<ScreenId>,
    #[serde(default)]
    pub screen_uuid: Option<ScreenUuid>,
    /// Protocol-v7 numeric pane handle.
    #[serde(default)]
    pub pane: Option<PaneId>,
    #[serde(default)]
    pub pane_uuid: Option<PaneUuid>,
    /// Protocol-v7 called the selected surface a `tab`.
    #[serde(default)]
    pub tab: Option<SurfaceId>,
    #[serde(default)]
    pub surface_uuid: Option<SurfaceUuid>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresentationZoom {
    /// Placeholder for presentation-local pane zoom. It does not mutate the
    /// canonical screen's current legacy zoom state.
    #[serde(default)]
    pub pane: Option<PaneId>,
    #[serde(default)]
    pub pane_uuid: Option<PaneUuid>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresentationScroll {
    /// Placeholder for a future presentation-local viewport binding.
    #[serde(default)]
    pub surface: Option<SurfaceId>,
    #[serde(default)]
    pub surface_uuid: Option<SurfaceUuid>,
    #[serde(default)]
    pub offset: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Presentation {
    pub presentation_id: PresentationId,
    pub generation: u64,
    pub client: u64,
    pub view: PresentationView,
    pub zoom: PresentationZoom,
    pub scroll: PresentationScroll,
}

// The Swift shell keeps one stable input-authority presentation per terminal.
// Leave bounded headroom for 1,000-workspace sessions, multiple windows, and
// reconnect overlap without weakening the renderer-specific admission caps.
const MAX_PRESENTATIONS_PER_CLIENT: usize = 4_096;
const MAX_PRESENTATIONS_GLOBAL: usize = 16_384;

#[derive(Debug, Clone, Copy)]
struct PresentationLimits {
    per_client: usize,
    global: usize,
}

impl Default for PresentationLimits {
    fn default() -> Self {
        Self { per_client: MAX_PRESENTATIONS_PER_CLIENT, global: MAX_PRESENTATIONS_GLOBAL }
    }
}

pub(crate) struct PresentationRegistry {
    state: Mutex<PresentationRegistryState>,
    limits: PresentationLimits,
}

#[derive(Default)]
struct PresentationRegistryState {
    presentations: BTreeMap<PresentationId, Presentation>,
    client_counts: BTreeMap<u64, usize>,
}

impl PresentationRegistry {
    pub(crate) fn new() -> Self {
        Self { state: Mutex::new(PresentationRegistryState::default()), limits: Default::default() }
    }

    #[cfg(test)]
    fn new_with_limits(per_client: usize, global: usize) -> Self {
        Self {
            state: Mutex::new(PresentationRegistryState::default()),
            limits: PresentationLimits { per_client, global },
        }
    }

    pub(crate) fn open(
        &self,
        client: u64,
        view: PresentationView,
        zoom: PresentationZoom,
        scroll: PresentationScroll,
    ) -> anyhow::Result<Presentation> {
        let mut state = self.state.lock().unwrap();
        if state.presentations.len() >= self.limits.global {
            anyhow::bail!("global presentation limit reached (maximum {})", self.limits.global);
        }
        let client_count = state.client_counts.get(&client).copied().unwrap_or(0);
        if client_count >= self.limits.per_client {
            anyhow::bail!(
                "presentation limit reached for client {client} (maximum {})",
                self.limits.per_client
            );
        }
        let presentation_id = loop {
            let candidate = PresentationId::new();
            if !state.presentations.contains_key(&candidate) {
                break candidate;
            }
        };
        let presentation =
            Presentation { presentation_id, generation: 1, client, view, zoom, scroll };
        state.presentations.insert(presentation_id, presentation.clone());
        state.client_counts.insert(client, client_count + 1);
        Ok(presentation)
    }

    pub(crate) fn get_for_client(
        &self,
        client: u64,
        presentation_id: PresentationId,
    ) -> anyhow::Result<Presentation> {
        let state = self.state.lock().unwrap();
        let presentation = state
            .presentations
            .get(&presentation_id)
            .ok_or_else(|| anyhow::anyhow!("unknown presentation {presentation_id}"))?;
        if presentation.client != client {
            anyhow::bail!("presentation {presentation_id} is owned by another client");
        }
        Ok(presentation.clone())
    }

    pub(crate) fn update(
        &self,
        client: u64,
        presentation_id: PresentationId,
        expected_generation: u64,
        view: Option<PresentationView>,
        zoom: Option<PresentationZoom>,
        scroll: Option<PresentationScroll>,
    ) -> anyhow::Result<Presentation> {
        let mut state = self.state.lock().unwrap();
        let presentation = state
            .presentations
            .get_mut(&presentation_id)
            .ok_or_else(|| anyhow::anyhow!("unknown presentation {presentation_id}"))?;
        if presentation.client != client {
            anyhow::bail!("presentation {presentation_id} is owned by another client");
        }
        if presentation.generation != expected_generation {
            anyhow::bail!(
                "stale presentation generation {expected_generation}; current generation is {}",
                presentation.generation
            );
        }
        let next_view = view.unwrap_or_else(|| presentation.view.clone());
        let next_zoom = zoom.unwrap_or_else(|| presentation.zoom.clone());
        let next_scroll = scroll.unwrap_or_else(|| presentation.scroll.clone());
        if presentation.view == next_view
            && presentation.zoom == next_zoom
            && presentation.scroll == next_scroll
        {
            return Ok(presentation.clone());
        }
        presentation.generation = presentation
            .generation
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("presentation generation exhausted"))?;
        presentation.view = next_view;
        presentation.zoom = next_zoom;
        presentation.scroll = next_scroll;
        Ok(presentation.clone())
    }

    pub(crate) fn close(&self, client: u64, presentation_id: PresentationId) -> anyhow::Result<()> {
        let mut state = self.state.lock().unwrap();
        let presentation = state
            .presentations
            .get(&presentation_id)
            .ok_or_else(|| anyhow::anyhow!("unknown presentation {presentation_id}"))?;
        if presentation.client != client {
            anyhow::bail!("presentation {presentation_id} is owned by another client");
        }
        state.presentations.remove(&presentation_id);
        Self::decrement_client_count(&mut state, client, 1);
        Ok(())
    }

    pub(crate) fn list_for_client(&self, client: u64) -> Vec<Presentation> {
        self.state
            .lock()
            .unwrap()
            .presentations
            .values()
            .filter(|presentation| presentation.client == client)
            .cloned()
            .collect()
    }

    pub(crate) fn remove_client(&self, client: u64) -> Vec<PresentationId> {
        let mut state = self.state.lock().unwrap();
        let removed = state
            .presentations
            .values()
            .filter(|presentation| presentation.client == client)
            .map(|presentation| presentation.presentation_id)
            .collect::<Vec<_>>();
        for presentation_id in &removed {
            state.presentations.remove(presentation_id);
        }
        state.client_counts.remove(&client);
        removed
    }

    pub(crate) fn remove_surface(&self, surface_uuid: SurfaceUuid) -> Vec<PresentationId> {
        let mut state = self.state.lock().unwrap();
        let removed = state
            .presentations
            .values()
            .filter(|presentation| presentation.view.surface_uuid == Some(surface_uuid))
            .map(|presentation| (presentation.presentation_id, presentation.client))
            .collect::<Vec<_>>();
        for (presentation_id, client) in &removed {
            state.presentations.remove(presentation_id);
            Self::decrement_client_count(&mut state, *client, 1);
        }
        removed.into_iter().map(|(presentation_id, _)| presentation_id).collect()
    }

    fn decrement_client_count(state: &mut PresentationRegistryState, client: u64, count: usize) {
        let remove = state.client_counts.get_mut(&client).is_some_and(|current| {
            *current = current.saturating_sub(count);
            *current == 0
        });
        if remove {
            state.client_counts.remove(&client);
        }
    }
}

/// Resolve protocol-v7 numeric handles and protocol-v8 UUIDs to one canonical
/// representation. Responses carry both forms so either generation of client
/// can round-trip its presentation state. Supplying both forms is accepted
/// only when they identify the same live entity.
pub(crate) fn normalize_presentation(
    state: &State,
    view: PresentationView,
    zoom: PresentationZoom,
    scroll: PresentationScroll,
) -> anyhow::Result<(PresentationView, PresentationZoom, PresentationScroll)> {
    let workspace = resolve_identity(
        "workspace",
        view.workspace,
        view.workspace_uuid,
        |id| state.workspaces.iter().any(|workspace| workspace.id == id),
        |uuid| state.workspace_id_by_uuid(uuid),
    )?;
    let screen = resolve_identity(
        "screen",
        view.screen,
        view.screen_uuid,
        |id| {
            state
                .workspaces
                .iter()
                .any(|workspace| workspace.screens.iter().any(|screen| screen.id == id))
        },
        |uuid| state.screen_id_by_uuid(uuid),
    )?;
    let pane = resolve_identity(
        "pane",
        view.pane,
        view.pane_uuid,
        |id| state.panes.contains_key(&id),
        |uuid| state.pane_id_by_uuid(uuid),
    )?;
    let surface = resolve_identity(
        "surface",
        view.tab,
        view.surface_uuid,
        |id| state.surfaces.contains_key(&id),
        |uuid| state.surface_id_by_uuid(uuid),
    )?;

    if let (Some(workspace), Some(screen)) = (workspace, screen)
        && workspace_of_screen(state, screen) != Some(workspace)
    {
        anyhow::bail!("presentation screen is outside its workspace");
    }
    if let (Some(screen), Some(pane)) = (screen, pane)
        && screen_of_pane(state, pane) != Some(screen)
    {
        anyhow::bail!("presentation pane is outside its screen");
    }
    if let (Some(workspace), Some(pane)) = (workspace, pane)
        && workspace_of_pane(state, pane) != Some(workspace)
    {
        anyhow::bail!("presentation pane is outside its workspace");
    }
    if let (Some(pane), Some(surface)) = (pane, surface)
        && state.pane_of(surface) != Some(pane)
    {
        anyhow::bail!("presentation surface is outside its pane");
    }
    if let (Some(screen), Some(surface)) = (screen, surface)
        && screen_of_surface(state, surface) != Some(screen)
    {
        anyhow::bail!("presentation surface is outside its screen");
    }
    if let (Some(workspace), Some(surface)) = (workspace, surface)
        && workspace_of_surface(state, surface) != Some(workspace)
    {
        anyhow::bail!("presentation surface is outside its workspace");
    }

    let anchor_workspace = workspace
        .or_else(|| screen.and_then(|screen| workspace_of_screen(state, screen)))
        .or_else(|| pane.and_then(|pane| workspace_of_pane(state, pane)))
        .or_else(|| surface.and_then(|surface| workspace_of_surface(state, surface)));
    let anchor_screen = screen
        .or_else(|| pane.and_then(|pane| screen_of_pane(state, pane)))
        .or_else(|| surface.and_then(|surface| screen_of_surface(state, surface)));

    let zoom_pane = resolve_identity(
        "zoom pane",
        zoom.pane,
        zoom.pane_uuid,
        |id| state.panes.contains_key(&id),
        |uuid| state.pane_id_by_uuid(uuid),
    )?;
    if let (Some(anchor), Some(zoom_pane)) = (anchor_workspace, zoom_pane)
        && workspace_of_pane(state, zoom_pane) != Some(anchor)
    {
        anyhow::bail!("presentation zoom pane is outside its workspace");
    }
    if let (Some(anchor), Some(zoom_pane)) = (anchor_screen, zoom_pane)
        && screen_of_pane(state, zoom_pane) != Some(anchor)
    {
        anyhow::bail!("presentation zoom pane is outside its screen");
    }

    let scroll_surface = resolve_identity(
        "scroll surface",
        scroll.surface,
        scroll.surface_uuid,
        |id| state.surfaces.contains_key(&id),
        |uuid| state.surface_id_by_uuid(uuid),
    )?;
    if let (Some(anchor), Some(scroll_surface)) = (anchor_workspace, scroll_surface)
        && workspace_of_surface(state, scroll_surface) != Some(anchor)
    {
        anyhow::bail!("presentation scroll surface is outside its workspace");
    }
    if let (Some(anchor), Some(scroll_surface)) = (anchor_screen, scroll_surface)
        && screen_of_surface(state, scroll_surface) != Some(anchor)
    {
        anyhow::bail!("presentation scroll surface is outside its screen");
    }
    if let (Some(anchor), Some(scroll_surface)) = (pane, scroll_surface)
        && state.pane_of(scroll_surface) != Some(anchor)
    {
        anyhow::bail!("presentation scroll surface is outside its pane");
    }
    Ok((
        PresentationView {
            workspace,
            workspace_uuid: workspace.and_then(|id| state.workspace_uuid(id)),
            screen,
            screen_uuid: screen.and_then(|id| state.screen_uuid(id)),
            pane,
            pane_uuid: pane.and_then(|id| state.pane_uuid(id)),
            tab: surface,
            surface_uuid: surface.and_then(|id| state.surface_uuid(id)),
        },
        PresentationZoom {
            pane: zoom_pane,
            pane_uuid: zoom_pane.and_then(|id| state.pane_uuid(id)),
        },
        PresentationScroll {
            surface: scroll_surface,
            surface_uuid: scroll_surface.and_then(|id| state.surface_uuid(id)),
            offset: scroll.offset,
        },
    ))
}

fn resolve_identity<Legacy, Stable>(
    label: &str,
    legacy: Option<Legacy>,
    stable: Option<Stable>,
    legacy_exists: impl Fn(Legacy) -> bool,
    stable_to_legacy: impl Fn(Stable) -> Option<Legacy>,
) -> anyhow::Result<Option<Legacy>>
where
    Legacy: Copy + Eq + std::fmt::Display,
    Stable: Copy + std::fmt::Display,
{
    if let Some(id) = legacy
        && !legacy_exists(id)
    {
        anyhow::bail!("unknown presentation {label} {id}");
    }
    let stable_id = stable
        .map(|uuid| {
            stable_to_legacy(uuid)
                .ok_or_else(|| anyhow::anyhow!("unknown presentation {label} UUID {uuid}"))
        })
        .transpose()?;
    if let (Some(legacy), Some(stable_id)) = (legacy, stable_id)
        && legacy != stable_id
    {
        anyhow::bail!("presentation {label} numeric handle and UUID refer to different entities");
    }
    Ok(legacy.or(stable_id))
}

fn workspace_of_screen(state: &State, screen: ScreenId) -> Option<WorkspaceId> {
    state
        .workspaces
        .iter()
        .find(|workspace| workspace.screens.iter().any(|candidate| candidate.id == screen))
        .map(|workspace| workspace.id)
}

fn screen_of_pane(state: &State, pane: PaneId) -> Option<ScreenId> {
    let (workspace_index, screen_index) = state.screen_of(pane)?;
    Some(state.workspaces[workspace_index].screens[screen_index].id)
}

fn workspace_of_pane(state: &State, pane: PaneId) -> Option<WorkspaceId> {
    let (workspace_index, _) = state.screen_of(pane)?;
    Some(state.workspaces[workspace_index].id)
}

fn screen_of_surface(state: &State, surface: SurfaceId) -> Option<ScreenId> {
    screen_of_pane(state, state.pane_of(surface)?)
}

fn workspace_of_surface(state: &State, surface: SurfaceId) -> Option<WorkspaceId> {
    workspace_of_pane(state, state.pane_of(surface)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn open(registry: &PresentationRegistry, client: u64) -> Presentation {
        registry
            .open(
                client,
                PresentationView::default(),
                PresentationZoom::default(),
                PresentationScroll::default(),
            )
            .unwrap()
    }

    #[test]
    fn presentation_limits_are_atomic_and_capacity_recovers() {
        let registry = PresentationRegistry::new_with_limits(2, 3);
        let first = open(&registry, 1);
        let second = open(&registry, 1);

        let per_client = registry
            .open(
                1,
                PresentationView::default(),
                PresentationZoom::default(),
                PresentationScroll::default(),
            )
            .unwrap_err();
        assert_eq!(per_client.to_string(), "presentation limit reached for client 1 (maximum 2)");

        open(&registry, 2);
        let global = registry
            .open(
                3,
                PresentationView::default(),
                PresentationZoom::default(),
                PresentationScroll::default(),
            )
            .unwrap_err();
        assert_eq!(global.to_string(), "global presentation limit reached (maximum 3)");

        registry.close(1, first.presentation_id).unwrap();
        open(&registry, 2);
        assert_eq!(registry.list_for_client(1).len(), 1);
        assert_eq!(registry.list_for_client(2).len(), 2);

        assert_eq!(registry.remove_client(1), vec![second.presentation_id]);
        assert!(registry.list_for_client(1).is_empty());
        open(&registry, 3);
        assert_eq!(registry.list_for_client(3).len(), 1);
    }

    #[test]
    fn default_capacity_admits_one_stable_input_owner_for_one_thousand_terminals() {
        let registry = PresentationRegistry::new();
        let presentations = (0..1_000).map(|_| open(&registry, 1)).collect::<Vec<_>>();

        assert_eq!(presentations.len(), 1_000);
        assert_eq!(registry.list_for_client(1).len(), 1_000);
        assert!(open(&registry, 1).generation == 1);
    }
}
