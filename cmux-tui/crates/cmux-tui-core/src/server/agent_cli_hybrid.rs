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
//! - A connection that declared both and [`TERMINAL_SHELL_LINES_CAPABILITY`] gets a plain
//!   shell's terminal (its own program a shell: `cmux_agent_cli_render::adapter`) as the same
//!   lean frames: its lines and cursor. A full-screen program the shell runs (the alternate
//!   screen or mouse tracking) goes as `output` PTY bytes from the byte that starts it, after
//!   a last frame of what came before, so the viewer's terminal tracks its modes; when it ends
//!   the frames go on from the screen the viewer then shows, with no keyframe. A terminal that
//!   is already full-screen when it attaches starts with `vt-state`. Any other program (a
//!   terminal whose own program is not a shell or an agent CLI) keeps the byte stream.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_agent_cli_render::adapter::{Adapter, FullScreenScan};
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

/// With both: a plain shell's terminal goes as lean frames too, PTY bytes only while it runs a
/// full-screen program.
pub const TERMINAL_SHELL_LINES_CAPABILITY: &str = "terminal-shell-lines-v1";

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

/// The stream a viewer gets for `surface`'s terminal: an agent CLI's adapter while one runs,
/// the shell's when its own program is a shell, else the PTY.
pub(super) fn adapter(mux: &Mux, surface: &crate::Surface) -> Adapter {
    let agent =
        surface.terminal_public_id().and_then(|terminal| mux.running_agent_adapter(terminal));
    if Adapter::of(agent.as_deref(), None) == Adapter::Agent {
        return Adapter::Agent;
    }
    let program = surface.process_id().and_then(crate::platform::process_executable);
    Adapter::of(None, program.as_deref())
}

/// Whether the terminal shows a full-screen program: the alternate screen or mouse tracking.
fn full_screen(term: &ghostty_vt::Terminal) -> bool {
    term.active_screen() == ghostty_vt::Screen::Alternate
        || [1000, 1002, 1003].into_iter().any(|mode| term.mode(mode, false))
}

/// A shell viewer's phase: its lines as frames, or a full-screen program's PTY bytes.
struct Shell {
    pty: bool,
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
    /// The cursor the viewer was last sent: when only the cursor moves (shows, hides), no cell
    /// changes, and the frame that says so changes none.
    cursor: vt::Cursor,
    /// The connection's lean encoder, when it declared `agent-cli-hybrid-v2`.
    lean: Option<LeanEncoder>,
    /// A plain shell's terminal ([`TERMINAL_SHELL_LINES_CAPABILITY`]).
    shell: Option<Shell>,
    /// A connection that declared [`TERMINAL_SHELL_LINES_CAPABILITY`]: its writes' input modes
    /// (and, for a shell, the start of a full-screen program).
    scan: Option<FullScreenScan>,
}

/// What a viewer declared: the lean frames (`agent-cli-hybrid-v2`), the shell adapter for
/// this terminal, and [`TERMINAL_SHELL_LINES_CAPABILITY`] (its input modes as bytes).
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct Wants {
    pub(super) lean: bool,
    pub(super) shell: bool,
    pub(super) lines: bool,
}

