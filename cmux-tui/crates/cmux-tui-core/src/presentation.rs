//! Connection-owned, presentation-local state.
//!
//! A socket connection may represent several windows. Each window gets a
//! presentation whose navigation and viewport placeholders are independent
//! from canonical mux topology and from the connection's other windows.

use std::collections::BTreeMap;
use std::sync::Mutex;

use serde::{Deserialize, Serialize};

use crate::{PaneId, PresentationId, ScreenId, SurfaceId, WorkspaceId};

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresentationView {
    #[serde(default)]
    pub workspace: Option<WorkspaceId>,
    #[serde(default)]
    pub screen: Option<ScreenId>,
    #[serde(default)]
    pub pane: Option<PaneId>,
    #[serde(default)]
    pub tab: Option<SurfaceId>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresentationZoom {
    /// Placeholder for presentation-local pane zoom. It does not mutate the
    /// canonical screen's current legacy zoom state.
    #[serde(default)]
    pub pane: Option<PaneId>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct PresentationScroll {
    /// Placeholder for a future presentation-local viewport binding.
    #[serde(default)]
    pub surface: Option<SurfaceId>,
    #[serde(default)]
    pub offset: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Presentation {
    pub presentation_id: PresentationId,
    pub client: u64,
    pub view: PresentationView,
    pub zoom: PresentationZoom,
    pub scroll: PresentationScroll,
}

pub(crate) struct PresentationRegistry {
    presentations: Mutex<BTreeMap<PresentationId, Presentation>>,
}

impl PresentationRegistry {
    pub(crate) fn new() -> Self {
        Self { presentations: Mutex::new(BTreeMap::new()) }
    }

    pub(crate) fn open(
        &self,
        client: u64,
        view: PresentationView,
        zoom: PresentationZoom,
        scroll: PresentationScroll,
    ) -> Presentation {
        let mut presentations = self.presentations.lock().unwrap();
        let presentation_id = loop {
            let candidate = PresentationId::new();
            if !presentations.contains_key(&candidate) {
                break candidate;
            }
        };
        let presentation = Presentation { presentation_id, client, view, zoom, scroll };
        presentations.insert(presentation_id, presentation.clone());
        presentation
    }

    pub(crate) fn close(&self, client: u64, presentation_id: PresentationId) -> anyhow::Result<()> {
        let mut presentations = self.presentations.lock().unwrap();
        let presentation = presentations
            .get(&presentation_id)
            .ok_or_else(|| anyhow::anyhow!("unknown presentation {presentation_id}"))?;
        if presentation.client != client {
            anyhow::bail!("presentation {presentation_id} is owned by another client");
        }
        presentations.remove(&presentation_id);
        Ok(())
    }

    pub(crate) fn list_for_client(&self, client: u64) -> Vec<Presentation> {
        self.presentations
            .lock()
            .unwrap()
            .values()
            .filter(|presentation| presentation.client == client)
            .cloned()
            .collect()
    }

    pub(crate) fn remove_client(&self, client: u64) -> Vec<PresentationId> {
        let mut presentations = self.presentations.lock().unwrap();
        let removed = presentations
            .values()
            .filter(|presentation| presentation.client == client)
            .map(|presentation| presentation.presentation_id)
            .collect::<Vec<_>>();
        for presentation_id in &removed {
            presentations.remove(presentation_id);
        }
        removed
    }
}
