//! Terminal input and output command handlers: run, send text or keys,
//! copy, clear history, read scrollback or screen, wait for output, scroll,
//! default colors, image paste and snapshot requests. Each function is one
//! `Command` arm of `handle_command_with_cancellation`.

use crate::Rgb;

use super::styled_run_json;
use base64::Engine;

use super::ConnectionCancellation;
use super::DeliveryClassifiedError;
use super::MessageWriter;
use super::ProtocolKeyInput;
use super::get_surface;
use super::image_paste;
use super::optional_surface_size;
use super::require_pty;
use super::terminal_io_wire::{SendParams, SnapshotRequestParams};
use super::terminal_snapshot;
use crate::Actor;
use crate::DefaultColors;
use crate::Mux;
use crate::PaneId;
use crate::SurfaceId;
use crate::platform;
use crate::stream_interrupt::StreamInterrupt;
use crate::workspace_registry::TerminalLifecycle;
use ghostty_vt::KeyEncoder;
use ghostty_vt::KeyInput;
use ghostty_vt::key_input_from_chord;
use ghostty_vt::rows_to_runs;
use regex::Regex;
use serde_json::Value;
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::{Arc, Weak};
use std::time::Duration;
use std::time::Instant;

#[allow(clippy::too_many_arguments)]
pub(super) fn paste_image(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    terminal_id: String,
    lease: String,
    upload_id: String,
    op: String,
    mime: Option<String>,
    size: Option<usize>,
    offset: Option<usize>,
    data: Option<String>,
) -> anyhow::Result<Value> {
    image_paste::ImagePasteRequest {
        surface,
        terminal_id,
        lease,
        upload_id,
        op,
        mime,
        size,
        offset,
        data,
    }
    .handle(mux, client)
}

/// `send-expect-foreground-v1`: `send` takes `expect_foreground`.
pub(super) const SEND_EXPECT_FOREGROUND_CAPABILITY: &str = "send-expect-foreground-v1";

/// `send-expect-agent-v1`: `send` takes `expect_agent` and `submit`, so a reply typed from
/// somewhere that cannot see the screen (the phone's Feed) reaches only the agent that waits at
/// its prompt, and is submitted with no gap between the text and Return.
pub(super) const SEND_EXPECT_AGENT_CAPABILITY: &str = "send-expect-agent-v1";

/// `send` `expect_agent`: the terminal's agent must wait at its prompt (`idle`, never `working`,
/// `blocked` on an approval or a question, or `done`), in this harness session.
#[derive(Debug, serde::Deserialize)]
#[cfg_attr(test, derive(serde::Serialize))]
pub(crate) struct ExpectAgent {
    /// The harness's own session id (`list-agents` `agent_session_id`, the `notification`
    /// event's `session`): a restarted agent in the same terminal is another session. Required:
    /// a send without it is refused.
    #[serde(default)]
    pub(super) session: Option<String>,
}

