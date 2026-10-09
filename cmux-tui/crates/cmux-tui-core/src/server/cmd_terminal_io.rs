//! Terminal input and output command handlers: run, send text or keys,
//! copy, clear history, read scrollback or screen, wait for output, scroll,
//! default colors, image paste and snapshot requests. Each function is one
//! `Command` arm of `handle_command_with_cancellation`.

use crate::Rgb;

use super::styled_run_json;
use base64::Engine;

use super::ConnectionCancellation;
use super::DeliveryClassifiedError;
use super::ProtocolKeyInput;
use super::get_surface;
use super::image_paste;
use super::optional_surface_size;
use super::require_pty;
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
use std::sync::Arc;
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

pub(super) fn send(
    mux: &Arc<Mux>,
    client: u64,
    surface: SurfaceId,
    text: Option<String>,
    bytes: Option<String>,
    paste: bool,
) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    if paste {
        let mut payload = text.unwrap_or_default().into_bytes();
        if let Some(b64) = bytes {
            payload.extend(base64::engine::general_purpose::STANDARD.decode(b64)?);
        }
        surface.write_paste(&payload)?;
    } else {
        if let Some(text) = text {
            surface.write_bytes(text.as_bytes())?;
        }
        if let Some(b64) = bytes {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64)?;
            surface.write_bytes(&raw)?;
        }
    }
    mux.note_terminal_input(surface.id, client);
    Ok(json!({}))
}

pub(super) fn read_screen(mux: &Arc<Mux>, surface: SurfaceId) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let text = surface.try_with_terminal(|t| t.viewport_text())??;
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
        anyhow::bail!("connection closed while waiting for pattern");
    }
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let regex = Regex::new(&pattern).map_err(|err| anyhow::anyhow!("bad regex: {err}"))?;
    let start = Instant::now();
    let check = || -> anyhow::Result<Option<String>> {
        let text = surface.try_with_terminal(|t| t.viewport_text())??;
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
    loop {
        if cancelled() {
            anyhow::bail!("connection closed while waiting for pattern");
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
    surface.write_bytes(&encoded)?;
    mux.note_terminal_input(surface.id, client);
    Ok(json!({}))
}

pub(super) fn copy(mux: &Arc<Mux>, surface: SurfaceId, mode: String) -> anyhow::Result<Value> {
    let surface = get_surface(mux, surface)?;
    require_pty(&surface)?;
    let text = match mode.as_str() {
        "screen" => surface.try_with_terminal(|t| t.viewport_text())??,
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
                palette[index as usize] = Some(parse_hex_color(&value)?);
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
    params: terminal_snapshot::SnapshotRequestParams,
) -> anyhow::Result<Value> {
    terminal_snapshot::handle_request(mux, client, params)
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
    let bytes = value.as_bytes();
    if bytes.len() != 7 || bytes[0] != b'#' {
        anyhow::bail!("bad color {value:?} (want \"#rrggbb\")");
    }
    let nibble = |b: u8| -> anyhow::Result<u8> {
        match b {
            b'0'..=b'9' => Ok(b - b'0'),
            b'a'..=b'f' => Ok(b - b'a' + 10),
            b'A'..=b'F' => Ok(b - b'A' + 10),
            _ => anyhow::bail!("bad color {value:?} (want \"#rrggbb\")"),
        }
    };
    let hex = |idx: usize| -> anyhow::Result<u8> {
        Ok((nibble(bytes[idx])? << 4) | nibble(bytes[idx + 1])?)
    };
    Ok(Rgb { r: hex(1)?, g: hex(3)?, b: hex(5)? })
}
