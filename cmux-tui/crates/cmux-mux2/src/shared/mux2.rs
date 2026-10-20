//! `mux2`: the client. Small on purpose: it starts in about a millisecond.
//!
//!   mux2 new [--cwd DIR] [--size COLSxROWS] [-- ARGV...]   print the new terminal id
//!   mux2 run [--cwd DIR] [-- ARGV...]                      create, wait, exit with its status
//!   mux2 ls | stats | stop | upgrade [NEW-MUX2D]
//!   mux2 screen ID | replay ID | wait ID | kill ID
//!   mux2 write ID TEXT          (TEXT is sent as is; use $'..' for control bytes)
//!   mux2 resize ID COLSxROWS
//!   mux2 attach ID              interactive; Ctrl-\ detaches
//!   mux2 bench create N         N creates over one connection, latency in microseconds
//!   mux2 bench rtt N            write -> visible on screen, over one connection
//!   mux2 bench echo N           keystroke -> echo at an attached viewer
//!
//! One source for every OS: the Unix and Windows parts are the server start,
//! the console size, raw mode and resize following.

use std::io::{self, Read, Write};
use std::time::Instant;

use cmux_mux2::{self as proto, Stream};

#[cfg(unix)]
#[path = "mux2_unix.rs"]
mod os;
#[cfg(windows)]
#[path = "mux2_windows.rs"]
mod os;
use os::{RawMode, spawn_server, term_size};

type UnixStream = Stream;

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("mux2: {msg}");
    std::process::exit(2);
}

/// Connects, starting `mux2d` (next to this binary) when no server listens.
fn connect() -> UnixStream {
    let path = proto::socket_path();
    if let Ok(s) = proto::connect(&path) {
        return s;
    }
    let exe = std::env::current_exe().unwrap_or_else(|e| die(e));
    let daemon = exe.with_file_name(if cfg!(windows) { "mux2d.exe" } else { "mux2d" });
    // The server writes one byte once it listens, or exits and closes the pipe.
    if let Err(e) = spawn_server(&daemon) {
        die(e);
    }
    proto::connect(&path).unwrap_or_else(|e| die(format!("connect: {e}")))
}

fn call(s: &mut UnixStream, kind: u8, payload: &[u8]) -> Vec<u8> {
    proto::write_frame(s, kind, payload).unwrap_or_else(|e| die(e));
    loop {
        let (k, body) = proto::read_frame(s).unwrap_or_else(|e| die(e));
        match k {
            proto::OK | proto::EXIT => return body,
            proto::ERR => die(String::from_utf8_lossy(&body)),
            _ => {}
        }
    }
}

/// Waits for terminal `t` to exit and returns its status. An upgrade closes
/// every connection while terminals live on, so a closed connection means
/// ask again (terminal ids survive the upgrade).
fn wait_exit(t: u32) -> i32 {
    for _ in 0..100 {
        let mut s = connect();
        if proto::write_frame(&mut s, proto::WAIT, &idp(t)).is_err() {
            continue;
        }
        loop {
            match proto::read_frame(&mut s) {
                Ok((proto::EXIT, body)) => {
                    return i32::from_le_bytes(body[..4].try_into().unwrap_or([0; 4]));
                }
                Ok((proto::ERR, body)) => die(String::from_utf8_lossy(&body)),
                Ok(_) => {}
                Err(_) => break,
            }
        }
    }
    die("server kept closing the connection")
}

fn id_arg(arg: Option<&String>) -> u32 {
    arg.and_then(|a| a.parse().ok()).unwrap_or_else(|| die("expected a terminal id"))
}

fn size_arg(arg: &str) -> (u16, u16) {
    let (c, r) = arg.split_once('x').unwrap_or_else(|| die("size is COLSxROWS"));
    (c.parse().unwrap_or_else(|_| die("bad cols")), r.parse().unwrap_or_else(|_| die("bad rows")))
}

fn create_from_args(s: &mut UnixStream, args: &[String]) -> u32 {
    let (mut cols, mut rows) = term_size();
    let mut cwd = os::cwd_bytes();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--cwd" => {
                cwd = args
                    .get(i + 1)
                    .unwrap_or_else(|| die("--cwd needs a value"))
                    .as_bytes()
                    .to_vec();
                i += 2;
            }
            "--size" => {
                (cols, rows) =
                    size_arg(args.get(i + 1).unwrap_or_else(|| die("--size needs a value")));
                i += 2;
            }
            "--" => {
                i += 1;
                break;
            }
            _ => break,
        }
    }
    let argv: Vec<&[u8]> = args[i..].iter().map(|a| a.as_bytes()).collect();
    let reply = call(s, proto::CREATE, &proto::create_payload(cols, rows, &cwd, &argv));
    u32::from_le_bytes(reply[..4].try_into().unwrap_or_else(|_| die("bad reply")))
}

