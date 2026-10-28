//! `screen-changed` deltas (the full screen and its index) and
//! `layout-changed` (the screen's layout), optionally echoing the client
//! transaction of the request that caused them.

use super::screen_groups::locate_screen;
use super::*;
use std::sync::PoisonError;

/// Orders `layout-changed` payloads (`Mux::emit_layout_changed`). Taken
/// only there, never while the state lock is held.
static LAYOUT_EMIT: Mutex<()> = Mutex::new(());

impl Mux {
    /// Emit `screen-changed` (full screen and its index) for each screen.
    #[track_caller]
    pub(crate) fn emit_screen_changed(&self, screens: &[ScreenId]) {
        self.emit_screen_changed_for_transaction(screens, None);
    }

    /// [`Self::emit_screen_changed`] for a request that carried a client
    /// transaction, which every delta it causes echoes.
    #[track_caller]
    pub(crate) fn emit_screen_changed_for_transaction(
        &self,
        screens: &[ScreenId],
        transaction: Option<Arc<str>>,
    ) {
        let decorations = self.tree_decorations();
        let deltas = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            screens
                .iter()
                .filter_map(|screen| {
                    let (wi, si) = locate_screen(&state, *screen)?;
                    name_screen_splits(&mut state, (wi, si));
                    let entity = crate::server::tree_entity_json(
                        &state,
                        &decorations,
                        TreeDeltaKind::ScreenChanged,
                        *screen,
                    )?;
                    Some(TreeDelta {
                        kind: TreeDeltaKind::ScreenChanged,
                        workspace: state.workspace_at(wi).ok()?.id,
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

    /// Emit `layout-changed` for `screen` with its layout now
    /// (`layout-delta-v1`): one screen's split tree and columns, built under
    /// the state lock, so a frontend patches that screen instead of
    /// re-fetching the tree. `transaction` is the request's decimal
    /// transaction (a divider or column drag), which lets the frontend that
    /// sent it recognize its own echo. Call without the state lock held.
    pub(crate) fn emit_layout_changed(&self, screen: ScreenId, transaction: Option<Arc<str>>) {
        // Read and send under one lock, so two commits racing on one screen
        // send their layouts in the order they were read: each read sees a
        // state at least as new as the one before, and a client that applies
        // them in stream order ends on the newest.
        let _ordered = LAYOUT_EMIT.lock().unwrap_or_else(PoisonError::into_inner);
        let delta = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            (|| {
                let (wi, si) = locate_screen(&state, screen)?;
                name_screen_splits(&mut state, (wi, si));
                let workspace = state.workspaces.get(wi)?;
                Some(Arc::new(LayoutDelta {
                    workspace: workspace.id,
                    layout: crate::server::screen_layout_json(
                        workspace.screens.get(si)?,
                        &state.resource_indexes.split_ids,
                    ),
                    transaction,
                }))
            })()
        };
        self.emit(MuxEvent::LayoutChanged(screen, delta));
    }
}

/// Names the splits of a screen the daemon is about to send
/// ([`ensure_screen_split_public_ids`]). A failure to mint leaves those
/// splits without `split_id`; a client then keys them by their handle.
fn name_screen_splits(state: &mut State, location: (usize, usize)) {
    if let Err(error) = ensure_screen_split_public_ids(state, location) {
        eprintln!("cmux-tui: split public ids could not be minted: {error:#}");
    }
}
