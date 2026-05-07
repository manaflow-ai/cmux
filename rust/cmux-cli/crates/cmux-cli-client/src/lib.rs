#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

//! cmx client over a Unix socket.
//!
//! Enters raw mode + alt screen, connects to a cmx server, and shuttles:
//! - keystrokes from crossterm → `ClientMsg::Input`
//! - terminal resizes → `ClientMsg::Resize`
//! - `ServerMsg::PtyBytes` → stdout
//! - `ServerMsg::HostControl` → stdout for host-side control sequences
//!
//! WebSocket transport lands in a later milestone.

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use cmux_cli_core::probe;
use cmux_cli_protocol::{
    ClientMsg, Command, CommandResult, MouseKind, PROTOCOL_VERSION, ServerMsg, TerminalColorReport,
    TerminalRgb, Viewport, read_msg, write_msg,
};
use crossterm::event::{
    self as ct_event, Event, KeyCode, KeyEvent, KeyModifiers, KeyboardEnhancementFlags,
    MouseButton, MouseEvent, MouseEventKind, PopKeyboardEnhancementFlags,
    PushKeyboardEnhancementFlags,
};
use crossterm::{execute, terminal};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

const TRACE_PALETTE_PROBES: &[(u8, &str)] = &[
    (0, "palette_0"),
    (1, "palette_1"),
    (2, "palette_2"),
    (3, "palette_3"),
    (4, "palette_4"),
    (5, "palette_5"),
    (6, "palette_6"),
    (7, "palette_7"),
    (8, "palette_8"),
    (9, "palette_9"),
    (10, "palette_10"),
    (11, "palette_11"),
    (12, "palette_12"),
    (13, "palette_13"),
    (14, "palette_14"),
    (15, "palette_15"),
    (118, "palette_118"),
    (135, "palette_135"),
];

pub struct AttachOptions {
    pub socket_path: PathBuf,
}

/// Run a single server-side command and return its result, without
/// entering interactive attach mode. Used by `cmx list-workspaces`,
/// `cmx ping`, and other one-shot subcommands.
///
/// One-shot commands ignore grid hydration frames and return when their
/// `CommandReply` arrives.
pub async fn run_query(socket: PathBuf, command: Command) -> Result<CommandResult> {
    let stream = UnixStream::connect(&socket)
        .await
        .with_context(|| format!("connect {}", socket.display()))?;
    let (read_half, mut w) = stream.into_split();
    let mut r = BufReader::new(read_half);

    write_msg(
        &mut w,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport {
                cols: 120,
                rows: 24,
            },
            token: None,
        },
    )
    .await?;

    let welcome = tokio::time::timeout(Duration::from_secs(5), read_msg::<_, ServerMsg>(&mut r))
        .await
        .map_err(|_| anyhow!("welcome timeout"))??
        .ok_or_else(|| anyhow!("server closed before welcome"))?;
    match welcome {
        ServerMsg::Welcome { .. } => {}
        ServerMsg::Error { message } => return Err(anyhow!("server error: {message}")),
        other => return Err(anyhow!("expected Welcome, got {other:?}")),
    }

    let request_id: u32 = 1;
    write_msg(
        &mut w,
        &ClientMsg::Command {
            id: request_id,
            command,
        },
    )
    .await?;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let result = loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return Err(anyhow!("command reply timeout"));
        }
        let msg = tokio::time::timeout(remaining, read_msg::<_, ServerMsg>(&mut r))
            .await
            .map_err(|_| anyhow!("command reply timeout"))??
            .ok_or_else(|| anyhow!("server closed before reply"))?;
        match msg {
            ServerMsg::CommandReply { id, result } if id == request_id => break result,
            ServerMsg::Error { message } => return Err(anyhow!("server error: {message}")),
            // Chrome frames, active-tab / active-workspace announcements,
            // and heartbeats are irrelevant for a one-shot query. Skip.
            _ => continue,
        }
    };

    let _ = write_msg(&mut w, &ClientMsg::Detach).await;
    let _ = w.shutdown().await;
    Ok(result)
}

