//! The cloud browser: `cmux-rd host --browser URL` keeps one Chromium running full screen in
//! the host's virtual display, so the display the host streams is the browser.
//! Design: plans/cmux-next/cloud-browser-DESIGN.md.
//!
//! The browser outlives viewers: a viewer that disconnects and comes back finds the same
//! tabs, scroll positions and logins (the session state lives on the host, not in the
//! stream). The supervisor restarts a browser that exits, with a backoff that grows while
//! it keeps crashing fast, and kills it when the host stops.

use std::io;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

/// What to run: the browser binary, its arguments and its environment additions.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrowserCommand {
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

impl BrowserCommand {
    /// Chrome or Chromium full screen in `display` at `width` x `height` device pixels.
    /// Scale 1: the stream is the display's pixels, so the viewer never scales text.
    pub fn chrome(
        program: &str,
        display: &str,
        url: &str,
        width: u32,
        height: u32,
        profile_dir: &str,
    ) -> Self {
        let args = [
            format!("--user-data-dir={profile_dir}"),
            "--no-first-run".into(),
            "--no-default-browser-check".into(),
            "--password-store=basic".into(),
            "--force-device-scale-factor=1".into(),
            "--kiosk".into(),
            "--window-position=0,0".into(),
            format!("--window-size={width},{height}"),
            "--disable-features=Translate".into(),
            url.to_string(),
        ];
        Self {
            program: program.to_string(),
            args: args.into(),
            env: vec![("DISPLAY".into(), display.to_string())],
        }
    }

    /// Opens Chrome's DevTools protocol (CDP) on `127.0.0.1:port`, so an agent on the same
    /// machine drives the browser the person watches (`--browser-cdp-port`, off by default).
    /// Loopback only: anyone who reaches the port controls the browser and its logins.
    pub fn with_cdp_port(mut self, port: u16) -> Self {
        // Before the URL, which stays the last argument.
        let at = self.args.len().saturating_sub(1);
        self.args.splice(
            at..at,
            [
                "--remote-debugging-address=127.0.0.1".to_string(),
                format!("--remote-debugging-port={port}"),
            ],
        );
        self
    }
}

/// Restart delays: the first restart waits `min`; each fast crash (uptime under `healthy`)
/// doubles it up to `max`; a run that stayed up `healthy` resets it.
#[derive(Clone, Copy, Debug)]
pub struct Backoff {
    pub min: Duration,
    pub max: Duration,
    pub healthy: Duration,
}

impl Default for Backoff {
    fn default() -> Self {
        Self {
            min: Duration::from_millis(500),
            max: Duration::from_secs(10),
            healthy: Duration::from_secs(10),
        }
    }
}

struct Shared {
    stop: AtomicBool,
    pid: AtomicU32,
    starts: AtomicU32,
    // Wakes the backoff wait when the supervisor stops.
    wake: (Mutex<()>, Condvar),
}

/// Keeps one browser process running until dropped.
pub struct BrowserSupervisor {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

impl BrowserSupervisor {
    /// Starts the browser now and supervises it on a thread. Fails if the first spawn fails
    /// (a missing binary is a configuration error, not a crash to retry).
    pub fn start(cmd: BrowserCommand, backoff: Backoff) -> io::Result<Self> {
        let shared = Arc::new(Shared {
            stop: AtomicBool::new(false),
            pid: AtomicU32::new(0),
            starts: AtomicU32::new(0),
            wake: (Mutex::new(()), Condvar::new()),
        });
        let first = spawn(&cmd, &shared)?;
        let s = Arc::clone(&shared);
        let thread = thread::Builder::new()
            .name("cmux-rd-browser".into())
            .spawn(move || supervise(cmd, backoff, first, &s))?;
        Ok(Self { shared, thread: Some(thread) })
    }

