//! Browser surfaces on the App: browser tab creation, omnibar focus, browser
//! control dispatch and the browser command queue, and copying the URL.

use cmux_tui_core::{PaneId, SurfaceId, SurfaceKind};

use crate::app::App;
use crate::app::frame_geometry::{browser_content_size_for_rect, pane_parts_for_rect};
use crate::app::overlays::OmnibarState;
use crate::browser_input::{BrowserInputEvent, BrowserInputKind};
use crate::localization;
use crate::session::SurfaceHandle;
use crate::ui::input::TextInput;

impl App {
    pub(super) fn browser_tab_size_hint(&self, pane: Option<PaneId>) -> Option<(u16, u16)> {
        match pane {
            Some(pane) => self.pane_areas.iter().find(|area| area.pane == pane).and_then(|area| {
                browser_content_size_for_rect(
                    area.logical_rect(),
                    self.config.scrollbar.position,
                    self.config.pane.padding,
                )
            }),
            None => self
                .active_pane()
                .and_then(|pane| self.browser_tab_size_hint(Some(pane)))
                .or_else(|| {
                    browser_content_size_for_rect(
                        self.content_area,
                        self.config.scrollbar.position,
                        self.config.pane.padding,
                    )
                }),
        }
    }

    pub(super) fn create_browser_tab_for_edit(
        &mut self,
        pane: Option<PaneId>,
        fallback_pane: Option<PaneId>,
        semantic_intent: Option<u64>,
    ) -> anyhow::Result<()> {
        if !self.prepare_pty_input_before_mutation() {
            return Ok(());
        }
        let pane = pane.or_else(|| self.active_pane());
        let selector_candidates = pane
            .map(|pane| self.pane_creation_selector_candidates(pane, fallback_pane))
            .transpose()?
            .unwrap_or_default();
        self.session.new_browser_tab_for_semantic_intent(
            "about:blank".to_string(),
            pane,
            self.browser_tab_size_hint(pane),
            selector_candidates,
            semantic_intent,
        )
    }

    pub(super) fn focus_omnibar(&mut self, pane: PaneId) {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        let Some(surface) = self.session.surface(surface_id) else { return };
        if surface.kind() != SurfaceKind::Browser {
            return;
        }
        let buffer = surface.browser_url().unwrap_or_default();
        self.focus_omnibar_with_buffer(pane, buffer, true);
    }

    pub(super) fn focus_omnibar_with_buffer(
        &mut self,
        pane: PaneId,
        buffer: String,
        select_all: bool,
    ) {
        let Some(surface) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        if self.tree.surface_kind(surface) != SurfaceKind::Browser {
            return;
        }
        let Some(area) = self.pane_areas.iter().find(|area| area.pane == pane) else {
            return;
        };
        let has_omnibar = if area.surface == surface {
            area.omnibar.is_some()
        } else {
            let (_, omnibar, _, _) = pane_parts_for_rect(
                area.rect,
                self.config.scrollbar.position,
                self.config.pane.padding,
                true,
            );
            omnibar.is_some()
        };
        if !has_omnibar {
            return;
        }
        self.omnibar =
            Some(OmnibarState { pane, surface, input: TextInput::new(buffer), select_all });
    }

    fn browser_surface_for_pane(&self, pane: PaneId) -> anyhow::Result<(SurfaceId, SurfaceHandle)> {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            anyhow::bail!("pane has no active surface");
        };
        let Some(surface) = self.session.surface(surface_id) else {
            anyhow::bail!("unknown surface {surface_id}");
        };
        if surface.kind() != SurfaceKind::Browser {
            anyhow::bail!("active surface is not a browser");
        }
        Ok((surface_id, surface))
    }

    /// Dispatch a discrete browser control command (navigate/back/forward/
    /// reload/activate). Unlike disposable input, a full dispatcher queue
    /// (worker wedged in a blocking browser call) must not drop the command
    /// silently: surface backpressure through the status line so the user
    /// knows the action did not take effect.
    fn dispatch_browser_control(
        &mut self,
        surface_id: SurfaceId,
        surface: SurfaceHandle,
        kind: BrowserInputKind,
    ) {
        if self.browser_input.enqueue(BrowserInputEvent { surface_id, surface, kind }) {
            if !self.status_message_hovered() {
                self.status_message = None;
            }
        } else {
            self.status_message = Some(localization::catalog().browser.busy.to_string());
        }
    }

    pub(super) fn enqueue_active_browser_command(&mut self, kind: BrowserInputKind) {
        let Some((surface_id, surface)) = self.active_surface_with_handle() else {
            self.status_message =
                Some(localization::catalog().browser.no_active_surface.to_string());
            return;
        };
        if surface.kind() != SurfaceKind::Browser {
            self.status_message = Some(localization::catalog().browser.not_browser.to_string());
            return;
        }
        self.dispatch_browser_control(surface_id, surface, kind);
    }

    pub(super) fn enqueue_browser_command_for_pane(
        &mut self,
        pane: PaneId,
        kind: BrowserInputKind,
    ) {
        match self.browser_surface_for_pane(pane) {
            Ok((surface_id, surface)) => {
                self.dispatch_browser_control(surface_id, surface, kind);
            }
            Err(err) => self.status_message = Some(err.to_string()),
        }
    }

    pub(super) fn enqueue_browser_command(
        &mut self,
        surface_id: SurfaceId,
        kind: BrowserInputKind,
    ) {
        let Some(surface) = self.session.surface(surface_id) else {
            self.status_message = Some(localization::catalog().browser.unknown_surface.to_string());
            return;
        };
        if surface.kind() != SurfaceKind::Browser {
            self.status_message = Some(localization::catalog().browser.not_browser.to_string());
            return;
        }
        self.dispatch_browser_control(surface_id, surface, kind);
    }

    pub(super) fn browser_copy_url(&mut self, pane: PaneId) {
        let Some(surface_id) = self.tree.pane(pane).and_then(|pane| pane.active_surface()) else {
            return;
        };
        let Some(url) = self.session.surface(surface_id).and_then(|surface| surface.browser_url())
        else {
            return;
        };
        self.copy_text_to_clipboard(&url);
        self.show_toast(localization::catalog().menu.copied_url.to_string());
    }
}
