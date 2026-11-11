//! `SurfaceHandle`: one surface of a local or remote session, and the per-surface
//! reads and writes (input, size, render, pointer, browser) the frontend makes on it.

use super::*;

#[derive(Clone)]
pub enum SurfaceHandle {
    Local(Arc<Surface>, Arc<Mux>),
    Remote(Arc<RemoteSurface>, Arc<RemoteSession>),
    RemoteBrowserUnsupported,
}

impl SurfaceHandle {
    #[cfg(test)]
    pub(crate) fn test_scan_cursor_provenance(&self, bytes: &[u8]) {
        if let SurfaceHandle::Remote(surface, _) = self {
            surface.test_scan_cursor_provenance(bytes);
        }
    }

    pub fn is_remote(&self) -> bool {
        matches!(self, SurfaceHandle::Remote(_, _))
    }

    /// Whether the terminal application authored its cursor style (DECSCUSR)
    /// rather than inheriting a session or frontend default. A scoped attach
    /// client mirrors the cursor to the host terminal only when this is true.
    /// Local surfaces render inside a full TUI that owns the host cursor, so
    /// they always report true.
    pub fn cursor_style_authored(&self) -> bool {
        match self {
            SurfaceHandle::Local(_, _) => true,
            SurfaceHandle::Remote(surface, _) => surface.cursor_style_authored(),
            SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn kind(&self) -> SurfaceKind {
        match self {
            SurfaceHandle::Local(surface, _) => surface.kind(),
            SurfaceHandle::Remote(surface, _) => surface.kind,
            SurfaceHandle::RemoteBrowserUnsupported => SurfaceKind::Browser,
        }
    }

    pub fn is_dead(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.is_dead(),
            SurfaceHandle::Remote(surface, session) => session.surface_is_exited(surface.id),
            SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn write_bytes(&self, bytes: &[u8]) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.write_bytes(bytes).map_err(Into::into),
            SurfaceHandle::Remote(surface, session) => session.send_bytes(surface.id, bytes),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser surface does not accept PTY input")
            }
        }
    }

    pub fn resize(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_reporting_acceptance(cols, rows, false, Box::new(|_| {}))
    }

    pub fn resize_reporting_acceptance(
        &self,
        cols: u16,
        rows: u16,
        _reassert: bool,
        report: Box<dyn FnOnce(Option<u64>) + Send>,
    ) -> anyhow::Result<bool> {
        let desired = (cols.max(1), rows.max(1));
        let reservation_id = match self {
            SurfaceHandle::Local(surface, mux) => {
                let report_changed = mux.client_surface_size(surface.id, 0) != Some(desired);
                let (accepted, reservation_id) = mux.resize_surface_for_client_with_reservation(
                    surface.id, 0, desired.0, desired.1,
                )?;
                if report_changed {
                    mux.emit(cmux_tui_core::MuxEvent::ClientChanged {
                        client: 0,
                        name: Some("This TUI".to_string()),
                        kind: Some("tui".to_string()),
                    });
                }
                report(reservation_id);
                return Ok(accepted);
            }
            SurfaceHandle::Remote(surface, session) => {
                if !resize_action(desired, surface.reported_size()) {
                    report(None);
                    return Ok(false);
                }
                let mut request = json!({
                    "cmd": "resize-surface",
                    "surface": surface.id,
                    "cols": desired.0,
                    "rows": desired.1,
                });
                if session
                    .supports_capability(cmux_tui_core::server::VIEW_ATTACHMENT_LEASE_CAPABILITY)
                {
                    let Some(lease) = session.attachment_lease(surface.id) else {
                        // The surface handle can outlive the attachment that
                        // authorized this resize. Treat that lifecycle race as
                        // superseded, exactly like the server does for a
                        // retired lease token.
                        surface.clear_reported_size();
                        report(None);
                        return Ok(false);
                    };
                    request = json!({
                        "cmd": "resize-attached-view",
                        "surface": surface.id,
                        "lease": lease,
                        "cols": desired.0,
                        "rows": desired.1,
                    });
                }
                let response = match session.request(request) {
                    Ok(response) => response,
                    Err(error) => {
                        report(None);
                        return Err(error);
                    }
                };
                match response.get("outcome").and_then(Value::as_str) {
                    Some("superseded") => {
                        report(None);
                        return Ok(false);
                    }
                    Some("passive") => {
                        surface.set_reported_size(desired);
                        report(None);
                        return Ok(false);
                    }
                    Some("applied") | None => {}
                    Some(other) => {
                        report(None);
                        anyhow::bail!("unknown resize outcome {other}");
                    }
                }
                let accepted = response.get("accepted").and_then(Value::as_bool).unwrap_or(true);
                surface.set_reported_size(desired);
                if !accepted {
                    report(None);
                    return Ok(false);
                }
                response.get("reservation_id").and_then(Value::as_u64).or(Some(0))
            }
            SurfaceHandle::RemoteBrowserUnsupported => {
                report(None);
                anyhow::bail!("browser surface is unavailable")
            }
        };
        report(reservation_id);
        Ok(true)
    }