/// Attach to a running server. The server streams fully rendered VT frames;
/// this client writes them through to the host terminal.
pub async fn attach(opts: AttachOptions) -> Result<()> {
    let attach_start_ms = probe::mono_ms();
    probe::log_event(
        "client",
        "attach_start",
        &[("socket", opts.socket_path.display().to_string())],
    );
    let stream = UnixStream::connect(&opts.socket_path)
        .await
        .with_context(|| format!("connect {}", opts.socket_path.display()))?;
    probe::log_event(
        "client",
        "connect_done",
        &[(
            "elapsed_ms",
            probe::mono_ms().saturating_sub(attach_start_ms).to_string(),
        )],
    );
    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);

    let (cols, rows) = terminal::size().unwrap_or((80, 24));
    let terminal_colors = query_host_terminal_colors();
    write_msg(
        &mut write_half,
        &ClientMsg::Hello {
            version: PROTOCOL_VERSION,
            viewport: Viewport { cols, rows },
            token: None,
        },
    )
    .await?;
    if let Some(colors) = terminal_colors {
        write_msg(&mut write_half, &ClientMsg::TerminalColors { colors }).await?;
    }
    probe::log_event(
        "client",
        "hello_sent",
        &[
            ("cols", cols.to_string()),
            ("rows", rows.to_string()),
            (
                "elapsed_ms",
                probe::mono_ms().saturating_sub(attach_start_ms).to_string(),
            ),
        ],
    );

    let welcome = read_msg::<_, ServerMsg>(&mut reader)
        .await?
        .ok_or_else(|| anyhow!("server closed before Welcome"))?;
    match welcome {
        ServerMsg::Welcome { .. } => {}
        ServerMsg::Error { message } => {
            return Err(anyhow!("server rejected attach: {message}"));
        }
        other => return Err(anyhow!("expected Welcome, got {other:?}")),
    }
    probe::log_event(
        "client",
        "welcome_received",
        &[(
            "elapsed_ms",
            probe::mono_ms().saturating_sub(attach_start_ms).to_string(),
        )],
    );

    terminal::enable_raw_mode().context("enable raw mode")?;
    probe::log_event(
        "client",
        "raw_mode_enabled",
        &[(
            "elapsed_ms",
            probe::mono_ms().saturating_sub(attach_start_ms).to_string(),
        )],
    );
    let enter_result = execute!(
        io::stdout(),
        terminal::EnterAlternateScreen,
        ct_event::EnableMouseCapture,
        PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES)
    );
    if let Err(error) = enter_result {
        execute!(
            io::stdout(),
            PopKeyboardEnhancementFlags,
            ct_event::DisableMouseCapture,
            terminal::LeaveAlternateScreen
        )
        .ok();
        terminal::disable_raw_mode().ok();
        return Err(error).context("enter alt screen + mouse capture");
    }
    probe::log_event(
        "client",
        "alt_screen_entered",
        &[(
            "elapsed_ms",
            probe::mono_ms().saturating_sub(attach_start_ms).to_string(),
        )],
    );

    let result = run_client_loop(reader, &mut write_half).await;

    execute!(
        io::stdout(),
        PopKeyboardEnhancementFlags,
        ct_event::DisableMouseCapture,
        terminal::LeaveAlternateScreen
    )
    .ok();
    terminal::disable_raw_mode().ok();
    result
}