pub(super) fn send(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    params: SendParams,
) -> anyhow::Result<Value> {
    let SendParams {
        surface,
        terminal_id,
        text,
        bytes,
        paste,
        expect_foreground,
        expect_agent,
        submit,
        flow,
    } = params;
    // The key press's first daemon stage, taken before any check.
    let received_ns =
        if flow.is_some_and(|flow| flow != 0) { crate::input_stages::now_ns() } else { 0 };
    let surface = match (surface, terminal_id) {
        (Some(surface), None) => surface,
        (None, Some(_)) if expect_foreground.is_some() || expect_agent.is_some() || submit => {
            return Err(DeliveryClassifiedError::known_not_delivered(anyhow::anyhow!(
                "bad request: expect_foreground, expect_agent and submit need surface, not terminal_id"
            )));
        }
        (None, Some(terminal_id)) => {
            return super::creating_input::send_to_terminal(
                mux,
                client,
                writer,
                &terminal_id,
                text,
                bytes,
                paste,
            );
        }
        _ => anyhow::bail!("bad request: send takes exactly one of surface and terminal_id"),
    };
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    // Bytes queued for this terminal while it was being created go first.
    mux.wait_for_creating_input_flush(&surface);
    if let Some(expected) = expect_agent {
        // Only this surface's own terminal's record: a surface with no terminal id fails closed
        // (an unfiltered roster would name another terminal's agent).
        let agent = surface.terminal_public_id().cloned().and_then(|terminal| {
            mux.list_agents(Some(surface.id), None)
                .into_iter()
                .find(|record| record.terminal_id == terminal)
        });
        // Idle only: `done` is an agent that ended, whose terminal is back at its shell or exiting.
        // A session is required: without one a restarted agent would pass.
        let waiting = agent.as_ref().is_some_and(|agent| {
            agent.state == crate::AgentState::Idle
                && expected
                    .session
                    .as_deref()
                    .is_some_and(|session| agent.agent_session_id.as_deref() == Some(session))
        });
        if !waiting {
            return Err(DeliveryClassifiedError::known_not_delivered(anyhow::anyhow!(
                "agent not waiting: the terminal's agent is working, asking, or another session"
            )));
        }
    }
    let raw = bytes.map(|b64| base64::engine::general_purpose::STANDARD.decode(b64)).transpose()?;
    // The whole send (text, bytes and Return) is one turn of the terminal's input FIFO: no
    // other input, from this connection's streams or any other, lands inside it.
    let turn = surface.input_turn().ok_or_else(|| anyhow::anyhow!("surface is not a terminal"))?;
    // A reply meant for the program that asked must not reach the shell that took the foreground
    // back after it exited: checked here, in the send's turn right before the write, not a
    // round trip earlier.
    if let Some(expected) = expect_foreground {
        let found = surface.process_id().and_then(platform::foreground_process_name);
        if found.as_deref() != Some(expected.as_str()) {
            return Err(DeliveryClassifiedError::known_not_delivered(anyhow::anyhow!(
                "foreground changed: the expected program no longer runs in the foreground"
            )));
        }
    }
    if paste {
        let mut payload = text.unwrap_or_default().into_bytes();
        if let Some(raw) = raw {
            payload.extend(raw);
        }
        surface.write_paste_in(&turn, &payload, None)?;
    } else {
        // The key press's flow goes with its first write, so one echo carries it.
        let flow = flow.unwrap_or(0);
        let mut echo_flow = flow;
        if let Some(text) = text {
            let text_flow = if text.is_empty() { 0 } else { std::mem::take(&mut echo_flow) };
            surface.write_key_flow_in(&turn, text.as_bytes(), text_flow, received_ns)?;
        }
        if let Some(raw) = raw {
            cmux_flow_trace::hop("daemon.send.write", flow, surface.flow_terminal_id());
            surface.write_key_flow_in(&turn, &raw, echo_flow, received_ns)?;
            cmux_flow_trace::hop("daemon.send.written", flow, surface.flow_terminal_id());
        }
    }
    if submit {
        // Return as its own key: a full-screen agent editor reads a pasted newline as a line
        // break, not a submit.
        // The text is already in: a failed Return must not read as "nothing was written".
        surface.write_bytes_in(&turn, b"\r", 0).map_err(|error| {
            anyhow::anyhow!("submit failed after the text was written: {error}")
        })?;
    }
    // The turn ends before the state lock is taken (crate::lock_rank `PtyInput`).
    drop(turn);
    mux.note_terminal_input(surface.id, client);
    Ok(json!({}))
}

/// The event an INPUT frame's failure sends on its stream (spec/events.md).
pub(super) const INPUT_FAILED_EVENT: &str = "input-failed";

/// Why an INPUT frame's bytes did not reach its terminal
/// (`input-failed.reason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum InputFailure {
    /// The surface closed or its terminal ended.
    TerminalEnded,
    /// The stream views a browser surface, which takes no PTY bytes.
    NotATerminal,
    /// The terminal refused the write (a host that did not come back, a
    /// write that timed out).
    WriteFailed,
    /// A daemon handoff is pending, so the daemon refused the bytes without
    /// writing them, as it refuses a line meanwhile.
    DaemonHandoff,
}

impl InputFailure {
    pub(super) fn reason(self) -> &'static str {
        match self {
            Self::TerminalEnded => "terminal_ended",
            Self::NotATerminal => "not_a_terminal",
            Self::WriteFailed => "write_failed",
            Self::DaemonHandoff => "daemon_handoff",
        }
    }

    /// Whether later INPUT fails the same way until a write reaches a
    /// terminal again (a respawned one) or the stream is opened again.
    pub(super) fn is_final(self) -> bool {
        matches!(self, Self::TerminalEnded | Self::NotATerminal)
    }

    /// `input-failed{stream, reason, bytes}` for `bytes` bytes of an INPUT
    /// frame on `stream` not delivered.
    pub(super) fn event(self, stream: u16, bytes: usize) -> Value {
        json!({
            "event": INPUT_FAILED_EVENT,
            "stream": stream,
            "reason": self.reason(),
            "bytes": bytes,
        })
    }
}

