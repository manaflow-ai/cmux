//! The quick terminal (`quick-terminal-v1`): the `quick-terminal` request.
//!
//! The quick terminal of a screen is the floating pane that has the mark
//! (model/floating_panes.rs). The rule of the request is the layout reducer's
//! (`quick_act`): it makes the quick terminal, shows it with the focus, or
//! hides it. Each act is one commit of the store:
//!
//! - The make is a pane creation (`pane.split`) with one more field, the
//!   frame. The effect that adds the pane floats it and marks it before the
//!   screen's record is written, so no state has the pane tiled and not
//!   marked, and a creation that a restart resumes reads the same field.
//! - The show is a focus of the pane: a quick terminal that gets the focus
//!   shows, and its mark names the pane that had the focus.
//! - The hide keeps the pane, its terminal and its entry of the list. The
//!   focus goes to the pane of the mark, else to the pane that a close of the
//!   quick terminal would give it to.

use cmux_layout_reducer::floating_panes::{FloatFrame, FloatMode, QuickAct, QuickMode, quick_act};

use super::focus_plan::expand_focus_stacks;
use super::*;
use crate::model::Screen;
use crate::mux::tree_edit::{close_focus_successor, close_sibling};

/// The `pane.split` field of a make: the frame of the new quick terminal as
/// `[x, y, w, h]` in millionths of the screen's pane area. The daemon writes
/// it; it is not a field of the public operation.
const QUICK_TERMINAL_FRAME_FIELD: &str = "quick_terminal_frame";

/// Internal journal operation name of a hide. It is not a public resource
/// operation: the command is reachable only through the JSON-lines
/// `quick-terminal`.
const HIDE_OPERATION: &str = "pane.quick-terminal-hide";

/// Where a new quick terminal stands with no frame in the request: the bottom
/// right of the screen.
const NEW_FRAME: FloatFrame = FloatFrame { x: 550_000, y: 550_000, w: 450_000, h: 450_000 };

/// The frame of [`QUICK_TERMINAL_FRAME_FIELD`] in the fields of a creation.
/// A value that is not four numbers is no frame.
fn frame_field(fields: &Value) -> Option<FloatFrame> {
    let mut parts = fields
        .get(QUICK_TERMINAL_FRAME_FIELD)?
        .as_array()?
        .iter()
        .map(|part| part.as_u64().and_then(|value| u32::try_from(value).ok()));
    let frame =
        FloatFrame { x: parts.next()??, y: parts.next()??, w: parts.next()??, h: parts.next()?? };
    Some(frame.clamped())
}

/// The floating panes of `screen` after the creation of `pane` by `fields`.
/// A creation that has [`QUICK_TERMINAL_FRAME_FIELD`] floats the new pane at
/// that frame and marks it, with `previous` as the pane that gets the focus
/// back at a hide; a screen that has a quick terminal, and a pane that never
/// floats, keep the pane tiled. Then the list follows the new layout: a
/// floating pane whose column got a row, or that the auto layout put into a
/// stack, is tiled.
pub(super) fn settle_new_pane(screen: &mut Screen, pane: PaneId, previous: PaneId, fields: &Value) {
    if let Some(frame) = frame_field(fields)
        && screen.quick_terminal().is_none()
        && !screen.pane_never_floats(pane)
        && screen.place_floating_pane(pane, FloatMode::On, Some(frame)).is_ok()
    {
        screen.mark_quick_terminal(pane, Some(previous));
    }
    screen.settle_floating_panes();
}

/// The screen `screen` of `state`.
fn screen_of(state: &State, screen: ScreenId) -> Option<&Screen> {
    state.workspaces.iter().flat_map(|workspace| &workspace.screens).find(|item| item.id == screen)
}

/// What a request does, and the pane that it does it to: the quick terminal
/// for a show, and the pane that a make splits.
fn planned_act(
    state: &State,
    screen: ScreenId,
    mode: QuickMode,
) -> Result<(QuickAct, Option<PaneId>), FloatPaneError> {
    let screen = screen_of(state, screen).ok_or(FloatPaneError::ScreenNotFound { screen })?;
    let act = quick_act(&screen.floating_panes(), mode, &screen.active_pane);
    let pane = match act {
        QuickAct::Make => {
            // The new pane is a split of its target, in the target's column:
            // it can float where the target can. The pane that has the focus
            // comes first.
            let target = std::iter::once(screen.active_pane)
                .chain(screen.root.pane_ids_vec())
                .find(|pane| !screen.pane_never_floats(*pane));
            Some(target.ok_or(FloatPaneError::NoPlaceForQuickTerminal)?)
        }
        QuickAct::Show => screen.quick_terminal().map(|(pane, _)| pane),
        QuickAct::Hide | QuickAct::Nothing => None,
    };
    Ok((act, pane))
}