async fn run_client_loop<R, W>(reader: R, write_half: &mut W) -> Result<()>
where
    R: tokio::io::AsyncRead + Unpin + Send + 'static,
    W: tokio::io::AsyncWrite + Unpin,
{
    let (ev_tx, mut ev_rx) = mpsc::channel::<Event>(256);
    let event_reader = spawn_event_reader(ev_tx);

    let (srv_tx, mut srv_rx) = mpsc::channel::<ServerMsg>(128);
    let (err_tx, err_rx) = tokio::sync::oneshot::channel::<Result<()>>();
    let reader_handle: JoinHandle<()> = tokio::spawn(async move {
        let mut reader = reader;
        let result = loop {
            match read_msg::<_, ServerMsg>(&mut reader).await {
                Ok(Some(m)) => {
                    if srv_tx.send(m).await.is_err() {
                        break Ok(());
                    }
                }
                Ok(None) => break Ok(()),
                Err(e) => break Err(anyhow!("server read error: {e}")),
            }
        };
        let _ = err_tx.send(result);
    });

    let mut stdout = io::stdout();
    let mut err_rx = Some(err_rx);
    let mut server_frame_seq: u64 = 0;
    let mut latency_tick = tokio::time::interval(Duration::from_secs(2));
    latency_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut pending_ping_sent_at: Option<Instant> = None;

    let outcome: Result<()> = loop {
        tokio::select! {
            biased;
            _ = latency_tick.tick() => {
                if pending_ping_sent_at.is_none() {
                    if write_msg(write_half, &ClientMsg::Ping).await.is_err() {
                        break Ok(());
                    }
                    pending_ping_sent_at = Some(Instant::now());
                }
            }
            ev = ev_rx.recv() => {
                let Some(ev) = ev else { break Ok(()) };
                match ev {
                    Event::Key(key) => {
                        if let Some(bytes) = encode_key(key)
                            && write_msg(write_half, &ClientMsg::Input { data: bytes })
                                .await
                                .is_err()
                        {
                            break Ok(());
                        }
                    }
                    Event::Mouse(m) => {
                        if let Some(msg) = encode_mouse(m)
                            && write_msg(write_half, &msg).await.is_err()
                        {
                            break Ok(());
                        }
                    }
                    Event::Resize(cols, rows) => {
                        match write_msg(
                            write_half,
                            &ClientMsg::Resize {
                                viewport: Viewport { cols, rows },
                            },
                        )
                        .await {
                            Ok(()) => {}
                            Err(_) => break Ok(()),
                        }
                    }
                    _ => {}
                }
            }
            msg = srv_rx.recv() => {
                let Some(msg) = msg else {
                    if let Some(err_rx_inner) = err_rx.take() {
                        match err_rx_inner.await {
                            Ok(res) => break res,
                            Err(_) => break Ok(()),
                        }
                    }
                    break Ok(());
                };
                match msg {
                    ServerMsg::PtyBytes { data, .. } => {
                        server_frame_seq = server_frame_seq.saturating_add(1);
                        if probe::verbose_enabled()
                            || probe::color_enabled()
                            || probe::contains_alt_screen(&data)
                            || server_frame_seq <= 16
                        {
                            probe::log_event(
                                "client",
                                "server_frame",
                                &[
                                    ("seq", server_frame_seq.to_string()),
                                    ("summary", probe::terminal_bytes_summary(&data)),
                                ],
                            );
                        }
                        write_server_frame(&mut stdout, &data)?;
                    }
                    ServerMsg::HostControl { data } => {
                        probe::log_event(
                            "client",
                            "host_control",
                            &[("summary", probe::terminal_bytes_summary(&data))],
                        );
                        if stdout.write_all(&data).is_err() { break Ok(()); }
                        if stdout.flush().is_err() { break Ok(()); }
                    }
                    ServerMsg::ActiveTabChanged { .. } => {
                        probe::log_event("client", "active_tab_changed", &[]);
                    }
                    ServerMsg::Pong => {
                        if let Some(sent_at) = pending_ping_sent_at.take() {
                            let latency_ms = sent_at
                                .elapsed()
                                .as_millis()
                                .min(u128::from(u32::MAX)) as u32;
                            if write_msg(write_half, &ClientMsg::ClientLatency { latency_ms })
                                .await
                                .is_err()
                            {
                                break Ok(());
                            }
                        }
                    }
                    ServerMsg::Bye => break Ok(()),
                    ServerMsg::Error { message } => {
                        break Err(anyhow!("server error: {message}"));
                    }
                    ServerMsg::CommandReply { .. }
                    | ServerMsg::ActiveWorkspaceChanged { .. }
                    | ServerMsg::ActiveSpaceChanged { .. }
                    | ServerMsg::NativeSnapshot { .. }
                    | ServerMsg::TerminalGridSnapshot { .. } => {}
                    ServerMsg::Welcome { .. } => {
                        tracing::debug!("unexpected Welcome after attach");
                    }
                }
            }
        }
    };

    let _ = write_msg(write_half, &ClientMsg::Detach).await;
    let _ = write_half.shutdown().await;
    event_reader.shutdown().await;
    reader_handle.abort();
    outcome
}

fn write_server_frame<W: Write>(stdout: &mut W, data: &[u8]) -> Result<()> {
    stdout.write_all(data)?;
    stdout.flush()?;
    Ok(())
}

fn query_host_terminal_colors() -> Option<TerminalColorReport> {
    if terminal::enable_raw_mode().is_err() {
        return None;
    }
    let result = query_host_terminal_colors_raw();
    let _ = terminal::disable_raw_mode();
    result
}

