//! `--watch` triggers: long-running commands whose stdout lines are events.
//!
//! The runner owns one [`Watches`]. [`Watches::reconcile`] starts a watch
//! command for every enabled automation with a `watch` trigger, stops the ones
//! whose automation went away, paused or changed, and restarts one that exited
//! (with backoff). Each command runs with `/bin/sh -c` in its own process
//! group; a reader thread per command sends its lines over one channel, so
//! [`Watches::wait`] is the runner's only sleep and a line wakes it at once.
//!
//! Lines closer together than the trigger's debounce are one event; a stream
//! that never pauses still makes an event every [`MAX_HOLD_MS`] at most. An
//! event keeps the first 16 KiB of its lines and counts the rest.
//!
//! The commands die with the runner: dropping [`Watches`] stops them, and on
//! Unix the runner's SIGTERM, SIGINT and SIGHUP stop them too (a handler that
//! signals the recorded process groups, then re-raises).

use std::collections::HashMap;
#[cfg(unix)]
use std::fs::OpenOptions;
use std::io::Read;
use std::process::Child;
#[cfg(unix)]
use std::process::{Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

use crate::automation::Automation;
use crate::gate::MAX_EVENT_BYTES;
use crate::store::Store;
#[cfg(unix)]
use crate::sys::private_file;
use crate::trigger::Trigger;

/// The longest an event is held while lines keep coming.
pub const MAX_HOLD_MS: i64 = 30_000;
/// The longest kept line; the rest of a longer line is cut.
const MAX_LINE_BYTES: usize = 4 * 1024;
/// Restart backoff after a watch command exits: 5 s, doubling, at most 5 min.
const FIRST_BACKOFF_MS: i64 = 5_000;
const MAX_BACKOFF_MS: i64 = 300_000;
/// A command that ran this long before it exited starts over at the first backoff.
const HEALTHY_MS: i64 = 60_000;

/// One event a watch made.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WatchEvent {
    pub automation: String,
    pub text: String,
    /// The key that makes the event's run id unique.
    pub key: String,
}

enum Msg {
    Line { id: String, generation: u64, line: String, at_ms: i64 },
    Closed { id: String, generation: u64 },
}

#[derive(Clone, Debug, PartialEq, Eq)]
struct Spec {
    command: String,
    folder: Option<String>,
    debounce_ms: i64,
}

struct Watcher {
    spec: Spec,
    generation: u64,
    child: Option<Child>,
    started_ms: i64,
    /// When a stopped command starts again.
    restart_at_ms: Option<i64>,
    backoff_ms: i64,
    /// Why the last start failed, for `status`.
    last_error: Option<String>,
}

struct Pending {
    text: String,
    lines: u64,
    cut: u64,
    first_ms: i64,
    last_ms: i64,
}

/// The status of one watch, for the runner's report.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WatchStatus {
    pub automation: String,
    pub running: bool,
    pub pid: Option<u32>,
    pub last_error: Option<String>,
}

/// Every watch command of one runner.
pub struct Watches {
    store: Store,
    tx: Sender<Msg>,
    rx: Receiver<Msg>,
    watchers: HashMap<String, Watcher>,
    pending: HashMap<String, Pending>,
    next_generation: u64,
    events: u64,
}

impl Watches {
    pub fn new(store: Store) -> Watches {
        let (tx, rx) = mpsc::channel();
        #[cfg(unix)]
        signals::install();
        Watches {
            store,
            tx,
            rx,
            watchers: HashMap::new(),
            pending: HashMap::new(),
            next_generation: 1,
            events: 0,
        }
    }

