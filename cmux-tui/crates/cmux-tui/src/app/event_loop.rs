//! The App event loop: host input readiness and batch draining, the main
//! loop over app events, and machine request processing between events.

use std::collections::HashSet;
use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use ratatui::Terminal as RatatuiTerminal;
use ratatui::backend::Backend;

use crate::app::events::AppEvent;
use crate::app::host_input::{HostInputMessage, host_event_retained_bytes};
use crate::app::pointer::deferred::PointerRoutePhase;
use crate::app::{
    App, DEFERRED_INPUT_CAPACITY, MAX_DEFERRED_INPUT_BYTES, RenderAction, TerminalPaintPacer,
};

impl App {
    fn host_input_is_ready(
        deferred_len: usize,
        deferred_bytes: usize,
        route_settled: bool,
        input: &HostInputMessage,
    ) -> bool {
        match input {
            HostInputMessage::Event(event) => {
                let input_bytes = host_event_retained_bytes(event);
                input_bytes > MAX_DEFERRED_INPUT_BYTES
                    || deferred_len < DEFERRED_INPUT_CAPACITY
                        && deferred_bytes.saturating_add(input_bytes) <= MAX_DEFERRED_INPUT_BYTES
            }
            HostInputMessage::Failed(_) => route_settled && deferred_len == 0,
        }
    }

    fn drain_host_input_batch(&mut self, maximum: usize) -> anyhow::Result<(RenderAction, usize)> {
        let mut action = RenderAction::None;
        let mut drained = 0;
        while drained < maximum && !self.quit {
            let deferred_len = self.deferred_input.len();
            let deferred_bytes = self.deferred_input.retained_bytes();
            let route_settled = !self.session.has_pending_mutations()
                && !self.session.remote_tree_is_stale()
                && self.mux_recovery_generation.load(Ordering::Acquire) == 0
                && self.pending_pointer_motion.is_none();
            let Some(input) = self.host_input.pop_if(|input| {
                Self::host_input_is_ready(deferred_len, deferred_bytes, route_settled, input)
            }) else {
                break;
            };
            let event = match input {
                HostInputMessage::Event(event) => AppEvent::Input(event),
                HostInputMessage::Failed(error) => AppEvent::HostInputFailed(error),
            };
            action = self.handle_event_and_process_machine_requests(event, action)?;
            drained += 1;
        }
        Ok((action, drained))
    }

    pub(super) fn handle_event_and_process_machine_requests(
        &mut self,
        event: AppEvent,
        mut action: RenderAction,
    ) -> anyhow::Result<RenderAction> {
        action = action.merge(self.handle(event)?);
        action = action.merge(self.process_machine_requests());
        self.mark_pointer_route_for_rebuild(action);
        Ok(action)
    }

