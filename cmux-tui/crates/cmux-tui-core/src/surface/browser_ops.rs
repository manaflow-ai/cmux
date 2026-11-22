//! Browser operations on `Surface`: frame reads, pointer frame routing, input,
//! and navigation. Each method forwards to the surface's `BrowserSurface` and
//! fails or returns nothing for a PTY surface.

use super::*;

impl Surface {
    pub fn browser_frame(&self) -> Option<BrowserFrame> {
        self.browser_frame_shared().map(|frame| frame.as_ref().clone())
    }

    pub fn browser_frame_shared(&self) -> Option<Arc<BrowserFrame>> {
        self.as_browser().and_then(BrowserSurface::latest_frame)
    }

    pub fn browser_frame_metadata(&self) -> Option<(u64, u32, u32, Option<u64>)> {
        self.as_browser().and_then(BrowserSurface::latest_frame_metadata)
    }

    pub fn browser_frame_update(&self) -> Option<BrowserFrameUpdate> {
        self.as_browser().and_then(BrowserSurface::latest_frame_update)
    }

    /// Return the opaque browser pointer-authority token for guarded input.
    pub fn browser_frame_seq(&self) -> Option<u64> {
        self.as_browser().and_then(BrowserSurface::latest_frame_seq)
    }

    /// Return whether the local renderer acknowledged this exact browser
    /// bitmap as its current presentation.
    pub fn browser_accepts_pointer_frame(&self, frame_seq: u64) -> bool {
        self.as_browser().is_some_and(|browser| browser.accepts_pointer_frame(frame_seq))
    }

    /// Return whether a browser bitmap belongs to the current document and
    /// coordinate mapping without granting it input authority.
    pub fn browser_pointer_frame_is_in_current_route(&self, frame_seq: u64) -> bool {
        self.as_browser()
            .is_some_and(|browser| browser.pointer_frame_is_in_current_route(frame_seq))
    }

    pub fn browser_acknowledge_pointer_frame(&self, frame_seq: u64) -> bool {
        self.as_browser().is_some_and(|browser| browser.acknowledge_pointer_frame(frame_seq))
    }

    pub(crate) fn browser_acknowledge_pointer_frame_from(
        &self,
        owner: BrowserPointerOwner,
        frame_seq: u64,
    ) -> bool {
        self.as_browser()
            .is_some_and(|browser| browser.acknowledge_pointer_frame_from(owner, frame_seq))
    }

    pub(crate) fn forget_browser_pointer_owner(&self, owner: BrowserPointerOwner) {
        if let Some(browser) = self.as_browser() {
            browser.forget_pointer_owner(owner);
        }
    }

    pub fn has_browser_frame(&self) -> bool {
        self.as_browser().is_some_and(BrowserSurface::has_latest_frame)
    }

    pub fn browser_url(&self) -> Option<String> {
        self.as_browser().map(BrowserSurface::url)
    }

    pub fn browser_source(&self) -> Option<BrowserSource> {
        self.as_browser().and_then(BrowserSurface::source)
    }

    pub fn browser_status(&self) -> Option<BrowserStatus> {
        self.as_browser().map(BrowserSurface::status)
    }

    pub fn browser_frames_stalled(&self) -> Option<bool> {
        self.as_browser().map(BrowserSurface::frames_stalled)
    }

    pub fn attach_frames(&self) -> anyhow::Result<(BrowserAttachState, BrowserFrameStream)> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        Ok(browser.attach_frames())
    }

    pub fn browser_insert_text(&self, text: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.insert_text(text)
    }

    pub fn browser_key_event(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.key_event(event_type, key, code, windows_virtual_key_code, modifiers, text)
    }

    pub fn browser_key_press(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.key_press(key, code, windows_virtual_key_code, modifiers, text)
    }

    pub fn browser_mouse_event(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event(event_type, x, y, button, click_count)
    }

    /// Queue browser mouse input admitted by a rendered frame sequence.
    /// Returns `None` for non-browser surfaces.
    pub fn browser_mouse_event_for_frame(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event_for_frame(event_type, x, y, button, click_count, frame_seq)
    }

    pub(crate) fn browser_mouse_event_for_frame_from(
        &self,
        dispatch: BrowserMouseDispatch<'_>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event_for_frame_from(dispatch)
    }

    pub(crate) fn wake_browser_pointer_cleanup(&self) {
        if let Some(browser) = self.as_browser() {
            browser.wake_pointer_cleanup();
        }
    }

    pub fn browser_wheel(&self, x: f64, y: f64, delta_y: f64) -> anyhow::Result<()> {
        self.browser_wheel_2d(x, y, 0.0, delta_y)
    }

    pub fn browser_wheel_2d(
        &self,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_2d(x, y, delta_x, delta_y)
    }

    /// Queue browser wheel input only while its rendered frame remains live.
    /// Returns `None` for non-browser surfaces.
    pub fn browser_wheel_for_frame(
        &self,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_for_frame(x, y, delta_y, frame_seq)
    }

    pub(crate) fn browser_wheel_for_frame_from(
        &self,
        owner: BrowserPointerOwner,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_for_frame_from(owner, x, y, delta_y, frame_seq)
    }

    pub fn browser_navigate(&self, url: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.navigate(url)
    }

    pub fn browser_back(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.back()
    }

    pub fn browser_forward(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.forward()
    }

    pub fn browser_reload(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.reload()
    }

    pub fn browser_activate(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.activate()
    }

    pub(crate) fn browser_insert_text_confirmed(&self, text: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.insert_text_confirmed(text)
    }

    pub(crate) fn browser_key_event_confirmed(
        &self,
        event_type: &str,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.key_event_confirmed(
            event_type,
            key,
            code,
            windows_virtual_key_code,
            modifiers,
            text,
        )
    }

    pub(crate) fn browser_mouse_event_confirmed(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.mouse_event_confirmed(event_type, x, y, button, click_count, frame_seq)
    }

    pub(crate) fn browser_wheel_confirmed(
        &self,
        x: f64,
        y: f64,
        delta_x: f64,
        delta_y: f64,
        frame_seq: u64,
    ) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.wheel_confirmed(x, y, delta_x, delta_y, frame_seq)
    }

    pub(crate) fn browser_navigate_confirmed(&self, url: &str) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.navigate_confirmed(url)
    }

    pub(crate) fn browser_back_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.back_confirmed()
    }

    pub(crate) fn browser_forward_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.forward_confirmed()
    }

    pub(crate) fn browser_reload_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.reload_confirmed()
    }

    pub(crate) fn browser_activate_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.activate_confirmed()
    }

    pub(crate) fn browser_close_confirmed(&self) -> anyhow::Result<()> {
        let Some(browser) = self.as_browser() else {
            anyhow::bail!("PTY surface is not a browser surface");
        };
        browser.close_confirmed()
    }
}