    /// Start, stop and restart watch commands to match `automations`.
    pub fn reconcile(&mut self, automations: &[Automation], now_ms: i64) {
        let wanted: HashMap<&str, Spec> = automations
            .iter()
            .filter(|a| a.enabled && !a.fenced())
            .filter_map(|a| match &a.trigger {
                Trigger::Watch { command, debounce_seconds } => Some((
                    a.id.as_str(),
                    Spec {
                        command: command.clone(),
                        folder: a.body.folder().map(str::to_string),
                        debounce_ms: (*debounce_seconds as i64).saturating_mul(1000),
                    },
                )),
                _ => None,
            })
            .collect();
        let gone: Vec<String> = self
            .watchers
            .iter()
            .filter(|(id, w)| wanted.get(id.as_str()) != Some(&w.spec))
            .map(|(id, _)| id.clone())
            .collect();
        for id in gone {
            if let Some(mut w) = self.watchers.remove(&id) {
                stop(&mut w);
            }
            self.pending.remove(&id);
        }
        for (id, spec) in wanted {
            if !self.watchers.contains_key(id) {
                let w = Watcher {
                    spec,
                    generation: 0,
                    child: None,
                    started_ms: now_ms,
                    restart_at_ms: Some(now_ms),
                    backoff_ms: FIRST_BACKOFF_MS,
                    last_error: None,
                };
                self.watchers.insert(id.to_string(), w);
            }
        }
        self.restart_due(now_ms);
    }

    /// Start every stopped command whose restart time came.
    pub fn restart_due(&mut self, now_ms: i64) {
        let due: Vec<String> = self
            .watchers
            .iter()
            .filter(|(_, w)| w.child.is_none() && w.restart_at_ms.is_some_and(|t| t <= now_ms))
            .map(|(id, _)| id.clone())
            .collect();
        for id in due {
            let generation = self.next_generation;
            self.next_generation = self.next_generation.saturating_add(1);
            let log = self.store.watch_log_path(&id);
            let tx = self.tx.clone();
            let Some(w) = self.watchers.get_mut(&id) else { continue };
            w.generation = generation;
            w.restart_at_ms = None;
            w.started_ms = now_ms;
            match spawn(&id, &w.spec, generation, &log, tx) {
                Ok(child) => {
                    w.last_error = None;
                    w.child = Some(child);
                }
                Err(why) => {
                    w.last_error = Some(why);
                    w.restart_at_ms = Some(now_ms.saturating_add(w.backoff_ms));
                    w.backoff_ms = w.backoff_ms.saturating_mul(2).min(MAX_BACKOFF_MS);
                }
            }
        }
    }

    /// Wait at most `timeout` for lines, then take every line already sent.
    /// `now_ms` reads the clock after the wait (tests pass a fixed one).
    pub fn wait(&mut self, timeout: Duration, now_ms: &dyn Fn() -> i64) {
        let first = match self.rx.recv_timeout(timeout) {
            Ok(msg) => msg,
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => return,
        };
        self.take(first, now_ms());
        while let Ok(msg) = self.rx.try_recv() {
            self.take(msg, now_ms());
        }
    }

    fn take(&mut self, msg: Msg, now_ms: i64) {
        match msg {
            Msg::Line { id, generation, line, at_ms } => {
                if self.watchers.get(&id).is_none_or(|w| w.generation != generation) {
                    return;
                }
                self.add_line(&id, &line, at_ms);
            }
            Msg::Closed { id, generation } => {
                let Some(w) = self.watchers.get_mut(&id) else { return };
                if w.generation != generation {
                    return;
                }
                if let Some(mut child) = w.child.take() {
                    let _ = child.wait();
                }
                if now_ms.saturating_sub(w.started_ms) >= HEALTHY_MS {
                    w.backoff_ms = FIRST_BACKOFF_MS;
                }
                w.restart_at_ms = Some(now_ms.saturating_add(w.backoff_ms));
                w.backoff_ms = w.backoff_ms.saturating_mul(2).min(MAX_BACKOFF_MS);
            }
        }
    }

    /// Add one line to the automation's pending event (a test seam too).
    pub fn add_line(&mut self, id: &str, line: &str, at_ms: i64) {
        let p = self.pending.entry(id.to_string()).or_insert(Pending {
            text: String::new(),
            lines: 0,
            cut: 0,
            first_ms: at_ms,
            last_ms: at_ms,
        });
        p.lines = p.lines.saturating_add(1);
        p.last_ms = at_ms;
        if p.text.len().saturating_add(line.len()).saturating_add(1) > MAX_EVENT_BYTES {
            p.cut = p.cut.saturating_add(1);
        } else {
            p.text.push_str(line);
            p.text.push('\n');
        }
    }

