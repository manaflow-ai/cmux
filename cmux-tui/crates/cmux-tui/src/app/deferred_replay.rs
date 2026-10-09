//! Replaying deferred input: replay barriers, semantic destination outcomes,
//! the deferred batch replay, and pointer route staleness checks (including
//! graphics changes under the pointer).

use std::sync::atomic::Ordering;

use cmux_tui_core::Rect;
use crossterm::event::MouseEvent;

#[cfg(test)]
use crate::app::GRAPHICS_ROUTE_COMPARISONS;
use crate::app::graphics::{
    GRAPHICS_ROUTE_INDEX_FAST_PATH_LIMIT, GraphicIdentity, GraphicRouteIndex, bounding_rect,
};
use crate::app::host_input::TerminalInput;
use crate::app::pointer::deferred::{
    DeferredInput, DeferredInputAdmission, DeferredPointerInput, DeferredReplayDisposition,
    DeferredReplayOutcome, PointerRoutePhase, ReplayedInputContext, SemanticDestinationOutcome,
};
use crate::app::{App, RenderAction};
use crate::localization;

impl App {
    pub(super) fn replay_can_continue_immediately(
        &self,
        disposition: DeferredReplayDisposition,
    ) -> bool {
        matches!(
            disposition,
            DeferredReplayDisposition::RenderBoundary | DeferredReplayDisposition::Yield
        ) && (!self.deferred_input.is_empty() || self.pending_pointer_motion.is_some())
            && !self.next_replay_pointer_route_is_stale()
    }

    fn pointer_replay_barrier(action: RenderAction) -> DeferredReplayDisposition {
        // RenderBoundary promises the event loop that rendering this batch can
        // make the next replay attempt progress.
        if action.rebuilds_pointer_route() {
            DeferredReplayDisposition::RenderBoundary
        } else {
            DeferredReplayDisposition::Blocked
        }
    }

    fn retains_input_sequence(&self, sequence: u64) -> bool {
        self.pending_pointer_motion.is_some_and(|pointer| pointer.sequence == sequence)
            || self.deferred_input.iter().any(|input| input.sequence == sequence)
    }

    pub(super) fn mark_semantic_destination_failed(&mut self, intent: u64) {
        if let Some(outcome) = self.semantic_destination_outcomes.get_mut(&intent) {
            *outcome = SemanticDestinationOutcome::Failed;
        }
    }

    pub(super) fn retire_deferred_semantic_result(&mut self, input: &DeferredInput) {
        if let Some(intent) = input.admission.semantic_result {
            self.mark_semantic_destination_failed(intent);
        }
    }

    fn semantic_dependency_outcome(
        &self,
        admission: &DeferredInputAdmission,
    ) -> Option<SemanticDestinationOutcome> {
        admission.semantic_dependency.map(|intent| {
            self.semantic_destination_outcomes
                .get(&intent)
                .copied()
                .unwrap_or(SemanticDestinationOutcome::Failed)
        })
    }

    pub(super) fn clear_finished_semantic_destinations(&mut self) {
        if self.deferred_input.is_empty()
            && !self
                .semantic_destination_outcomes
                .values()
                .any(|outcome| *outcome == SemanticDestinationOutcome::Pending)
        {
            self.latest_semantic_destination_intent = None;
            self.semantic_destination_outcomes.clear();
        }
    }

