//! Input admission against pending session mutations: which input may
//! overlap or overtake deferred input, semantic destinations, deferral and
//! retained pointer motion, and terminal pointer admission per route.

use cmux_tui_core::{GuardedMouseEncode, PointerSnapshotProbe, SurfaceId};
use crossterm::event::{KeyModifiers, MouseButton, MouseEvent, MouseEventKind};
use ghostty_vt::{MouseAction, MouseButton as GhosttyMouseButton, MouseInput};

use crate::app::host_input::TerminalInput;
use crate::app::layout::FocusTarget;
use crate::app::pointer::deferred::{
    DeferredInput, DeferredInputAdmission, DeferredPointerInput, PendingPointerMotion,
    SemanticDestinationOutcome,
};
use crate::app::pointer::route::PointerRouteIdentity;
use crate::app::pointer::{
    Drag, TerminalPointerAdmission, TerminalPointerAdmissionResult, TerminalPointerEncoding,
};
use crate::app::{
    App, DEFERRED_INPUT_CAPACITY, DEFERRED_INPUT_FIXED_BYTES, MAX_DEFERRED_INPUT_BYTES,
    RenderAction, action_creates_destination, action_is_frontend_local,
};
use crate::config::Action;
use crate::localization;
use crate::machine::WorkspaceCreationPolicy;
use crate::pty_input::PtyInputBytes;