impl HybridViewer {
    /// The viewer of a terminal of `cols` x `rows` whose screen `replay` rebuilds, and its
    /// first `agent-cli-frame`: a keyframe, or a delta from the frame `resume` names when its
    /// stream is still kept. A shell's viewer whose terminal is full-screen has no first frame:
    /// the attach sends `vt-state`, and frames start when the program ends.
    pub(super) fn start(
        surface: SurfaceId,
        cols: u16,
        rows: u16,
        replay: &[u8],
        resume: Option<(String, u64)>,
        wants: Wants,
    ) -> anyhow::Result<(HybridViewer, Option<Value>)> {
        let Wants { lean, shell, lines } = wants;
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
            cursor: vt::Cursor::default(),
            lean: lean.then(LeanEncoder::new),
            shell: shell.then_some(Shell { pty: false }),
            scan: (lines || shell).then(FullScreenScan::new),
        };
        if let Some(shell) = viewer.shell.as_mut()
            && full_screen(&viewer.term)
        {
            shell.pty = true;
            viewer.stream.resize(cols, rows);
            return Ok((viewer, None));
        }
        let (real, cursor) = viewer.screen()?;
        viewer.stream.update(&real, 0);
        let frame = id
            .and_then(|(_, frame)| viewer.stream.resume(frame, 0))
            .unwrap_or_else(|| viewer.stream.keyframe(0));
        let event = viewer.event(&frame, cursor);
        Ok((viewer, Some(event)))
    }

    /// Whether the viewer gets PTY bytes now (a shell running a full-screen program).
    pub(super) fn sends_bytes(&self) -> bool {
        self.shell.as_ref().is_some_and(|shell| shell.pty)
    }

    /// The input modes the terminal's screen has set, as bytes for the viewer's terminal: what
    /// a lines viewer needs before its first frame (`None` for any other viewer).
    pub(super) fn input_modes(&self) -> Option<Vec<u8>> {
        self.scan.as_ref()?;
        let modes: String = cmux_agent_cli_render::adapter::INPUT_MODES
            .iter()
            .filter(|mode| self.term.mode(**mode, false))
            .map(|mode| format!("\x1b[?{mode}h"))
            .collect();
        (!modes.is_empty()).then(|| modes.into_bytes())
    }

    /// The terminal wrote `bytes` at `now`: a shell's viewer may switch phase within them.
    fn write(
        &mut self,
        bytes: &[u8],
        now: Instant,
        out: &mut Vec<HybridOut>,
    ) -> anyhow::Result<()> {
        if self.sends_bytes() {
            self.term.vt_write(bytes);
            out.push(HybridOut::Attach(AttachFrame::Output(bytes.to_vec())));
            return self.leave_full_screen(now);
        }
        let Some(scan) = self.scan.as_mut() else {
            self.output(bytes, now);
            return Ok(());
        };
        // The keys and pastes the viewer sends follow the program's input modes (bracketed
        // paste, cursor keys), which frames do not carry: their sets and resets go as bytes
        // (they draw nothing). Only a shell's full-screen program switches to bytes.
        let found = scan.scan(bytes).filter(|_| self.shell.is_some());
        let modes = scan.take_modes();
        let Some(start) = found else {
            self.output(bytes, now);
            if !modes.is_empty() {
                out.push(HybridOut::Attach(AttachFrame::Output(modes)));
            }
            return Ok(());
        };
        // What came before the program reaches the viewer as a last frame, then its bytes.
        let (before, rest) = bytes.split_at(start.at.min(bytes.len()));
        if !before.is_empty() {
            self.output(before, now);
        }
        if let Some(event) = self.frame_now(now)? {
            out.push(HybridOut::Event(event));
        }
        if !modes.is_empty() {
            out.push(HybridOut::Attach(AttachFrame::Output(modes)));
        }
        self.bytes_from_now();
        self.term.vt_write(rest);
        out.push(HybridOut::Attach(AttachFrame::Output([&start.carried[..], rest].concat())));
        self.leave_full_screen(now)
    }

    /// The viewer gets PTY bytes from now on; no frame before can be resumed from.
    fn bytes_from_now(&mut self) {
        if let Some(shell) = self.shell.as_mut() {
            shell.pty = true;
        }
        let (cols, rows) = self.stream.size();
        self.stream.resize(cols, rows);
        self.pacer = FramePacer::default();
    }

    /// A shell's full-screen program ended: frames go on from the screen the viewer shows (it
    /// got every byte), with no keyframe.
    fn leave_full_screen(&mut self, now: Instant) -> anyhow::Result<()> {
        if full_screen(&self.term) {
            return Ok(());
        }
        if let Some(shell) = self.shell.as_mut() {
            shell.pty = false;
        }
        self.scan = Some(FullScreenScan::new());
        let (real, cursor) = self.screen()?;
        // The viewer got the program's bytes, its cursor moves among them.
        self.cursor = cursor;
        let at_ms = u64::try_from(now.duration_since(self.started).as_millis()).unwrap_or(u64::MAX);
        self.stream.update(&real, at_ms);
        Ok(())
    }

    /// A shell's resize, when it decides the viewer's phase: a full-screen terminal's viewer
    /// gets the replay as a byte viewer does, and so does one leaving full-screen (frames go on
    /// from it). False when the frame is not that (a shell at its lines gets a keyframe).
    fn shell_resize(
        &mut self,
        frame: &AttachFrame,
        now: Instant,
        out: &mut Vec<HybridOut>,
    ) -> anyhow::Result<bool> {
        let (AttachFrame::Resized { cols, rows, replay, pending_sequence, .. }
        | AttachFrame::ResizedWithColors { cols, rows, replay, pending_sequence, .. }) = frame
        else {
            return Ok(false);
        };
        let Some(shell) = self.shell.as_ref() else { return Ok(false) };
        let shadow = shadow(*cols, *rows, &[&**replay, &**pending_sequence].concat())?;
        let now_full = full_screen(&shadow);
        if !now_full && !shell.pty {
            return Ok(false);
        }
        out.push(HybridOut::Attach(frame.clone()));
        self.term = shadow;
        self.stream.resize(*cols, *rows);
        self.bytes_from_now();
        self.leave_full_screen(now)?;
        Ok(true)
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
        let frame = match self.stream.update(&real, at_ms) {
            Some(frame) => frame,
            // Only the cursor moved: the viewer's terminal places typed text, pans and keeps
            // the cursor row in view by it, as over the PTY.
            None if cursor != self.cursor => self.stream.still(at_ms),
            None => return Ok(None),
        };
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
        if self.shell_resize(&frame, now, out)? {
            return Ok(());
        }
        match frame {
            AttachFrame::Output(bytes) => self.write(&bytes, now, out)?,
            AttachFrame::OutputWithColors { output, colors } => {
                self.write(&output, now, out)?;
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

    fn event(&mut self, frame: &Frame, cursor: vt::Cursor) -> Value {
        let (cols, rows) = self.stream.size();
        self.cursor = cursor;
        if let Some(lean) = self
            .lean
            .as_mut()
            .and_then(|encoder| encoder.encode(&self.id, cols, rows, frame, cursor))
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
            "cursor_x": cursor.x,
            "cursor_y": cursor.y,
            "cursor_visible": cursor.visible,
        })
    }

    /// The shadow terminal's screen as cells, and its cursor. A hidden cursor still has its
    /// place (`visible` false): the PTY's terminal keeps it there, and so must the viewer's.
    fn screen(&mut self) -> anyhow::Result<(Grid, vt::Cursor)> {
        self.render.update(&mut self.term)?;
        let frame = self.render.build_frame()?;
        let cursor = match frame.cursor {
            Some(c) => vt::Cursor { x: c.x, y: c.y, visible: true },
            None => self
                .term
                .cursor_position()
                .map_or(vt::Cursor::default(), |(x, y)| vt::Cursor { x, y, visible: false }),
        };
        Ok((grid(&frame), cursor))
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
        let (mut viewer, first) =
            HybridViewer::start(7, 20, 4, b"hello", None, Wants::default()).unwrap();
        let first = first.unwrap();
        assert_eq!(first["base"], Value::Null);
        let id = first["stream"].as_str().unwrap().to_owned();
        let applied = first["frame"].as_u64().unwrap();
        let now = Instant::now();
        viewer.output(b"\r\nworld", now);
        let next = viewer.frame_now(now).unwrap().unwrap();
        assert_eq!(next["base"].as_u64(), Some(applied));
        drop(viewer);
        // Back after missing frame `next`: one delta from `applied`, not a keyframe.
        let (_viewer, resumed) = HybridViewer::start(
            7,
            20,
            4,
            b"hello\r\nworld!",
            Some((id.clone(), applied)),
            Wants::default(),
        )
        .unwrap();
        let resumed = resumed.unwrap();
        assert_eq!(resumed["stream"].as_str(), Some(id.as_str()));
        assert_eq!(resumed["base"].as_u64(), Some(applied));
        drop(_viewer);
        let (_viewer, other) =
            HybridViewer::start(7, 30, 4, b"hello", Some((id, applied)), Wants::default()).unwrap();
        assert_eq!(other.unwrap()["base"], Value::Null);
    }
}