/// An INPUT frame's bytes: the raw bytes of `send`, with no
/// JSON and no base64, written the way `send` writes them. `flow` (0: none)
/// is the key press's flow id, carried by the frame header: its hops and
/// the echo that answers it carry it, as `send`'s `flow` does. The mux is
/// held only to find the surface, not across the write, which waits while
/// the program does not read.
pub(super) fn write_input(
    mux: &Weak<Mux>,
    client: u64,
    surface: SurfaceId,
    bytes: &[u8],
    flow: u64,
) -> Result<(), InputFailure> {
    let surface = {
        let Some(mux) = mux.upgrade() else { return Err(InputFailure::TerminalEnded) };
        let Some(surface) = mux.surface(surface).filter(|surface| !surface.is_dead()) else {
            return Err(InputFailure::TerminalEnded);
        };
        if require_pty(&surface).is_err() {
            return Err(InputFailure::NotATerminal);
        }
        // Bytes queued for this terminal while it was being created go first.
        mux.wait_for_creating_input_flush(&surface);
        surface
    };
    cmux_flow_trace::hop("daemon.send.write", flow, surface.flow_terminal_id());
    if surface.write_bytes_flow(bytes, flow).is_err() {
        return Err(if surface.is_dead() {
            InputFailure::TerminalEnded
        } else {
            InputFailure::WriteFailed
        });
    }
    cmux_flow_trace::hop("daemon.send.written", flow, surface.flow_terminal_id());
    if let Some(mux) = mux.upgrade() {
        mux.note_terminal_input(surface.id, client);
    }
    Ok(())
}

pub(super) fn read_screen(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let text = surface.try_with_terminal(|t| t.active_text())??;
    Ok(json!({ "text": text }))
}

pub(super) fn clear_history(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    fallback_key: Option<ProtocolKeyInput>,
) -> anyhow::Result<Value> {
    let surface =
        get_surface(mux, surface).map_err(DeliveryClassifiedError::known_not_delivered)?;
    require_pty(&surface).map_err(DeliveryClassifiedError::known_not_delivered)?;
    let fallback_key = fallback_key
        .map(KeyInput::try_from)
        .transpose()
        .map_err(DeliveryClassifiedError::known_not_delivered)?;
    // Bytes queued for this terminal while it was being created go before the clear or its key.
    mux.wait_for_creating_input_flush(&surface);
    surface
        .clear_history_or_encode_key_classified(fallback_key.as_ref())
        .map_err(DeliveryClassifiedError::from)?;
    Ok(json!({}))
}

