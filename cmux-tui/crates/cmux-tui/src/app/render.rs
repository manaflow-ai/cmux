//! Drawing a frame: graphics writer health, `draw_terminal`, text input
//! viewports, host mouse capture and scoped host terminal state, frame layout
//! preparation and the terminal cursor spec.

use std::io::Write;

use cmux_tui_core::{PointerSemanticProbe, Rect, SurfaceId, SurfaceKind};
use ghostty_vt::{CursorShape, Rgb};
use ratatui::Terminal as RatatuiTerminal;
use ratatui::backend::Backend;
use unicode_width::UnicodeWidthStr;

use crate::app::layout::SidebarLayout;
use crate::app::pointer::deferred::OuterCursorSpec;
use crate::app::terminal_guard::catch_renderer_panic;
use crate::app::{
    App, RenderAction, host_mouse_capture_escape_if_changed, outer_cursor_escape_if_changed,
};
use crate::localization;
use crate::ui::graphics_writer::GraphicsWriter;

impl App {
    pub(super) fn ensure_graphics_writer_healthy(&self) -> anyhow::Result<()> {
        let Some(failure) = self.graphics_writer.as_ref().and_then(GraphicsWriter::failure) else {
            return Ok(());
        };
        let messages = &localization::catalog().graphics;
        let message = if failure.parser_reset_required {
            messages.parser_recovery_failed
        } else {
            messages.output_failed
        };
        anyhow::bail!("{message}")
    }

    pub(super) fn draw_terminal<B: Backend>(
        &mut self,
        terminal: &mut RatatuiTerminal<B>,
        action: RenderAction,
    ) -> anyhow::Result<()>
    where
        B::Error: Send + Sync + 'static,
    {
        let lock = self.stdout_lock.clone();
        let _guard = lock.lock();
        lock.recover_stream_locked()?;
        self.ensure_graphics_writer_healthy()?;
        self.painted_durable_notice_this_frame = None;
        catch_renderer_panic(|| {
            terminal.draw(|frame| {
                self.prepare_frame_layout(frame.area(), action);
                crate::ui::draw(self, frame);
            })
        })??;
        self.sync_text_input_viewports();
        if self.graphics_host_scene_reset_pending {
            if let Some(writer) = &self.graphics_writer {
                writer.invalidate_host_scene();
            }
            self.graphics_scene_cache.invalidate();
            self.graphics_host_scene_reset_pending = false;
        }
        self.commit_successful_durable_notice_paint();
        self.submit_pending_durable_notice_ack();
        if let Some(sequence) =
            outer_cursor_escape_if_changed(self.applied_outer_cursor, self.desired_outer_cursor)
        {
            let mut stdout = std::io::stdout();
            stdout.write_all(sequence.as_bytes())?;
            stdout.flush()?;
            self.applied_outer_cursor = Some(self.desired_outer_cursor);
        }
        let desired_mouse_capture = self.desired_host_mouse_capture();
        if let Some(sequence) = host_mouse_capture_escape_if_changed(
            self.host_mouse_capture_applied,
            desired_mouse_capture,
        ) {
            let mut stdout = std::io::stdout();
            stdout.write_all(sequence.as_bytes())?;
            stdout.flush()?;
            self.host_mouse_capture_applied = Some(desired_mouse_capture);
        }
        Ok(())
    }

    /// Persist the viewport derived by the immutable text-input renderers
    /// after a successful frame, so the next input event starts from the
    /// window the user actually saw.
    fn sync_text_input_viewports(&mut self) {
        if let Some(prompt) = self.prompt.as_mut() {
            let width = prompt.input_rect.width as usize;
            prompt.input.sync_viewport(width);
        }

        let omnibar_width = self.omnibar.as_ref().and_then(|state| {
            self.pane_areas
                .iter()
                .find(|area| area.pane == state.pane && area.surface == state.surface)
                .and_then(|area| area.omnibar)
                .map(|rect| rect.width as usize)
        });
        if let Some(state) = self.omnibar.as_mut() {
            state.input.sync_viewport(omnibar_width.unwrap_or_default());
        }

        let menu_search_width = self.menu.as_ref().and_then(|menu| {
            let search = menu.search.as_ref()?;
            let level = menu.levels.first()?;
            let title_width = level.rect.width.saturating_sub(4) as usize;
            // The literal spaces around the label keep the three segments
            // separate, so their display widths add without constructing a
            // temporary prefix string on every frame.
            let prefix_width = " "
                .width()
                .saturating_add(search.label.width())
                .saturating_add(" · ".width())
                .min(title_width);
            Some(title_width.saturating_sub(prefix_width).saturating_sub(1))
        });
        if let Some(menu) = self.menu.as_mut()
            && let Some(search) = menu.search.as_mut()
        {
            search.input.sync_viewport(menu_search_width.unwrap_or_default());
        }

        if self.sidebar_files.filter_mode() {
            let width = self
                .workspace_sidebar_area(self.outer_size.1)
                .map_or(0, |area| area.width.saturating_sub(2) as usize);
            self.sidebar_files.sync_filter_viewport(width);
        }
    }

