//! An agent's layout change never shrinks a terminal a person watches on
//! another device (docs/shared-terminal-sizing.md, "Agent layout changes").
//!
//! When an agent or a script (a process in a cmux terminal, an acpmux
//! session, an app) splits, moves or resizes panes, this Mac's panes of that
//! workspace get narrower and their views report the smaller size. Under Fit
//! the smallest viewer that report used to take the grid from the phone the
//! person was reading (39x26 on a phone of 54 columns, 2026-11-15). Now such a
//! smaller report of one of this Mac's views does not count while another
//! view counts: the view keeps counting at its size before the change until
//! the person uses that pane (input, or a focus click), or until no other
//! view counts. The published size state stays consistent: the engine sees
//! the kept size.

use super::*;
use std::sync::PoisonError;
use std::time::Duration;
use std::time::Instant;

/// How long after an agent's layout change a smaller report of one of this
/// Mac's views of that workspace is taken as caused by it. The app reports
/// a pane's new size within a frame of the layout event.
const AGENT_LAYOUT_WINDOW: Duration = Duration::from_secs(5);

/// Layout operations that can make an existing pane smaller.
fn may_shrink_panes(operation: ResourceOperation) -> bool {
    matches!(
        operation,
        ResourceOperation::PaneCreate
            | ResourceOperation::PaneSplit
            | ResourceOperation::PaneMove
            | ResourceOperation::PaneSwap
            | ResourceOperation::PaneZoom
            | ResourceOperation::PaneSplitRatioSet
            | ResourceOperation::PaneViewportWidthSet
            | ResourceOperation::ColumnUpdate
            | ResourceOperation::WorkspaceLayoutApply
    )
}

/// Whether `actor` is an agent or a script, not a person: a process in a
/// cmux terminal, an acpmux session, an app. The verified cmux app, the
/// local user's own connections and other machines are people.
fn is_agent(actor: &Actor) -> bool {
    matches!(actor, Actor::Terminal { .. } | Actor::AcpSession { .. } | Actor::App { .. })
}

impl Mux {
    /// Before `operation` of `actor` runs: marks the views it may shrink. A
    /// view's report can arrive before the commit returns, so every placement
    /// is marked now and [`Self::narrow_agent_layout_marks`] keeps only the
    /// change's workspace once it is known.
    pub(in crate::mux) fn mark_agent_layout_change(
        &self,
        actor: &Actor,
        operation: ResourceOperation,
    ) -> Option<Instant> {
        if !is_agent(actor) || !may_shrink_panes(operation) {
            return None;
        }
        let now = Instant::now();
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        let sizing = &mut *sizing;
        sizing.agent_layout_marks.retain(|_, at| now.duration_since(*at) < AGENT_LAYOUT_WINDOW);
        let placements = sizing.terminal_runtime_by_placement.keys().copied().collect::<Vec<_>>();
        for placement in placements {
            sizing.agent_layout_marks.insert(placement, now);
        }
        Some(now)
    }

    /// After the change committed: keeps the marks `mark_agent_layout_change`
    /// set at `at` only on the placements of the workspace the change was in
    /// (its result's tab or screen). When the result names neither, every
    /// mark stays until the window ends.
    pub(in crate::mux) fn narrow_agent_layout_marks(&self, at: Instant, result: &Value) {
        let Some(workspace) = self.workspace_of_topology_result(result) else { return };
        let marked = {
            let sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
            sizing
                .agent_layout_marks
                .iter()
                .filter(|(_, marked_at)| **marked_at == at)
                .map(|(placement, _)| *placement)
                .collect::<Vec<_>>()
        };
        // The workspaces are read without the sizing lock held.
        let elsewhere = marked
            .into_iter()
            .filter(|placement| self.surface_workspace(*placement) != Some(workspace))
            .collect::<Vec<_>>();
        if elsewhere.is_empty() {
            return;
        }
        let mut sizing = self.client_sizing.lock().unwrap_or_else(PoisonError::into_inner);
        for placement in elsewhere {
            if sizing.agent_layout_marks.get(&placement) == Some(&at) {
                sizing.agent_layout_marks.remove(&placement);
            }
        }
    }