fn query_host_terminal_colors_raw() -> Option<TerminalColorReport> {
    let mut stdout = io::stdout();
    let trace_palette = probe::color_enabled();
    let mut query = Vec::from(&b"\x1b]10;?\x1b\\\x1b]11;?\x1b\\"[..]);
    // iOS renders raw PTY bytes with libghostty, so palette-indexed prompt
    // colors must use the same palette as the attached TUI terminal.
    for index in 0u8..=u8::MAX {
        query.extend_from_slice(format!("\x1b]4;{index};?\x1b\\").as_bytes());
    }
    if stdout.write_all(&query).is_err() || stdout.flush().is_err() {
        return None;
    }
    let bytes = read_available_stdin_bytes(Duration::from_millis(120), true).ok()?;
    let colors = TerminalColorReport {
        foreground: parse_osc_color(&bytes, 10),
        background: parse_osc_color(&bytes, 11),
        palette: (0u8..=u8::MAX)
            .filter_map(|index| parse_osc_palette_color(&bytes, index).map(|color| (index, color)))
            .collect::<BTreeMap<_, _>>(),
    };
    if colors.foreground.is_none() && colors.background.is_none() && colors.palette.is_empty() {
        return None;
    }
    if trace_palette {
        log_host_terminal_color_probe(&bytes, &colors);
    }
    Some(colors)
}

fn read_available_stdin_bytes(timeout: Duration, trace_palette: bool) -> io::Result<Vec<u8>> {
    let stdin = io::stdin();
    let fd = stdin.as_raw_fd();
    // SAFETY: fcntl with F_GETFL does not dereference pointers and only reads
    // flags for the valid stdin fd.
    let old_flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
    if old_flags < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: fcntl with F_SETFL updates flags for the valid stdin fd.
    let set_result = unsafe { libc::fcntl(fd, libc::F_SETFL, old_flags | libc::O_NONBLOCK) };
    if set_result < 0 {
        return Err(io::Error::last_os_error());
    }

    let read_result = read_available_stdin_bytes_nonblocking(fd, timeout, trace_palette);

    // SAFETY: restore the original flags captured from this fd.
    let restore_result = unsafe { libc::fcntl(fd, libc::F_SETFL, old_flags) };
    if restore_result < 0 {
        return Err(io::Error::last_os_error());
    }

    read_result
}

fn read_available_stdin_bytes_nonblocking(
    fd: i32,
    timeout: Duration,
    trace_palette: bool,
) -> io::Result<Vec<u8>> {
    let deadline = Instant::now() + timeout;
    let mut out = Vec::new();
    let mut tmp = [0_u8; 512];

    while let Some(remaining) = deadline.checked_duration_since(Instant::now()) {
        let timeout_ms = remaining.as_millis().min(i32::MAX as u128) as i32;
        let mut poll_fd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: poll receives a valid pointer to one pollfd and does not
        // retain it after returning.
        let ready = unsafe { libc::poll(&mut poll_fd, 1, timeout_ms) };
        if ready < 0 {
            return Err(io::Error::last_os_error());
        }
        if ready == 0 || poll_fd.revents & libc::POLLIN == 0 {
            break;
        }

        loop {
            // SAFETY: tmp is a valid writable byte buffer for read(2).
            let n = unsafe { libc::read(fd, tmp.as_mut_ptr().cast(), tmp.len()) };
            if n > 0 {
                out.extend_from_slice(&tmp[..n as usize]);
                if host_terminal_probe_complete(&out, trace_palette) {
                    return Ok(out);
                }
                continue;
            }
            if n == 0 {
                return Ok(out);
            }
            let err = io::Error::last_os_error();
            if err.kind() == io::ErrorKind::WouldBlock {
                break;
            }
            return Err(err);
        }
    }

    Ok(out)
}

fn host_terminal_probe_complete(data: &[u8], trace_palette: bool) -> bool {
    parse_osc_color(data, 10).is_some()
        && parse_osc_color(data, 11).is_some()
        && (!trace_palette
            || (0u8..=u8::MAX).all(|index| parse_osc_palette_color(data, index).is_some()))
}

