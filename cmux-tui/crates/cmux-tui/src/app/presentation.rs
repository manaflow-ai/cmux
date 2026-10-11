//! Render decision and frontend presentation journaling: which render action
//! an event needs, and the presentation snapshot the app journals when focus,
//! size or viewport changes.

use cmux_tui_core::FrontendJournalEvent;
use ratatui::Terminal as RatatuiTerminal;
use ratatui::backend::Backend;

use crate::app::pointer::deferred::PointerRoutePhase;
use crate::app::{
    App, FrontendFocusSnapshot, FrontendPresentationSnapshot, FrontendResizeSnapshot,
    FrontendViewportSnapshot, RenderAction, frontend_journal_event_id,
};

impl App {
    pub(super) fn render_action<B: Backend>(
        &mut self,
        terminal: &mut RatatuiTerminal<B>,
        action: RenderAction,
    ) -> anyhow::Result<()>
    where
        B::Error: Send + Sync + 'static,
    {
        self.ensure_graphics_writer_healthy()?;
        self.mark_pointer_route_for_rebuild(action);
        match action {
            RenderAction::Draw | RenderAction::Paint => {
                self.draw_terminal(terminal, action)?;
                self.emit_graphics()?;
            }
            RenderAction::Graphics => self.emit_dirty_graphics()?,
            RenderAction::None => {}
        }
        if action.rebuilds_pointer_route() {
            self.commit_rendered_pointer_frame_for(action);
            self.pointer_route_phase = if self.pending_graphics_submission.is_some() {
                PointerRoutePhase::GraphicsProcessingPending
            } else {
                PointerRoutePhase::Fresh
            };
        }
        self.journal_frontend_presentation();
        Ok(())
    }

    pub(super) fn frontend_presentation_snapshot(&self) -> FrontendPresentationSnapshot {
        let workspace = self.tree.active_workspace();
        let screen = workspace.and_then(|workspace| workspace.active_screen_ref());
        let pane = screen.and_then(|screen| screen.pane(screen.active_pane));
        let tab = pane.and_then(|pane| pane.tabs.get(pane.active_tab));
        let focus = FrontendFocusSnapshot {
            target: self.focus.frontend_journal_target(),
            workspace_id: workspace.and_then(|workspace| workspace.resource_id.clone()),
            screen_id: screen.and_then(|screen| screen.resource_id.clone()),
            pane_id: pane.and_then(|pane| pane.resource_id.clone()),
            tab_id: tab.and_then(|tab| tab.public_id.clone()),
            content_id: tab.and_then(|tab| tab.content_id.clone()),
        };
        let resize = FrontendResizeSnapshot {
            cols: self.outer_size.0,
            rows: self.outer_size.1,
            cell_width: self.cell_pixels.0,
            cell_height: self.cell_pixels.1,
        };
        let (target, settled) = screen
            .and_then(|screen| self.viewport_states.get(&screen.id))
            .map_or((self.viewport_offset, true), |motion| {
                (motion.target.round() as u64, !motion.animating())
            });
        let viewport = FrontendViewportSnapshot {
            screen_id: screen.and_then(|screen| screen.resource_id.clone()),
            offset: if settled { self.viewport_offset } else { target },
            target,
            settled,
        };
        FrontendPresentationSnapshot { focus, resize, viewport }
    }

    pub(super) fn frontend_presentation_unchanged(&self) -> bool {
        let Some(previous) = &self.last_frontend_presentation else { return false };
        let workspace = self.tree.active_workspace();
        let screen = workspace.and_then(|workspace| workspace.active_screen_ref());
        let pane = screen.and_then(|screen| screen.pane(screen.active_pane));
        let tab = pane.and_then(|pane| pane.tabs.get(pane.active_tab));
        let target = self.focus.frontend_journal_target();
        if previous.focus.target != target
            || previous.focus.workspace_id.as_ref()
                != workspace.and_then(|workspace| workspace.resource_id.as_ref())
            || previous.focus.screen_id.as_ref()
                != screen.and_then(|screen| screen.resource_id.as_ref())
            || previous.focus.pane_id.as_ref() != pane.and_then(|pane| pane.resource_id.as_ref())
            || previous.focus.tab_id.as_ref() != tab.and_then(|tab| tab.public_id.as_ref())
            || previous.focus.content_id.as_ref() != tab.and_then(|tab| tab.content_id.as_ref())
        {
            return false;
        }
        if previous.resize
            != (FrontendResizeSnapshot {
                cols: self.outer_size.0,
                rows: self.outer_size.1,
                cell_width: self.cell_pixels.0,
                cell_height: self.cell_pixels.1,
            })
        {
            return false;
        }
        let (target, settled) = screen
            .and_then(|screen| self.viewport_states.get(&screen.id))
            .map_or((self.viewport_offset, true), |motion| {
                (motion.target.round() as u64, !motion.animating())
            });
        previous.viewport.screen_id.as_ref()
            == screen.and_then(|screen| screen.resource_id.as_ref())
            && previous.viewport.offset == if settled { self.viewport_offset } else { target }
            && previous.viewport.target == target
            && previous.viewport.settled == settled
    }

    pub(super) fn journal_frontend_presentation(&mut self) {
        if self.outer_size.0 == 0 || self.outer_size.1 == 0 {
            return;
        }
        if self.frontend_presentation_unchanged() {
            return;
        }
        let next = self.frontend_presentation_snapshot();
        let previous = self.last_frontend_presentation.replace(next.clone());
        let generation = format!("{}_{}", self.frontend_projection_id, self.session_generation);
        let session = self.session.inner.clone();
        if previous.as_ref().is_none_or(|previous| previous.focus != next.focus) {
            let focus = next.focus;
            self.frontend_journal.send(
                session.clone(),
                FrontendJournalEvent::Focus {
                    event_id: frontend_journal_event_id(),
                    frontend_projection_id: self.frontend_projection_id.clone(),
                    generation: generation.clone(),
                    target: focus.target,
                    workspace_id: focus.workspace_id,
                    screen_id: focus.screen_id,
                    pane_id: focus.pane_id,
                    tab_id: focus.tab_id,
                    content_id: focus.content_id,
                },
            );
        }
        if previous.as_ref().is_none_or(|previous| previous.resize != next.resize) {
            let resize = next.resize;
            self.frontend_journal.send(
                session.clone(),
                FrontendJournalEvent::Resize {
                    event_id: frontend_journal_event_id(),
                    frontend_projection_id: self.frontend_projection_id.clone(),
                    generation: generation.clone(),
                    cols: resize.cols,
                    rows: resize.rows,
                    cell_width: resize.cell_width,
                    cell_height: resize.cell_height,
                },
            );
        }
        if previous.as_ref().is_none_or(|previous| previous.viewport != next.viewport) {
            let viewport = next.viewport;
            self.frontend_journal.send(
                session,
                FrontendJournalEvent::Viewport {
                    event_id: frontend_journal_event_id(),
                    frontend_projection_id: self.frontend_projection_id.clone(),
                    generation,
                    screen_id: viewport.screen_id,
                    offset: viewport.offset,
                    target: viewport.target,
                    settled: viewport.settled,
                },
            );
        }
    }
}
