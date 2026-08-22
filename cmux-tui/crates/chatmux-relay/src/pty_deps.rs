//! Production `PtyDeps`: real PTY allocation (cmux-pty), cmux-tui binary
//! resolution, headless daemon management, and the unix control socket.
//! Behavior port of the default* helpers in `packages/relay/bin/pty.mjs`.
//!
//! PTY reads and the child wait are blocking, so each runs on a dedicated
//! blocking thread that forwards into the attachment's event channel; writes
//! and resizes go through the (blocking) master behind a mutex.

#![cfg(unix)]

use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use async_trait::async_trait;
use bytes::Bytes;
use cmux_pty::{MasterPty, PtySize};

use crate::control::{CONTROL_TIMEOUT_MS, ControlHandle, connect_control};
use crate::pty::{
    CmuxTui, DataSink, EnsureDaemon, ExitSink, PtyControl, PtyDeps, PtyHandle, PtyOutput,
    SpawnSpec, session_name_ok,
};

const DAEMON_SOCKET_WAIT_MS: u64 = 5_000;

/// Buffers output until the manager subscribes, then calls the sink directly
/// from the reader/wait threads. One sink; the manager fans out itself.
#[derive(Default)]
struct SourceState {
    on_data: Option<DataSink>,
    on_exit: Option<ExitSink>,
    backlog: Vec<Bytes>,
    pending_exit: Option<i64>,
    exited: bool,
}

struct ThreadOutput {
    state: Mutex<SourceState>,
}

impl ThreadOutput {
    fn new() -> Arc<ThreadOutput> {
        Arc::new(ThreadOutput { state: Mutex::new(SourceState::default()) })
    }

    fn push_data(&self, chunk: Bytes) {
        let sink = {
            let mut state = self.state.lock().expect("source lock");
            match state.on_data.clone() {
                Some(sink) => Some(sink),
                None => {
                    state.backlog.push(chunk.clone());
                    None
                }
            }
        };
        if let Some(sink) = sink {
            sink(chunk);
        }
    }

    fn push_exit(&self, code: i64) {
        let sink = {
            let mut state = self.state.lock().expect("source lock");
            if state.exited {
                return;
            }
            state.exited = true;
            match state.on_exit.clone() {
                Some(sink) => Some(sink),
                None => {
                    state.pending_exit = Some(code);
                    None
                }
            }
        };
        if let Some(sink) = sink {
            sink(code);
        }
    }
}

impl PtyOutput for ThreadOutput {
    fn subscribe(&self, on_data: DataSink, on_exit: ExitSink) {
        let (backlog, pending_exit) = {
            let mut state = self.state.lock().expect("source lock");
            state.on_data = Some(Arc::clone(&on_data));
            state.on_exit = Some(Arc::clone(&on_exit));
            (std::mem::take(&mut state.backlog), state.pending_exit.take())
        };
        for chunk in backlog {
            on_data(chunk);
        }
        if let Some(code) = pending_exit {
            on_exit(code);
        }
    }
}

pub struct RealPtyDeps {
    env: HashMap<String, String>,
    uid: u32,
    shell: String,
}

impl RealPtyDeps {
    pub fn new(env: HashMap<String, String>) -> RealPtyDeps {
        // SAFETY: getuid is always safe.
        let uid = unsafe { libc::getuid() };
        let shell = env.get("SHELL").cloned().unwrap_or_else(|| "/bin/sh".to_owned());
        RealPtyDeps { env, uid, shell }
    }
}

/// A real PTY master behind a mutex; write/resize block briefly.
struct MasterControl {
    master: Mutex<Box<dyn MasterPty + Send>>,
    writer: Mutex<Box<dyn Write + Send>>,
    killer: Mutex<Box<dyn cmux_pty::ChildKiller + Send + Sync>>,
}

impl PtyControl for MasterControl {
    fn write(&self, data: &[u8]) {
        if let Ok(mut writer) = self.writer.lock() {
            let _ = writer.write_all(data);
            let _ = writer.flush();
        }
    }
    fn resize(&self, cols: u16, rows: u16) {
        if let Ok(master) = self.master.lock() {
            let _ = master.resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
        }
    }
    fn pause(&self) {}
    fn resume(&self) {}
    fn kill(&self) {
        if let Ok(mut killer) = self.killer.lock() {
            let _ = killer.kill();
        }
    }
}

/// A degraded pipe-mode shell (no TTY) used when PTY allocation fails. The
/// child is owned by its wait thread; kill signals it by pid.
struct PipeControl {
    stdin: Mutex<Option<std::process::ChildStdin>>,
    pid: i32,
}

impl PtyControl for PipeControl {
    fn write(&self, data: &[u8]) {
        if let Ok(mut guard) = self.stdin.lock()
            && let Some(stdin) = guard.as_mut()
        {
            let _ = stdin.write_all(data);
            let _ = stdin.flush();
        }
    }
    fn resize(&self, _cols: u16, _rows: u16) {}
    fn pause(&self) {}
    fn resume(&self) {}
    fn kill(&self) {
        // SAFETY: signalling a child pid this handle spawned; harmless if gone.
        unsafe {
            libc::kill(self.pid, libc::SIGKILL);
        }
    }
}