fn log_host_terminal_color_probe(data: &[u8], colors: &TerminalColorReport) {
    let mut fields = vec![
        ("foreground", format_rgb(colors.foreground)),
        ("background", format_rgb(colors.background)),
    ];
    for (index, field) in TRACE_PALETTE_PROBES {
        fields.push((*field, format_rgb(colors.palette.get(index).copied())));
    }
    fields.push(("palette_count", colors.palette.len().to_string()));
    fields.push(("response", probe::preview_bytes(data, 240)));
    probe::log_event("client", "host_terminal_color_probe", &fields);
}

fn format_rgb(color: Option<TerminalRgb>) -> String {
    color.map_or_else(
        || "none".to_string(),
        |color| format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b),
    )
}

fn parse_osc_color(data: &[u8], slot: u8) -> Option<TerminalRgb> {
    let prefix = format!("\x1b]{slot};rgb:");
    parse_osc_rgb_response(data, &prefix)
}

fn parse_osc_palette_color(data: &[u8], index: u8) -> Option<TerminalRgb> {
    let prefix = format!("\x1b]4;{index};rgb:");
    parse_osc_rgb_response(data, &prefix)
}

fn parse_osc_rgb_response(data: &[u8], prefix: &str) -> Option<TerminalRgb> {
    let mut search = data;
    while let Some(start) = search
        .windows(prefix.len())
        .position(|window| window == prefix.as_bytes())
    {
        let body_start = start + prefix.len();
        let body = &search[body_start..];
        let bel_end = body.iter().position(|&b| b == 0x07);
        let st_end = body.windows(2).position(|window| window == b"\x1b\\");
        let end = match (bel_end, st_end) {
            (Some(bel), Some(st)) => bel.min(st),
            (Some(bel), None) => bel,
            (None, Some(st)) => st,
            (None, None) => return None,
        };
        if let Some(rgb) = parse_rgb_body(&body[..end]) {
            return Some(rgb);
        }
        search = &body[end..];
    }
    None
}

fn parse_rgb_body(body: &[u8]) -> Option<TerminalRgb> {
    let body = std::str::from_utf8(body).ok()?;
    let mut parts = body.split('/');
    let r = parse_u16_color_component(parts.next()?)?;
    let g = parse_u16_color_component(parts.next()?)?;
    let b = parse_u16_color_component(parts.next()?)?;
    if parts.next().is_some() {
        return None;
    }
    Some(TerminalRgb { r, g, b })
}

fn parse_u16_color_component(value: &str) -> Option<u8> {
    if value.is_empty() || value.len() > 4 {
        return None;
    }
    let raw = u32::from_str_radix(value, 16).ok()?;
    let max = (1u32 << (value.len() * 4)) - 1;
    Some(((raw * 255 + (max / 2)) / max) as u8)
}

struct EventReaderHandle {
    stop: Arc<AtomicBool>,
    task: JoinHandle<()>,
}

impl EventReaderHandle {
    async fn shutdown(self) {
        self.stop.store(true, Ordering::Relaxed);
        let _ = tokio::time::timeout(Duration::from_millis(250), self.task).await;
    }
}

fn spawn_event_reader(tx: mpsc::Sender<Event>) -> EventReaderHandle {
    let stop = Arc::new(AtomicBool::new(false));
    let task_stop = Arc::clone(&stop);
    let task = tokio::task::spawn_blocking(move || {
        while !task_stop.load(Ordering::Relaxed) {
            match crossterm::event::poll(Duration::from_millis(50)) {
                Ok(true) => {
                    let Ok(ev) = crossterm::event::read() else {
                        break;
                    };
                    if tx.blocking_send(ev).is_err() {
                        break;
                    }
                }
                Ok(false) => {}
                Err(_) => break,
            }
        }
    });
    EventReaderHandle { stop, task }
}

fn encode_mouse(m: MouseEvent) -> Option<ClientMsg> {
    // Only the left-button drag-to-select flow is wired server-side today.
    // Right / middle / modifier combos + wheel can land later; we still
    // forward them so the server can add behaviour without a client bump.
    let kind = match m.kind {
        MouseEventKind::Down(MouseButton::Left) => MouseKind::Down,
        MouseEventKind::Drag(MouseButton::Left) => MouseKind::Drag,
        MouseEventKind::Up(MouseButton::Left) => MouseKind::Up,
        MouseEventKind::ScrollDown => MouseKind::Wheel { lines: 3 },
        MouseEventKind::ScrollUp => MouseKind::Wheel { lines: -3 },
        _ => return None,
    };
    Some(ClientMsg::Mouse {
        col: m.column,
        row: m.row,
        event: kind,
    })
}

