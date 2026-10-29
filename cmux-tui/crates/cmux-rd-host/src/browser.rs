//! The cloud browser: `cmux-rd host --browser URL` keeps one Chromium running full screen in
//! the host's virtual display, so the display the host streams is the browser.
//! Design: plans/cmux-next/cloud-browser-DESIGN.md.
//!
//! The browser outlives viewers: a viewer that disconnects and comes back finds the same
//! tabs, scroll positions and logins (the session state lives on the host, not in the
//! stream). The supervisor restarts a browser that exits, with a backoff that grows while
//! it keeps crashing fast, and kills it when the host stops.

use crate::cdp_socket::{self, CdpBridge};
use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::JoinHandle;
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

    /// Chrome speaks CDP on an inherited pipe (`--remote-debugging-pipe`: fds 3 and 4), never
    /// on a TCP port that every local process could reach. The supervisor opens the pipe for
    /// each launch and hands it to the host's owner-only CDP socket (`cdp_socket.rs`,
    /// `--browser-cdp-socket`, off by default).
    pub fn with_cdp_pipe(mut self) -> Self {
        // Before the URL, which stays the last argument.
        let at = self.args.len().saturating_sub(1);
        self.args.insert(at, CDP_PIPE_SWITCH.to_string());
        self
    }

    /// Does this command ask the browser to read CDP from fds 3 and 4?
    fn wants_cdp_pipe(&self) -> bool {
        self.args.iter().any(|a| a == CDP_PIPE_SWITCH)
    }
}

