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

use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::time::Instant;

use cmux_mux2::{self as proto};

fn die(msg: impl std::fmt::Display) -> ! {
    eprintln!("mux2: {msg}");
    std::process::exit(2);
}

/// Connects, starting `mux2d` (next to this binary) when no server listens.
// The server outlives this client on purpose (it leaves our session with
// setsid); it is only waited for when it fails to start.
#[allow(clippy::zombie_processes)]
fn connect() -> UnixStream {
    let path = proto::socket_path();
    if let Ok(s) = UnixStream::connect(&path) {
        return s;
    }
    let exe = std::env::current_exe().unwrap_or_else(|e| die(e));
    let daemon = exe.with_file_name("mux2d");
    let mut fds = [0; 2];
    // SAFETY: pipe writes two descriptors.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        die(io::Error::last_os_error());
    }
    // SAFETY: both descriptors were just created and are owned here.
    let (rd, wr) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    let wr_fd = wr.as_raw_fd();
    let mut cmd = std::process::Command::new(&daemon);
    cmd.env("MUX2_READY_FD", wr_fd.to_string())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // SAFETY: setsid is async-signal-safe; the daemon leaves our session.
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child =
        cmd.spawn().unwrap_or_else(|e| die(format!("cannot start {}: {e}", daemon.display())));
    drop(wr);
    // The daemon writes one byte once it listens, or exits and closes the pipe.
    let mut byte = [0u8; 1];
    let ready = std::fs::File::from(rd).read(&mut byte).unwrap_or(0) == 1;
    if !ready {
        let _ = child.wait();
        die("server failed to start");
    }
    UnixStream::connect(&path).unwrap_or_else(|e| die(format!("connect: {e}")))
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

fn term_size() -> (u16, u16) {
    // SAFETY: TIOCGWINSZ into a zeroed winsize.
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    // SAFETY: TIOCGWINSZ writes one winsize through the pointer, which points to the live local
    // `ws`; a non-terminal stdout fails with ENOTTY and writes nothing.
    if unsafe { libc::ioctl(1, libc::TIOCGWINSZ, &mut ws) } == 0 && ws.ws_col > 0 {
        (ws.ws_col, ws.ws_row)
    } else {
        (80, 24)
    }
}

fn create_from_args(s: &mut UnixStream, args: &[String]) -> u32 {
    let (mut cols, mut rows) = term_size();
    let mut cwd =
        std::env::current_dir().map(|p| p.as_os_str().as_bytes().to_vec()).unwrap_or_default();
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
            let argv: [&[u8]; 2] = [b"/bin/sleep", b"1000000"];
            let payload = proto::create_payload(80, 24, b"", &argv);
            for _ in 0..n {
                let t = Instant::now();
                call(s, proto::CREATE, &payload);
                lat.push(t.elapsed().as_secs_f64() * 1e6);
            }
        }
        Some("rtt") => {
            let argv: [&[u8]; 1] = [b"/bin/cat"];
            let reply = call(s, proto::CREATE, &proto::create_payload(80, 24, b"", &argv));
            let t_id = u32::from_le_bytes(reply[..4].try_into().expect("id"));
            for i in 0..n {
                let mark = format!("M{i:06}X");
                let mut w = idp(t_id);
                w.extend_from_slice(format!("{mark}\n").as_bytes());
                let t = Instant::now();
                call(s, proto::WRITE, &w);
                while !String::from_utf8_lossy(&call(s, proto::SCREEN, &idp(t_id))).contains(&mark)
                {
                }
                lat.push(t.elapsed().as_secs_f64() * 1e6);
            }
        }
        _ => die("bench create N | bench rtt N"),
    }
    println!(
        "{{\"bench\":\"{}\",\"n\":{n},\"p50_us\":{:.1},\"p95_us\":{:.1},\"p99_us\":{:.1}}}",
        args[0],
        pct(&mut lat, 0.5),
        pct(&mut lat, 0.95),
        pct(&mut lat, 0.99)
    );
}

struct RawMode(libc::termios);

impl RawMode {
    fn enter() -> Option<Self> {
        // SAFETY: tcgetattr/tcsetattr on stdin with valid termios storage.
        unsafe {
            let mut t: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &mut t) != 0 {
                return None;
            }
            let saved = t;
            libc::cfmakeraw(&mut t);
            libc::tcsetattr(0, libc::TCSANOW, &t);
            Some(RawMode(saved))
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        // SAFETY: restoring the saved termios.
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0) };
    }
}

fn resize_payload(t: u32) -> Vec<u8> {
    let (cols, rows) = term_size();
    let mut p = idp(t);
    p.extend_from_slice(&cols.to_le_bytes());
    p.extend_from_slice(&rows.to_le_bytes());
    p
}

fn attach(s: UnixStream, t: u32) -> i32 {
    // SIGWINCH is handled by a sigwait thread; block it everywhere first.
    let mut winch: libc::sigset_t = 0;
    // SAFETY: the set functions write only to `winch`, a live local, and pthread_sigmask only
    // reads it; no threads exist yet, so every later thread inherits the mask.
    unsafe {
        libc::sigemptyset(&mut winch);
        libc::sigaddset(&mut winch, libc::SIGWINCH);
        libc::pthread_sigmask(libc::SIG_BLOCK, &winch, std::ptr::null_mut());
    }
    // Frames from different threads must not interleave on the socket.
    let writer =
        std::sync::Arc::new(std::sync::Mutex::new(s.try_clone().unwrap_or_else(|e| die(e))));
    let send = |w: &std::sync::Mutex<UnixStream>, kind: u8, payload: &[u8]| {
        proto::write_frame(&mut *w.lock().expect("writer"), kind, payload).is_ok()
    };
    send(&writer, proto::RESIZE, &resize_payload(t));
    send(&writer, proto::ATTACH, &idp(t));
    let raw = RawMode::enter();
    let winch_writer = writer.clone();
    // A resize is a person's action but not the echo path.
    // supervise-allow: this attach client's resize forwarder, ending with the process; a panic ends resize forwarding only (a panic holding the writer lock makes the next input write fail, which ends the attach).
    cmux_threads::spawn("mux2-winch", cmux_threads::ThreadQos::UserInitiated, move || {
        loop {
            let mut sig = 0;
            // SAFETY: waiting on the blocked SIGWINCH set.
            if unsafe { libc::sigwait(&winch, &mut sig) } != 0 {
                return;
            }
            if proto::write_frame(
                &mut *winch_writer.lock().expect("writer"),
                proto::RESIZE,
                &resize_payload(t),
            )
            .is_err()
            {
                return;
            }
        }
    })
    .unwrap_or_else(|e| die(e));
    let mut reader = s;
    // Output the person waits for: UserInitiated (only ECHO_PATH_QOS
    // threads are user-interactive, threading-model.md).
    // supervise-allow: joined at the end of attach; a panic finishes the thread, so the input loop stops and the client exits.
    let out =
        cmux_threads::spawn("mux2-out", cmux_threads::ThreadQos::UserInitiated, move || -> i32 {
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
        })
        .unwrap_or_else(|e| die(e));
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
