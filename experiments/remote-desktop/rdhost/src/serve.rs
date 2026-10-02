//! `rdhost serve`: TCP listener, one session at a time, and the test app lifecycle.

use crate::args::Opts;
use crate::proto::{self, Hello};
use crate::session::{self, ServeCfg};
use crate::workload::Kind;
use crate::Res;
use std::io::{BufRead, BufReader};
use std::net::{TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// How long a new connection waits for the previous session to finish tearing down.
const BUSY_WAIT: Duration = Duration::from_secs(3);
/// Unacknowledged data or a blocked write older than this ends the session.
const PEER_TIMEOUT: Duration = Duration::from_secs(10);

/// One session at a time; a new client waits briefly for the previous one to tear down.
#[derive(Default)]
struct Slot {
    busy: Mutex<bool>,
    cv: Condvar,
}

impl Slot {
    fn acquire(&self) -> bool {
        let Ok(g) = self.busy.lock() else { return false };
        let Ok((mut g, _)) = self.cv.wait_timeout_while(g, BUSY_WAIT, |busy| *busy) else { return false };
        if *g {
            return false;
        }
        *g = true;
        true
    }

    fn release(&self) {
        if let Ok(mut g) = self.busy.lock() {
            *g = false;
        }
        self.cv.notify_all();
    }
}

/// Keeps one test app child running with the workload the current client asked for.
struct TestApp {
    display: String,
    child: Option<(Child, Kind)>,
}

impl TestApp {
    fn ensure(&mut self, kind: Kind) -> Res<()> {
        if let Some((child, k)) = self.child.as_mut() {
            if *k == kind && matches!(child.try_wait(), Ok(None)) {
                return Ok(());
            }
            let _ = child.kill();
            let _ = child.wait();
        }
        self.child = None;
        let exe = std::env::current_exe()?;
        let mut child = Command::new(exe)
            .args(["testapp", "--display", &self.display, "--workload", kind.name(), "--die-with-parent", "1"])
            .stdout(Stdio::piped())
            .spawn()?;
        let out = child.stdout.take().ok_or("test app has no stdout")?;
        let mut line = String::new();
        // Blocks until the test app reports its first frame is on screen (or exits).
        BufReader::new(out).read_line(&mut line)?;
        if !line.starts_with("ready") {
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!("test app did not start: {line:?}").into());
        }
        eprintln!("rdhost serve: test app {} pid {} {}", kind.name(), child.id(), line.trim());
        self.child = Some((child, kind));
        Ok(())
    }
}

pub fn run(opts: &Opts) -> Res<()> {
    let qp = match opts.get("rc") {
        Some("bitrate") => None,
        _ => Some(opts.num_or("qp", 24u8)?),
    };
    let cores = crate::sysinfo::cores() as usize;
    let cfg = ServeCfg {
        display: opts.str_or("display", ":99"),
        capture: opts.str_or("capture", "damage"),
        max_fps: opts.num_or("max-fps", 60u32)?,
        qp,
        threads: opts.num_or("threads", 1u16)?,
        convert_threads: opts.num_or("convert-threads", cores.min(4))?,
        screen: opts.str_or("usage", "screen") != "camera",
        codec: opts.str_or("codec", "openh264"),
        x264_preset: opts.str_or("x264-preset", "ultrafast"),
        x264_profile: opts.str_or("x264-profile", "baseline"),
    };
    let port: u16 = opts.num_or("port", 7400)?;
    let auto_app = opts.str_or("testapp", "auto") == "auto";
    let log_dir = opts.get("log-dir").map(str::to_string);
    let app = Arc::new(Mutex::new(TestApp { display: cfg.display.clone(), child: None }));
    if auto_app {
        lock(&app)?.ensure(Kind::Marker)?;
    }
    let listener = TcpListener::bind(("0.0.0.0", port))?;
    eprintln!("rdhost serve: listening on 0.0.0.0:{port} display {} capture {} codec {} qp {:?}", cfg.display, cfg.capture, cfg.codec, cfg.qp);
    let slot = Arc::new(Slot::default());
    let mut session_no = 0u64;
    for conn in listener.incoming() {
        let stream = match conn {
            Ok(s) => s,
            Err(e) => {
                eprintln!("rdhost serve: accept failed: {e}");
                continue;
            }
        };
        session_no += 1;
        let (cfg, app, slot, log_dir) = (cfg.clone(), Arc::clone(&app), Arc::clone(&slot), log_dir.clone());
        std::thread::spawn(move || {
            if !slot.acquire() {
                let mut s = stream;
                let _ = proto::write_msg(&mut s, proto::BYE, b"busy: another session is active");
                return;
            }
            let peer = stream.peer_addr().map(|a| a.to_string()).unwrap_or_default();
            match handle(stream, &cfg, auto_app.then_some(&app)) {
                Ok(summary) => {
                    eprintln!("rdhost serve: session {session_no} from {peer} ended");
                    write_log(log_dir.as_deref(), session_no, &summary);
                }
                Err(e) => eprintln!("rdhost serve: session {session_no} from {peer} failed: {e}"),
            }
            slot.release();
        });
    }
    Ok(())
}