    pub fn resize_needed(&self, cols: u16, rows: u16, _user_interaction: bool) -> bool {
        let desired = (cols.max(1), rows.max(1));
        match self {
            SurfaceHandle::Local(surface, mux) => {
                resize_action(desired, mux.client_surface_size(surface.id, 0))
            }
            SurfaceHandle::Remote(surface, _) => resize_action(desired, surface.reported_size()),
            SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn reassert_size(&self, cols: u16, rows: u16) -> anyhow::Result<bool> {
        self.resize_reporting_acceptance(cols, rows, true, Box::new(|_| {}))
    }
    pub fn take_dirty(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.take_dirty(),
            SurfaceHandle::Remote(surface, _) => surface.dirty.swap(false, Ordering::AcqRel),
            SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn render_frame(
        &self,
        rs: &mut RenderState,
    ) -> ghostty_vt::Result<Arc<SurfaceRenderFrame>> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.render_view_frame(rs),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                rs.update(&mut term)?;
                let palette_colors = std::array::from_fn(|idx| rs.palette_color(idx as u8));
                let palette_overridden =
                    std::array::from_fn(|idx| rs.palette_overridden(idx as u8));
                Ok(Arc::new(SurfaceRenderFrame {
                    frame: rs.build_frame()?,
                    content_generation: surface.content_generation.load(Ordering::Acquire),
                    scrollback_rows: term.history_rows(),
                    history_epoch: term.history_epoch(),
                    pointer_semantics: term.pointer_semantic_snapshot(),
                    palette_colors,
                    palette_overridden,
                }))
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => {
                Err(ghostty_vt::Error::InvalidValue)
            }
        }
    }

    /// Whether the terminal holds DEC private `mode` now; `None` for a
    /// surface with no terminal. Reads only: unlike [`Self::with_terminal`],
    /// nothing is synchronized from the terminal afterwards. A mirror lock
    /// poisoned by a panic elsewhere still answers: a mode read never
    /// writes the terminal.
    pub fn with_terminal_mode(&self, mode: u16) -> Option<bool> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.with_terminal(|term| term.mode(mode, false))
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => Some(
                surface
                    .term
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .mode(mode, false),
            ),
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    /// Run `f` against the surface's terminal state (the mirror, for
    /// remote surfaces — modes and keyboard state replay there too).
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> Option<R> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.with_terminal(f),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut terminal = surface.term.lock().unwrap();
                let result = f(&mut terminal);
                surface.sync_mouse_encoders(&terminal);
                Some(result)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.encode_mouse(input, output),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.encode_mouse(input, output)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_if_semantics(
        &self,
        expected: TerminalPointerSemanticSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.encode_mouse_if_semantics(expected, input, output)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.encode_mouse_if_semantics(expected, input, output))
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.encode_mouse_if_snapshot(expected, input, output)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.encode_mouse_if_snapshot(expected, input, output))
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_release(
        &self,
        input: MouseInput,
        output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.encode_mouse_release(input, output),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.encode_mouse_release(input, output)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_press_pair(
        &self,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<ghostty_vt::Result<()>> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.encode_mouse_press_pair(press, release, press_output, release_output)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.encode_mouse_press_pair(press, release, press_output, release_output)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn encode_mouse_press_pair_if_snapshot(
        &self,
        expected: TerminalPointerSnapshot,
        press: MouseInput,
        release: MouseInput,
        press_output: &mut impl Extend<u8>,
        release_output: &mut impl Extend<u8>,
    ) -> Option<GuardedMouseEncode> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.encode_mouse_press_pair_if_snapshot(
                expected,
                press,
                release,
                press_output,
                release_output,
            ),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.encode_mouse_press_pair_if_snapshot(
                    expected,
                    press,
                    release,
                    press_output,
                    release_output,
                ))
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn reset_mouse_motion_dedupe(&self) {
        match self {
            SurfaceHandle::Local(surface, _) => surface.reset_mouse_motion_dedupe(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.reset_mouse_motion_dedupe();
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => {}
        }
    }

    pub fn try_pointer_semantics(&self) -> Option<PointerSemanticProbe> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.try_pointer_semantics(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.try_pointer_semantics())
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn try_pointer_snapshot(&self) -> Option<PointerSnapshotProbe> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.try_pointer_snapshot(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                Some(surface.try_pointer_snapshot())
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scroll_delta(&self, delta: isize) -> Option<bool> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                let before = surface.view_scrollbar()?.offset;
                let after = surface.view_scroll_delta(delta).ok()??.offset;
                Some(before != after)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                term.scroll_delta(delta);
                let after = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                if before != after {
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                }
                Some(before != after)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scroll_delta_if_scrollbar(
        &self,
        expected: Scrollbar,
        delta: isize,
    ) -> Option<Scrollbar> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.view_scroll_delta_if_scrollbar(expected, delta).ok().flatten()
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar();
                if before != Some(expected) {
                    return None;
                }
                term.scroll_delta(delta);
                let after = term.scrollbar();
                if after != before {
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                }
                after
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scroll_to_bottom(&self) -> Option<bool> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.view_scroll_to_bottom().ok(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                let mut term = surface.term.lock().unwrap();
                let before = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                term.scroll_to_bottom();
                let after = term.scrollbar().map(|sb| sb.offset).unwrap_or(0);
                if before != after {
                    surface.content_generation.fetch_add(1, Ordering::AcqRel);
                }
                Some(before != after)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn scrollbar(&self) -> Option<Scrollbar> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.view_scrollbar(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Pty => {
                surface.term.lock().unwrap().scrollbar()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_frame_update(&self) -> Option<BrowserFrameUpdate> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frame_update(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frame_update()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_frame_metadata(&self) -> Option<(u64, u32, u32, Option<u64>)> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frame_metadata(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frame_metadata()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    #[cfg(test)]
    pub fn browser_frame_seq(&self) -> Option<u64> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frame_seq(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frame_seq()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_accepts_pointer_frame(&self, frame_seq: u64) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_accepts_pointer_frame(frame_seq),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_accepts_pointer_frame(frame_seq)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn browser_pointer_frame_is_in_current_route(&self, frame_seq: u64) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_pointer_frame_is_in_current_route(frame_seq)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_pointer_frame_is_in_current_route(frame_seq)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    /// Update the renderer-local presentation acknowledgement immediately.
    /// Returns whether the exact acknowledged token changed.
    pub fn browser_acknowledge_pointer_frame(&self, frame_seq: u64) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_acknowledge_pointer_frame(frame_seq)
            }
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.acknowledge_browser_pointer_frame(frame_seq)
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    /// Publish a renderer acknowledgement to the surface owner. Remote calls
    /// perform control-socket I/O and must run off the app event loop.
    pub fn browser_publish_pointer_frame(&self, frame_seq: u64) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                let _ = surface.browser_acknowledge_pointer_frame(frame_seq);
                Ok(())
            }
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(json!({
                        "cmd": "browser-frame-presented",
                        "surface": surface.id,
                        "frame_seq": frame_seq,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn has_browser_frame(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.has_browser_frame(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.has_browser_frame()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn browser_url(&self) -> Option<String> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_url(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_url()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_status(&self) -> Option<BrowserStatus> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_status(),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                Some(surface.browser_status())
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => None,
        }
    }

    pub fn browser_frames_stalled(&self) -> bool {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_frames_stalled().unwrap_or(false),
            SurfaceHandle::Remote(surface, _) if surface.kind == SurfaceKind::Browser => {
                surface.browser_frames_stalled()
            }
            SurfaceHandle::Remote(_, _) | SurfaceHandle::RemoteBrowserUnsupported => false,
        }
    }

    pub fn browser_insert_text(&self, text: &str) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_insert_text(text),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(
                        json!({"cmd": "browser-insert-text", "surface": surface.id, "text": text}),
                    )
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
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
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_key_event(
                event_type,
                key,
                code,
                windows_virtual_key_code,
                modifiers,
                text,
            ),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                let kind = match event_type {
                    "keyDown" => "down",
                    "keyUp" => "up",
                    _ => anyhow::bail!("bad browser key event type {event_type:?}"),
                };
                session
                    .request(json!({
                        "cmd": "browser-key",
                        "surface": surface.id,
                        "kind": kind,
                        "key": key,
                        "code": code,
                        "windows_virtual_key_code": windows_virtual_key_code,
                        "modifiers": modifiers,
                        "text": text,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_key_press(
        &self,
        key: &str,
        code: &str,
        windows_virtual_key_code: u32,
        modifiers: u32,
        text: Option<&str>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_key_press(key, code, windows_virtual_key_code, modifiers, text)
            }
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(json!({
                        "cmd": "browser-key-press",
                        "surface": surface.id,
                        "key": key,
                        "code": code,
                        "windows_virtual_key_code": windows_virtual_key_code,
                        "modifiers": modifiers,
                        "text": text,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_mouse_event_for_frame(
        &self,
        event_type: &str,
        x: f64,
        y: f64,
        button: Option<&str>,
        click_count: Option<u32>,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_mouse_event_for_frame(
                event_type,
                x,
                y,
                button,
                click_count,
                frame_seq,
            ),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                let frame_seq = frame_seq.ok_or_else(|| {
                    anyhow::anyhow!("remote browser pointer input requires an admitted frame")
                })?;
                let (kind, lifecycle) = match event_type {
                    "mousePressed" => ("down", remote::GuardedPointerLifecycle::CaptureMutation),
                    "mouseReleased" => ("up", remote::GuardedPointerLifecycle::CaptureMutation),
                    "mouseMoved" => ("move", remote::GuardedPointerLifecycle::Motion),
                    _ => anyhow::bail!("bad browser mouse event type {event_type:?}"),
                };
                session
                    .request_guarded_pointer(
                        json!({
                            "cmd": "browser-mouse-guarded",
                            "surface": surface.id,
                            "kind": kind,
                            "x_px": x,
                            "y_px": y,
                            "button": button,
                            "click_count": click_count,
                            "frame_seq": frame_seq,
                        }),
                        lifecycle,
                    )
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_wheel_for_frame(
        &self,
        x: f64,
        y: f64,
        delta_y: f64,
        frame_seq: Option<u64>,
    ) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => {
                surface.browser_wheel_for_frame(x, y, delta_y, frame_seq)
            }
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                let frame_seq = frame_seq.ok_or_else(|| {
                    anyhow::anyhow!("remote browser pointer input requires an admitted frame")
                })?;
                session
                    .request(json!({
                        "cmd": "browser-wheel-guarded",
                        "surface": surface.id,
                        "x_px": x,
                        "y_px": y,
                        "delta_y_px": delta_y,
                        "frame_seq": frame_seq,
                    }))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_navigate(&self, url: &str) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => surface.browser_navigate(url),
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session
                    .request(json!({"cmd": "browser-navigate", "surface": surface.id, "url": url}))
                    .map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }

    pub fn browser_back(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-back")
    }

    pub fn browser_forward(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-forward")
    }

    pub fn browser_reload(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-reload")
    }

    pub fn browser_activate(&self) -> anyhow::Result<()> {
        self.browser_nav_command("browser-activate")
    }

    fn browser_nav_command(&self, cmd: &str) -> anyhow::Result<()> {
        match self {
            SurfaceHandle::Local(surface, _) => match cmd {
                "browser-back" => surface.browser_back(),
                "browser-forward" => surface.browser_forward(),
                "browser-reload" => surface.browser_reload(),
                "browser-activate" => surface.browser_activate(),
                _ => unreachable!(),
            },
            SurfaceHandle::Remote(surface, session) if surface.kind == SurfaceKind::Browser => {
                session.request(json!({"cmd": cmd, "surface": surface.id})).map(|_| ())
            }
            SurfaceHandle::Remote(_, _) => anyhow::bail!("PTY surface is not a browser surface"),
            SurfaceHandle::RemoteBrowserUnsupported => {
                anyhow::bail!("browser panes are not supported over attach yet")
            }
        }
    }
}
