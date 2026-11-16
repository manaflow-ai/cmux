//! `agent-cli-hybrid-v1`: a byte viewer of an agent CLI's terminal (Claude Code, Codex,
//! opencode) gets the screen's changes as cell deltas instead of the CLI's PTY bytes (Leo,
//! 2026-11-14: "but i mean the terminal like claude code cli codex cli opencode etc can we
//! still keep the current behaviour/appearance and not stream").
//!
//! The attach keeps a terminal of its own fed with the same bytes (the replay, then each
//! `output`), and at most once per frame (`cmux_agent_cli_render::stream::FramePacer`: 8 ms
//! after the first write it holds, at most one per 100 ms) sends the delta that turns what the
//! viewer shows into that terminal's screen, as an `agent-cli-frame` event. The viewer draws
//! each frame into its own terminal (`cmux_agent_cli_render::vt::frame_bytes`), so it keeps
//! its look; `tests/parity.rs` in that crate checks every frame of a real Claude Code and
//! Codex session for cell parity and measures the bytes.
//!
//! - Only a connection that declared the capability in `set-client-info`, on a plain bytes
//!   attach (no `snapshot`, not render mode), of a terminal whose agent report names one of
//!   [`AGENT_CLIS`] when it attaches. Any other attach, and any other program, gets today's
//!   `vt-state` and `output` stream unchanged.
//! - The first event is a `colors-changed` with the terminal's colors (what `vt-state`
//!   carries), then one `agent-cli-frame`: a keyframe (`base: null`), or, for an attach that
//!   names the `hybrid_stream` and `hybrid_frame` it last applied, one delta from that frame
//!   (no full resync). A stream is kept [`PARKED_FOR`] after its viewer leaves, at most
//!   [`PARKED_MAX`] of them.
//! - `resized` becomes a keyframe at the new size; `colors-changed` passes through;
//!   `detached` ends the stream as before.
//! - A connection that also declared [`AGENT_CLI_HYBRID_LEAN_CAPABILITY`] gets each frame as
//!   an `agent-cli-lean` event instead: `{event, surface, f}`, `f` one lean frame
//!   (`cmux_agent_cli_render::lean`), which says the stream, size, frame numbers and cursor only
//!   when the viewer does not know them yet and names styles from a table the connection builds,
//!   so the link carries less than the PTY it replaces for every agent CLI (v1's JSON per frame
//!   cost more than the PTY for Claude Code).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_agent_cli_render::lean::LeanEncoder;
use cmux_agent_cli_render::stream::{Frame, FramePacer, HybridStream};
use cmux_agent_cli_render::vt;
use cmux_agent_cli_render::{Cell, Color, Grid, Style, UNDERLINE};
use serde_json::{Value, json};

use crate::panic_free::RecoverPoison;
use crate::surface::AttachFrame;
use crate::{Mux, SurfaceId};

/// Advertised in `identify`; a client declares it in `set-client-info` before `attach-surface`.
pub const AGENT_CLI_HYBRID_CAPABILITY: &str = "agent-cli-hybrid-v1";
/// With [`AGENT_CLI_HYBRID_CAPABILITY`]: frames go as lean `agent-cli-lean` events.
pub const AGENT_CLI_HYBRID_LEAN_CAPABILITY: &str = "agent-cli-hybrid-v2";

/// The agent adapters (`cmux_agent` hook `adapter.id`) whose terminals get the hybrid stream.
pub(super) const AGENT_CLIS: &[&str] = &["claude", "claude-code", "codex", "opencode"];

/// How long a stream whose viewer left can still be resumed.
pub(super) const PARKED_FOR: Duration = Duration::from_secs(600);
/// How many left streams are kept.
pub(super) const PARKED_MAX: usize = 64;

/// The shadow terminal keeps no more history than this: only its screen is read.
const SHADOW_SCROLLBACK_BYTES: usize = 64 * 1024;

struct Parked {
    surface: SurfaceId,
    stream: HybridStream,
    at: Instant,
}