fn lock(app: &Mutex<TestApp>) -> Res<std::sync::MutexGuard<'_, TestApp>> {
    app.lock().map_err(|_| "test app lock poisoned".into())
}

/// Dead-peer detection: a client that vanishes without a FIN (for example behind a tunnel)
/// must free the single session slot within seconds, not after the kernel's ~15 min retry limit.
fn detect_dead_peers(stream: &TcpStream) -> Res<()> {
    let fd = stream.as_raw_fd();
    let set = |level: libc::c_int, opt: libc::c_int, val: libc::c_int| -> std::io::Result<()> {
        // SAFETY: setsockopt with a valid fd and a c_int option value.
        let rc = unsafe { libc::setsockopt(fd, level, opt, (&val as *const libc::c_int).cast(), std::mem::size_of::<libc::c_int>() as libc::socklen_t) };
        if rc == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
    };
    set(libc::SOL_SOCKET, libc::SO_KEEPALIVE, 1)?;
    set(libc::IPPROTO_TCP, libc::TCP_KEEPIDLE, 2)?;
    set(libc::IPPROTO_TCP, libc::TCP_KEEPINTVL, 1)?;
    set(libc::IPPROTO_TCP, libc::TCP_KEEPCNT, 3)?;
    set(libc::IPPROTO_TCP, libc::TCP_USER_TIMEOUT, PEER_TIMEOUT.as_millis() as libc::c_int)?;
    stream.set_write_timeout(Some(PEER_TIMEOUT))?;
    Ok(())
}

fn handle(mut stream: TcpStream, cfg: &ServeCfg, app: Option<&Arc<Mutex<TestApp>>>) -> Res<serde_json::Value> {
    stream.set_nodelay(true)?;
    detect_dead_peers(&stream)?;
    stream.set_read_timeout(Some(Duration::from_secs(10)))?;
    let (ty, payload) = proto::read_msg(&mut stream)?;
    if ty != proto::HELLO {
        return Err(format!("expected HELLO, got type {ty:#04x}").into());
    }
    let hello: Hello = serde_json::from_slice(&payload)?;
    stream.set_read_timeout(None)?;
    eprintln!("rdhost serve: HELLO {}", String::from_utf8_lossy(&payload));
    if let Some(app) = app {
        lock(app)?.ensure(Kind::parse(&hello.workload).unwrap_or(Kind::Marker))?;
    }
    session::run(stream, &hello, cfg)
}

fn write_log(dir: Option<&str>, n: u64, summary: &serde_json::Value) {
    let Some(dir) = dir else { return };
    let path = format!("{dir}/session-{n:04}.json");
    let body = serde_json::to_string_pretty(summary).unwrap_or_default();
    if let Err(e) = std::fs::create_dir_all(dir).and_then(|()| std::fs::write(&path, body)) {
        eprintln!("rdhost serve: cannot write {path}: {e}");
    }
}
