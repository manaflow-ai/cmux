//! The Computer Use worker as the host's child: started while Computer Use is
//! on, configured over its stdin, restarted after a crash with backoff (200 ms
//! doubling to 30 s, reset after 30 s healthy), stopped by closing its stdin.

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use tokio::io::{AsyncWriteExt, BufReader};
use tokio::sync::{Notify, mpsc, watch};

use super::{HostCore, Layout};
use crate::wire;

const HEALTHY_RUN: Duration = Duration::from_secs(30);
const FIRST_DELAY: Duration = Duration::from_millis(200);
const MAX_DELAY: Duration = Duration::from_secs(30);

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(Default)]
struct State {
    generation: u64,
    pid: Option<u32>,
    to_worker: Option<mpsc::UnboundedSender<Value>>,
    restarts: u64,
    ready: Option<Value>,
    last_exit: Option<String>,
    supervising: bool,
}

pub struct WorkerLink {
    core: Weak<HostCore>,
    exe: Option<PathBuf>,
    layout: Layout,
    state_dir: PathBuf,
    state: Mutex<State>,
    wanted: watch::Sender<bool>,
    restart_now: Notify,
}

impl WorkerLink {
    pub(super) fn new(core: Weak<HostCore>, exe: Option<PathBuf>, layout: Layout, state_dir: PathBuf) -> Self {
        Self {
            core,
            exe,
            layout,
            state_dir,
            state: Mutex::new(State::default()),
            wanted: watch::Sender::new(false),
            restart_now: Notify::new(),
        }
    }

    pub fn status(&self) -> Value {
        let state = lock(&self.state);
        let wanted = *self.wanted.borrow();
        let mut status = json!({
            "state": match (state.pid, wanted, self.exe.is_some()) {
                (Some(_), _, _) if state.ready.is_some() => "running",
                (Some(_), _, _) => "starting",
                (None, true, false) => "unavailable",
                (None, true, true) => "starting",
                (None, false, _) => "off",
            },
            "restarts": state.restarts,
        });
        if let Some(pid) = state.pid {
            status["pid"] = json!(pid);
        }
        if let Some(ready) = &state.ready {
            status["mode"] = ready.get("mode").cloned().unwrap_or(Value::Null);
            status["driver"] = ready.get("driver").cloned().unwrap_or(Value::Null);
        }
        if let Some(exit) = &state.last_exit {
            status["last_exit"] = json!(exit);
        }
        status
    }

    /// Starts or stops the worker to match.
    pub fn set_wanted(self: &WorkerLink, wanted: bool) {
        let start = {
            let mut state = lock(&self.state);
            self.wanted.send_replace(wanted);
            wanted && !std::mem::replace(&mut state.supervising, true)
        };
        if start {
            let Some(core) = self.core.upgrade() else { return };
            tokio::spawn(async move { core.worker.supervise(&core).await });
        }
    }

    /// Ends the running worker; the next one starts at once.
    pub fn restart(&self) {
        // Only a running worker listens; no permit is left for the next one.
        self.restart_now.notify_waiters();
    }

    /// A control line to the running worker.
    pub fn send(&self, message: Value) {
        if let Some(sender) = &lock(&self.state).to_worker {
            let _ = sender.send(message);
        }
    }

    /// A control line to the worker of `generation` only (an answer to its question).
    pub fn send_to_generation(&self, generation: u64, message: Value) {
        let state = lock(&self.state);
        if state.generation == generation
            && let Some(sender) = &state.to_worker
        {
            let _ = sender.send(message);
        }
    }

    /// Tests: a running worker of `generation` whose control lines arrive here.
    #[cfg(test)]
    pub(super) fn attach_for_test(&self, generation: u64) -> mpsc::UnboundedReceiver<Value> {
        let (sender, receiver) = mpsc::unbounded_channel();
        let mut state = lock(&self.state);
        state.generation = generation;
        state.to_worker = Some(sender);
        receiver
    }

    async fn supervise(&self, core: &Arc<HostCore>) {
        let mut wanted = self.wanted.subscribe();
        let mut delay = FIRST_DELAY;
        while *wanted.borrow_and_update() {
            let started = Instant::now();
            let restart_requested = self.run_once(core, &mut wanted).await;
            core.status_changed();
            if !*wanted.borrow() {
                break;
            }
            if restart_requested {
                delay = FIRST_DELAY;
                continue;
            }
            if started.elapsed() >= HEALTHY_RUN {
                delay = FIRST_DELAY;
            }
            lock(&self.state).restarts += 1;
            // A bounded restart delay after a crash, not a synchronization; a switch-off ends it.
            tokio::select! {
                _ = tokio::time::sleep(delay) => {}
                _ = wanted.changed() => {}
            }
            delay = (delay * 2).min(MAX_DELAY);
        }
        // Cleared under the lock that set_wanted takes: a want that arrived after the loop's
        // last check either sees supervising=false (and starts one) or is seen here.
        let again = {
            let mut state = lock(&self.state);
            state.supervising = false;
            *self.wanted.borrow()
        };
        if again {
            self.set_wanted(true);
        }
    }