fn parked() -> &'static Mutex<HashMap<String, Parked>> {
    static PARKED: OnceLock<Mutex<HashMap<String, Parked>>> = OnceLock::new();
    PARKED.get_or_init(Mutex::default)
}

/// Whether `surface`'s terminal runs an agent CLI now.
pub(super) fn runs_agent_cli(mux: &Mux, surface: &crate::Surface) -> bool {
    surface
        .terminal_public_id()
        .and_then(|terminal| mux.running_agent_adapter(terminal))
        .is_some_and(|agent| AGENT_CLIS.contains(&agent.as_str()))
}

/// The `hybrid_stream` and `hybrid_frame` an attach names to resume.
pub(super) fn resume_request(
    declared: bool,
    stream: Option<String>,
    frame: Option<u64>,
) -> anyhow::Result<Option<(String, u64)>> {
    match (stream, frame) {
        (None, None) => Ok(None),
        (Some(_), Some(_)) if !declared => Ok(None),
        (Some(stream), Some(frame)) => Ok(Some((stream, frame))),
        _ => {
            anyhow::bail!("attach-surface hybrid_stream and hybrid_frame must be supplied together")
        }
    }
}

/// What a hybrid attach sends: an `agent-cli-frame`, or an attach frame as today.
pub(super) enum HybridOut {
    Event(Value),
    Attach(AttachFrame),
}

/// One attach's hybrid stream.
pub(super) struct HybridViewer {
    surface: SurfaceId,
    id: String,
    term: ghostty_vt::Terminal,
    render: ghostty_vt::RenderState,
    stream: HybridStream,
    pacer: FramePacer,
    started: Instant,
    /// The connection's lean encoder, when it declared `agent-cli-hybrid-v2`.
    lean: Option<LeanEncoder>,
}

impl HybridViewer {
    /// The viewer of a terminal of `cols` x `rows` whose screen `replay` rebuilds, and its
    /// first `agent-cli-frame`: a keyframe, or a delta from the frame `resume` names when its
    /// stream is still kept.
    pub(super) fn start(
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        replay: &[u8],
        resume: Option<(String, u64)>,
        lean: bool,
    ) -> anyhow::Result<(HybridViewer, Value)> {
        let term = shadow(cols, rows, replay)?;
        let render = ghostty_vt::RenderState::new()?;
        let kept = resume.as_ref().and_then(|(id, _)| {
            let mut parked = parked().lock().recover_poison();
            parked.retain(|_, entry| entry.at.elapsed() < PARKED_FOR);
            parked
                .remove(id)
                .filter(|entry| entry.surface == surface && entry.stream.size() == (cols, rows))
        });
        let (id, stream) = match (kept, resume) {
            (Some(entry), Some((id, frame))) => (Some((id, frame)), entry.stream),
            _ => (None, HybridStream::new(cols, rows)),
        };
        let mut viewer = HybridViewer {
            surface,
            id: id
                .as_ref()
                .map_or_else(crate::workspace_registry::new_uuid_v4, |(id, _)| id.clone()),
            term,
            render,
            stream,
            pacer: FramePacer::default(),
            started: Instant::now(),
            lean: lean.then(LeanEncoder::new),
        };
        let (real, cursor) = viewer.screen()?;
        viewer.stream.update(&real, 0);
        let frame = id
            .and_then(|(_, frame)| viewer.stream.resume(frame, 0))
            .unwrap_or_else(|| viewer.stream.keyframe(0));
        let event = viewer.event(&frame, cursor);
        Ok((viewer, event))
    }

    /// The terminal wrote `bytes` at `now`.
    pub(super) fn output(&mut self, bytes: &[u8], now: Instant) {
        self.term.vt_write(bytes);
        self.pacer.wrote(now);
    }

    /// When the next frame is due; `None` while the terminal wrote nothing since the last.
    pub(super) fn due(&self) -> Option<Instant> {
        self.pacer.due()
    }

    /// The frame due at `now`, if one is and the screen changed.
    pub(super) fn frame_due(&mut self, now: Instant) -> anyhow::Result<Option<Value>> {
        if self.pacer.due().is_none_or(|due| now < due) {
            return Ok(None);
        }
        self.frame_now(now)
    }