pub(super) fn read_scrollback(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    start: u32,
    count: u32,
) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let count = u16::try_from(count).map_err(|_| anyhow::anyhow!("count out of range"))?;
    let (start, total, epoch, rows) = surface.try_with_terminal(|term| {
        let total = term.history_rows();
        let start = start.min(total);
        let epoch = term.history_epoch();
        term.styled_history_rows(start, count).map(|rows| (start, total, epoch, rows))
    })??;
    let runs = rows_to_runs(&rows);
    let rows = runs
        .iter()
        .enumerate()
        .map(|(row, runs)| {
            json!({
                "row": row as u16,
                "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({ "rows": rows, "start": start, "total": total, "epoch": epoch }))
}

pub(super) fn wait_for(
    mux: &Arc<Mux>,
    cancellation: Option<&ConnectionCancellation>,
    surface: SurfaceId,
    pattern: String,
    timeout_ms: u64,
) -> anyhow::Result<Value> {
    let cancelled = || cancellation.is_some_and(ConnectionCancellation::is_cancelled);
    if cancelled() {
        anyhow::bail!("cancelled while waiting for pattern");
    }
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let regex = Regex::new(&pattern).map_err(|err| anyhow::anyhow!("bad regex: {err}"))?;
    let start = Instant::now();
    let check = || -> anyhow::Result<Option<String>> {
        let text = surface.try_with_terminal(|t| t.active_text())??;
        Ok(regex.is_match(&text).then_some(text))
    };
    if timeout_ms == 0 {
        if let Some(text) = check()? {
            return Ok(json!({
                "matched": true,
                "text": text,
                "elapsed_ms": start.elapsed().as_millis() as u64,
            }));
        }
        anyhow::bail!("timeout waiting for pattern");
    }
    let deadline = start + Duration::from_millis(timeout_ms);
    let attach = surface.attach_stream()?;
    // The wait ends on output, the deadline, or the connection
    // closing; it used to wake every 100 ms to check the last.
    let interrupt = StreamInterrupt::new();
    if let Some(cancellation) = cancellation {
        cancellation.register_interrupt(&interrupt);
    }
    attach.stream.wake_on(&interrupt);
    if let Some(text) = check()? {
        return Ok(json!({
            "matched": true,
            "text": text,
            "elapsed_ms": start.elapsed().as_millis() as u64,
        }));
    }
    // The wait blocks by design: a pool worker that runs it starts a
    // temporary one meanwhile (sequenced_pool.rs).
    crate::request_path::will_block(|| {
        loop {
            if cancelled() {
                anyhow::bail!("cancelled while waiting for pattern");
            }
            let now = Instant::now();
            if now >= deadline {
                anyhow::bail!("timeout waiting for pattern");
            }
            match attach.stream.recv_interruptible(&interrupt, Some(deadline)) {
                Ok(_) => {
                    if let Some(text) = check()? {
                        return Ok(json!({
                            "matched": true,
                            "text": text,
                            "elapsed_ms": start.elapsed().as_millis() as u64,
                        }));
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                    if Instant::now() >= deadline {
                        anyhow::bail!("timeout waiting for pattern");
                    }
                }
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
                    anyhow::bail!("timeout waiting for pattern");
                }
            }
        }
    })
}

#[allow(clippy::too_many_arguments)]
pub(super) fn run(
    mux: &Arc<Mux>,
    actor: Actor,
    argv: Option<Vec<String>>,
    command: Option<String>,
    cwd: Option<String>,
    pane: Option<PaneId>,
    new_workspace: bool,
    key: Option<String>,
    name: Option<String>,
    cols: Option<u16>,
    rows: Option<u16>,
) -> anyhow::Result<Value> {
    if argv.is_some() && command.is_some() {
        anyhow::bail!("argv and command are mutually exclusive");
    }
    let argv = match (argv, command) {
        (Some(argv), None) if !argv.is_empty() => argv,
        (None, Some(command)) if !command.is_empty() => {
            vec![platform::default_shell(), "-lc".to_string(), command]
        }
        _ => anyhow::bail!("argv or command is required"),
    };
    if new_workspace && pane.is_some() {
        anyhow::bail!("pane and new_workspace are mutually exclusive");
    }
    if key.is_some() && !new_workspace {
        anyhow::bail!("key requires new_workspace");
    }
    let result = mux.run_command_result_with_options_as(
        &actor,
        argv,
        crate::mux::RunCommandOptions {
            pane,
            new_workspace,
            workspace_key: key,
            cwd,
            name,
            size: optional_surface_size(cols, rows),
        },
    )?;
    let placement = result.placement;
    let already_exited = result.terminal.lifecycle == TerminalLifecycle::Exited;
    Ok(json!({
        "surface": placement.as_ref().map(|placement| placement.surface),
        "terminal_id": result.terminal.terminal_id,
        "terminal_incarnation": result.terminal.incarnation,
        "pane": placement.as_ref().map(|placement| placement.pane),
        "screen": placement.as_ref().map(|placement| placement.screen),
        "workspace": placement.as_ref().map(|placement| placement.workspace),
        "lifecycle": result.terminal.lifecycle,
        "exit": result.terminal.exit,
        "terminal_revision": result.terminal_revision,
        "already_exited": already_exited,
    }))
}

pub(super) fn send_key(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    keys: Vec<String>,
) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface).map_err(|_| anyhow::anyhow!("surface does not support key input"))?;
    if keys.is_empty() {
        anyhow::bail!("bad request: keys must be non-empty");
    }
    let mut encoder = KeyEncoder::new()?;
    let mut encoded = Vec::new();
    surface.scroll_to_bottom()?;
    surface.try_with_terminal(|term| {
        encoder.sync_from_terminal(term);
        for key in &keys {
            let Some(input) = key_input_from_chord(key) else {
                return Err(anyhow::anyhow!("unknown key {key}"));
            };
            encoder.encode(&input, &mut encoded).map_err(anyhow::Error::from)?;
        }
        Ok::<(), anyhow::Error>(())
    })??;
    mux.wait_for_creating_input_flush(&surface);
    surface.write_bytes(&encoded)?;
    mux.note_terminal_input(surface.id, client);
    Ok(json!({}))
}

pub(super) fn copy(mux: &Arc<Mux>, surface: SurfaceId, mode: String) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let text = match mode.as_str() {
        "screen" => surface.try_with_terminal(|t| t.active_text())??,
        "scrollback" => surface.try_with_terminal(|t| t.plain_text())??,
        "selection" => surface.selection_text().ok_or_else(|| anyhow::anyhow!("no selection"))?,
        other => anyhow::bail!("bad mode {other}"),
    };
    Ok(json!({ "text": text, "mode": mode }))
}