impl App {
    pub(super) fn input_can_update_pending_mutation(&self, input: &TerminalInput) -> bool {
        if input.is_keyboard_command()
            && (self.pairing_dialog.is_some()
                || self.shortcut_help.is_some()
                || self.prompt.is_some()
                || self.menu.is_some()
                || self.omnibar.is_some()
                || self.machine_sidebar_focused()
                || self.workspace_sidebar_focused() && self.config.sidebar.plugin.is_none())
        {
            return true;
        }
        match input {
            TerminalInput::FrontendAction { action, .. }
                if action_is_frontend_local(*action) || *action == Action::Detach =>
            {
                return true;
            }
            _ => {}
        }
        if let TerminalInput::Mouse(mouse) = input
            && self.pointer_has_capture(mouse.kind)
        {
            // Once a press has been admitted, its drag and release belong to
            // that frontend-local capture. Let the gesture finish against its
            // stable target even while a backend mutation rebuilds routing.
            return true;
        }
        matches!(
            (input, &self.drag),
            (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::HorizontalScrollbar { .. })
            ) | (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::ResizeSplit { .. })
            ) | (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::Select { .. })
            ) | (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::Browser { .. })
            ) | (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(_) | MouseEventKind::Up(_),
                    ..
                }),
                Some(Drag::PtyMouse { .. })
            ) | (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::TabArm { .. })
            ) | (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(MouseButton::Left)
                        | MouseEventKind::Up(MouseButton::Left),
                    ..
                }),
                Some(Drag::WorkspaceArm { .. } | Drag::Workspace { .. })
            )
        )
    }

    pub(super) fn input_can_overtake_deferred(&self, input: &TerminalInput) -> bool {
        if matches!(input, TerminalInput::FrontendAction { action: Action::Detach, .. }) {
            return true;
        }
        if let TerminalInput::Mouse(mouse) = input
            && self.pointer_has_capture(mouse.kind)
        {
            return true;
        }
        matches!(
            (input, &self.drag),
            (
                TerminalInput::Mouse(MouseEvent {
                    kind: MouseEventKind::Drag(_) | MouseEventKind::Up(_),
                    ..
                }),
                Some(
                    Drag::HorizontalScrollbar { .. }
                        | Drag::ResizeSplit { .. }
                        | Drag::Select { .. }
                        | Drag::Browser { .. }
                        | Drag::PtyMouse { .. }
                        | Drag::WorkspaceArm { .. }
                        | Drag::TabArm { .. }
                )
            )
        )
    }

    /// Prefix syntax is resolved exactly once at host ingress. Frontend-owned
    /// suffixes can therefore survive a backend refresh without consulting
    /// mutable parser state during replay.
    pub(super) fn input_is_client_owned(&self, input: &TerminalInput) -> bool {
        matches!(
            input,
            TerminalInput::FrontendAction { action, .. } if action_is_frontend_local(*action)
        )
    }

    pub(super) fn input_accepts_semantic_destination(input: &TerminalInput) -> bool {
        input.is_keyboard_or_paste()
    }

    pub(super) fn semantic_destination_for_input(
        &self,
        input: &TerminalInput,
        admission: Option<&DeferredInputAdmission>,
    ) -> Option<SurfaceId> {
        if !Self::input_accepts_semantic_destination(input) {
            return None;
        }
        let intent = admission?.semantic_dependency?;
        match self.semantic_destination_outcomes.get(&intent) {
            Some(SemanticDestinationOutcome::Resolved(surface)) => Some(*surface),
            Some(SemanticDestinationOutcome::Pending | SemanticDestinationOutcome::Failed)
            | None => None,
        }
    }

    pub(super) fn input_creates_session_destination(&self, input: &TerminalInput) -> bool {
        let TerminalInput::FrontendAction { action, .. } = input else { return false };
        action_creates_destination(*action)
            && (*action != Action::NewWorkspace
                || self.workspace_creation_policy() == Some(WorkspaceCreationPolicy::SessionOwned))
    }

    pub(super) fn allocate_semantic_destination_intent(&mut self) -> u64 {
        self.next_semantic_destination_intent =
            self.next_semantic_destination_intent.wrapping_add(1).max(1);
        let intent = self.next_semantic_destination_intent;
        let previous =
            self.semantic_destination_outcomes.insert(intent, SemanticDestinationOutcome::Pending);
        debug_assert!(previous.is_none(), "live semantic destination intent reused");
        intent
    }

    pub(super) fn advance_pointer_focus_generation(&mut self) {
        self.pointer_focus_generation = self.pointer_focus_generation.wrapping_add(1);
        self.deferred_input.retain(|input| !matches!(&input.event, TerminalInput::Mouse(_)));
        self.pending_pointer_motion = None;
        self.active_pointer_buttons.clear();
        self.ignored_pty_mouse_buttons.clear();
        self.reset_selection_click_sequence();
    }

    #[cfg(test)]
    pub(super) fn defer_input(&mut self, input: impl Into<TerminalInput>) -> RenderAction {
        self.defer_input_with_sequence(input.into(), None, None, None)
    }

    pub(super) fn defer_input_with_sequence(
        &mut self,
        input: TerminalInput,
        replay_sequence: Option<u64>,
        replay_pointer: Option<DeferredPointerInput>,
        replay_admission: Option<DeferredInputAdmission>,
    ) -> RenderAction {
        // Admission belongs to the input's arrival, not to whichever pane is
        // focused when asynchronous mutations later replay it. Preserve the
        // complete original admission whenever an input must wait again.
        let admission = if let Some(admission) = replay_admission {
            admission
        } else {
            self.clear_finished_semantic_destinations();
            let destination_started = self.session.destination_mutation_started();
            let client_owned = self.input_is_client_owned(&input);
            let semantic_dependency =
                if client_owned { None } else { self.latest_semantic_destination_intent };
            let semantic_result = self
                .input_creates_session_destination(&input)
                .then(|| self.allocate_semantic_destination_intent());
            if let Some(intent) = semantic_result {
                self.latest_semantic_destination_intent = Some(intent);
            }
            DeferredInputAdmission {
                destination: self.input_destination(&input),
                destination_intent: (destination_started > self.applied_destination_generation)
                    .then_some(destination_started),
                semantic_dependency,
                semantic_result,
                sidebar_focus_intent: self.sidebar_focus_pending && input.is_keyboard_or_paste(),
                pairing_request: replay_sequence
                    .is_none()
                    .then(|| self.pairing_dialog.as_ref().map(|dialog| dialog.challenge.id))
                    .flatten(),
                client_owned,
            }
        };
        let pointer = if replay_sequence.is_some() {
            replay_pointer
        } else if let TerminalInput::Mouse(mouse) = &input {
            Some(DeferredPointerInput {
                focus_generation: self.pointer_focus_generation,
                pointer_map_generation: self.rendered_pointer_frame.pointer_map_generation,
                route: Self::mouse_requires_rendered_route(mouse.kind)
                    .then(|| self.rendered_pointer_route_for_mouse(mouse)),
            })
        } else {
            None
        };
        let sequence = replay_sequence.unwrap_or_else(|| self.next_deferred_input_sequence());
        let replace_motion = replay_sequence.is_none()
            && match (&input, self.deferred_input.back()) {
                (
                    TerminalInput::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. }),
                    Some(DeferredInput {
                        event: TerminalInput::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. }),
                        admission: previous_admission,
                        pointer: previous_pointer,
                        ..
                    }),
                ) => {
                    *previous_admission == admission
                        && previous_pointer.as_ref().map(|pointer| pointer.focus_generation)
                            == pointer.as_ref().map(|pointer| pointer.focus_generation)
                }
                (
                    TerminalInput::Mouse(MouseEvent { kind: MouseEventKind::Drag(button), .. }),
                    Some(DeferredInput {
                        event:
                            TerminalInput::Mouse(MouseEvent {
                                kind: MouseEventKind::Drag(previous),
                                ..
                            }),
                        admission: previous_admission,
                        pointer: previous_pointer,
                        ..
                    }),
                ) => {
                    button == previous
                        && *previous_admission == admission
                        && previous_pointer.as_ref().map(|pointer| pointer.focus_generation)
                            == pointer.as_ref().map(|pointer| pointer.focus_generation)
                }
                _ => false,
            };
        if replace_motion {
            self.deferred_input.replace_back(DeferredInput {
                event: input,
                admission,
                pointer,
                sequence,
            });
            return RenderAction::None;
        }
        let input_bytes = input.retained_bytes();
        let prioritize_release =
            matches!(&input, TerminalInput::Mouse(MouseEvent { kind: MouseEventKind::Up(_), .. }));
        while self.deferred_input.retained_bytes().saturating_add(input_bytes)
            > MAX_DEFERRED_INPUT_BYTES
        {
            if !prioritize_release {
                self.status_message =
                    Some(localization::catalog().terminal.deferred_input_queue_full.to_string());
                return RenderAction::Draw;
            }
            let Some(removed) = self.deferred_input.pop_front() else { break };
            self.retire_deferred_semantic_result(&removed);
        }
        let input = DeferredInput { event: input, admission, pointer, sequence };
        if replay_sequence.is_some() {
            // A replayed input keeps its original chronological position.
            let index = self
                .deferred_input
                .iter()
                .position(|queued| queued.sequence > sequence)
                .unwrap_or(self.deferred_input.len());
            self.deferred_input.insert(index, input);
        } else {
            self.deferred_input.push_back(input);
        }
        RenderAction::None
    }

    fn next_deferred_input_sequence(&mut self) -> u64 {
        self.deferred_input_sequence = self.deferred_input_sequence.saturating_add(1);
        self.deferred_input_sequence
    }

    #[cfg(test)]
    pub(super) fn retain_pointer_motion(&mut self, event: MouseEvent) {
        self.retain_pointer_motion_with_sequence(event, None, None);
    }

    pub(super) fn retain_pointer_motion_with_sequence(
        &mut self,
        event: MouseEvent,
        replay_sequence: Option<u64>,
        replay_focus_generation: Option<u64>,
    ) {
        let sequence = replay_sequence.unwrap_or_else(|| self.next_deferred_input_sequence());
        let focus_generation = replay_focus_generation.unwrap_or(self.pointer_focus_generation);
        let destination = self.input_destination(&TerminalInput::Mouse(event));
        let retained = PendingPointerMotion { event, destination, focus_generation, sequence };
        let Some(pending) = self.pending_pointer_motion else {
            self.pending_pointer_motion = Some(retained);
            return;
        };
        if pending.sequence == sequence {
            self.pending_pointer_motion = Some(retained);
            return;
        }
        let (earlier, later) = if pending.sequence < sequence {
            (pending.sequence, sequence)
        } else {
            (sequence, pending.sequence)
        };
        let has_discrete_barrier = self.deferred_input.iter().any(|input| {
            input.sequence > earlier
                && input.sequence < later
                && !matches!(
                    input.event,
                    TerminalInput::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. })
                )
        });
        if !has_discrete_barrier {
            if pending.sequence < sequence {
                self.pending_pointer_motion = Some(retained);
            }
            return;
        }
        if pending.sequence < sequence {
            if self.spill_retained_pointer_motion(pending) {
                self.pending_pointer_motion = Some(retained);
            }
        } else if !self.spill_retained_pointer_motion(retained) {
            // Under queue pressure preserve the earlier motion before its
            // discrete barrier and discard the newer passive sample.
            self.pending_pointer_motion = Some(retained);
        }
    }

    fn spill_retained_pointer_motion(&mut self, pending: PendingPointerMotion) -> bool {
        if self.deferred_input.len() >= DEFERRED_INPUT_CAPACITY
            || self.deferred_input.retained_bytes().saturating_add(DEFERRED_INPUT_FIXED_BYTES)
                > MAX_DEFERRED_INPUT_BYTES
        {
            return false;
        }
        let input = DeferredInput {
            event: TerminalInput::Mouse(pending.event),
            admission: DeferredInputAdmission {
                destination: pending.destination,
                destination_intent: None,
                semantic_dependency: None,
                semantic_result: None,
                sidebar_focus_intent: false,
                pairing_request: None,
                client_owned: false,
            },
            pointer: Some(DeferredPointerInput {
                focus_generation: pending.focus_generation,
                pointer_map_generation: self.rendered_pointer_frame.pointer_map_generation,
                route: None,
            }),
            sequence: pending.sequence,
        };
        let index = self
            .deferred_input
            .iter()
            .position(|queued| queued.sequence > pending.sequence)
            .unwrap_or(self.deferred_input.len());
        self.deferred_input.insert(index, input);
        true
    }

    fn mouse_requires_rendered_route(kind: MouseEventKind) -> bool {
        kind != MouseEventKind::Moved
    }

    pub(super) fn mouse_opens_cmux_context_menu(mouse: &MouseEvent) -> bool {
        mouse.kind == MouseEventKind::Down(MouseButton::Right)
            && (mouse.modifiers.contains(KeyModifiers::SHIFT)
                || mouse.modifiers.contains(KeyModifiers::ALT))
    }

    pub(super) fn rendered_pointer_route_for_mouse(
        &self,
        mouse: &MouseEvent,
    ) -> PointerRouteIdentity {
        let route = self.rendered_pointer_frame.route_for_mouse(mouse);
        if Self::mouse_opens_cmux_context_menu(mouse) {
            // The menu press never enters the pane's application; async output
            // must not change its recorded route.
            route.normalized_for_cmux_menu()
        } else {
            route
        }
    }

    pub(super) fn pointer_has_capture(&self, kind: MouseEventKind) -> bool {
        match kind {
            MouseEventKind::Drag(button) | MouseEventKind::Up(button) => {
                self.active_pointer_buttons.contains(&button)
            }
            _ => false,
        }
    }

    pub(super) fn fresh_pointer_motion_must_follow_deferred(
        &self,
        input_sequence: Option<u64>,
    ) -> bool {
        input_sequence.is_none()
            && self
                .deferred_input
                .iter()
                .any(|input| matches!(input.event, TerminalInput::Mouse(_)))
    }

    pub(super) fn fresh_input_must_follow_deferred(
        &self,
        input: &TerminalInput,
        input_sequence: Option<u64>,
    ) -> bool {
        if input_sequence.is_some()
            || self.deferred_input.is_empty() && self.pending_pointer_motion.is_none()
        {
            return false;
        }
        if input.is_keyboard_or_paste() {
            true
        } else {
            match input {
                TerminalInput::Mouse(MouseEvent { kind: MouseEventKind::Moved, .. }) => false,
                TerminalInput::Mouse(_) => self.active_pointer_buttons.is_empty(),
                _ => false,
            }
        }
    }

    pub(super) fn terminal_pointer_admission_for_route(
        &self,
        rendered_route: &PointerRouteIdentity,
        mouse: &MouseEvent,
        missing_surface: Option<SurfaceId>,
    ) -> TerminalPointerAdmissionResult {
        if Self::mouse_opens_cmux_context_menu(mouse) {
            // The menu is owned by cmux rather than the terminal
            // application: the press never forwards bytes, so encoder
            // semantics and content-generation admission cannot gate it.
            // Geometry barriers (pending paints, pointer-map mutations)
            // still defer it through the route staleness checks.
            return TerminalPointerAdmissionResult::NotTerminal;
        }
        let Some((surface, input_rect, expected_snapshot)) =
            rendered_route.terminal_pointer_snapshot()
        else {
            return TerminalPointerAdmissionResult::NotTerminal;
        };
        let Some(expected_snapshot) = expected_snapshot else {
            return if missing_surface == Some(surface) {
                TerminalPointerAdmissionResult::NotTerminal
            } else {
                TerminalPointerAdmissionResult::Rejected
            };
        };
        if missing_surface == Some(surface) {
            return TerminalPointerAdmissionResult::Ready(TerminalPointerAdmission {
                surface,
                semantics: expected_snapshot.semantics,
                encoding: TerminalPointerEncoding::None,
            });
        }
        let Some(surface_handle) = self.session.surface(surface) else {
            return TerminalPointerAdmissionResult::Rejected;
        };

        let cell_width = u32::from(self.cell_pixels.0.max(1));
        let cell_height = u32::from(self.cell_pixels.1.max(1));
        let position = (
            (mouse.column as f32 - input_rect.x as f32 + 0.5) * cell_width as f32,
            (mouse.row as f32 - input_rect.y as f32 + 0.5) * cell_height as f32,
        );
        let screen_size = (
            u32::from(input_rect.width).saturating_mul(cell_width),
            u32::from(input_rect.height).saturating_mul(cell_height),
        );
        let input = |action, button, any_button_pressed| MouseInput {
            action,
            button,
            mods: Self::ghostty_mouse_mods(mouse.modifiers),
            position,
            screen_size,
            cell_size: (cell_width, cell_height),
            any_button_pressed,
        };
        let bypasses_terminal_mouse = mouse.modifiers.contains(KeyModifiers::SHIFT)
            || matches!(
                (mouse.kind, self.drag.as_ref()),
                (MouseEventKind::Down(_), Some(Drag::PtyMouse { .. }))
            );
        let guarded = if bypasses_terminal_mouse {
            None
        } else {
            match mouse.kind {
                MouseEventKind::Down(button) => {
                    let press =
                        input(MouseAction::Press, Some(Self::ghostty_mouse_button(button)), true);
                    let release = MouseInput {
                        action: MouseAction::Release,
                        any_button_pressed: false,
                        ..press
                    };
                    let mut press_output = PtyInputBytes::new();
                    let mut release_output = PtyInputBytes::new();
                    let encoded = surface_handle.encode_mouse_press_pair_if_snapshot(
                        expected_snapshot,
                        press,
                        release,
                        &mut press_output,
                        &mut release_output,
                    );
                    encoded.map(|encoded| {
                        (
                            encoded,
                            TerminalPointerEncoding::PressPair {
                                press: press_output,
                                release: release_output,
                            },
                        )
                    })
                }
                MouseEventKind::ScrollUp
                | MouseEventKind::ScrollDown
                | MouseEventKind::ScrollLeft
                | MouseEventKind::ScrollRight
                | MouseEventKind::Moved => {
                    let (action, button) = match mouse.kind {
                        MouseEventKind::ScrollUp => {
                            (MouseAction::Press, Some(GhosttyMouseButton::WheelUp))
                        }
                        MouseEventKind::ScrollDown => {
                            (MouseAction::Press, Some(GhosttyMouseButton::WheelDown))
                        }
                        MouseEventKind::ScrollLeft => {
                            (MouseAction::Press, Some(GhosttyMouseButton::WheelLeft))
                        }
                        MouseEventKind::ScrollRight => {
                            (MouseAction::Press, Some(GhosttyMouseButton::WheelRight))
                        }
                        MouseEventKind::Moved => (MouseAction::Motion, None),
                        _ => unreachable!("guarded by the outer pointer-kind match"),
                    };
                    let mut output = PtyInputBytes::new();
                    let encoded = surface_handle.encode_mouse_if_snapshot(
                        expected_snapshot,
                        input(action, button, false),
                        &mut output,
                    );
                    encoded.map(|encoded| (encoded, TerminalPointerEncoding::Single(output)))
                }
                MouseEventKind::Drag(_) | MouseEventKind::Up(_) => None,
            }
        };
        let encoding = match guarded {
            Some((GuardedMouseEncode::Encoded(Ok(())), encoding)) => encoding,
            Some((GuardedMouseEncode::Contended, _)) => {
                return TerminalPointerAdmissionResult::Contended;
            }
            Some((GuardedMouseEncode::Encoded(Err(_)), _))
            | Some((GuardedMouseEncode::SemanticsChanged, _))
            | Some((GuardedMouseEncode::ContentChanged, _)) => {
                return TerminalPointerAdmissionResult::Rejected;
            }
            None => match surface_handle.try_pointer_snapshot() {
                Some(PointerSnapshotProbe::Contended) => {
                    return TerminalPointerAdmissionResult::Contended;
                }
                Some(PointerSnapshotProbe::Ready(live)) if live == expected_snapshot => {
                    TerminalPointerEncoding::None
                }
                Some(PointerSnapshotProbe::Ready(_)) | None => {
                    return TerminalPointerAdmissionResult::Rejected;
                }
            },
        };
        TerminalPointerAdmissionResult::Ready(TerminalPointerAdmission {
            surface,
            semantics: expected_snapshot.semantics,
            encoding,
        })
    }

    pub(super) fn input_destination(&self, input: &TerminalInput) -> Option<SurfaceId> {
        match input {
            TerminalInput::Keyboard(_)
            | TerminalInput::ClearHistoryKey(_)
            | TerminalInput::Paste(_)
                if self.prompt.is_none()
                    && self.shortcut_help.is_none()
                    && self.omnibar.is_none()
                    && self.focus == FocusTarget::Pane =>
            {
                self.active_surface()
            }
            TerminalInput::FrontendAction { action, .. }
                if !action_is_frontend_local(*action) && self.focus == FocusTarget::Pane =>
            {
                self.active_surface()
            }
            TerminalInput::Mouse(mouse) => self
                .pane_area_at(mouse.column, mouse.row)
                .filter(|area| area.content.contains(mouse.column, mouse.row))
                .map(|area| area.surface),
            _ => None,
        }
    }
}