    /// The frame of the screen now, whatever the pacer says (the terminal ended).
    pub(super) fn frame_now(&mut self, now: Instant) -> anyhow::Result<Option<Value>> {
        self.pacer.sent(now);
        let (real, cursor) = self.screen()?;
        let at_ms = u64::try_from(now.duration_since(self.started).as_millis()).unwrap_or(u64::MAX);
        let Some(frame) = self.stream.update(&real, at_ms) else { return Ok(None) };
        Ok(Some(self.event(&frame, cursor)))
    }

    /// The terminal changed size and `replay` rebuilds its screen: a keyframe at that size.
    pub(super) fn resized(&mut self, cols: u16, rows: u16, replay: &[u8]) -> anyhow::Result<Value> {
        self.term = shadow(cols, rows, replay)?;
        self.stream.resize(cols, rows);
        self.pacer = FramePacer::default();
        let (real, cursor) = self.screen()?;
        let at_ms = u64::try_from(self.started.elapsed().as_millis()).unwrap_or(u64::MAX);
        self.stream.update(&real, at_ms);
        let frame = self.stream.keyframe(at_ms);
        Ok(self.event(&frame, cursor))
    }

    /// Takes one attach frame at `now`: output feeds the shadow terminal (its frame goes out
    /// when [`HybridViewer::due`]), a resize is a keyframe at once, colors pass through.
    pub(super) fn take(
        &mut self,
        frame: AttachFrame,
        now: Instant,
        out: &mut Vec<HybridOut>,
    ) -> anyhow::Result<()> {
        match frame {
            AttachFrame::Output(bytes) => self.output(&bytes, now),
            AttachFrame::OutputWithColors { output, colors } => {
                self.output(&output, now);
                out.push(HybridOut::Attach(AttachFrame::ColorsChanged(Arc::new(*colors))));
            }
            AttachFrame::Resized { cols, rows, replay, pending_sequence, .. } => {
                out.push(HybridOut::Event(self.resized(
                    cols,
                    rows,
                    &[&*replay, &*pending_sequence].concat(),
                )?));
            }
            AttachFrame::ResizedWithColors {
                cols, rows, replay, pending_sequence, colors, ..
            } => {
                out.push(HybridOut::Attach(AttachFrame::ColorsChanged(Arc::new(*colors))));
                out.push(HybridOut::Event(self.resized(
                    cols,
                    rows,
                    &[&*replay, &*pending_sequence].concat(),
                )?));
            }
            other @ AttachFrame::ColorsChanged(_) => out.push(HybridOut::Attach(other)),
        }
        Ok(())
    }

    fn event(&mut self, frame: &Frame, cursor: Option<ghostty_vt::CursorInfo>) -> Value {
        let (cols, rows) = self.stream.size();
        let at =
            cursor.map_or(vt::Cursor::default(), |c| vt::Cursor { x: c.x, y: c.y, visible: true });
        if let Some(lean) =
            self.lean.as_mut().and_then(|encoder| encoder.encode(&self.id, cols, rows, frame, at))
        {
            return json!({
                "event": "agent-cli-lean",
                "surface": self.surface,
                "f": base64::engine::general_purpose::STANDARD.encode(lean),
            });
        }
        json!({
            "event": "agent-cli-frame",
            "surface": self.surface,
            "stream": self.id,
            "frame": frame.frame,
            "base": frame.base,
            "cols": cols,
            "rows": rows,
            "data": base64::engine::general_purpose::STANDARD.encode(&frame.data),
            "cursor_x": cursor.map_or(0, |c| c.x),
            "cursor_y": cursor.map_or(0, |c| c.y),
            "cursor_visible": cursor.is_some(),
        })
    }

    /// The shadow terminal's screen as cells, and its cursor when it shows.
    fn screen(&mut self) -> anyhow::Result<(Grid, Option<ghostty_vt::CursorInfo>)> {
        self.render.update(&mut self.term)?;
        let frame = self.render.build_frame()?;
        Ok((grid(&frame), frame.cursor))
    }
}

