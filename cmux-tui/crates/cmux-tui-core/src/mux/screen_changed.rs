//! `screen-changed` deltas (the full screen and its index), optionally
//! echoing the client transaction of the request that caused them.

use super::screen_groups::locate_screen;
use super::*;

impl Mux {
    /// Emit `screen-changed` (full screen and its index) for each screen.
    pub(crate) fn emit_screen_changed(&self, screens: &[ScreenId]) {
        self.emit_screen_changed_for_transaction(screens, None);
    }

    /// [`Self::emit_screen_changed`] for a request that carried a client
    /// transaction, which every delta it causes echoes.
    pub(crate) fn emit_screen_changed_for_transaction(
        &self,
        screens: &[ScreenId],
        transaction: Option<Arc<str>>,
    ) {
        let decorations = self.tree_decorations();
        let deltas = {
            let state = self.state.lock().unwrap();
            screens
                .iter()
                .filter_map(|screen| {
                    let (wi, si) = locate_screen(&state, *screen)?;
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &decorations,
                        TreeDeltaKind::ScreenChanged,
                        *screen,
                    )?;
                    Some(TreeDelta {
                        kind: TreeDeltaKind::ScreenChanged,
                        workspace: state.workspaces[wi].id,
                        screen: Some(*screen),
                        pane: None,
                        surface: None,
                        index: Some(si),
                        entity,
                        workspace_revision: None,
                        transaction: transaction.clone(),
                    })
                })
                .collect::<Vec<_>>()
        };
        for delta in deltas {
            self.emit(MuxEvent::TreeDelta(delta));
        }
    }
}