#[allow(clippy::too_many_arguments)]
pub(super) fn set_default_colors(
    mux: &Arc<Mux>,
    fg: Option<String>,
    bg: Option<String>,
    cursor: Option<String>,
    selection_bg: Option<String>,
    selection_fg: Option<String>,
    cursor_style: Option<String>,
    cursor_blink: Option<bool>,
    palette: Option<BTreeMap<String, String>>,
    complete: bool,
) -> anyhow::Result<Value> {
    let current = mux.default_colors();
    let base = if complete { DefaultColors::default() } else { current };
    let palette = match palette {
        Some(entries) => {
            let mut palette = [None; 256];
            for (index, value) in entries {
                let index = index
                    .parse::<u8>()
                    .map_err(|_| anyhow::anyhow!("invalid palette index {index}"))?;
                let color = parse_hex_color(&value)?;
                if let Some(slot) = palette.get_mut(usize::from(index)) {
                    *slot = Some(color);
                }
            }
            palette
        }
        None => base.palette,
    };
    let colors = DefaultColors {
        fg: match fg {
            Some(value) => Some(parse_hex_color(&value)?),
            None => base.fg,
        },
        bg: match bg {
            Some(value) => Some(parse_hex_color(&value)?),
            None => base.bg,
        },
        cursor: match cursor {
            Some(value) => Some(parse_hex_color(&value)?),
            None => base.cursor,
        },
        selection_bg: match selection_bg {
            Some(value) => Some(parse_hex_color(&value)?),
            None => base.selection_bg,
        },
        selection_fg: match selection_fg {
            Some(value) => Some(parse_hex_color(&value)?),
            None => base.selection_fg,
        },
        cursor_style: match cursor_style.as_deref() {
            Some("block") => Some(ghostty_vt::CursorShape::Block),
            Some("underline") => Some(ghostty_vt::CursorShape::Underline),
            Some("bar") => Some(ghostty_vt::CursorShape::Bar),
            Some(value) => anyhow::bail!("invalid cursor style {value}"),
            None => base.cursor_style,
        },
        cursor_blink: cursor_blink.or(base.cursor_blink),
        palette,
    };
    mux.set_default_colors(colors);
    Ok(json!({}))
}

pub(super) fn snapshot_request(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    params: SnapshotRequestParams,
) -> anyhow::Result<Value> {
    terminal_snapshot::handle_request(mux, client, writer, params)
}

pub(super) fn scroll_surface(
    mux: &Arc<Mux>,
    surface: SurfaceId,
    delta: isize,
) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    mux.scroll_surface_viewport(&surface, delta)?;
    Ok(json!({}))
}

fn parse_hex_color(value: &str) -> anyhow::Result<Rgb> {
    let bad = || anyhow::anyhow!("bad color {value:?} (want \"#rrggbb\")");
    let Some(bytes) = value.as_bytes().strip_prefix(b"#").filter(|bytes| bytes.len() == 6) else {
        return Err(bad());
    };
    let nibble = |b: u8| -> anyhow::Result<u8> {
        match b {
            b'0'..=b'9' => Ok(b - b'0'),
            b'a'..=b'f' => Ok(b - b'a' + 10),
            b'A'..=b'F' => Ok(b - b'A' + 10),
            _ => anyhow::bail!("bad color {value:?} (want \"#rrggbb\")"),
        }
    };
    let hex = |idx: usize| -> anyhow::Result<u8> {
        let (Some(&high), Some(&low)) = (bytes.get(idx), bytes.get(idx + 1)) else {
            return Err(bad());
        };
        Ok((nibble(high)? << 4) | nibble(low)?)
    };
    Ok(Rgb { r: hex(0)?, g: hex(2)?, b: hex(4)? })
}

#[cfg(test)]
#[path = "pty_input_order_tests.rs"]
mod pty_input_order_tests;

#[cfg(all(test, unix))]
#[path = "cmd_terminal_io_wire_tests.rs"]
mod wire_tests;