fn encode_key(key: KeyEvent) -> Option<Vec<u8>> {
    let mods = key.modifiers;
    if mods.contains(KeyModifiers::SUPER)
        && !mods.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT)
        && matches!(key.code, KeyCode::Char('k' | 'K'))
    {
        return Some(vec![0x0c]);
    }
    let alt = mods.contains(KeyModifiers::ALT);
    // Build the base byte sequence for this keycode. Alt-prefixing (ESC
    // before the base sequence) is applied at the end for every non-char
    // code, so Alt-Backspace, Alt-Enter, Alt-Tab, Alt-Arrow all produce
    // the meta-prefixed form readline / tmux / emacs-style apps expect.
    let base: Vec<u8> = match key.code {
        KeyCode::Char(c) => {
            if mods.contains(KeyModifiers::CONTROL) && c.is_ascii() {
                let upper = c.to_ascii_uppercase();
                if upper.is_ascii_uppercase() {
                    let byte = (upper as u8) - b'A' + 1;
                    return Some(if alt { vec![0x1b, byte] } else { vec![byte] });
                }
                match upper {
                    '[' => return Some(if alt { vec![0x1b, 0x1b] } else { vec![0x1b] }),
                    '\\' => return Some(if alt { vec![0x1b, 0x1c] } else { vec![0x1c] }),
                    ']' => return Some(if alt { vec![0x1b, 0x1d] } else { vec![0x1d] }),
                    ' ' => return Some(if alt { vec![0x1b, 0] } else { vec![0] }),
                    _ => {}
                }
            }
            let mut buf = [0u8; 4];
            let utf8 = c.encode_utf8(&mut buf).as_bytes();
            if alt {
                let mut s = Vec::with_capacity(1 + utf8.len());
                s.push(0x1b);
                s.extend_from_slice(utf8);
                return Some(s);
            }
            return Some(utf8.to_vec());
        }
        KeyCode::Enter => vec![b'\r'],
        KeyCode::Esc => vec![0x1b],
        // Bare backspace = DEL (0x7f), the standard macOS / Linux xterm
        // convention. Alt-Backspace becomes ESC DEL, which readline / zsh
        // / emacs all bind to backward-kill-word out of the box.
        KeyCode::Backspace => vec![0x7f],
        KeyCode::Tab => vec![b'\t'],
        KeyCode::BackTab => b"\x1b[Z".to_vec(),
        KeyCode::Up => b"\x1b[A".to_vec(),
        KeyCode::Down => b"\x1b[B".to_vec(),
        KeyCode::Right => b"\x1b[C".to_vec(),
        KeyCode::Left => b"\x1b[D".to_vec(),
        KeyCode::Home => b"\x1b[H".to_vec(),
        KeyCode::End => b"\x1b[F".to_vec(),
        KeyCode::PageUp => b"\x1b[5~".to_vec(),
        KeyCode::PageDown => b"\x1b[6~".to_vec(),
        KeyCode::Delete => b"\x1b[3~".to_vec(),
        KeyCode::Insert => b"\x1b[2~".to_vec(),
        KeyCode::F(n) => match n {
            1 => b"\x1bOP".to_vec(),
            2 => b"\x1bOQ".to_vec(),
            3 => b"\x1bOR".to_vec(),
            4 => b"\x1bOS".to_vec(),
            5 => b"\x1b[15~".to_vec(),
            6 => b"\x1b[17~".to_vec(),
            7 => b"\x1b[18~".to_vec(),
            8 => b"\x1b[19~".to_vec(),
            9 => b"\x1b[20~".to_vec(),
            10 => b"\x1b[21~".to_vec(),
            11 => b"\x1b[23~".to_vec(),
            12 => b"\x1b[24~".to_vec(),
            _ => return None,
        },
        _ => return None,
    };
    if alt {
        let mut s = Vec::with_capacity(1 + base.len());
        s.push(0x1b);
        s.extend_from_slice(&base);
        Some(s)
    } else {
        Some(base)
    }
}

