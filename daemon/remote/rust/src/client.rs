use std::env;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use base64::Engine;
use serde_json::{Value, json};
use signal_hook::consts::signal::SIGWINCH;
use signal_hook::iterator::Signals;

use crate::rpc::Response;

pub struct UnixRpcClient {
    writer: UnixStream,
    reader: BufReader<UnixStream>,
    next_id: u64,
}

impl UnixRpcClient {
    pub fn connect(path: &str) -> Result<Self, String> {
        let writer = UnixStream::connect(path).map_err(|err| err.to_string())?;
        let reader = BufReader::new(writer.try_clone().map_err(|err| err.to_string())?);
        Ok(Self {
            writer,
            reader,
            next_id: 1,
        })
    }

    pub fn call_value(&mut self, method: String, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        let payload = json!({
            "id": id,
            "method": method,
            "params": params,
        });
        let encoded = serde_json::to_vec(&payload).map_err(|err| err.to_string())?;
        self.writer
            .write_all(&encoded)
            .map_err(|err| err.to_string())?;
        self.writer
            .write_all(b"\n")
            .map_err(|err| err.to_string())?;
        self.writer.flush().map_err(|err| err.to_string())?;

        let mut line = String::new();
        self.reader
            .read_line(&mut line)
            .map_err(|err| err.to_string())?;
        let response: Response = serde_json::from_str(&line).map_err(|err| err.to_string())?;
        if response.ok {
            Ok(response.result.unwrap_or_else(|| json!({})))
        } else {
            Err(response
                .error
                .map(|value| value.message)
                .unwrap_or_else(|| "request failed".to_string()))
        }
    }
}

pub fn run_session_cli(args: &[String]) -> Result<i32, String> {
    if args.is_empty() {
        print_session_usage();
        return Ok(2);
    }
    let socket_path = find_socket_arg(args)
        .or_else(|| env::var("CMUXD_UNIX_PATH").ok())
        .ok_or_else(|| "missing --socket and CMUXD_UNIX_PATH".to_string())?;
    let filtered = strip_socket_arg(args);
    match filtered.first().map(String::as_str) {
        Some("ls") | Some("list") => session_list(&socket_path),
        Some("status") => session_status(
            &socket_path,
            filtered
                .get(1)
                .ok_or_else(|| "status requires a session id".to_string())?,
        ),
        Some("history") => session_history(
            &socket_path,
            filtered
                .get(1)
                .ok_or_else(|| "history requires a session id".to_string())?,
        ),
        Some("kill") => session_kill(
            &socket_path,
            filtered
                .get(1)
                .ok_or_else(|| "kill requires a session id".to_string())?,
        ),
        Some("new") => session_new(&socket_path, &filtered[1..]),
        Some("attach") => session_attach(
            &socket_path,
            filtered
                .get(1)
                .ok_or_else(|| "attach requires a session id".to_string())?,
        ),
        _ => {
            print_session_usage();
            Ok(2)
        }
    }
}

pub fn run_amux_cli(args: &[String]) -> Result<i32, String> {
    if args.is_empty() {
        eprintln!("Usage: cmuxd-remote amux capture|events|wait ...");
        return Ok(2);
    }
    let socket_path = find_socket_arg(args)
        .or_else(|| env::var("CMUXD_UNIX_PATH").ok())
        .ok_or_else(|| "missing --socket and CMUXD_UNIX_PATH".to_string())?;
    let filtered = strip_socket_arg(args);
    match filtered.first().map(String::as_str) {
        Some("capture") => {
            let mut client = UnixRpcClient::connect(&socket_path)?;
            let session_id = filtered.get(1).cloned().unwrap_or_default();
            let value = client.call_value(
                "amux.capture".to_string(),
                json!({
                    "session_id": session_id,
                    "history": true,
                }),
            )?;
            println!(
                "{}",
                serde_json::to_string_pretty(&value).map_err(|err| err.to_string())?
            );
            Ok(0)
        }
        Some("events") => {
            let mut cursor = 0_u64;
            let mut client = UnixRpcClient::connect(&socket_path)?;
            loop {
                let value = client.call_value(
                    "amux.events.read".to_string(),
                    json!({
                        "cursor": cursor,
                        "timeout_ms": 1000,
                    }),
                )?;
                if let Some(next_cursor) = value.get("cursor").and_then(Value::as_u64) {
                    cursor = next_cursor;
                }
                if let Some(events) = value.get("events").and_then(Value::as_array) {
                    for event in events {
                        println!(
                            "{}",
                            serde_json::to_string(event).map_err(|err| err.to_string())?
                        );
                    }
                }
            }
        }
        Some("wait") => {
            let kind = filtered
                .get(1)
                .cloned()
                .unwrap_or_else(|| "ready".to_string());
            let mut client = UnixRpcClient::connect(&socket_path)?;
            let value = client.call_value(
                "amux.wait".to_string(),
                json!({
                    "kind": kind,
                    "session_id": filtered.get(2).cloned().unwrap_or_default(),
                    "timeout_ms": 30_000,
                }),
            )?;
            println!(
                "{}",
                serde_json::to_string_pretty(&value).map_err(|err| err.to_string())?
            );
            Ok(0)
        }
        _ => {
            eprintln!("Usage: cmuxd-remote amux capture|events|wait ...");
            Ok(2)
        }
    }
}