fn spawn_real_pty(spec: &SpawnSpec) -> anyhow::Result<PtyHandle> {
    let pair = cmux_pty::open(PtySize {
        rows: spec.rows,
        cols: spec.cols,
        pixel_width: 0,
        pixel_height: 0,
    })?;
    let mut command = cmux_pty::PtyCommand::new(spec.file.clone());
    command.args(spec.args.clone());
    command.cwd(&spec.cwd);
    command.env_clear();
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    let spawned = pair.spawn(command)?;
    let reader = spawned.master.try_clone_reader()?;
    let writer = spawned.master.take_writer()?;
    let killer = spawned.child.clone_killer();
    let output = ThreadOutput::new();

    // Blocking reader thread -> output sink.
    let data_output = Arc::clone(&output);
    std::thread::spawn(move || {
        let mut reader = reader;
        let mut buffer = [0_u8; 32_768];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) | Err(_) => break,
                Ok(count) => data_output.push_data(Bytes::copy_from_slice(&buffer[..count])),
            }
        }
    });
    // Blocking wait thread -> exit.
    let mut child = spawned.child;
    let exit_output = Arc::clone(&output);
    std::thread::spawn(move || {
        let code = child.wait().map(|status| i64::from(status.exit_code() as i32)).unwrap_or(0);
        exit_output.push_exit(code);
    });

    Ok(PtyHandle {
        control: Arc::new(MasterControl {
            master: Mutex::new(spawned.master),
            writer: Mutex::new(writer),
            killer: Mutex::new(killer),
        }),
        output,
        banner: None,
    })
}

fn spawn_pipe_mode(spec: &SpawnSpec, reason: &str) -> PtyHandle {
    let shell = spec.env.get("SHELL").cloned().unwrap_or_else(|| "/bin/sh".to_owned());
    let output = ThreadOutput::new();
    let mut command = std::process::Command::new(&shell);
    command.arg("-i").current_dir(&spec.cwd).env_clear();
    for (key, value) in &spec.env {
        command.env(key, value);
    }
    command.env("TERM", "dumb");
    command.stdin(std::process::Stdio::piped());
    command.stdout(std::process::Stdio::piped());
    command.stderr(std::process::Stdio::piped());
    let banner = format!(
        "[cmux-relay] PTY allocation failed ({reason}); running {} without a TTY.\r\n",
        Path::new(&shell)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| shell.clone()),
    );
    match command.spawn() {
        Ok(mut child) => {
            let stdin = child.stdin.take();
            let pid = child.id() as i32;
            if let Some(stdout) = child.stdout.take() {
                let out = Arc::clone(&output);
                std::thread::spawn(move || pump_pipe(stdout, out));
            }
            if let Some(stderr) = child.stderr.take() {
                let out = Arc::clone(&output);
                std::thread::spawn(move || pump_pipe(stderr, out));
            }
            // The wait would need its own thread; the shell exits when its
            // pipes close, and the manager treats a data EOF plus process
            // teardown as the end. Report exit when both pipes close.
            let wait_output = Arc::clone(&output);
            std::thread::spawn(move || {
                let code =
                    child.wait().map(|status| status.code().unwrap_or(0) as i64).unwrap_or(0);
                wait_output.push_exit(code);
            });
            PtyHandle {
                control: Arc::new(PipeControl { stdin: Mutex::new(stdin), pid }),
                output,
                banner: Some(banner.into_bytes()),
            }
        }
        Err(error) => {
            let _ = error;
            output.push_exit(1);
            PtyHandle { control: Arc::new(DeadControl), output, banner: Some(banner.into_bytes()) }
        }
    }
}

struct DeadControl;
impl PtyControl for DeadControl {
    fn write(&self, _data: &[u8]) {}
    fn resize(&self, _cols: u16, _rows: u16) {}
    fn pause(&self) {}
    fn resume(&self) {}
    fn kill(&self) {}
}

fn pump_pipe(mut stream: impl Read, output: Arc<ThreadOutput>) {
    let mut buffer = [0_u8; 32_768];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => output.push_data(Bytes::copy_from_slice(&buffer[..count])),
        }
    }
}

async fn socket_exists(path: &Path) -> bool {
    tokio::fs::metadata(path).await.is_ok()
}

#[async_trait]
impl PtyDeps for RealPtyDeps {
    async fn spawn_pty(&self, spec: SpawnSpec) -> PtyHandle {
        // PTY allocation and thread setup are blocking; run off the reactor.
        // On PTY allocation failure (ptmx exhaustion et al) degrade to a
        // pipe-mode shell so the terminal still functions, with a banner.
        tokio::task::spawn_blocking(move || match spawn_real_pty(&spec) {
            Ok(handle) => handle,
            Err(error) => spawn_pipe_mode(&spec, &error.to_string()),
        })
        .await
        .unwrap_or_else(|_| PtyHandle {
            control: Arc::new(DeadControl),
            output: ThreadOutput::new(),
            banner: None,
        })
    }

