//! Public sidebar-view identity, snapshots, and styled render serialization.
//!
//! Sidebar plugins are auxiliary PTY surfaces. They deliberately do not enter
//! the workspace topology, but their public resource identity is stable for
//! one durable session and their render protocol is the same styled-cell
//! protocol used by terminal attachments.

use std::sync::Arc;

use ghostty_vt::{Dirty, StyledRun, UnderlineStyle};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::resource::{ResourceError, Selector, SessionPublicId, SidebarViewPublicId};
use crate::surface::RenderAttachFrameReceiver;
use crate::{
    Mux, RenderAttachStream, ResourceSelectors, ResourceTarget, Rgb, Surface, SurfaceKind,
    SurfaceRenderFrame,
};

pub(crate) const SIDEBAR_VIEW_NAME: &str = "sidebar";

/// Derive an independent stable opaque ID without persisting a second copy of
/// the durable session identity.
pub(crate) fn sidebar_view_id(
    session_id: &SessionPublicId,
) -> Result<SidebarViewPublicId, ResourceError> {
    let mut digest = Sha256::new();
    digest.update(b"cmux.protocol/2/sidebar-view/");
    digest.update(session_id.as_str().as_bytes());
    let digest = digest.finalize();
    let payload = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    SidebarViewPublicId::parse(format!("sidebar_view_{payload}"))
}

pub(crate) fn resolve_sidebar_view(
    mux: &Mux,
    selectors: &ResourceSelectors,
) -> Result<(SidebarViewPublicId, SessionPublicId), ResourceError> {
    let mut session_selectors = selectors.clone();
    session_selectors.sidebar_view = None;
    let path = mux.resolve_resource_path(ResourceTarget::Session, &session_selectors)?;
    let session_id =
        path.session.ok_or_else(|| ResourceError::not_found("session", "<resolved>"))?;
    let sidebar_id = sidebar_view_id(&session_id)?;
    let raw = selectors.sidebar_view.as_deref().ok_or_else(|| {
        ResourceError::selector_invalid(
            "sidebar_view",
            "",
            "missing required sidebar_view selector",
        )
    })?;
    match Selector::parse(raw)? {
        Selector::Current => {}
        Selector::Id(id) if id == sidebar_id.as_str() => {}
        Selector::Name(name) if name == SIDEBAR_VIEW_NAME || name == "default" => {}
        Selector::Id(_) | Selector::Name(_) => {
            return Err(ResourceError::not_found("sidebar_view", raw));
        }
    }
    Ok((sidebar_id, session_id))
}

pub(crate) fn sidebar_snapshot(
    id: &SidebarViewPublicId,
    session_id: &SessionPublicId,
    last_size: (u16, u16),
    surface: Option<&Arc<Surface>>,
) -> Value {
    let running =
        surface.is_some_and(|surface| surface.kind() == SurfaceKind::Pty && !surface.is_dead());
    let (cols, rows) = surface
        .filter(|surface| surface.kind() == SurfaceKind::Pty)
        .map(|surface| surface.size())
        .unwrap_or(last_size);
    json!({
        "id":id,
        "session_id":session_id,
        "cols":cols.max(1),
        "rows":rows.max(1),
        "running":running,
    })
}

pub(crate) struct SidebarRenderAttachment {
    pub sidebar_view_id: SidebarViewPublicId,
    pub sidebar_view: Value,
    pub initial: Arc<SurfaceRenderFrame>,
    pub stream: RenderAttachFrameReceiver,
}

pub(crate) fn attach_sidebar_render(
    id: SidebarViewPublicId,
    sidebar_view: Value,
    surface: &Arc<Surface>,
) -> Result<SidebarRenderAttachment, ResourceError> {
    if surface.kind() != SurfaceKind::Pty || surface.is_dead() {
        return Err(ResourceError::not_found("sidebar_view", id.as_str()));
    }
    let RenderAttachStream { initial, stream, .. } =
        surface.attach_render_stream().map_err(|error| {
            ResourceError::operation_failed(
                "sidebar_view.attach",
                "could not attach to the sidebar render stream",
                json!({"error":error.to_string()}),
            )
        })?;
    Ok(SidebarRenderAttachment { sidebar_view_id: id, sidebar_view, initial, stream })
}