pub fn run_tmux_cli(args: &[String]) -> Result<i32, String> {
    let socket_path = find_socket_arg(args)
        .or_else(|| env::var("CMUXD_UNIX_PATH").ok())
        .ok_or_else(|| "missing --socket and CMUXD_UNIX_PATH".to_string())?;
    let filtered = strip_socket_arg(args);
    if filtered.is_empty() {
        eprintln!("Usage: cmuxd-remote tmux <command> [args...]");
        return Ok(2);
    }
    let mut client = UnixRpcClient::connect(&socket_path)?;
    let value = client.call_value("tmux.exec".to_string(), json!({ "argv": filtered }))?;
    if let Some(stdout) = value.get("stdout").and_then(Value::as_str) {
        print!("{stdout}");
    } else {
        println!(
            "{}",
            serde_json::to_string_pretty(&value).map_err(|err| err.to_string())?
        );
    }
    Ok(0)
}

fn session_list(socket_path: &str) -> Result<i32, String> {
    let mut client = UnixRpcClient::connect(socket_path)?;
    let value = client.call_value("session.list".to_string(), json!({}))?;
    let sessions = value
        .get("sessions")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if sessions.is_empty() {
        println!("No sessions");
        return Ok(0);
    }
    for item in sessions {
        let session_id = item
            .get("session_id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let status = client.call_value(
            "session.status".to_string(),
            json!({ "session_id": session_id }),
        )?;
        let effective_cols = status
            .get("effective_cols")
            .and_then(Value::as_u64)
            .unwrap_or_default();
        let effective_rows = status
            .get("effective_rows")
            .and_then(Value::as_u64)
            .unwrap_or_default();
        let attachments = status
            .get("attachments")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        if attachments.is_empty() {
            println!("session {session_id} {effective_cols}x{effective_rows} [detached]");
            continue;
        }
        println!(
            "session {session_id} {effective_cols}x{effective_rows} attachments={}",
            attachments.len()
        );
        for (index, attachment) in attachments.iter().enumerate() {
            let branch = if index + 1 == attachments.len() {
                "└──"
            } else {
                "├──"
            };
            let attachment_id = attachment
                .get("attachment_id")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let cols = attachment
                .get("cols")
                .and_then(Value::as_u64)
                .unwrap_or_default();
            let rows = attachment
                .get("rows")
                .and_then(Value::as_u64)
                .unwrap_or_default();
            println!("{branch} {attachment_id} {cols}x{rows}");
        }
    }
    Ok(0)
}

fn session_status(socket_path: &str, session_id: &str) -> Result<i32, String> {
    let mut client = UnixRpcClient::connect(socket_path)?;
    let value = client.call_value(
        "session.status".to_string(),
        json!({ "session_id": session_id }),
    )?;
    let effective_cols = value
        .get("effective_cols")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    let effective_rows = value
        .get("effective_rows")
        .and_then(Value::as_u64)
        .unwrap_or_default();
    println!("{session_id} {effective_cols}x{effective_rows}");
    Ok(0)
}

fn session_history(socket_path: &str, session_id: &str) -> Result<i32, String> {
    let mut client = UnixRpcClient::connect(socket_path)?;
    let value = client.call_value(
        "session.history".to_string(),
        json!({ "session_id": session_id }),
    )?;
    print!(
        "{}",
        value
            .get("history")
            .and_then(Value::as_str)
            .unwrap_or_default()
    );
    Ok(0)
}

fn session_kill(socket_path: &str, session_id: &str) -> Result<i32, String> {
    let mut client = UnixRpcClient::connect(socket_path)?;
    let _ = client.call_value(
        "session.close".to_string(),
        json!({ "session_id": session_id }),
    )?;
    println!("{session_id}");
    Ok(0)
}

