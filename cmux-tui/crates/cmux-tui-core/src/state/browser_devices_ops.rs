//! `browser.devices.add_custom` and `.remove_custom`: one state commit each
//! (row, replay record and one `session.events` batch with a `state_upsert`
//! of resource `browser_device`, id `custom`). Readers fetch the list with
//! `browser.devices.list` (a read, never journaled).

use serde_json::json;

use crate::mux::*;
use crate::panic_free::JsonFields;
use crate::state::browser_devices::{self as devices, ID, RESOURCE};
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit, state_upsert};

impl Mux {
    /// Stores custom `device` (a custom device with its title is replaced).
    #[track_caller]
    pub(crate) fn state_browser_device_add(
        &self,
        mutation: &WorkspaceMutation,
        device: &Value,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = json!({"operation": "browser.devices.add_custom", "device": device});
        self.commit_state(
            mutation,
            "browser.devices.add_custom",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let stored = devices::add_custom(transaction, device)?;
                let upsert = state_upsert(RESOURCE, ID, json!({"title": stored.field("title")}));
                Ok(StateChanges::new(json!({"device": stored}), vec![upsert]))
            },
        )
    }

    /// Removes custom device `title`; removing a missing one changes nothing.
    #[track_caller]
    pub(crate) fn state_browser_device_remove(
        &self,
        mutation: &WorkspaceMutation,
        title: &str,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = json!({"operation": "browser.devices.remove_custom", "title": title});
        self.commit_state(
            mutation,
            "browser.devices.remove_custom",
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let removed = devices::remove_custom(transaction, title)?;
                let changes = if removed {
                    vec![state_upsert(RESOURCE, ID, json!({"title": title}))]
                } else {
                    Vec::new()
                };
                Ok(StateChanges::new(json!({"removed": removed}), changes))
            },
        )
    }
}