fn idp(t: u32) -> Vec<u8> {
    t.to_le_bytes().to_vec()
}

fn pct(xs: &mut [f64], f: f64) -> f64 {
    xs.sort_by(f64::total_cmp);
    xs[((xs.len() - 1) as f64 * f) as usize]
}

fn bench(s: &mut UnixStream, args: &[String]) {
    let n: usize = args.get(1).and_then(|a| a.parse().ok()).unwrap_or(100);
    let mut lat = Vec::with_capacity(n);
    match args.first().map(String::as_str) {
        Some("create") => {
            let payload = proto::create_payload(80, 24, b"", os::IDLE_ARGV);
            for _ in 0..n {
                let t = Instant::now();
                call(s, proto::CREATE, &payload);
                lat.push(t.elapsed().as_secs_f64() * 1e6);
            }
        }
        Some("rtt") => {
            let reply = call(s, proto::CREATE, &proto::create_payload(80, 24, b"", os::ECHO_ARGV));
            let t_id = u32::from_le_bytes(reply[..4].try_into().expect("id"));
            for i in 0..n {
                let mark = format!("M{i:06}X");
                let mut w = idp(t_id);
                w.extend_from_slice(mark.as_bytes());
                w.extend_from_slice(os::ENTER);
                let t = Instant::now();
                call(s, proto::WRITE, &w);
                while !String::from_utf8_lossy(&call(s, proto::SCREEN, &idp(t_id))).contains(&mark)
                {
                }
                lat.push(t.elapsed().as_secs_f64() * 1e6);
            }
        }
        Some("echo") => {
            // Keystroke echo as an attached viewer sees it: one byte typed on
            // the viewer's connection, until an OUTPUT frame carries it back.
            let reply = call(s, proto::CREATE, &proto::create_payload(80, 24, b"", os::ECHO_ARGV));
            let t_id = u32::from_le_bytes(reply[..4].try_into().expect("id"));
            let mut v = proto::connect(&proto::socket_path()).unwrap_or_else(|e| die(e));
            proto::write_frame(&mut v, proto::ATTACH, &idp(t_id)).unwrap_or_else(|e| die(e));
            // Waits for an OUTPUT frame holding `want` (any frame for None).
            let typed = |v: &mut UnixStream, bytes: &[u8], want: Option<u8>| {
                let mut w = idp(t_id);
                w.extend_from_slice(bytes);
                proto::write_frame(v, proto::WRITE, &w).unwrap_or_else(|e| die(e));
                loop {
                    let (k, body) = proto::read_frame(v).unwrap_or_else(|e| die(e));
                    if k == proto::OUTPUT && want.is_none_or(|c| body.contains(&c)) {
                        return;
                    }
                }
            };
            // Untimed: the program is reading once its first keystroke echoes.
            typed(&mut v, b"z", Some(b'z'));
            typed(&mut v, b"\x7f", None);
            for i in 0..n {
                let c = b'a' + (i % 25) as u8;
                let t = Instant::now();
                typed(&mut v, &[c], Some(c));
                lat.push(t.elapsed().as_secs_f64() * 1e6);
                // Erase it (untimed), so the line never fills.
                typed(&mut v, b"\x7f", None);
            }
            call(s, proto::KILL, &idp(t_id));
        }
        _ => die("bench create N | bench rtt N | bench echo N"),
    }
    println!(
        "{{\"bench\":\"{}\",\"n\":{n},\"p50_us\":{:.1},\"p95_us\":{:.1},\"p99_us\":{:.1}}}",
        args[0],
        pct(&mut lat, 0.5),
        pct(&mut lat, 0.95),
        pct(&mut lat, 0.99)
    );
}

fn resize_payload(t: u32) -> Vec<u8> {
    let (cols, rows) = term_size();
    let mut p = idp(t);
    p.extend_from_slice(&cols.to_le_bytes());
    p.extend_from_slice(&rows.to_le_bytes());
    p
}