    async fn resolve_cmux_tui(&self) -> Option<CmuxTui> {
        if let Some(override_path) =
            self.env.get("CHATMUX_RELAY_CMUX_TUI").filter(|value| !value.trim().is_empty())
        {
            let path = override_path.trim();
            return if is_executable(Path::new(path)).await {
                Some(CmuxTui { file: path.to_owned(), prefix: Vec::new() })
            } else {
                None
            };
        }
        // Never a bare `cmux` on PATH — that name is ambiguous; only cmux-tui.
        for dir in self.env.get("PATH").map(String::as_str).unwrap_or("").split(':') {
            if dir.is_empty() {
                continue;
            }
            let candidate = Path::new(dir).join("cmux-tui");
            if is_executable(&candidate).await {
                return Some(CmuxTui {
                    file: candidate.to_string_lossy().into_owned(),
                    prefix: Vec::new(),
                });
            }
        }
        None
    }

    async fn ensure_daemon(
        &self,
        cmux_tui: &CmuxTui,
        session: &str,
        socket_dir: &Path,
        cwd: &Path,
        env: &HashMap<String, String>,
    ) -> Result<EnsureDaemon, String> {
        let socket_path = socket_dir.join(format!("{session}.sock"));
        if socket_exists(&socket_path).await {
            return Ok(EnsureDaemon { created: false, socket_path });
        }
        let mut args = cmux_tui.prefix.clone();
        args.extend(["--headless".to_owned(), "--session".to_owned(), session.to_owned()]);
        let mut command = tokio::process::Command::new(&cmux_tui.file);
        command.args(&args).current_dir(cwd).env_clear();
        for (key, value) in env {
            command.env(key, value);
        }
        command.stdin(std::process::Stdio::null());
        command.stdout(std::process::Stdio::null());
        command.stderr(std::process::Stdio::null());
        command.process_group(0);
        command.spawn().map_err(|error| format!("cmux-tui daemon spawn failed: {error}"))?;

        let deadline = Instant::now() + Duration::from_millis(DAEMON_SOCKET_WAIT_MS);
        while Instant::now() < deadline {
            if socket_exists(&socket_path).await {
                // Probe a control round-trip before declaring readiness.
                while Instant::now() < deadline {
                    let mut probe = tokio::process::Command::new(&cmux_tui.file);
                    let mut probe_args = cmux_tui.prefix.clone();
                    probe_args.extend([
                        "--session".to_owned(),
                        session.to_owned(),
                        "client".to_owned(),
                        "list".to_owned(),
                        "--json".to_owned(),
                    ]);
                    probe.args(&probe_args).env_clear();
                    for (key, value) in env {
                        probe.env(key, value);
                    }
                    probe.stdin(std::process::Stdio::null());
                    probe.stdout(std::process::Stdio::null());
                    probe.stderr(std::process::Stdio::null());
                    match probe.status().await {
                        Ok(status) if status.success() => {
                            return Ok(EnsureDaemon { created: true, socket_path });
                        }
                        _ => tokio::time::sleep(Duration::from_millis(50)).await,
                    }
                }
                // Soft gate: socket exists but the probe verb never answered
                // (an older cmux-tui). Attach anyway.
                return Ok(EnsureDaemon { created: true, socket_path });
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        Err(format!("cmux-tui daemon for \"{session}\" never created {}", socket_path.display()))
    }

    async fn connect_control(&self, socket_path: &Path) -> Result<Arc<dyn ControlHandle>, String> {
        connect_control(socket_path, CONTROL_TIMEOUT_MS).await
    }

    async fn read_dir(&self, path: &Path) -> Result<Vec<String>, ()> {
        let mut entries = tokio::fs::read_dir(path).await.map_err(|_| ())?;
        let mut names = Vec::new();
        while let Ok(Some(entry)) = entries.next_entry().await {
            names.push(entry.file_name().to_string_lossy().into_owned());
        }
        Ok(names)
    }

    fn socket_dir(&self) -> PathBuf {
        let runtime = self
            .env
            .get("XDG_RUNTIME_DIR")
            .or_else(|| self.env.get("TMPDIR"))
            .map(String::as_str)
            .filter(|value| !value.is_empty())
            .unwrap_or("/tmp");
        Path::new(runtime).join(format!("cmux-tui-{}", self.uid))
    }

    fn shell(&self) -> String {
        self.shell.clone()
    }
}

async fn is_executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt as _;
    match tokio::fs::metadata(path).await {
        Ok(meta) => meta.is_file() && meta.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    }
}

/// Session-name validity is re-exported so the daemon path can reject early.
pub fn valid_session(name: &str) -> bool {
    session_name_ok(name)
}