pub(crate) fn sidebar_attach_snapshot(attachment: &SidebarRenderAttachment) -> Value {
    json!({
        "kind":"snapshot",
        "sidebar_view":attachment.sidebar_view,
        "render":render_snapshot_json(&attachment.initial),
    })
}

pub(crate) struct SidebarRenderClientState {
    size: (u16, u16),
    default_colors: (Rgb, Rgb),
    scrollback_rows: u32,
}

impl SidebarRenderClientState {
    pub(crate) fn new(frame: &SurfaceRenderFrame) -> Self {
        Self {
            size: frame.frame.size,
            default_colors: frame.frame.default_colors,
            scrollback_rows: frame.scrollback_rows,
        }
    }

    pub(crate) fn patch(
        &mut self,
        sidebar_view_id: &SidebarViewPublicId,
        frame: &SurfaceRenderFrame,
    ) -> Value {
        let size_changed = self.size != frame.frame.size;
        let foreground_changed = self.default_colors.1 != frame.frame.default_colors.1;
        let background_changed = self.default_colors.0 != frame.frame.default_colors.0;
        let scrollback_changed = self.scrollback_rows != frame.scrollback_rows;
        let full_reset = size_changed
            || foreground_changed
            || background_changed
            || frame.frame.dirty == Dirty::Full;
        let rows = if full_reset {
            render_rows_json(frame, 0..frame.frame.size.1)
        } else {
            render_rows_json(frame, frame.frame.dirty_rows.iter().copied())
        };
        let mut render = json!({
            "cursor":render_cursor_json(frame),
            "full_reset":full_reset,
            "rows":rows,
        });
        if size_changed {
            render["size"] = json!({"cols":frame.frame.size.0,"rows":frame.frame.size.1});
        }
        if foreground_changed {
            render["default_fg"] = json!(rgb_hex(frame.frame.default_colors.1));
        }
        if background_changed {
            render["default_bg"] = json!(rgb_hex(frame.frame.default_colors.0));
        }
        if scrollback_changed {
            render["scrollback_rows"] = json!(frame.scrollback_rows);
        }
        self.size = frame.frame.size;
        self.default_colors = frame.frame.default_colors;
        self.scrollback_rows = frame.scrollback_rows;
        json!({
            "kind":"patch",
            "sidebar_view_id":sidebar_view_id,
            "render":render,
        })
    }

    pub(crate) fn scroll(
        sidebar_view_id: &SidebarViewPublicId,
        offset: u64,
        at_bottom: bool,
    ) -> Value {
        json!({
            "kind":"scroll",
            "sidebar_view_id":sidebar_view_id,
            "scroll":{
                "offset":offset.to_string(),
                "at_bottom":at_bottom,
            },
        })
    }
}

fn render_snapshot_json(frame: &SurfaceRenderFrame) -> Value {
    let (cols, rows) = frame.frame.size;
    json!({
        "size":{"cols":cols,"rows":rows},
        "cursor":render_cursor_json(frame),
        "default_fg":rgb_hex(frame.frame.default_colors.1),
        "default_bg":rgb_hex(frame.frame.default_colors.0),
        "scrollback_rows":frame.scrollback_rows,
        "rows":render_rows_json(frame, 0..rows),
    })
}

fn render_rows_json(frame: &SurfaceRenderFrame, rows: impl IntoIterator<Item = u16>) -> Vec<Value> {
    rows.into_iter()
        .filter_map(|row| {
            frame.frame.row_runs(row).map(|runs| {
                json!({
                    "row":row,
                    "runs":runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                })
            })
        })
        .collect()
}

fn render_cursor_json(frame: &SurfaceRenderFrame) -> Value {
    let (style, blink) = frame.frame.cursor_visual;
    let style = match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    };
    let (x, y, visible) =
        frame.frame.cursor.map(|cursor| (cursor.x, cursor.y, true)).unwrap_or((0, 0, false));
    json!({
        "x":x,
        "y":y,
        "style":style,
        "blink":blink,
        "visible":visible,
        "color":frame.frame.cursor_color.map(rgb_hex),
    })
}