#[cfg(test)]
mod tests {
    use super::{
        encode_key, host_terminal_probe_complete, parse_osc_color, parse_osc_palette_color,
        write_server_frame,
    };
    use cmux_cli_protocol::TerminalRgb;
    use crossterm::event::{KeyCode, KeyEvent, KeyEventKind, KeyEventState, KeyModifiers};

    fn key(code: KeyCode, mods: KeyModifiers) -> KeyEvent {
        KeyEvent {
            code,
            modifiers: mods,
            kind: KeyEventKind::Press,
            state: KeyEventState::NONE,
        }
    }

    #[test]
    fn ctrl_c_is_0x03() {
        assert_eq!(
            encode_key(key(KeyCode::Char('c'), KeyModifiers::CONTROL)),
            Some(vec![0x03])
        );
    }

    #[test]
    fn ctrl_z_is_0x1a() {
        assert_eq!(
            encode_key(key(KeyCode::Char('z'), KeyModifiers::CONTROL)),
            Some(vec![0x1a])
        );
    }

    #[test]
    fn ctrl_d_is_0x04() {
        assert_eq!(
            encode_key(key(KeyCode::Char('d'), KeyModifiers::CONTROL)),
            Some(vec![0x04])
        );
    }

    #[test]
    fn ctrl_bracket_group() {
        assert_eq!(
            encode_key(key(KeyCode::Char('['), KeyModifiers::CONTROL)),
            Some(vec![0x1b])
        );
        assert_eq!(
            encode_key(key(KeyCode::Char('\\'), KeyModifiers::CONTROL)),
            Some(vec![0x1c])
        );
        assert_eq!(
            encode_key(key(KeyCode::Char(']'), KeyModifiers::CONTROL)),
            Some(vec![0x1d])
        );
    }

    #[test]
    fn ctrl_space_is_null() {
        assert_eq!(
            encode_key(key(KeyCode::Char(' '), KeyModifiers::CONTROL)),
            Some(vec![0x00])
        );
    }

    #[test]
    fn ctrl_letter_range_covers_all_ascii() {
        // Ctrl-a..=Ctrl-z should produce bytes 0x01..=0x1a.
        for i in 0..26 {
            let ch = (b'a' + i) as char;
            let expected = 0x01 + i;
            assert_eq!(
                encode_key(key(KeyCode::Char(ch), KeyModifiers::CONTROL)),
                Some(vec![expected]),
                "Ctrl-{ch}"
            );
        }
    }

    #[test]
    fn bare_char_passes_through() {
        assert_eq!(
            encode_key(key(KeyCode::Char('x'), KeyModifiers::NONE)),
            Some(vec![b'x'])
        );
        assert_eq!(
            encode_key(key(KeyCode::Char('あ'), KeyModifiers::NONE)),
            Some("あ".as_bytes().to_vec())
        );
    }

    #[test]
    fn alt_char_is_escape_prefixed() {
        assert_eq!(
            encode_key(key(KeyCode::Char('x'), KeyModifiers::ALT)),
            Some(vec![0x1b, b'x'])
        );
    }

    #[test]
    fn special_keys() {
        assert_eq!(
            encode_key(key(KeyCode::Enter, KeyModifiers::NONE)),
            Some(vec![b'\r'])
        );
        assert_eq!(
            encode_key(key(KeyCode::Esc, KeyModifiers::NONE)),
            Some(vec![0x1b])
        );
        assert_eq!(
            encode_key(key(KeyCode::Backspace, KeyModifiers::NONE)),
            Some(vec![0x7f])
        );
        assert_eq!(
            encode_key(key(KeyCode::Tab, KeyModifiers::NONE)),
            Some(vec![b'\t'])
        );
        assert_eq!(
            encode_key(key(KeyCode::Up, KeyModifiers::NONE)),
            Some(b"\x1b[A".to_vec())
        );
    }

    // Opt-Backspace on macOS (crossterm delivers as Backspace+ALT) must
    // emit ESC DEL so readline / zsh / bash all invoke
    // `backward-kill-word`. Before this was fixed it emitted bare DEL,
    // which deleted one character instead of one word.
    #[test]
    fn alt_backspace_is_meta_prefixed() {
        assert_eq!(
            encode_key(key(KeyCode::Backspace, KeyModifiers::ALT)),
            Some(vec![0x1b, 0x7f])
        );
    }