    /// Full-TUI clients always capture host mouse input. A scoped attach
    /// client mirrors the inner terminal's mouse-tracking state instead, so
    /// the host terminal keeps native click and selection handling whenever
    /// the inner application did not request mouse input.
    ///
    /// The state is read from the scoped surface's terminal itself (the
    /// mirror a daemon replay restores and live output keeps current), never
    /// from the rendered-frame projection: `draw_content` removes a
    /// surface's rendered semantics at the start of every draw and restores
    /// them only after a successful render, so a frame whose pane render
    /// failed or was skipped (renderer error while daemon output is applied,
    /// zero-sized pane during layout churn) must not release capture the
    /// inner application still holds. When the state is momentarily
    /// unknowable (terminal lock contended, surface gone during teardown)
    /// the client keeps the capture it last applied instead of toggling the
    /// host.
    pub(super) fn desired_host_mouse_capture(&self) -> bool {
        let Some(surface_id) = self.surface_only else { return true };
        let canonical = self
            .session
            .surface(surface_id)
            .and_then(|surface| surface.try_pointer_semantics())
            .and_then(|probe| match probe {
                PointerSemanticProbe::Ready(semantics) => Some(semantics.mouse_tracking),
                PointerSemanticProbe::Contended => None,
            });
        canonical.unwrap_or_else(|| self.host_mouse_capture_applied.unwrap_or(false))
    }

    /// A scoped attach client mirrors the inner terminal's input modes onto
    /// the host terminal, but the host can silently drop those modes without
    /// the client ever seeing it: app-side session restore can write a reset
    /// into the Ghostty surface after the client's capture-on burst, or the
    /// host can re-initialize the surface on relaunch. The per-frame capture
    /// (and cursor) sync is edge-triggered on the last applied state, so a
    /// dropped mode is never re-asserted and the bridge tab loses mouse input
    /// until the inner application happens to toggle modes (btop never does).
    ///
    /// Focus-in and resize are the two host-visible signals that the host may
    /// have re-initialized: Ghostty emits a focus-in report on every window
    /// re-activation and app reopen, and the reattached surface is resized to
    /// the new window's geometry. Clearing the applied host bookkeeping on
    /// those events forces the next frame to re-derive the canonical inner
    /// state and re-emit it, recovering any mode the host silently dropped.
    /// Scoped clients only: a full TUI owns the whole host surface and
    /// re-emits its modes through its own lifecycle.
    pub(super) fn reassert_scoped_host_terminal_state(&mut self) {
        if self.surface_only.is_none() {
            return;
        }
        // Keep the last applied state when the inner terminal cannot be
        // probed. Clearing it here would make the next frame guess `false`
        // and release host capture during a transient lock/contention.
        let probe_available = self
            .surface_only
            .and_then(|surface_id| self.session.surface(surface_id))
            .and_then(|surface| surface.try_pointer_semantics())
            .is_some_and(|probe| matches!(probe, PointerSemanticProbe::Ready(_)));
        if probe_available {
            self.host_mouse_capture_applied = None;
        }
        // The previous frame may have applied an authored style. If the
        // inner application reset DECSCUSR, clear the desired style now so
        // focus or resize cannot replay stale cursor state onto the host.
        if self
            .surface_only
            .and_then(|surface_id| self.session.surface(surface_id))
            .is_some_and(|surface| !surface.cursor_style_authored())
        {
            self.desired_outer_cursor = OuterCursorSpec::Reset;
        }
        self.applied_outer_cursor = None;
    }

    fn prepare_frame_layout(&mut self, area: ratatui::layout::Rect, action: RenderAction) {
        let size = (area.width, area.height);
        if action == RenderAction::Draw || self.outer_size != size {
            self.sync_layout(size);
        }
        if area.width == 0 || area.height == 0 {
            self.clear_empty_frame_geometry();
        }
    }

    fn clear_empty_frame_geometry(&mut self) {
        self.sidebar_layout = SidebarLayout::default();
        self.sidebar_width = 0;
        self.machine_sidebar_width = 0;
        self.tabs_sidebar_width = 0;
        self.content_area = Rect::default();
        self.hits.clear();
        self.pane_areas.clear();
        self.viewport_projection.clear();
        self.viewport_layout.clear();
        self.viewport_stacked_headers.clear();
        self.viewport_virtual_width = 0;
        self.viewport_offset = 0;
        self.rendered_terminal_sizes.clear();
        self.rendered_terminal_bounds.clear();
        self.rendered_kitty_graphics.clear();
        self.rendered_terminal_pointer_semantics.clear();
        self.rendered_pane_content_generations.clear();
    }

    pub(crate) fn reset_frame_cursor_spec(&mut self) {
        // Scoped attach is transparent to the host cursor. Do not schedule a
        // reset merely because a frame starts when the host state is already
        // the initial reset. Once a scoped inner application stops authoring
        // DECSCUSR, however, every normal frame must derive Reset so a stale
        // authored style cannot survive without a focus or resize event.
        let authored = self
            .surface_only
            .and_then(|surface_id| self.session.surface(surface_id))
            .is_some_and(|surface| surface.cursor_style_authored());
        if self.surface_only.is_none() || !authored {
            self.desired_outer_cursor = OuterCursorSpec::Reset;
        }
    }

    pub(crate) fn use_terminal_cursor_spec(
        &mut self,
        color: Rgb,
        shape: CursorShape,
        blinking: bool,
    ) {
        self.desired_outer_cursor = OuterCursorSpec::Terminal { color, shape, blinking };
    }

    pub(super) fn frame_only_browser_update(&self, id: SurfaceId) -> bool {
        if !self.graphics_supported {
            return false;
        }
        let Some(area) = self.pane_areas.iter().find(|area| area.surface == id) else {
            return false;
        };
        let Some(surface) = self.session.surface(id) else {
            return false;
        };
        surface.kind() == SurfaceKind::Browser
            && surface.browser_frame_metadata().is_some()
            && area.content.width > 0
            && area.content.height > 0
    }
}
