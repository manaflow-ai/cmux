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
mod tests;