    fn debounce_ms(&self, id: &str) -> i64 {
        self.watchers.get(id).map(|w| w.spec.debounce_ms).unwrap_or(0)
    }

    fn due_at(&self, id: &str, p: &Pending) -> i64 {
        let debounce = self.debounce_ms(id);
        p.last_ms.saturating_add(debounce).min(p.first_ms.saturating_add(MAX_HOLD_MS.max(debounce)))
    }

    /// The events whose debounce ended by `now_ms`, oldest first.
    pub fn due_events(&mut self, now_ms: i64) -> Vec<WatchEvent> {
        let due: Vec<String> = self
            .pending
            .iter()
            .filter(|(id, p)| self.due_at(id, p) <= now_ms)
            .map(|(id, _)| id.clone())
            .collect();
        let mut out = Vec::new();
        for id in due {
            let Some(p) = self.pending.remove(&id) else { continue };
            self.events = self.events.saturating_add(1);
            let mut text = p.text;
            if p.cut > 0 {
                text.push_str(&format!("[{} more line(s) not kept]\n", p.cut));
            }
            out.push((
                p.first_ms,
                WatchEvent {
                    automation: id,
                    text,
                    key: format!("{}-{}-{}", p.first_ms, std::process::id(), self.events),
                },
            ));
        }
        out.sort_by_key(|(first, _)| *first);
        out.into_iter().map(|(_, e)| e).collect()
    }

    /// The next time something is due: a pending event or a restart.
    pub fn next_deadline_ms(&self) -> Option<i64> {
        let events = self.pending.iter().map(|(id, p)| self.due_at(id, p));
        let restarts = self.watchers.values().filter_map(|w| w.restart_at_ms);
        events.chain(restarts).min()
    }

    /// One row per watch command.
    pub fn status(&self) -> Vec<WatchStatus> {
        let mut rows: Vec<WatchStatus> = self
            .watchers
            .iter()
            .map(|(id, w)| WatchStatus {
                automation: id.clone(),
                running: w.child.is_some(),
                pid: w.child.as_ref().map(Child::id),
                last_error: w.last_error.clone(),
            })
            .collect();
        rows.sort_by(|a, b| a.automation.cmp(&b.automation));
        rows
    }
}

impl Drop for Watches {
    fn drop(&mut self) {
        for w in self.watchers.values_mut() {
            stop(w);
        }
    }
}

/// Stop a watch command's whole process group (a pipeline is several processes).
fn stop(w: &mut Watcher) {
    if let Some(mut child) = w.child.take() {
        #[cfg(unix)]
        {
            let pgid = child.id() as libc::pid_t;
            signals::forget(pgid);
            // SAFETY: signals the process group this runner started for this command.
            unsafe { libc::kill(-pgid, libc::SIGTERM) };
        }
        #[cfg(not(unix))]
        {
            let _ = child.kill();
        }
        let _ = child.wait();
    }
}

#[cfg(unix)]
fn spawn(
    id: &str,
    spec: &Spec,
    generation: u64,
    log: &std::path::Path,
    tx: Sender<Msg>,
) -> Result<Child, String> {
    use std::os::unix::process::CommandExt;
    if let Some(dir) = log.parent() {
        crate::sys::create_private_dir(dir).map_err(|e| e.to_string())?;
    }
    let stderr = private_file(OpenOptions::new().create(true).append(true))
        .open(log)
        .map_err(|e| e.to_string())?;
    let mut c = Command::new("/bin/sh");
    c.arg("-c")
        .arg(&spec.command)
        .env("CMUX_AUTOMATION_ID", id)
        .env("CMUX_AUTOMATION_TRIGGER", "watch")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(stderr)
        .process_group(0);
    if let Some(folder) = &spec.folder {
        c.current_dir(crate::exec::expand_home(folder));
    }
    let mut child = c.spawn().map_err(|e| e.to_string())?;
    if !signals::remember(child.id() as libc::pid_t) {
        // SAFETY: the process group this function just started.
        unsafe { libc::kill(-(child.id() as libc::pid_t), libc::SIGTERM) };
        let _ = child.wait();
        return Err(format!("more than {} watch commands on one runner", signals::SLOTS));
    }
    let Some(stdout) = child.stdout.take() else {
        return Err("the watch command has no stdout".into());
    };
    let id = id.to_string();
    std::thread::spawn(move || read_lines(id, generation, stdout, tx));
    Ok(child)
}