    #[test]
    fn alt_prefix_applies_to_every_special_key() {
        for (code, base) in [
            (KeyCode::Enter, vec![b'\r']),
            (KeyCode::Esc, vec![0x1b]),
            (KeyCode::Backspace, vec![0x7f]),
            (KeyCode::Tab, vec![b'\t']),
            (KeyCode::Left, b"\x1b[D".to_vec()),
            (KeyCode::Right, b"\x1b[C".to_vec()),
            (KeyCode::Up, b"\x1b[A".to_vec()),
            (KeyCode::Down, b"\x1b[B".to_vec()),
            (KeyCode::Home, b"\x1b[H".to_vec()),
            (KeyCode::End, b"\x1b[F".to_vec()),
            (KeyCode::Delete, b"\x1b[3~".to_vec()),
        ] {
            let mut expected = vec![0x1b];
            expected.extend_from_slice(&base);
            assert_eq!(
                encode_key(key(code, KeyModifiers::ALT)),
                Some(expected),
                "Alt-{code:?}"
            );
        }
    }

    #[test]
    fn ctrl_alt_combo_is_still_meta_prefixed() {
        // Alt+Ctrl-C is ESC + 0x03 (emacs / readline convention).
        assert_eq!(
            encode_key(key(
                KeyCode::Char('c'),
                KeyModifiers::CONTROL | KeyModifiers::ALT
            )),
            Some(vec![0x1b, 0x03])
        );
    }

    #[test]
    fn cmd_k_maps_to_ctrl_l_clear() {
        assert_eq!(
            encode_key(key(KeyCode::Char('k'), KeyModifiers::SUPER)),
            Some(vec![0x0c])
        );
    }

    #[test]
    fn cmd_shift_k_also_maps_to_clear() {
        assert_eq!(
            encode_key(key(
                KeyCode::Char('K'),
                KeyModifiers::SUPER | KeyModifiers::SHIFT
            )),
            Some(vec![0x0c])
        );
    }

    #[test]
    fn server_frame_bytes_are_written_without_reformatting() {
        let server_frame = b"\x1b[?25l\x1b[H\x1b[49m> prompt\x1b[0m";
        let mut out = Vec::new();

        write_server_frame(&mut out, server_frame).expect("write server frame");

        assert_eq!(out, server_frame);
        assert!(
            !String::from_utf8_lossy(&out).contains("\x1b[48;2;"),
            "client must not resolve default backgrounds to RGB"
        );
    }

    #[test]
    fn parses_osc_default_color_reports() {
        let response = b"\x1b]10;rgb:ffff/eeee/dddd\x1b\\noise\x1b]11;rgb:1111/2222/3333\x07";

        assert_eq!(
            parse_osc_color(response, 10),
            Some(TerminalRgb {
                r: 255,
                g: 238,
                b: 221,
            })
        );
        assert_eq!(
            parse_osc_color(response, 11),
            Some(TerminalRgb {
                r: 17,
                g: 34,
                b: 51,
            })
        );
    }

    #[test]
    fn parses_osc_color_reports_with_short_components() {
        let response = b"\x1b]10;rgb:ff/ee/dd\x1b\\noise\x1b]11;rgb:f/8/0\x07";

        assert_eq!(
            parse_osc_color(response, 10),
            Some(TerminalRgb {
                r: 255,
                g: 238,
                b: 221,
            })
        );
        assert_eq!(
            parse_osc_color(response, 11),
            Some(TerminalRgb {
                r: 255,
                g: 136,
                b: 0,
            })
        );
    }

    #[test]
    fn parses_osc_palette_color_reports() {
        let response = b"\x1b]4;118;rgb:1234/5678/9abc\x1b\\\x1b]4;135;rgb:aaaa/bbbb/cccc\x07";

        assert_eq!(
            parse_osc_palette_color(response, 118),
            Some(TerminalRgb {
                r: 0x12,
                g: 0x56,
                b: 0x9a,
            })
        );
        assert_eq!(
            parse_osc_palette_color(response, 135),
            Some(TerminalRgb {
                r: 0xaa,
                g: 0xbb,
                b: 0xcc,
            })
        );
    }

    #[test]
    fn host_probe_waits_for_palette_when_tracing() {
        let defaults = b"\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:0000/0000/0000\x1b\\";
        assert!(host_terminal_probe_complete(defaults, false));
        assert!(!host_terminal_probe_complete(defaults, true));
    }
}
