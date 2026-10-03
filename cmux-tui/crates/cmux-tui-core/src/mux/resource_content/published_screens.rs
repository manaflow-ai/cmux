//! Screen upserts of a full effect projection.
//!
//! A screen's published value depends on the pane and tab rows of the same
//! commit, which the projection builds after the screen row. The projection
//! reserves the screen's place in the delta order, then fills every screen
//! with the one screen builder (`resource_screen::screen_value`) from the
//! registry rows it commits. `session.events` therefore publishes exactly the
//! screen that `session.snapshot` returns at that revision, viewport columns
//! included.

use anyhow::Context;
use serde_json::Value;

use crate::workspace_registry::{RegistryScreen, ResourceChange};

struct DeferredScreen {
    slot: usize,
    durable: RegistryScreen,
    focused: bool,
}

#[derive(Default)]
pub(super) struct PublishedScreens {
    deferred: Vec<DeferredScreen>,
}

impl PublishedScreens {
    /// Reserve the screen's upsert at its place in `public`.
    pub(super) fn defer(
        &mut self,
        public: &mut Vec<(&'static str, String, Value)>,
        durable: RegistryScreen,
        focused: bool,
    ) {
        let id = durable.public_id.to_string();
        self.deferred.push(DeferredScreen { slot: public.len(), durable, focused });
        public.push(("screen", id, Value::Null));
    }

    /// Fill every reserved screen upsert from the pane and tab rows in
    /// `changes`, the rows this projection commits.
    pub(super) fn publish(
        self,
        public: &mut [(&'static str, String, Value)],
        changes: &[ResourceChange],
    ) -> anyhow::Result<()> {
        let panes = changes
            .iter()
            .filter_map(|change| match change {
                ResourceChange::UpsertPane(pane) => Some(pane.clone()),
                _ => None,
            })
            .collect::<Vec<_>>();
        let tabs = changes
            .iter()
            .filter_map(|change| match change {
                ResourceChange::UpsertTab(tab) => Some(tab.clone()),
                _ => None,
            })
            .collect::<Vec<_>>();
        let tabs_by_pane = crate::resource_screen::tabs_by_pane(&tabs);
        let panes_by_id = crate::resource_screen::panes_by_id(&panes);
        for screen in self.deferred {
            let entry = public.get_mut(screen.slot).context("reserved screen upsert is missing")?;
            entry.2 = crate::resource_screen::screen_value(
                &screen.durable,
                screen.focused,
                &tabs_by_pane,
                &panes_by_id,
            )?;
        }
        Ok(())
    }
}