fn attach(s: UnixStream, t: u32) -> i32 {
    // Frames from different threads must not interleave on the socket.
    let writer =
        std::sync::Arc::new(std::sync::Mutex::new(s.try_clone().unwrap_or_else(|e| die(e))));
    let send = |w: &std::sync::Mutex<UnixStream>, kind: u8, payload: &[u8]| {
        proto::write_frame(&mut *w.lock().expect("writer"), kind, payload).is_ok()
    };
    // Follow resizes first, so one during the attach is not missed.
    let follow = writer.clone();
    os::follow_resize(move || {
        proto::write_frame(&mut *follow.lock().expect("writer"), proto::RESIZE, &resize_payload(t))
            .is_ok()
    });
    send(&writer, proto::RESIZE, &resize_payload(t));
    send(&writer, proto::ATTACH, &idp(t));
    let raw = RawMode::enter();
    let mut reader = s;
    let out = std::thread::spawn(move || -> i32 {
        let mut stdout = io::stdout().lock();
        let mut strip = proto::QueryStripper::default();
        let mut clean = Vec::new();
        loop {
            let Ok((k, body)) = proto::read_frame(&mut reader) else { return 0 };
            clean.clear();
            match k {
                proto::SNAPSHOT if body.len() >= 4 => {
                    // A snapshot replaces whatever the screen showed. Its
                    // first four bytes are the server's size.
                    strip = proto::QueryStripper::default();
                    clean.extend_from_slice(b"\x1bc");
                    strip.push(&body[4..], &mut clean);
                }
                proto::OUTPUT => strip.push(&body, &mut clean),
                proto::EXIT => {
                    let _ = stdout.flush();
                    return i32::from_le_bytes(body[..4].try_into().unwrap_or([0; 4]));
                }
                proto::ERR => {
                    let _ = stdout.flush();
                    eprintln!("mux2: {}", String::from_utf8_lossy(&body));
                    return 2;
                }
                _ => {}
            }
            let _ = stdout.write_all(&clean);
            let _ = stdout.flush();
        }
    });
    let mut buf = [0u8; 4096];
    let mut stdin = io::stdin().lock();
    loop {
        if out.is_finished() {
            break;
        }
        let Ok(n) = stdin.read(&mut buf) else { break };
        if n == 0 || buf[..n].contains(&0x1c) {
            break;
        }
        let mut w = idp(t);
        w.extend_from_slice(&buf[..n]);
        if !send(&writer, proto::WRITE, &w) {
            break;
        }
    }
    drop(raw);
    let _ = writer.lock().expect("writer").shutdown(std::net::Shutdown::Both);
    out.join().unwrap_or(0)
}

pub fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some(cmd) = args.first().map(String::as_str) else {
        die("usage: mux2 new|run|ls|screen|replay|write|resize|wait|kill|attach|bench|stats|stop")
    };
    let mut s = connect();
    let mut stdout = io::stdout().lock();
    match cmd {
        "new" => {
            let t = create_from_args(&mut s, &args[1..]);
            let _ = writeln!(stdout, "{t}");
        }
        "run" => {
            let t = create_from_args(&mut s, &args[1..]);
            std::process::exit(wait_exit(t));
        }
        "ls" => {
            let _ = stdout.write_all(&call(&mut s, proto::LIST, &[]));
        }
        "stats" => {
            let _ = stdout.write_all(&call(&mut s, proto::STATS, &[]));
        }
        "stop" => {
            call(&mut s, proto::SHUTDOWN, &[]);
        }
        "upgrade" => {
            // Optional path of the new server binary; default: the server's
            // own path, so a replaced file on disk takes over.
            let path = args.get(1).map(|p| p.as_bytes().to_vec()).unwrap_or_default();
            call(&mut s, proto::UPGRADE, &path);
        }
        "screen" | "replay" => {
            let kind = if cmd == "screen" { proto::SCREEN } else { proto::REPLAY };
            let body = call(&mut s, kind, &idp(id_arg(args.get(1))));
            let _ = stdout.write_all(&body);
            if kind == proto::SCREEN && !body.ends_with(b"\n") {
                let _ = stdout.write_all(b"\n");
            }
        }
        "write" => {
            let mut w = idp(id_arg(args.get(1)));
            w.extend_from_slice(args.get(2).unwrap_or_else(|| die("write ID TEXT")).as_bytes());
            call(&mut s, proto::WRITE, &w);
        }
        "resize" => {
            let (cols, rows) = size_arg(args.get(2).unwrap_or_else(|| die("resize ID COLSxROWS")));
            let mut w = idp(id_arg(args.get(1)));
            w.extend_from_slice(&cols.to_le_bytes());
            w.extend_from_slice(&rows.to_le_bytes());
            call(&mut s, proto::RESIZE, &w);
        }
        "wait" => {
            let code = wait_exit(id_arg(args.get(1)));
            let _ = writeln!(stdout, "{code}");
        }
        "kill" => {
            call(&mut s, proto::KILL, &idp(id_arg(args.get(1))));
        }
        "attach" => {
            drop(stdout);
            std::process::exit(attach(s, id_arg(args.get(1))));
        }
        "bench" => bench(&mut s, &args[1..]),
        _ => die(format!("unknown command {cmd}")),
    }
}