fn session_new(socket_path: &str, args: &[String]) -> Result<i32, String> {
    let session_id = args
        .first()
        .ok_or_else(|| "new requires a session id".to_string())?;
    let detached = args.iter().any(|value| value == "--detached");
    let quiet = args.iter().any(|value| value == "--quiet");
    let command =
        split_command_tail(args).unwrap_or_else(|| "exec ${SHELL:-/bin/sh} -l".to_string());
    let (cols, rows) = current_size();
    let mut client = UnixRpcClient::connect(socket_path)?;
    let value = client.call_value(
        "terminal.open".to_string(),
        json!({
            "session_id": session_id,
            "command": command,
            "cols": cols,
            "rows": rows,
        }),
    )?;
    let attachment_id = value
        .get("attachment_id")
        .and_then(Value::as_str)
        .ok_or_else(|| "terminal.open did not return attachment_id".to_string())?
        .to_string();
    if !quiet {
        println!("{session_id}");
    }
    let _ = client.call_value(
        "session.detach".to_string(),
        json!({
            "session_id": session_id,
            "attachment_id": attachment_id,
        }),
    )?;
    if detached {
        Ok(0)
    } else {
        session_attach(socket_path, session_id)
    }
}

fn session_attach(socket_path: &str, session_id: &str) -> Result<i32, String> {
    let attachment_id = format!("cli-{}-{}", std::process::id(), unix_now());
    let (cols, rows) = current_size();
    let mut control = UnixRpcClient::connect(socket_path)?;
    let _ = control.call_value(
        "session.attach".to_string(),
        json!({
            "session_id": session_id,
            "attachment_id": attachment_id,
            "cols": cols,
            "rows": rows,
        }),
    )?;

    let stop = Arc::new(AtomicBool::new(false));
    let reported_size = Arc::new(AtomicU32::new(pack_size(cols, rows)));
    let result = (|| -> Result<i32, String> {
        let raw_mode = RawModeGuard::new()?;

        {
            let stop = Arc::clone(&stop);
            let reported_size = Arc::clone(&reported_size);
            let socket_path = socket_path.to_string();
            let session_id = session_id.to_string();
            let attachment_id = attachment_id.clone();
            thread::spawn(move || {
                let mut signals = match Signals::new([SIGWINCH]) {
                    Ok(value) => value,
                    Err(_) => return,
                };
                for _ in signals.forever() {
                    if stop.load(Ordering::Relaxed) {
                        break;
                    }
                    let (cols, rows) = current_size();
                    if let Ok(mut client) = UnixRpcClient::connect(&socket_path) {
                        let _ = sync_attachment_size_if_needed(
                            &mut client,
                            &reported_size,
                            &session_id,
                            &attachment_id,
                            cols,
                            rows,
                        );
                    }
                }
            });
        }

        {
            let stop = Arc::clone(&stop);
            let socket_path = socket_path.to_string();
            let session_id = session_id.to_string();
            thread::spawn(move || {
                let mut client = match UnixRpcClient::connect(&socket_path) {
                    Ok(value) => value,
                    Err(_) => {
                        stop.store(true, Ordering::Relaxed);
                        return;
                    }
                };
                let mut offset = 0_u64;
                let stdout = io::stdout();
                let mut stdout = stdout.lock();
                while !stop.load(Ordering::Relaxed) {
                    match client.call_value(
                        "terminal.read".to_string(),
                        json!({
                            "session_id": session_id,
                            "offset": offset,
                            "max_bytes": 32 * 1024,
                            "timeout_ms": 200,
                        }),
                    ) {
                        Ok(value) => {
                            if let Some(next_offset) = value.get("offset").and_then(Value::as_u64) {
                                offset = next_offset;
                            }
                            if let Some(data) = value.get("data").and_then(Value::as_str) {
                                if let Ok(decoded) =
                                    base64::engine::general_purpose::STANDARD.decode(data)
                                {
                                    let _ = stdout.write_all(&decoded);
                                    let _ = stdout.flush();
                                }
                            }
                            if value.get("eof").and_then(Value::as_bool) == Some(true) {
                                stop.store(true, Ordering::Relaxed);
                                break;
                            }
                        }
                        Err(err) if err == "terminal read timed out" => continue,
                        Err(_) => {
                            stop.store(true, Ordering::Relaxed);
                            break;
                        }
                    }
                }
            });
        }

        let stdin = io::stdin();
        let mut stdin = stdin.lock();
        let mut buf = [0_u8; 1024];
        loop {
            if stop.load(Ordering::Relaxed) {
                break;
            }
            let (cols, rows) = current_size();
            let _ = sync_attachment_size_if_needed(
                &mut control,
                &reported_size,
                session_id,
                &attachment_id,
                cols,
                rows,
            );
            if !poll_stdin(200)? {
                continue;
            }
            let len = stdin.read(&mut buf).map_err(|err| err.to_string())?;
            if len == 0 {
                break;
            }
            if buf[..len].contains(&0x1c) {
                break;
            }
            let data = base64::engine::general_purpose::STANDARD.encode(&buf[..len]);
            let _ = control.call_value(
                "terminal.write".to_string(),
                json!({
                    "session_id": session_id,
                    "data": data,
                }),
            )?;
        }
        drop(raw_mode);
        Ok(0)
    })();

    stop.store(true, Ordering::Relaxed);
    let _ = control.call_value(
        "session.detach".to_string(),
        json!({
            "session_id": session_id,
            "attachment_id": attachment_id,
        }),
    );
    result
}