    /// How many times the browser was started (1 after `start`, +1 per restart).
    #[cfg_attr(not(test), allow(dead_code))] // read by the tests; the host logs the pid
    pub fn starts(&self) -> u32 {
        self.shared.starts.load(Ordering::SeqCst)
    }

    /// The running browser's pid, or 0 between a crash and its restart.
    pub fn pid(&self) -> u32 {
        self.shared.pid.load(Ordering::SeqCst)
    }
}

impl Drop for BrowserSupervisor {
    fn drop(&mut self) {
        self.shared.stop.store(true, Ordering::SeqCst);
        self.shared.wake.1.notify_all();
        terminate(self.shared.pid.load(Ordering::SeqCst));
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn spawn(cmd: &BrowserCommand, shared: &Shared) -> io::Result<Child> {
    let mut c = Command::new(&cmd.program);
    c.args(&cmd.args);
    for (k, v) in &cmd.env {
        c.env(k, v);
    }
    let child = c.spawn()?;
    shared.pid.store(child.id(), Ordering::SeqCst);
    shared.starts.fetch_add(1, Ordering::SeqCst);
    Ok(child)
}

fn supervise(cmd: BrowserCommand, backoff: Backoff, first: Child, shared: &Shared) {
    let mut child = Some(first);
    let mut delay = backoff.min;
    loop {
        let started = Instant::now();
        if let Some(mut c) = child.take() {
            let status = c.wait();
            shared.pid.store(0, Ordering::SeqCst);
            if shared.stop.load(Ordering::SeqCst) {
                return;
            }
            eprintln!("cmux-rd host: browser exited ({status:?}); restarting in {delay:?}");
        }
        delay = if started.elapsed() >= backoff.healthy { backoff.min } else { delay };
        // A bounded restart delay that `Drop` cuts short through the condvar.
        let (lock, cvar) = &shared.wake;
        let guard = lock.lock().unwrap_or_else(|e| e.into_inner());
        let _ = cvar
            .wait_timeout_while(guard, delay, |_| !shared.stop.load(Ordering::SeqCst))
            .unwrap_or_else(|e| e.into_inner());
        if shared.stop.load(Ordering::SeqCst) {
            return;
        }
        match spawn(&cmd, shared) {
            Ok(c) => {
                // `Drop` may have read the pid before this spawn stored it: stop the new
                // browser here so the wait below returns and the thread ends.
                if shared.stop.load(Ordering::SeqCst) {
                    terminate(c.id());
                }
                child = Some(c);
            }
            Err(e) => eprintln!("cmux-rd host: browser restart failed: {e}"),
        }
        delay = (delay * 2).min(backoff.max);
    }
}

fn terminate(pid: u32) {
    if pid != 0 {
        // SIGTERM lets Chrome flush its profile; the wait in `supervise` reaps it.
        unsafe { libc::kill(pid as libc::pid_t, libc::SIGTERM) };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fast() -> Backoff {
        Backoff {
            min: Duration::from_millis(20),
            max: Duration::from_millis(80),
            healthy: Duration::from_secs(5),
        }
    }

    /// A fake browser: appends its pid to `log`, then runs `then`.
    fn fake(log: &std::path::Path, then: &str) -> BrowserCommand {
        BrowserCommand {
            program: "/bin/sh".into(),
            args: vec!["-c".into(), format!("echo $$ >> '{}'; {then}", log.display())],
            env: vec![("DISPLAY".into(), ":99".into())],
        }
    }

    fn wait_until(what: &str, f: impl Fn() -> bool) {
        let t0 = Instant::now();
        while !f() {
            assert!(t0.elapsed() < Duration::from_secs(30), "timed out waiting for {what}");
            // Test-only wait for real child processes; the code under test uses no polling.
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn alive(pid: u32) -> bool {
        unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
    }

    #[test]
    fn a_crashed_browser_is_restarted_and_the_session_survives() {
        let dir = std::env::temp_dir().join(format!("cmux-rd-browser-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("starts");
        let _ = fs::remove_file(&log);
        let sup = BrowserSupervisor::start(fake(&log, "exec sleep 30"), fast()).expect("start");
        wait_until("first start", || {
            fs::read_to_string(&log).unwrap_or_default().lines().count() == 1
        });
        let first = sup.pid();
        assert_eq!(sup.starts(), 1);
        // The browser crashes (or a person quits it): the supervisor starts a new one.
        unsafe { libc::kill(first as libc::pid_t, libc::SIGKILL) };
        wait_until("restart", || sup.starts() == 2 && sup.pid() != 0 && sup.pid() != first);
        let second = sup.pid();
        assert!(alive(second));
        wait_until("second browser running", || {
            fs::read_to_string(&log).unwrap_or_default().lines().count() == 2
        });
        drop(sup);
        // Stopping the host stops the browser and starts no other.
        wait_until("browser stopped", || !alive(second));
        let lines = fs::read_to_string(&log).unwrap().lines().count();
        assert_eq!(lines, 2, "exactly two browser starts");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_browser_that_keeps_crashing_backs_off() {
        let dir =
            std::env::temp_dir().join(format!("cmux-rd-browser-crash-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let log = dir.join("starts");
        let _ = fs::remove_file(&log);
        let sup = BrowserSupervisor::start(fake(&log, "exit 1"), fast()).expect("start");
        // 20 + 40 + 80 + 80 ms of delay after the first start: 5 starts take at least 220 ms.
        let t0 = Instant::now();
        wait_until("five starts", || sup.starts() >= 5);
        assert!(
            t0.elapsed() >= Duration::from_millis(200),
            "restarts did not back off: {:?}",
            t0.elapsed()
        );
        drop(sup);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_browser_is_a_start_error() {
        let cmd =
            BrowserCommand { program: "/nonexistent/chrome".into(), args: vec![], env: vec![] };
        assert!(BrowserSupervisor::start(cmd, fast()).is_err());
    }

    /// Real Chrome, real CDP: an agent on the host drives the page the person watches.
    /// Needs Google Chrome and Xvfb (the cloud browser VM image); run on a Linux VM with
    /// `cargo test -- --ignored cdp`. `CMUX_RD_TEST_CHROME` names another Chrome binary.
    #[test]
    #[ignore = "needs Google Chrome and Xvfb; run with --ignored on a Linux VM"]
    fn cdp_an_agent_drives_the_cloud_browser_on_loopback_only() {
        use std::io::{Read, Write};
        use std::net::{TcpListener, TcpStream, UdpSocket};

        let chrome =
            std::env::var("CMUX_RD_TEST_CHROME").unwrap_or_else(|_| "google-chrome".into());
        let display = format!(":{}", 50 + std::process::id() % 40);
        let mut xvfb = std::process::Command::new("Xvfb")
            .args([display.as_str(), "-screen", "0", "1280x800x24", "-nolisten", "tcp"])
            .spawn()
            .expect("Xvfb");
        let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let dir = std::env::temp_dir().join(format!("cmux-rd-cdp-{}", std::process::id()));
        let cmd = BrowserCommand::chrome(
            &chrome,
            &display,
            "about:blank",
            1280,
            800,
            &dir.to_string_lossy(),
        )
        .with_cdp_port(port);
        let sup = BrowserSupervisor::start(cmd, fast()).expect("start chrome");

        let http = |method: &str, path: &str| -> Option<String> {
            let mut s = TcpStream::connect(("127.0.0.1", port)).ok()?;
            s.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
            write!(s, "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n\r\n").ok()?;
            // Chrome may keep the connection open: read the head, then Content-Length bytes.
            let mut buf = Vec::new();
            let mut chunk = [0u8; 4096];
            loop {
                let n = s.read(&mut chunk).ok()?;
                if n == 0 {
                    return None;
                }
                buf.extend_from_slice(&chunk[..n]);
                let Some(end) = buf.windows(4).position(|w| w == b"\r\n\r\n") else { continue };
                let head = String::from_utf8_lossy(&buf[..end]).to_ascii_lowercase();
                let len: usize = head
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length:"))
                    .and_then(|v| v.trim().parse().ok())?;
                if buf.len() >= end + 4 + len {
                    return Some(
                        String::from_utf8_lossy(&buf[end + 4..end + 4 + len]).into_owned(),
                    );
                }
            }
        };
        let pages = || -> Vec<serde_json::Value> {
            http("GET", "/json/list")
                .and_then(|b| serde_json::from_str::<Vec<serde_json::Value>>(&b).ok())
                .unwrap_or_default()
                .into_iter()
                .filter(|t| t["type"] == "page")
                .collect()
        };
        wait_until("CDP answers on the cdp port", || !pages().is_empty());

        // Drive the page over the DevTools WebSocket: run script in it and read the result.
        let ws_url = pages()[0]["webSocketDebuggerUrl"].as_str().expect("ws url").to_string();
        let path = &ws_url[ws_url.find("/devtools/").expect("devtools path")..];
        let mut ws = TcpStream::connect(("127.0.0.1", port)).unwrap();
        ws.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        write!(
            ws,
            "GET {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
             Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        .unwrap();
        let mut head = Vec::new();
        let mut byte = [0u8; 1];
        while !head.ends_with(b"\r\n\r\n") {
            ws.read_exact(&mut byte).unwrap();
            head.push(byte[0]);
        }
        assert!(String::from_utf8_lossy(&head).starts_with("HTTP/1.1 101"), "no WebSocket upgrade");
        let call = serde_json::json!({
            "id": 1, "method": "Runtime.evaluate",
            "params": {"expression": "document.title = 'driven by cdp'; 6 * 7", "returnByValue": true}
        })
        .to_string();
        // One masked text frame (clients must mask; mask 0 keeps the payload as is).
        let mut frame = vec![0x81u8];
        let n = call.len();
        if n < 126 {
            frame.push(0x80 | n as u8);
        } else {
            frame.push(0x80 | 126);
            frame.extend_from_slice(&(n as u16).to_be_bytes());
        }
        frame.extend_from_slice(&[0, 0, 0, 0]);
        frame.extend_from_slice(call.as_bytes());
        ws.write_all(&frame).unwrap();
        let reply = loop {
            let mut h = [0u8; 2];
            ws.read_exact(&mut h).unwrap();
            let mut len = u64::from(h[1] & 0x7f);
            if len == 126 {
                let mut b = [0u8; 2];
                ws.read_exact(&mut b).unwrap();
                len = u64::from(u16::from_be_bytes(b));
            } else if len == 127 {
                let mut b = [0u8; 8];
                ws.read_exact(&mut b).unwrap();
                len = u64::from_be_bytes(b);
            }
            let mut body = vec![0u8; len as usize];
            ws.read_exact(&mut body).unwrap();
            let v: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
            if v["id"] == 1 {
                break v;
            }
        };
        assert_eq!(reply["result"]["result"]["value"], 42, "CDP reply: {reply}");
        wait_until("the page title the agent set", || {
            pages().iter().any(|p| p["title"] == "driven by cdp")
        });

        // Loopback only: the port is not reachable on the machine's network address.
        let probe = UdpSocket::bind("0.0.0.0:0").unwrap();
        if probe.connect("1.1.1.1:53").is_ok() {
            let ip = probe.local_addr().unwrap().ip();
            if !ip.is_loopback() && !ip.is_unspecified() {
                assert!(
                    TcpStream::connect_timeout(&(ip, port).into(), Duration::from_secs(2)).is_err(),
                    "CDP port {port} answered on {ip}"
                );
            }
        }

        drop(ws);
        drop(sup);
        let _ = xvfb.kill();
        let _ = xvfb.wait();
        let _ = fs::remove_dir_all(&dir);
    }
}