    /// Runs one worker until it exits; true when a restart was asked for.
    async fn run_once(&self, core: &Arc<HostCore>, wanted: &mut watch::Receiver<bool>) -> bool {
        let Some(exe) = self.exe.clone() else {
            // No executable (tests): wait for the switch to change.
            let _ = wanted.changed().await;
            return false;
        };
        let mut command = tokio::process::Command::new(&exe);
        command
            .args(["worker", "computer-use", "--layout-dir"])
            .arg(&self.layout.dir)
            .arg("--state-dir")
            .arg(&self.state_dir)
            .env_clear()
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .kill_on_drop(true);
        for name in crate::platform::DESKTOP_ENV {
            if let Some(value) = std::env::var_os(name) {
                command.env(name, value);
            }
        }
        for (name, value) in crate::worker::DRIVER_ENV {
            command.env(name, value);
        }
        // The config in force (the host's one reading; `computer_use.reload` changes it).
        let config = core.config();
        if let Ok(config) = &*config {
            for (name, value) in config.driver_environment() {
                command.env(name, value);
            }
        }
        if cfg!(unix) {
            command.env("XDG_CONFIG_HOME", crate::platform::xdg_config_home(&self.state_dir));
            let _ = crate::platform::make_private_dir(&crate::platform::xdg_config_home(&self.state_dir));
        }
        match std::fs::OpenOptions::new().create(true).append(true).open(self.layout.log()) {
            Ok(log) => {
                command.stderr(Stdio::from(log));
            }
            Err(_) => {
                command.stderr(Stdio::null());
            }
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => {
                lock(&self.state).last_exit = Some(format!("did not start: {error}"));
                return false;
            }
        };
        let pid = child.id().unwrap_or(0);
        let (Some(mut stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else { return false };
        let (sender, mut outgoing) = mpsc::unbounded_channel::<Value>();
        let generation = {
            let mut state = lock(&self.state);
            state.generation += 1;
            state.pid = Some(pid);
            state.ready = None;
            state.to_worker = Some(sender.clone());
            state.generation
        };
        let writing = tokio::spawn(async move {
            while let Some(line) = outgoing.recv().await {
                if stdin.write_all(&wire::encode(&line)).await.is_err() || stdin.flush().await.is_err() {
                    break;
                }
            }
            // Dropping stdin here is the worker's EOF: it stops.
        });
        let secret = wire::make_secret().map(|bytes| bytes.to_vec()).unwrap_or_default();
        let socket = self.layout.worker_socket();
        let _ = sender.send(json!({
            "type": "configure",
            "socket": socket.display().to_string(),
            "secret": wire::hex(&secret),
            "acpmux_hashes": core.acpmux_hashes(),
            "client": core.client(),
            "acpmux_socket": core.bootstrap.acpmux_socket.as_ref().map(|socket| socket.display().to_string()),
            "machine": crate::platform::machine_name(),
            "config": crate::config::snapshot_value(&config),
        }));
        drop(sender);
        core.status_changed();
        let mut reader = BufReader::new(stdout);
        let mut restart_requested = false;
        loop {
            tokio::select! {
                line = wire::read_object(&mut reader) => {
                    let Ok(Some(message)) = line else { break };
                    self.dispatch(core, generation, &secret, pid, Value::Object(message));
                }
                _ = wanted.changed() => {
                    if !*wanted.borrow() {
                        lock(&self.state).to_worker = None; // closes stdin
                    }
                }
                _ = self.restart_now.notified() => {
                    restart_requested = true;
                    lock(&self.state).to_worker = None;
                }
            }
        }
        let status = child.wait().await.map(|status| status.to_string()).unwrap_or_else(|error| error.to_string());
        writing.abort();
        core.withdraw_endpoint();
        core.worker_gone(generation);
        let mut state = lock(&self.state);
        state.pid = None;
        state.ready = None;
        state.to_worker = None;
        state.last_exit = Some(status);
        restart_requested
    }

    pub(super) fn dispatch(&self, core: &Arc<HostCore>, generation: u64, secret: &[u8], pid: u32, message: Value) {
        match message.get("type").and_then(Value::as_str).unwrap_or_default() {
            "ready" => {
                let socket = message.get("socket").and_then(Value::as_str).unwrap_or_default().to_owned();
                lock(&self.state).ready = Some(message.clone());
                core.publish_endpoint(&socket, secret, pid);
                {
                    // Read and sent under the saved list's lock: a revoke or an Always
                    // that changes the file after this read reaches the worker after it.
                    let _saved = lock(&core.saved_lock);
                    let apps: Vec<Value> = core.saved_apps().iter().map(crate::approval::Target::app_entry).collect();
                    self.send_to_generation(generation, json!({"type": "approved_apps", "apps": apps}));
                }
                for daemon in core.acpmux_daemons() {
                    self.send_to_generation(
                        generation,
                        json!({"type": "register_acpmux", "pid": daemon.pid, "start": daemon.start}),
                    );
                }
                core.status_changed();
            }
            "app_approval" => core.worker_asked(generation, &message),
            "app_approval_cancel" => core.worker_cancelled(&message),
            "error" => eprintln!("cmux-remote-host: worker: {}", message.get("error").and_then(Value::as_str).unwrap_or("?")),
            _ => {}
        }
    }
}