/// Chrome's switch for CDP on fds 3 (read) and 4 (write).
const CDP_PIPE_SWITCH: &str = "--remote-debugging-pipe";

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
    /// Where each launch's CDP pipe goes (commands with `--remote-debugging-pipe` only).
    cdp: Option<Arc<CdpBridge>>,
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
        Self::launch(cmd, backoff, None)
    }

    /// As [`BrowserSupervisor::start`] for a command made `with_cdp_pipe`: every launch,
    /// restarts included, gets a new CDP pipe that is attached to `cdp`.
    pub fn start_with_cdp(
        cmd: BrowserCommand,
        backoff: Backoff,
        cdp: Arc<CdpBridge>,
    ) -> io::Result<Self> {
        Self::launch(cmd, backoff, Some(cdp))
    }

    fn launch(
        cmd: BrowserCommand,
        backoff: Backoff,
        cdp: Option<Arc<CdpBridge>>,
    ) -> io::Result<Self> {
        if cmd.wants_cdp_pipe() != cdp.is_some() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "a browser with --remote-debugging-pipe needs a CDP socket, and only it",
            ));
        }
        let shared = Arc::new(Shared {
            cdp,
            stop: AtomicBool::new(false),
            pid: AtomicU32::new(0),
            starts: AtomicU32::new(0),
            wake: (Mutex::new(()), Condvar::new()),
        });
        let first = spawn(&cmd, &shared)?;
        let s = Arc::clone(&shared);
        // A supervisor waits on the browser's exit and restarts it: Utility.
        // supervise-allow: the browser's restarter, owned by BrowserSupervisor (joined at drop); a panic ends restarts only: the running browser keeps serving, and its next crash is final.
        let thread =
            cmux_threads::spawn("cmux-rd-browser", cmux_threads::ThreadQos::Utility, move || {
                supervise(cmd, backoff, first, &s)
            })?;
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
    let pipes = match &shared.cdp {
        Some(_) => Some(cdp_socket::browser_pipes()?),
        None => None,
    };
    if let Some((_, ends)) = &pipes {
        let (read, write) = ends.raw();
        // SAFETY: the closure runs in the forked child before exec and calls only
        // async-signal-safe functions (fcntl, dup2, close) on fds the child inherited.
        unsafe { c.pre_exec(move || cdp_socket::install_child_fds(read, write)) };
    }
    let child = c.spawn()?;
    // The browser's ends close here (dropped with `pipes`); the host keeps its own.
    if let (Some((pipe, _ends)), Some(cdp)) = (pipes, &shared.cdp) {
        cdp.attach(pipe);
    }
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
        // SAFETY: kill takes integers only and touches no memory.
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
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn alive(pid: u32) -> bool {
        // SAFETY: kill with signal 0 only checks that the process exists; it takes integers only.
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
        // SAFETY: kill takes integers only; `first` is the supervisor's live, unreaped browser
        // child.
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

    #[test]
    fn chrome_speaks_cdp_on_a_pipe_never_a_tcp_port() {
        let cmd = BrowserCommand::chrome("chrome", ":99", "https://example.com/", 1280, 800, "/p")
            .with_cdp_pipe();
        assert!(cmd.args.iter().any(|a| a == "--remote-debugging-pipe"), "{:?}", cmd.args);
        assert!(
            !cmd.args.iter().any(|a| a.starts_with("--remote-debugging-port")
                || a.starts_with("--remote-debugging-address")),
            "a TCP debugging endpoint in {:?}",
            cmd.args
        );
        // The URL stays the last argument.
        assert_eq!(cmd.args.last().map(String::as_str), Some("https://example.com/"));
        // A pipe command needs the CDP socket that serves it, and a plain one refuses it.
        assert!(BrowserSupervisor::start(cmd, fast()).is_err());
    }

    /// A private test directory under /tmp (short enough for a socket path).
    fn private_dir(tag: &str) -> std::path::PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::path::PathBuf::from(format!("/tmp/rdbr-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        dir
    }

    /// Sends `msg` on the CDP socket and reads one NUL-terminated reply (None if closed).
    fn cdp_roundtrip(s: &mut std::os::unix::net::UnixStream, msg: &str) -> Option<String> {
        use std::io::{Read, Write};
        s.write_all(msg.as_bytes()).ok()?;
        s.write_all(&[0]).ok()?;
        let mut out = Vec::new();
        let mut byte = [0u8; 1];
        loop {
            match s.read(&mut byte) {
                Ok(1) if byte[0] == 0 => return String::from_utf8(out).ok(),
                Ok(1) => out.push(byte[0]),
                _ => return None,
            }
        }
    }

    fn cdp_connect(path: &std::path::Path) -> std::os::unix::net::UnixStream {
        let s = std::os::unix::net::UnixStream::connect(path).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s
    }

    #[test]
    fn a_browser_restart_reconnects_the_cdp_pipe_and_closes_the_old_client() {
        use std::io::Read;
        let dir = private_dir("restart");
        let log = dir.join("starts");
        let sock = dir.join("cdp.sock");
        let bridge = Arc::new(CdpBridge::serve(&sock).expect("CDP socket"));
        // A fake browser that answers on fds 3 and 4 by echoing every message.
        let mut cmd = fake(&log, "exec cat <&3 >&4");
        cmd.args.push("--remote-debugging-pipe".into()); // sh's $0: the pipe switch only
        let sup =
            BrowserSupervisor::start_with_cdp(cmd, fast(), Arc::clone(&bridge)).expect("start");
        let mut client = cdp_connect(&sock);
        assert_eq!(cdp_roundtrip(&mut client, "{\"id\":1}").as_deref(), Some("{\"id\":1}"));
        // The browser crashes: its client is closed, and the restarted browser has a new pipe.
        let first = sup.pid();
        // SAFETY: kill takes integers only; `first` is the supervisor's live browser child.
        unsafe { libc::kill(first as libc::pid_t, libc::SIGKILL) };
        let mut byte = [0u8; 1];
        assert!(
            matches!(client.read(&mut byte), Ok(0) | Err(_)),
            "the client of a crashed browser stayed open"
        );
        wait_until("restart", || sup.starts() == 2 && sup.pid() != 0 && sup.pid() != first);
        let mut again = cdp_connect(&sock);
        assert_eq!(cdp_roundtrip(&mut again, "{\"id\":2}").as_deref(), Some("{\"id\":2}"));
        drop(again);
        drop(sup);
        drop(bridge);
        assert!(!sock.exists(), "the CDP socket outlived the host");
        let _ = fs::remove_dir_all(&dir);
    }

    /// Real Chrome, real CDP: an agent on the host drives the page the person watches, over
    /// the owner-only socket, and reconnects after a crash. Needs Google Chrome and Xvfb (the
    /// cloud browser VM image); run on a Linux VM with `cargo test -- --ignored cdp`.
    /// `CMUX_RD_TEST_CHROME` names another Chrome binary.
    #[test]
    #[ignore = "needs Google Chrome and Xvfb; run with --ignored on a Linux VM"]
    fn cdp_an_agent_drives_the_cloud_browser_over_the_owner_only_socket() {
        let chrome =
            std::env::var("CMUX_RD_TEST_CHROME").unwrap_or_else(|_| "google-chrome".into());
        let display = format!(":{}", 50 + std::process::id() % 40);
        let mut xvfb = std::process::Command::new("Xvfb")
            .args([display.as_str(), "-screen", "0", "1280x800x24", "-nolisten", "tcp"])
            .spawn()
            .expect("Xvfb");
        let dir = private_dir("chrome");
        let sock = dir.join("cdp.sock");
        let profile = dir.join("profile");
        let bridge = Arc::new(CdpBridge::serve(&sock).expect("CDP socket"));
        let cmd = BrowserCommand::chrome(
            &chrome,
            &display,
            "about:blank",
            1280,
            800,
            &profile.to_string_lossy(),
        )
        .with_cdp_pipe();
        let sup = BrowserSupervisor::start_with_cdp(cmd, fast(), Arc::clone(&bridge))
            .expect("start chrome");

        // One CDP call: send it, then read messages (events too) until its reply.
        let call = |s: &mut std::os::unix::net::UnixStream,
                    id: u64,
                    method: &str,
                    params: serde_json::Value,
                    session: Option<&str>|
         -> serde_json::Value {
            use std::io::{Read, Write};
            let mut msg = serde_json::json!({"id": id, "method": method, "params": params});
            if let Some(session) = session {
                msg["sessionId"] = session.into();
            }
            s.write_all(format!("{msg}\0").as_bytes()).unwrap();
            loop {
                let mut out = Vec::new();
                let mut byte = [0u8; 1];
                loop {
                    s.read_exact(&mut byte).expect("a CDP reply");
                    if byte[0] == 0 {
                        break;
                    }
                    out.push(byte[0]);
                }
                let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
                if v["id"] == id {
                    return v;
                }
            }
        };
        let drive = |s: &mut std::os::unix::net::UnixStream, title: &str| {
            // The page target appears shortly after Chrome answers its first call.
            let t0 = Instant::now();
            let page = loop {
                let targets = call(s, 1, "Target.getTargets", serde_json::json!({}), None);
                let page = targets["result"]["targetInfos"]
                    .as_array()
                    .and_then(|t| t.iter().find(|t| t["type"] == "page"))
                    .map(|t| t["targetId"].clone());
                if let Some(page) = page {
                    break page;
                }
                assert!(t0.elapsed() < Duration::from_secs(30), "no page target: {targets}");
                // Test-only wait for a real browser; the code under test uses no polling.
                std::thread::sleep(Duration::from_millis(50));
            };
            let attached = call(
                s,
                2,
                "Target.attachToTarget",
                serde_json::json!({"targetId": page, "flatten": true}),
                None,
            );
            let session = attached["result"]["sessionId"].as_str().expect("session").to_string();
            let reply = call(
                s,
                3,
                "Runtime.evaluate",
                serde_json::json!({
                    "expression": format!("document.title = '{title}'; 6 * 7"),
                    "returnByValue": true
                }),
                Some(&session),
            );
            assert_eq!(reply["result"]["result"]["value"], 42, "CDP reply: {reply}");
        };
        let mut client = cdp_connect(&sock);
        client.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        drive(&mut client, "driven by cdp");
        // No TCP endpoint: Chrome wrote no DevToolsActivePort file.
        assert!(!profile.join("DevToolsActivePort").exists(), "Chrome opened a debugging port");

        // A crash closes the client; the restarted Chrome answers a new one.
        let first = sup.pid();
        // SAFETY: kill takes integers only; `first` is the supervisor's live browser child.
        unsafe { libc::kill(first as libc::pid_t, libc::SIGKILL) };
        let mut byte = [0u8; 1];
        assert!(matches!(std::io::Read::read(&mut client, &mut byte), Ok(0) | Err(_)));
        wait_until("chrome restart", || sup.starts() == 2 && sup.pid() != 0);
        let mut again = cdp_connect(&sock);
        again.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        drive(&mut again, "driven again");

        drop(again);
        drop(sup);
        drop(bridge);
        let _ = xvfb.kill();
        let _ = xvfb.wait();
        let _ = fs::remove_dir_all(&dir);
    }
}