    fn workspace_of_topology_result(&self, result: &Value) -> Option<WorkspaceId> {
        let tab = result
            .get("tab_id")
            .and_then(Value::as_str)
            .and_then(|id| TabPublicId::parse(id.to_string()).ok());
        if let Some(tab) = tab
            && let Some(surface) =
                self.with_state(|state| state.resource_indexes.tabs.get(&tab).copied())
        {
            return self.surface_workspace(surface);
        }
        let screen = result
            .get("screen")
            .or_else(|| result.get("screen_id"))
            .and_then(Value::as_str)
            .and_then(|id| ScreenPublicId::parse(id.to_string()).ok())?;
        self.with_state(|state| {
            let screen = state.resource_indexes.screens.get(&screen).copied()?;
            state
                .workspaces
                .iter()
                .find(|workspace| workspace.screens.iter().any(|candidate| candidate.id == screen))
                .map(|workspace| workspace.id)
        })
    }

    /// The viewport `participant` (the view of `client` on `placement`)
    /// counts at: its report, unless it is one of this Mac's views whose
    /// report an agent's layout change made smaller while another view
    /// counts. Then it keeps counting at its size before the change.
    pub(in crate::mux) fn hold_agent_layout_report(
        &self,
        sizing: &mut ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
        participant: &mut TerminalSizingParticipant,
    ) {
        let marked = sizing
            .agent_layout_marks
            .get(&placement)
            .is_some_and(|at| at.elapsed() < AGENT_LAYOUT_WINDOW);
        let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { return };
        let id = participant.id.as_str();
        let Some(reported) = participant.viewport.map(TerminalGridSize::clamped) else {
            entry.agent_layout_holds.remove(id);
            return;
        };
        let covers =
            |kept: TerminalGridSize| reported.cols >= kept.cols && reported.rows >= kept.rows;
        if let Some(kept) = entry.agent_layout_holds.get(id).copied() {
            if covers(kept) {
                entry.agent_layout_holds.remove(id);
            } else {
                participant.viewport = Some(kept);
            }
            return;
        }
        if !marked || !participant.device_kind.is_desktop() || !self.is_this_mac_connection(client)
        {
            return;
        }
        let Some(kept) = entry.engine.participant(id).and_then(|current| current.viewport) else {
            return;
        };
        if covers(kept) {
            return;
        }
        let others_count =
            entry.engine.participant_ids().any(|other| other != id && entry.engine.counts(other));
        if !others_count {
            return;
        }
        entry.agent_layout_holds.insert(id.to_owned(), kept);
        participant.viewport = Some(kept);
    }

    /// The person used `client`'s view of `placement` (input or a focus
    /// click): its own report counts again. True when the engine changed.
    pub(in crate::mux) fn end_agent_layout_hold(
        &self,
        sizing: &mut ClientSizingState,
        runtime: SurfaceId,
        placement: SurfaceId,
        client: u64,
    ) -> bool {
        sizing.agent_layout_marks.remove(&placement);
        let id = view_participant_id(runtime, placement, client);
        let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { return false };
        if entry.agent_layout_holds.remove(&id).is_none() {
            return false;
        }
        self.sync_terminal_view_report_locked(sizing, runtime, placement, client)
    }

    /// A view keeps its size only while another view counts: once none does,
    /// every kept view counts at its own report again.
    pub(in crate::mux) fn settle_agent_layout_holds(
        &self,
        sizing: &mut ClientSizingState,
        runtime: SurfaceId,
    ) {
        let Some(entry) = sizing.terminal_sizing.get_mut(&runtime) else { return };
        if entry.agent_layout_holds.is_empty() {
            return;
        }
        let alone = entry
            .agent_layout_holds
            .keys()
            .filter(|id| {
                !entry
                    .engine
                    .participant_ids()
                    .any(|other| other != id.as_str() && entry.engine.counts(other))
            })
            .cloned()
            .collect::<Vec<_>>();
        let mut views = Vec::new();
        for id in alone {
            entry.agent_layout_holds.remove(&id);
            if let Some(member) = entry.members.get(&id).filter(|member| member.view.is_none()) {
                views.push((member.placement, member.client));
            }
        }
        for (placement, client) in views {
            self.sync_terminal_view_report_locked(sizing, runtime, placement, client);
        }
    }
}