fn styled_run_json(run: &StyledRun) -> Value {
    let underline = run.underline.map(|style| match style {
        UnderlineStyle::Single => "single",
        UnderlineStyle::Double => "double",
        UnderlineStyle::Curly => "curly",
        UnderlineStyle::Dotted => "dotted",
        UnderlineStyle::Dashed => "dashed",
    });
    let mut value = json!({
        "text":run.text,
        "fg":run.fg.map(rgb_hex),
        "bg":run.bg.map(rgb_hex),
        "attrs":run.attrs,
    });
    if let Some(underline) = underline {
        value["underline"] = json!(underline);
    }
    if let Some(width_hint) = run.width_hint {
        value["width_hint"] = json!(width_hint);
    }
    value
}

fn rgb_hex(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SidebarPluginOptions, SurfaceOptions};
    use std::time::{Duration, Instant};

    fn session_id(value: u128) -> SessionPublicId {
        SessionPublicId::parse(format!("session_{value:032x}")).unwrap()
    }

    #[test]
    fn sidebar_identity_is_stable_and_type_separated() {
        let session = session_id(7);
        let first = sidebar_view_id(&session).unwrap();
        let second = sidebar_view_id(&session).unwrap();
        assert_eq!(first, second);
        assert!(first.as_str().starts_with("sidebar_view_"));
        assert!(!first.as_str().ends_with(&session.as_str()["session_".len()..]));
    }

    #[test]
    fn stopped_sidebar_snapshot_preserves_last_nonzero_size() {
        let session = session_id(8);
        let id = sidebar_view_id(&session).unwrap();
        assert_eq!(
            sidebar_snapshot(&id, &session, (0, 0), None),
            json!({
                "id":id,
                "session_id":session,
                "cols":1,
                "rows":1,
                "running":false,
            })
        );
    }

    #[test]
    fn scroll_uses_wire_decimal_offset_and_public_view_id() {
        let id = sidebar_view_id(&session_id(9)).unwrap();
        let value = SidebarRenderClientState::scroll(&id, u64::MAX, false);
        assert_eq!(value["kind"], "scroll");
        assert_eq!(value["sidebar_view_id"], id.as_str());
        assert_eq!(value["scroll"]["offset"], u64::MAX.to_string());
        assert_eq!(value["scroll"]["at_bottom"], false);
    }

    #[test]
    fn fake_plugin_input_reaches_the_styled_render_attachment() {
        let mux = Mux::new("sidebar-resource-fake-plugin", SurfaceOptions::default());
        mux.configure_sidebar_plugin(Some(SidebarPluginOptions {
            command: vec!["/bin/cat".to_string()],
            cwd: None,
        }));
        let status = mux.ensure_sidebar_plugin(24, 5, false);
        let surface = mux
            .surface(status.surface.expect("configured fake plugin must start"))
            .expect("sidebar surface must remain registered");
        surface.write_bytes(b"sidebar-resource-e2e\n").unwrap();

        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let text =
                surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
            if text.contains("sidebar-resource-e2e") {
                break;
            }
            assert!(Instant::now() < deadline, "fake plugin output did not reach its VT");
            std::thread::sleep(Duration::from_millis(10));
        }

        let context = mux.local_resource_context().unwrap();
        let id = sidebar_view_id(&context.session_id).unwrap();
        let view = sidebar_snapshot(&id, &context.session_id, (24, 5), Some(&surface));
        let attachment = attach_sidebar_render(id, view, &surface).unwrap();
        let snapshot = sidebar_attach_snapshot(&attachment);
        assert_eq!(snapshot["kind"], "snapshot");
        assert_eq!(snapshot["sidebar_view"]["running"], true);
        assert_eq!(snapshot["render"]["size"], json!({"cols":24,"rows":5}));
        assert!(
            snapshot["render"]["rows"]
                .as_array()
                .unwrap()
                .iter()
                .flat_map(|row| row["runs"].as_array().unwrap())
                .filter_map(|run| run["text"].as_str())
                .any(|text| text.contains("sidebar-resource-e2e"))
        );
        surface.kill();
    }
}