impl Drop for HybridViewer {
    fn drop(&mut self) {
        let mut parked = parked().lock().recover_poison();
        parked.retain(|_, entry| entry.at.elapsed() < PARKED_FOR);
        while parked.len() >= PARKED_MAX {
            let Some(oldest) =
                parked.iter().min_by_key(|(_, entry)| entry.at).map(|(id, _)| id.clone())
            else {
                break;
            };
            parked.remove(&oldest);
        }
        let stream = std::mem::replace(&mut self.stream, HybridStream::new(1, 1));
        parked.insert(
            std::mem::take(&mut self.id),
            Parked { surface: self.surface, stream, at: Instant::now() },
        );
    }
}

fn shadow(cols: u16, rows: u16, replay: &[u8]) -> anyhow::Result<ghostty_vt::Terminal> {
    let mut term = ghostty_vt::Terminal::new(
        cols,
        rows,
        SHADOW_SCROLLBACK_BYTES,
        ghostty_vt::Callbacks::default(),
    )?;
    term.vt_write(replay);
    Ok(term)
}

fn color(spec: ghostty_vt::ColorSpec) -> Color {
    match spec {
        ghostty_vt::ColorSpec::Default => Color::Default,
        ghostty_vt::ColorSpec::Palette(index) => Color::Palette(index),
        ghostty_vt::ColorSpec::Rgb(rgb) => Color::Rgb(rgb.r, rgb.g, rgb.b),
    }
}

/// A frame's screen as the hybrid stream's cells: authored colors (the viewer's theme
/// resolves them, as it does the PTY's), the v7 attributes and underline.
fn grid(frame: &ghostty_vt::RenderFrame) -> Grid {
    let (cols, rows) = frame.size;
    let mut grid = Grid::blank(cols, rows);
    for (slot, row) in grid.cells.iter_mut().zip(frame.styled_rows()) {
        *slot = row
            .iter()
            .map(|cell| Cell {
                text: cell.text.clone(),
                style: Style {
                    fg: color(cell.fg),
                    bg: color(cell.bg),
                    attrs: cell.attrs() | if cell.underline { UNDERLINE } else { 0 },
                },
            })
            .collect();
        slot.resize(usize::from(cols), Cell::default());
    }
    grid
}

/// Test only: whether the stream `id` is kept for a resume (its viewer's worker dropped it).
#[cfg(test)]
pub(super) fn is_parked(id: &str) -> bool {
    parked().lock().recover_poison().contains_key(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_resume_needs_both_fields_and_the_capability() {
        assert_eq!(resume_request(true, None, None).unwrap(), None);
        assert_eq!(resume_request(false, Some("s".into()), Some(3)).unwrap(), None);
        assert_eq!(resume_request(true, Some("s".into()), Some(3)).unwrap(), Some(("s".into(), 3)));
        assert!(resume_request(true, Some("s".into()), None).is_err());
    }

    #[test]
    fn a_left_stream_resumes_from_its_frame_and_another_size_starts_over() {
        let (mut viewer, first) = HybridViewer::start(7, 20, 4, b"hello", None, false).unwrap();
        assert_eq!(first["base"], Value::Null);
        let id = first["stream"].as_str().unwrap().to_owned();
        let applied = first["frame"].as_u64().unwrap();
        let now = Instant::now();
        viewer.output(b"\r\nworld", now);
        let next = viewer.frame_now(now).unwrap().unwrap();
        assert_eq!(next["base"].as_u64(), Some(applied));
        drop(viewer);
        // Back after missing frame `next`: one delta from `applied`, not a keyframe.
        let (_viewer, resumed) =
            HybridViewer::start(7, 20, 4, b"hello\r\nworld!", Some((id.clone(), applied)), false)
                .unwrap();
        assert_eq!(resumed["stream"].as_str(), Some(id.as_str()));
        assert_eq!(resumed["base"].as_u64(), Some(applied));
        drop(_viewer);
        let (_viewer, other) =
            HybridViewer::start(7, 30, 4, b"hello", Some((id, applied)), false).unwrap();
        assert_eq!(other["base"], Value::Null);
    }
}
