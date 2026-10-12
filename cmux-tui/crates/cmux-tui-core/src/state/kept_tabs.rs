//! Keep-layout writes on the state commit path: a resource revision, a
//! replay record and one `session.events` batch that restates every
//! touched tab with its `extra.relaunch`. Also the rename of a kept tab
//! that has no surface (after a restart).

use serde_json::json;

use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::kept_tab_store::{self as store, KeptTab};
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::state::values::fresh_upserts;
use crate::workspace_registry::WorkspaceRegistry;

impl Mux {
    /// Record `tabs` (public tab id, shell directory, last title) as kept.
    pub(crate) fn commit_kept_tabs(&self, tabs: &[KeptTab]) -> anyhow::Result<()> {
        store::validate_kept_tabs(tabs)?;
        if tabs.is_empty() {
            return Ok(());
        }
        let fingerprint = json!({
            "operation": "tab.kept_layout.record",
            "tabs": tabs
                .iter()
                .map(|tab| json!([tab.tab_id, tab.cwd, tab.title]))
                .collect::<Vec<_>>(),
            "nonce": crate::workspace_registry::new_uuid_v4(),
        });
        self.commit_state(
            &WorkspaceMutation::daemon_local("cmux-tui-keep-layout"),
            "tab.kept_layout.record",
            &fingerprint,
            None,
            StateEffects::PRESENTATION,
            |transaction, _| {
                store::write_kept_tabs(transaction, tabs)?;
                let ids = tabs.iter().map(|tab| tab.tab_id.clone()).collect::<Vec<_>>();
                let changes = fresh_upserts(transaction, &[], &[], &ids)?;
                Ok(StateChanges::new(json!({"tabs": ids}), changes))
            },
        )?;
        Ok(())
    }

    /// A tab rename sets the tab resource's name and, when one exists, the
    /// live surface's name. A kept tab has no surface after a restart and
    /// renames anyway (no process needed); another tab without a surface (a
    /// host still being adopted) is refused, since its surface would bring
    /// its own name.
    pub(crate) fn ensure_tab_renamable(
        state: &State,
        registry: &WorkspaceRegistry,
        surface: SurfaceId,
        tab_id: &TabPublicId,
    ) -> anyhow::Result<()> {
        if state.surfaces.contains_key(&surface) || registry.any_kept_tab(&[tab_id.to_string()])? {
            return Ok(());
        }
        anyhow::bail!("tab {tab_id} has no live surface")
    }

    /// After a committed tab rename: the tree reads a kept tab's name from
    /// the presentation snapshot (`kept_tabs` joined with the tab resource),
    /// so reload it at once for a kept tab.
    pub(crate) fn reload_kept_tab_name(&self, tab_id: Option<&str>) -> anyhow::Result<()> {
        if tab_id.is_none_or(|id| !self.presentation_snapshot().kept_tabs.contains_key(id)) {
            return Ok(());
        }
        let registry = self
            .workspace_registry
            .lock()
            .map_err(|_| anyhow::anyhow!("workspace registry lock is poisoned"))?;
        self.reload_presentation(&registry)
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
            &WorkspaceMutation::daemon_local("cmux-tui-keep-layout"),
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