/// Refused on Windows (see `sys`): a watch's process tree could not be stopped.
#[cfg(windows)]
fn spawn(
    _id: &str,
    _spec: &Spec,
    _generation: u64,
    _log: &std::path::Path,
    _tx: Sender<Msg>,
) -> Result<Child, String> {
    Err(crate::sys::UNSUPPORTED_ON_WINDOWS.into())
}

/// Send every line of `out` until it closes, then `Closed`. A line longer
/// than [`MAX_LINE_BYTES`] is cut; invalid UTF-8 is replaced.
fn read_lines(id: String, generation: u64, mut out: impl Read, tx: Sender<Msg>) {
    let mut line: Vec<u8> = Vec::new();
    let mut buf = [0u8; 8192];
    let now_ms = || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0)
    };
    loop {
        let n = match out.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        for &b in buf.iter().take(n) {
            if b == b'\n' {
                let text = String::from_utf8_lossy(&line).trim_end_matches('\r').to_string();
                line.clear();
                let msg = Msg::Line { id: id.clone(), generation, line: text, at_ms: now_ms() };
                if tx.send(msg).is_err() {
                    return;
                }
            } else if line.len() < MAX_LINE_BYTES {
                line.push(b);
            }
        }
    }
    if !line.is_empty() {
        let text = String::from_utf8_lossy(&line).into_owned();
        let _ = tx.send(Msg::Line { id: id.clone(), generation, line: text, at_ms: now_ms() });
    }
    let _ = tx.send(Msg::Closed { id, generation });
}

/// The runner's SIGTERM, SIGINT and SIGHUP stop its watch commands' process
/// groups before the runner exits, so a `tail -F` never outlives it. The
/// groups are kept in a fixed table of atomics: a signal handler may only
/// read memory and call async-signal-safe functions (`kill`, `signal`, `raise`).
#[cfg(unix)]
mod signals {
    use std::sync::Once;
    use std::sync::atomic::{AtomicI32, Ordering};

    pub(super) const SLOTS: usize = 64;
    static GROUPS: [AtomicI32; SLOTS] = [const { AtomicI32::new(0) }; SLOTS];
    static INSTALL: Once = Once::new();

    pub(super) fn remember(pgid: libc::pid_t) -> bool {
        GROUPS
            .iter()
            .any(|slot| slot.compare_exchange(0, pgid, Ordering::SeqCst, Ordering::SeqCst).is_ok())
    }

    pub(super) fn forget(pgid: libc::pid_t) {
        for slot in &GROUPS {
            let _ = slot.compare_exchange(pgid, 0, Ordering::SeqCst, Ordering::SeqCst);
        }
    }

    extern "C" fn on_signal(sig: libc::c_int) {
        for slot in &GROUPS {
            let pgid = slot.load(Ordering::SeqCst);
            if pgid > 0 {
                // SAFETY: kill is async-signal-safe; pgid is a group this runner started.
                unsafe { libc::kill(-pgid, libc::SIGTERM) };
            }
        }
        // SAFETY: signal and raise are async-signal-safe; the default action ends the process.
        unsafe {
            libc::signal(sig, libc::SIG_DFL);
            libc::raise(sig);
        }
    }

    pub(super) fn install() {
        INSTALL.call_once(|| {
            for sig in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP] {
                // SAFETY: installs a handler that only uses async-signal-safe calls.
                unsafe { libc::signal(sig, on_signal as *const () as libc::sighandler_t) };
            }
        });
    }
}