fn print_session_usage() {
    eprintln!("Usage:");
    eprintln!("  cmuxd-remote session ls|list [--socket <path>]");
    eprintln!("  cmuxd-remote session attach|status|history|kill <name> [--socket <path>]");
    eprintln!(
        "  cmuxd-remote session new <name> [--socket <path>] [--detached] [--quiet] [-- <command>]"
    );
    eprintln!("Defaults:");
    eprintln!("  --socket defaults to $CMUXD_UNIX_PATH when set.");
}

fn find_socket_arg(args: &[String]) -> Option<String> {
    let mut idx = 0;
    while idx < args.len() {
        if args[idx] == "--socket" && idx + 1 < args.len() {
            return Some(args[idx + 1].clone());
        }
        idx += 1;
    }
    None
}

fn strip_socket_arg(args: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    let mut idx = 0;
    while idx < args.len() {
        if args[idx] == "--socket" && idx + 1 < args.len() {
            idx += 2;
            continue;
        }
        out.push(args[idx].clone());
        idx += 1;
    }
    out
}

fn split_command_tail(args: &[String]) -> Option<String> {
    args.iter()
        .position(|value| value == "--")
        .map(|index| args[index + 1..].join(" "))
        .filter(|value| !value.trim().is_empty())
}

fn current_size() -> (u16, u16) {
    for fd in [libc::STDOUT_FILENO, libc::STDIN_FILENO, libc::STDERR_FILENO] {
        let mut size = libc::winsize {
            ws_row: 24,
            ws_col: 80,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        unsafe {
            if libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) == 0
                && size.ws_col > 0
                && size.ws_row > 0
            {
                return (size.ws_col.max(2), size.ws_row.max(1));
            }
        }
    }
    (80, 24)
}

fn pack_size(cols: u16, rows: u16) -> u32 {
    (u32::from(cols) << 16) | u32::from(rows)
}

fn sync_attachment_size_if_needed(
    client: &mut UnixRpcClient,
    reported_size: &AtomicU32,
    session_id: &str,
    attachment_id: &str,
    cols: u16,
    rows: u16,
) -> Result<(), String> {
    let packed = pack_size(cols, rows);
    if reported_size.load(Ordering::Relaxed) == packed {
        return Ok(());
    }
    let _ = client.call_value(
        "session.resize".to_string(),
        json!({
            "session_id": session_id,
            "attachment_id": attachment_id,
            "cols": cols,
            "rows": rows,
        }),
    )?;
    reported_size.store(packed, Ordering::Relaxed);
    Ok(())
}

struct RawModeGuard {
    original: libc::termios,
}

impl RawModeGuard {
    fn new() -> Result<Self, String> {
        unsafe {
            let mut original = std::mem::zeroed::<libc::termios>();
            if libc::tcgetattr(libc::STDIN_FILENO, &mut original) != 0 {
                return Err(io::Error::last_os_error().to_string());
            }
            let mut raw = original;
            libc::cfmakeraw(&mut raw);
            if libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &raw) != 0 {
                return Err(io::Error::last_os_error().to_string());
            }
            Ok(Self { original })
        }
    }
}

impl Drop for RawModeGuard {
    fn drop(&mut self) {
        unsafe {
            let _ = libc::tcsetattr(libc::STDIN_FILENO, libc::TCSANOW, &self.original);
        }
    }
}

fn poll_stdin(timeout_ms: i32) -> Result<bool, String> {
    let mut pollfd = libc::pollfd {
        fd: libc::STDIN_FILENO,
        events: libc::POLLIN,
        revents: 0,
    };
    let ready = unsafe { libc::poll(&mut pollfd, 1, timeout_ms) };
    if ready < 0 {
        let err = io::Error::last_os_error();
        if err.kind() == io::ErrorKind::Interrupted {
            return Ok(false);
        }
        return Err(err.to_string());
    }
    Ok(ready > 0 && (pollfd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR)) != 0)
}

fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs())
        .unwrap_or_default()
}
