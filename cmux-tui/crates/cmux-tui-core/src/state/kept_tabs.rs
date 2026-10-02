//! Keep-layout writes on the state commit path: a resource revision, a
//! replay record and one `session.events` batch that restates every
//! touched tab with its `extra.relaunch`.

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::kept_tab_store as store;
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::state::values::fresh_upserts;

impl Mux {
    /// Record `tabs` (public tab id, shell directory) as kept.
    pub(crate) fn commit_kept_tabs(&self, tabs: &[(String, Option<String>)]) -> anyhow::Result<()> {
        store::validate_kept_tabs(tabs)?;
        if tabs.is_empty() {
            return Ok(());
        }
        let fingerprint = json!({
            "operation": "tab.kept_layout.record",
            "tabs": tabs,
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        self.commit_state(
            &WorkspaceMutation::local("cmux-tui-keep-layout"),
            "tab.kept_layout.record",
            &fingerprint,
            None,
            StateEffects::PRESENTATION,
            |transaction, _| {
                store::write_kept_tabs(transaction, tabs)?;
                let ids = tabs.iter().map(|(id, _)| id.clone()).collect::<Vec<_>>();
                let changes = fresh_upserts(transaction, &[], &[], &ids)?;
                Ok(StateChanges::new(json!({"tabs": ids}), changes))
            },
        )?;
        Ok(())
    }

    /// Forget the records of `tab_ids` (a cancelled keep-layout handoff).
    pub(crate) fn forget_kept_tabs(&self, tab_ids: &[String]) -> anyhow::Result<()> {
        if tab_ids.is_empty() {
            return Ok(());
        }
        let fingerprint = json!({
            "operation": "tab.kept_layout.forget",
            "tabs": tab_ids,
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        self.commit_state(
            &WorkspaceMutation::local("cmux-tui-keep-layout"),
            "tab.kept_layout.forget",
            &fingerprint,
            None,
            StateEffects::PRESENTATION,
            |transaction, _| {
                let removed = store::delete_kept_tabs(transaction, tab_ids)?;
                let changes = fresh_upserts(transaction, &[], &[], &removed)?;
                Ok(StateChanges::new(json!({"tabs": removed}), changes))
            },
        )?;
        Ok(())
    }
}
