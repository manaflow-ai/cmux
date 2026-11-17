//! The quick terminal (`quick-terminal-v1`): the `quick-terminal` request.
//!
//! The quick terminal of a workspace is the floating pane that has the mark
//! (model/floating_panes.rs): one for a workspace, a pane of one of its
//! screens. A request names the screen that the client shows. The rule of the
//! request is the layout reducer's (`quick_act`): it makes the quick terminal,
//! shows it with the focus, or hides it. Each act is one commit of the store:
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
//! - The bring is for a quick terminal in another screen of the workspace:
//!   the pane moves to the screen of the request by the plan of `pane.move`
//!   (it keeps its id, its tabs and its terminal), floats there at its frame
//!   with the mark, shows and has the focus.

use cmux_layout_reducer::floating_panes::{FloatFrame, FloatMode, QuickAct, QuickMode, quick_act};

use super::focus_plan::expand_focus_stacks;
use super::pane_move::{Destination, move_pane_in_state};
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

/// Internal journal operation name of a bring. It is not a public resource
/// operation: the command is reachable only through the JSON-lines
/// `quick-terminal`.
const BRING_OPERATION: &str = "pane.quick-terminal-bring";

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

/// Floats `pane` of `screen` at `frame` and marks it as the quick terminal,
/// with `previous` as the pane that gets the focus back at a hide. No frame, a
/// screen that has a quick terminal, and a pane that never floats, keep the
/// pane tiled. Then the list follows the layout: a floating pane whose column
/// got a row, or that the auto layout put into a stack, is tiled.
fn settle_quick_pane(
    screen: &mut Screen,
    pane: PaneId,
    previous: PaneId,
    frame: Option<FloatFrame>,
) {
    if let Some(frame) = frame
        && screen.quick_terminal().is_none()
        && !screen.pane_never_floats(pane)
        && screen.place_floating_pane(pane, FloatMode::On, Some(frame)).is_ok()
    {
        screen.mark_quick_terminal(pane, Some(previous));
    }
    screen.settle_floating_panes();
}

/// The floating panes of `screen` after the creation of `pane` by `fields`.
/// A creation that has [`QUICK_TERMINAL_FRAME_FIELD`] makes the new pane the
/// quick terminal at that frame ([`settle_quick_pane`]).
pub(super) fn settle_new_pane(screen: &mut Screen, pane: PaneId, previous: PaneId, fields: &Value) {
    settle_quick_pane(screen, pane, previous, frame_field(fields));
}

/// The screen `screen` of `state`.
fn screen_of(state: &State, screen: ScreenId) -> Option<&Screen> {
    state.workspaces.iter().flat_map(|workspace| &workspace.screens).find(|item| item.id == screen)
}

/// The pane of `screen` that the pane of the quick terminal splits: the new
/// leaf is in that pane's column, so it can float where that pane can. The
/// pane that has the focus comes first.
fn split_target(screen: &Screen) -> Option<PaneId> {
    std::iter::once(screen.active_pane)
        .chain(screen.root.pane_ids_vec())
        .find(|pane| !screen.pane_never_floats(*pane))
}

/// What a request does.
enum Plan {
    /// Make the quick terminal as a split of this pane.
    Make(PaneId),
    /// Give this pane, the quick terminal, the focus: it shows.
    Show(PaneId),
    /// Hide the quick terminal of this screen.
    Hide(ScreenId),
    /// Bring this pane, the quick terminal of another screen of the
    /// workspace, to the screen of the request.
    Bring(PaneId),
    Nothing,
}

/// What a request for `screen` does. A workspace has one quick terminal: when
/// another screen of the workspace holds it, a toggle and a show bring it to
/// `screen`, and a hide hides it where it is.
fn planned_act(state: &State, screen: ScreenId, mode: QuickMode) -> Result<Plan, FloatPaneError> {
    let found = state.workspaces.iter().find_map(|workspace| {
        let at = workspace.screens.iter().position(|item| item.id == screen)?;
        Some((workspace, at, workspace.screens.get(at)?))
    });
    let (workspace, at, shown) = found.ok_or(FloatPaneError::ScreenNotFound { screen })?;
    if let Some((holder, pane, mark)) = workspace.quick_terminal()
        && holder != at
    {
        return Ok(match (mode, workspace.screens.get(holder)) {
            (QuickMode::Hide, Some(other)) if !mark.hidden => Plan::Hide(other.id),
            (QuickMode::Hide, _) => Plan::Nothing,
            (QuickMode::Toggle | QuickMode::Show, _) => Plan::Bring(pane),
        });
    }
    Ok(match quick_act(&shown.floating_panes(), mode, &shown.active_pane) {
        QuickAct::Make => {
            Plan::Make(split_target(shown).ok_or(FloatPaneError::NoPlaceForQuickTerminal)?)
        }
        QuickAct::Show => {
            shown.quick_terminal().map_or(Plan::Nothing, |(pane, _)| Plan::Show(pane))
        }
        QuickAct::Hide => Plan::Hide(screen),
        QuickAct::Nothing => Plan::Nothing,
    })
}