    pub(super) fn replay_deferred_input_batch(&mut self) -> anyhow::Result<DeferredReplayOutcome> {
        const MAX_REPLAYED_INPUTS: usize = 256;
        let mut action = RenderAction::None;
        // A replayed event can discover that its destination mirror is still
        // unavailable and append itself again. Only process the queue snapshot
        // that existed at entry so a blocked attach cannot spin this frame.
        let replay_count = self
            .deferred_input
            .len()
            .saturating_add(usize::from(self.pending_pointer_motion.is_some()))
            .min(MAX_REPLAYED_INPUTS);
        let mut replayed = 0;
        while replayed < replay_count {
            let pointer_is_next = self.pending_pointer_motion.as_ref().is_some_and(|pointer| {
                self.deferred_input.front().is_none_or(|input| pointer.sequence < input.sequence)
            });
            if pointer_is_next {
                if self.pending_pointer_motion.is_some_and(|pointer| {
                    pointer.focus_generation != self.pointer_focus_generation
                }) {
                    self.pending_pointer_motion = None;
                    replayed += 1;
                    continue;
                }
                if self
                    .pending_pointer_motion
                    .is_some_and(|pointer| self.pointer_route_is_stale_for_mouse(&pointer.event))
                {
                    return Ok(DeferredReplayOutcome {
                        action,
                        disposition: Self::pointer_replay_barrier(action),
                    });
                }
                let pointer = self.pending_pointer_motion.take().unwrap();
                replayed += 1;
                let pointer_action = self.handle_replayed_input(
                    TerminalInput::Mouse(pointer.event),
                    pointer.sequence,
                    Some(ReplayedInputContext {
                        pointer: Some(DeferredPointerInput {
                            focus_generation: pointer.focus_generation,
                            pointer_map_generation: self
                                .rendered_pointer_frame
                                .pointer_map_generation,
                            route: None,
                        }),
                        admission: None,
                    }),
                )?;
                action = action.merge(pointer_action);
                action = action.merge(self.process_machine_requests());
                // A missing mirror can retain the same logical input again.
                // Stop here so later sequences cannot overtake it.
                if self.retains_input_sequence(pointer.sequence) {
                    return Ok(DeferredReplayOutcome {
                        action,
                        disposition: DeferredReplayDisposition::Blocked,
                    });
                }
                continue;
            }
            if self.session.has_pending_mutations()
                || self.session.remote_tree_is_stale()
                || self.mux_recovery_generation.load(Ordering::Acquire) != 0
            {
                return Ok(DeferredReplayOutcome {
                    action,
                    disposition: DeferredReplayDisposition::Blocked,
                });
            }
            let Some(input) = self.deferred_input.front() else { break };
            match self.semantic_dependency_outcome(&input.admission) {
                Some(SemanticDestinationOutcome::Pending) => {
                    return Ok(DeferredReplayOutcome {
                        action,
                        disposition: DeferredReplayDisposition::Blocked,
                    });
                }
                Some(SemanticDestinationOutcome::Failed) => {
                    let input = self.deferred_input.pop_front().unwrap();
                    self.retire_deferred_semantic_result(&input);
                    self.status_message = Some(
                        localization::catalog()
                            .terminal
                            .deferred_input_destination_changed
                            .to_string(),
                    );
                    action = action.merge(RenderAction::Draw);
                    replayed += 1;
                    continue;
                }
                Some(SemanticDestinationOutcome::Resolved(surface))
                    if !input.admission.client_owned
                        && !Self::input_accepts_semantic_destination(&input.event)
                        && self.input_destination(&input.event) != Some(surface) =>
                {
                    let input = self.deferred_input.pop_front().unwrap();
                    self.retire_deferred_semantic_result(&input);
                    self.status_message = Some(
                        localization::catalog()
                            .terminal
                            .deferred_input_destination_changed
                            .to_string(),
                    );
                    action = action.merge(RenderAction::Draw);
                    replayed += 1;
                    continue;
                }
                Some(SemanticDestinationOutcome::Resolved(_)) | None => {}
            }
            if input
                .pointer
                .as_ref()
                .is_some_and(|pointer| pointer.focus_generation != self.pointer_focus_generation)
            {
                self.deferred_input.pop_front();
                replayed += 1;
                continue;
            }
            if let TerminalInput::Mouse(mouse) = &input.event
                && self.pointer_route_is_stale_for_mouse(mouse)
            {
                return Ok(DeferredReplayOutcome {
                    action,
                    disposition: Self::pointer_replay_barrier(action),
                });
            }
            let input = self.deferred_input.pop_front().unwrap();
            replayed += 1;
            let replay_context =
                ReplayedInputContext { pointer: input.pointer, admission: Some(input.admission) };
            let input_action =
                self.handle_replayed_input(input.event, input.sequence, Some(replay_context))?;
            action = action.merge(input_action);
            action = action.merge(self.process_machine_requests());
            // A missing mirror can retain the same logical input again.
            // Stop here so later sequences cannot overtake it.
            if self.retains_input_sequence(input.sequence) {
                return Ok(DeferredReplayOutcome {
                    action,
                    disposition: DeferredReplayDisposition::Blocked,
                });
            }
        }
        let has_remaining_input =
            !self.deferred_input.is_empty() || self.pending_pointer_motion.is_some();
        let disposition = if !has_remaining_input {
            DeferredReplayDisposition::Drained
        } else if replayed >= MAX_REPLAYED_INPUTS {
            DeferredReplayDisposition::Yield
        } else if self.next_replay_pointer_route_is_stale() {
            Self::pointer_replay_barrier(action)
        } else {
            DeferredReplayDisposition::Blocked
        };
        self.clear_finished_semantic_destinations();
        Ok(DeferredReplayOutcome { action, disposition })
    }

    #[cfg(test)]
    pub(super) fn replay_deferred_input(&mut self) -> anyhow::Result<RenderAction> {
        Ok(self.replay_deferred_input_batch()?.action)
    }

    fn pointer_route_is_globally_stale(&self) -> bool {
        self.session.has_pending_pointer_mutations()
            || self.session.remote_tree_is_stale()
            || self.mux_recovery_generation.load(Ordering::Acquire) != 0
            || self.pointer_route_phase.invalidates_all_pointer_routes()
    }