impl Mux {
    /// `quick-terminal`: make the quick terminal of `screen`, show it with
    /// the focus, or hide it, by `mode` and the state of the screen
    /// (`quick_act`). `frame`, `spawn` and `size` are for a make only: where
    /// the new pane floats, what its terminal runs, and the expected content
    /// size. Returns the surface of a quick terminal that the request made.
    pub(crate) fn quick_terminal_as(
        self: &Arc<Self>,
        actor: &Actor,
        screen: ScreenId,
        mode: QuickMode,
        frame: Option<FloatFrame>,
        spawn: TerminalSpawnOptions,
        size: Option<(u16, u16)>,
    ) -> anyhow::Result<Option<SurfaceId>> {
        match self.with_state(|state| planned_act(state, screen, mode))? {
            (QuickAct::Make, Some(target)) => {
                let frame = frame.unwrap_or(NEW_FRAME);
                let fields = Map::from_iter([
                    ("direction".into(), Value::String("right".into())),
                    (
                        QUICK_TERMINAL_FRAME_FIELD.into(),
                        serde_json::json!([frame.x, frame.y, frame.w, frame.h]),
                    ),
                ]);
                let created = self.split_with_fields_as(actor, target, fields, spawn, size)?;
                Ok(Some(created.surface.id))
            }
            (QuickAct::Show, Some(pane)) => {
                anyhow::ensure!(
                    self.focus_pane_as(actor, pane),
                    "the quick terminal {pane} did not take the focus"
                );
                Ok(None)
            }
            (QuickAct::Hide, _) => self.hide_quick_terminal_as(actor, screen).map(|()| None),
            (QuickAct::Make | QuickAct::Show | QuickAct::Nothing, _) => Ok(None),
        }
    }

    /// Hides the quick terminal of `screen` in one commit: the list, the mark
    /// and the focus of after the hide are one state of the store, and one
    /// layout event. A hide is no entry of the layout undo, as a focus is
    /// none.
    fn hide_quick_terminal_as(
        self: &Arc<Self>,
        actor: &Actor,
        screen: ScreenId,
    ) -> anyhow::Result<()> {
        let fingerprint = serde_json::json!({"operation": HIDE_OPERATION, "screen": screen});
        let commit = self.commit_resource_mutation_plan(
            &WorkspaceMutation::local("cmux-tui-quick-terminal", actor.clone()),
            HIDE_OPERATION,
            &fingerprint,
            None,
            None,
            |state, registry| {
                let mut projected = state.clone();
                let target = projected
                    .workspaces
                    .iter_mut()
                    .flat_map(|workspace| &mut workspace.screens)
                    .find(|item| item.id == screen)
                    .ok_or(FloatPaneError::ScreenNotFound { screen })?;
                let screen_id = target.public_id.as_str().to_string();
                let previous = target.active_pane;
                let quick = target.quick_terminal().map(|(pane, _)| pane);
                // The focus of a quick terminal whose mark names no pane goes
                // where a close of it would send the focus.
                let fallback = quick.and_then(|quick| {
                    let mut panes = target.root.pane_ids_vec();
                    panes.retain(|pane| *pane != quick);
                    close_focus_successor(state, &panes, close_sibling(target, quick))
                });
                target.hide_quick_terminal(fallback);
                let focused = target.active_pane;
                if focused != previous {
                    expand_focus_stacks(target, previous, focused);
                    stamp_pane_focus(self, &mut projected, focused);
                }
                let projection = self.changed_state_projection_locked(
                    registry,
                    state,
                    &mut projected,
                    serde_json::json!({"screen": screen_id}),
                )?;
                Ok(ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    move |state| *state = projected,
                )
                .projected(projection.restates_all)
                .restating(projection.restated))
            },
        )?;
        if !commit.replayed {
            self.emit_screen_changed_for_transaction(&[screen], None);
            self.emit_layout_changed(screen, None);
        }
        Ok(())
    }
}