impl Mux {
    /// `quick-terminal`: make the quick terminal of the workspace of
    /// `screen`, show it in `screen` with the focus, or hide it, by `mode` and
    /// the state ([`planned_act`]). `frame`, `spawn` and `size` are for a make only: where
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
            Plan::Make(target) => {
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
            Plan::Show(pane) => {
                anyhow::ensure!(
                    self.focus_pane_as(actor, pane),
                    "the quick terminal {pane} did not take the focus"
                );
                Ok(None)
            }
            Plan::Hide(holder) => self.hide_quick_terminal_as(actor, holder).map(|()| None),
            Plan::Bring(pane) => self.bring_quick_terminal_as(actor, pane, screen).map(|()| None),
            Plan::Nothing => Ok(None),
        }
    }

    /// Brings the quick terminal `pane` from another screen of the workspace
    /// to `screen` in one commit: the move of the pane (the plan of
    /// `pane.move`), its frame and its mark in the list of `screen`, and the
    /// focus. The screen that the pane leaves gives its focus as a close of
    /// the pane does. A screen where the pane can not float refuses, and
    /// nothing moves.
    fn bring_quick_terminal_as(
        self: &Arc<Self>,
        actor: &Actor,
        pane: PaneId,
        screen: ScreenId,
    ) -> anyhow::Result<()> {
        let fingerprint = serde_json::json!({"operation": BRING_OPERATION, "screen": screen});
        let mut left = None;
        let commit = self.commit_resource_mutation_plan(
            &WorkspaceMutation::local("cmux-tui-quick-terminal", actor.clone()),
            BRING_OPERATION,
            &fingerprint,
            None,
            None,
            |state, registry| {
                // The move takes the entry of the pane out of the list of the
                // screen that it leaves: the frame is read before the move.
                let (source, frame) = state
                    .workspaces
                    .iter()
                    .flat_map(|workspace| &workspace.screens)
                    .find_map(|item| {
                        let (quick, _) = item.quick_terminal()?;
                        let list = item.floating_panes();
                        let entry = list.iter().find(|entry| entry.pane == quick)?;
                        (quick == pane && item.id != screen).then_some((item.id, entry.frame))
                    })
                    .context("the quick terminal is not in another screen")?;
                let target =
                    screen_of(state, screen).ok_or(FloatPaneError::ScreenNotFound { screen })?;
                let screen_id = target.public_id.as_str().to_string();
                let previous = target.active_pane;
                let beside = split_target(target).ok_or(FloatPaneError::NoPlaceForQuickTerminal)?;
                let destination =
                    Destination::Split { pane: beside, dir: SplitDir::Right, before: false };
                let mut projected = state.clone();
                let moved = move_pane_in_state(self, &mut projected, pane, destination, None)?;
                let workspace = projected
                    .workspaces
                    .iter_mut()
                    .find(|workspace| workspace.screens.iter().any(|item| item.id == screen))
                    .ok_or(FloatPaneError::ScreenNotFound { screen })?;
                let workspace_id = workspace.id;
                let target = workspace
                    .screens
                    .iter_mut()
                    .find(|item| item.id == screen)
                    .ok_or(FloatPaneError::ScreenNotFound { screen })?;
                settle_quick_pane(target, pane, previous, Some(frame));
                anyhow::ensure!(
                    target.quick_terminal().is_some_and(|(quick, _)| quick == pane),
                    FloatPaneError::NoPlaceForQuickTerminal
                );
                moved.update_session_paths(self, workspace_id, screen);
                apply_focus_path(self, &mut projected, pane);
                let projection = self.changed_state_projection_locked(
                    registry,
                    state,
                    &mut projected,
                    serde_json::json!({"screen": screen_id}),
                )?;
                left = Some(source);
                Ok(ResourceMutationPlan::replacing(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    projected,
                )
                .projected(projection.restates_all)
                .restating(projection.restated))
            },
        )?;
        if !commit.replayed {
            let screens: Vec<ScreenId> = left.into_iter().chain([screen]).collect();
            self.emit_screen_changed_for_transaction(&screens, None);
            self.emit(MuxEvent::TreeChanged);
            for screen in screens {
                self.emit_layout_changed(screen, None);
            }
        }
        Ok(())
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