    pub(super) fn pointer_route_is_stale_for_mouse(&self, mouse: &MouseEvent) -> bool {
        if self.pointer_route_is_globally_stale() {
            return true;
        }
        if Self::mouse_opens_cmux_context_menu(mouse) {
            // The menu is owned by cmux rather than the browser bitmap or a
            // graphics scene. Keep global and layout barriers above, but do
            // not wait for content admission this press never enters.
            return false;
        }
        if self.pending_graphics_changes_cell(mouse.column, mouse.row) {
            return true;
        }
        if !matches!(
            self.pointer_route_phase,
            PointerRoutePhase::GraphicsRenderPending | PointerRoutePhase::GraphicsProcessingPending
        ) {
            return false;
        }
        let route = self.rendered_pointer_frame.route_for_mouse(mouse);
        let Some((surface, rendered_generation)) = route.browser_content_generation() else {
            return false;
        };
        rendered_generation.is_none_or(|generation| {
            !self
                .session
                .surface(surface)
                .is_some_and(|surface| surface.browser_accepts_pointer_frame(generation))
        })
    }

    fn graphics_share_pointer_route(
        &self,
        processed: GraphicIdentity,
        pending: GraphicIdentity,
    ) -> bool {
        #[cfg(test)]
        GRAPHICS_ROUTE_COMPARISONS.with(|count| count.set(count.get().saturating_add(1)));
        if !processed.same_pointer_layout(pending) {
            return false;
        }
        let surface_id = processed.surface;
        match (processed.pointer_frame_seq, pending.pointer_frame_seq) {
            (None, None) => true,
            (Some(processed), Some(pending)) if processed == pending => true,
            (Some(processed), Some(pending)) => {
                self.session.surface(surface_id).is_some_and(|surface| {
                    surface.browser_pointer_frame_is_in_current_route(processed)
                        && surface.browser_pointer_frame_is_in_current_route(pending)
                })
            }
            (None, Some(_)) | (Some(_), None) => false,
        }
    }

    pub(super) fn graphics_changed_rect_bound(
        &self,
        previous: &[GraphicIdentity],
        next: &[GraphicIdentity],
    ) -> Option<Rect> {
        if previous.len().saturating_add(next.len()) <= GRAPHICS_ROUTE_INDEX_FAST_PATH_LIMIT {
            return previous
                .iter()
                .filter(|graphic| {
                    !next
                        .iter()
                        .any(|candidate| self.graphics_share_pointer_route(**graphic, *candidate))
                })
                .chain(next.iter().filter(|graphic| {
                    !previous
                        .iter()
                        .any(|candidate| self.graphics_share_pointer_route(**graphic, *candidate))
                }))
                .map(|graphic| graphic.rect)
                .reduce(bounding_rect);
        }
        let previous_index = GraphicRouteIndex::build(self, previous);
        let next_index = GraphicRouteIndex::build(self, next);
        let mut changed = None;
        for &graphic in previous {
            if !previous_index.has_match(graphic, &next_index) {
                changed =
                    Some(changed.map_or(graphic.rect, |bound| bounding_rect(bound, graphic.rect)));
            }
        }
        for &graphic in next {
            if !next_index.has_match(graphic, &previous_index) {
                changed =
                    Some(changed.map_or(graphic.rect, |bound| bounding_rect(bound, graphic.rect)));
            }
        }
        changed
    }

    pub(super) fn pending_graphics_changes_cell(&self, x: u16, y: u16) -> bool {
        if self.pointer_route_phase != PointerRoutePhase::GraphicsProcessingPending
            || self.pending_graphics_submission.is_none()
        {
            return false;
        }
        if self.pending_graphics_affected_rect.is_some_and(|rect| rect.contains(x, y)) {
            return true;
        }
        let pending = self.pending_graphics_snapshot.as_deref().unwrap_or(&[]);
        let graphic_at = |snapshot: &[GraphicIdentity]| {
            snapshot.iter().copied().find(|graphic| graphic.rect.contains(x, y))
        };
        match (graphic_at(&self.last_graphics_snapshot), graphic_at(pending)) {
            (Some(processed), Some(pending)) => {
                !self.graphics_share_pointer_route(processed, pending)
            }
            (None, None) => false,
            (Some(_), None) | (None, Some(_)) => true,
        }
    }

    fn next_replay_pointer_route_is_stale(&self) -> bool {
        if self.pointer_route_is_globally_stale() {
            return true;
        }
        let pending_motion_is_next = self.pending_pointer_motion.as_ref().is_some_and(|pointer| {
            self.deferred_input.front().is_none_or(|input| pointer.sequence < input.sequence)
        });
        if pending_motion_is_next {
            return self
                .pending_pointer_motion
                .as_ref()
                .is_some_and(|pointer| self.pointer_route_is_stale_for_mouse(&pointer.event));
        }
        self.deferred_input.front().is_some_and(|input| match &input.event {
            TerminalInput::Mouse(mouse) => self.pointer_route_is_stale_for_mouse(mouse),
            _ => false,
        })
    }
}