    pub(super) fn event_loop<B: Backend>(
        &mut self,
        terminal: &mut RatatuiTerminal<B>,
        rx: crossbeam_channel::Receiver<AppEvent>,
    ) -> anyhow::Result<()>
    where
        B::Error: Send + Sync + 'static,
    {
        // Initial layout + draw.
        self.draw_terminal(terminal, RenderAction::Draw)?;
        self.emit_graphics()?;
        self.commit_rendered_pointer_frame();
        self.pointer_route_phase = if self.pending_graphics_submission.is_some() {
            PointerRoutePhase::GraphicsProcessingPending
        } else {
            PointerRoutePhase::Fresh
        };
        self.journal_frontend_presentation();
        let mut terminal_paints = TerminalPaintPacer::after_paint(Instant::now());

        let mut replay_ready =
            !self.deferred_input.is_empty() || self.pending_pointer_motion.is_some();
        while !self.quit
            && !crate::shutdown_requested()
            && !self.session.daemon_shutdown_requested()
            && !self.owner_shutdown_requested()
        {
            if replay_ready {
                let replay = self.replay_deferred_input_batch()?;
                let action = terminal_paints.render_immediately(replay.action, Instant::now());
                self.render_action(terminal, action)?;
                self.retry_pending_surface_attach();
                replay_ready = self.replay_can_continue_immediately(replay.disposition);
                continue;
            }
            let (mut action, drained_host_input) = self.drain_host_input_batch(256)?;
            // Block for the first event, then drain whatever queued so a
            // torrent of pty output coalesces into one frame.
            let timeout = if drained_host_input > 0 {
                Duration::ZERO
            } else if self.viewport_animation_active() {
                Duration::from_millis(16)
            } else if self.shake_frames > 0
                || self.selection_auto_scroll_active()
                || self.toast.is_some()
            {
                Duration::from_millis(30)
            } else {
                Duration::from_millis(250)
            };
            let timeout = terminal_paints.wait_timeout(timeout, Instant::now());
            let mut toast_expired_on_timeout = false;
            let first = match rx.recv_timeout(timeout) {
                Ok(event) => Some(event),
                Err(crossbeam_channel::RecvTimeoutError::Timeout) => {
                    if self.shake_frames > 0 {
                        action = RenderAction::Draw;
                    }
                    if self.auto_scroll_selection_tick() {
                        action = action.merge(RenderAction::Draw);
                    }
                    if self.expire_toast() {
                        toast_expired_on_timeout = true;
                        action = action.merge(RenderAction::Draw);
                    }
                    if self.tick_sidebar_files() {
                        action = action.merge(RenderAction::Draw);
                    }
                    None
                }
                Err(crossbeam_channel::RecvTimeoutError::Disconnected) => {
                    let action =
                        terminal_paints.render_immediately(RenderAction::None, Instant::now());
                    self.render_action(terminal, action)?;
                    break;
                }
            };
            // Timeout work can mutate hit-tested state without entering
            // `handle`. Publish its pending render boundary before draining
            // pointer input that arrived concurrently with the timeout.
            self.mark_pointer_route_for_rebuild(action);
            #[cfg(test)]
            if first.is_none()
                && let Some(hook) = self.timeout_drain_hook.take()
            {
                hook(self);
            }
            if let Some(event) = first {
                action = self.handle_event_and_process_machine_requests(event, action)?;
            }
            for _ in 0..256 {
                match rx.try_recv() {
                    Ok(event) => {
                        action = self.handle_event_and_process_machine_requests(event, action)?;
                    }
                    Err(_) => break,
                }
            }
            action = action.merge(self.apply_graphics_completion());
            action = action.merge(self.process_machine_requests());
            // Always drain retained failures. PtyFailuresReady only shortens
            // the idle wait, so a failed try_send cannot create a lost wakeup.
            action = action.merge(self.apply_pty_failures());
            self.ensure_graphics_writer_healthy()?;
            if self.session.take_cancellation_pending() {
                if self.session.has_pending_mutations() {
                    self.session.defer_cancellation();
                } else {
                    self.apply_session_cancellation();
                    action = action.merge(RenderAction::Draw);
                }
            }
            if self.quit {
                break;
            }
            // Keep a toast reintroduced by the timeout drain hook alive for one iteration.
            if !toast_expired_on_timeout && self.expire_toast() {
                action = action.merge(RenderAction::Draw);
            }
            action = action.merge(self.advance_viewport_animation(Instant::now()));
            if self.advance_expired_durable_notice() {
                action = action.merge(RenderAction::Draw);
            }
            self.retry_pending_surface_attach();
            if self.browser_input.resize_retry_due() {
                let mut visible_surfaces =
                    self.pane_areas.iter().map(|area| area.surface).collect::<HashSet<_>>();
                if let Some(surface) = self.sidebar_plugin_surface {
                    visible_surfaces.insert(surface);
                }
                if self.browser_input.visible_resize_retry_due(&visible_surfaces) {
                    self.reassert_visible_surface_sizes();
                }
            }
            if self.session.surface_resize_retry_due() {
                self.reassert_visible_surface_sizes();
            }
            self.retry_sidebar_plugin_if_due();
            self.retry_background_refresh_if_due();
            if self.session.surface_overflow_retry_due() {
                action = action.merge(RenderAction::Draw);
            }
            let now = Instant::now();
            let action = terminal_paints.schedule(action, now);
            let action = if !self.deferred_input.is_empty() || self.pending_pointer_motion.is_some()
            {
                terminal_paints.render_immediately(action, now)
            } else {
                action
            };
            self.render_action(terminal, action)?;
            self.retry_pending_surface_attach();
            if !self.deferred_input.is_empty() || self.pending_pointer_motion.is_some() {
                let replay = self.replay_deferred_input_batch()?;
                let action = terminal_paints.render_immediately(replay.action, Instant::now());
                self.render_action(terminal, action)?;
                self.retry_pending_surface_attach();
                replay_ready = self.replay_can_continue_immediately(replay.disposition);
            }
        }
        Ok(())
    }
}
