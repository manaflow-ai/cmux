use std::env;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use cmux_pty::{PtyCommand, PtySize};
use rusqlite::Connection;
use serde_json::Value;
use wait_timeout::ChildExt;

use super::{Evidence, RunResult, Scenario, TargetKind, duration_ns};

const EVENT_TIMEOUT: Duration = Duration::from_secs(30);
const PROCESS_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_CAPTURE_BYTES: usize = 2 * 1024 * 1024;
const INCOMPATIBLE_SCHEMA: i64 = 2_147_483_647;

#[derive(Debug, Clone)]
pub struct Target {
    pub kind: TargetKind,
    pub binary: PathBuf,
    pub source: PathBuf,
    pub sha: String,
    pub observed_sha: String,
    pub ghostty_sha: String,
    pub launcher: Vec<String>,
}

impl Target {
    pub fn new(
        kind: TargetKind,
        binary: PathBuf,
        source: PathBuf,
        sha: String,
        launcher: Vec<String>,
    ) -> Result<Self> {
        let observed_sha = git_sha(&source)?;
        if observed_sha != sha {
            bail!(
                "{} source SHA mismatch: requested {sha}, observed {observed_sha}",
                kind.as_str()
            );
        }
        let ghostty_sha = git_sha(&source.join("ghostty"))?;
        Ok(Self { kind, binary, source, sha, observed_sha, ghostty_sha, launcher })
    }
}

pub enum Fixture {
    Cold(Common),
    Warm { common: Common, server: RunningHeadless },
    Headless(Common),
    Restored { common: Common, state: PathBuf, terminal_id: String },
    Incompatible { common: Common, state: PathBuf, database: PathBuf, expected: String },
}

impl Fixture {
    pub fn new(target: Target, scenario: Scenario, wrap_measured_process: bool) -> Result<Self> {
        let mut common = Common::new(target, scenario, wrap_measured_process)?;
        match scenario {
            Scenario::Cold => Ok(Self::Cold(common)),
            Scenario::Headless => Ok(Self::Headless(common)),
            Scenario::Warm => {
                let socket = common.path("warm.sock");
                let session = common.session_name("warm");
                let args = headless_args(&session, &socket, None);
                let mut server = RunningHeadless::start(&common, args, &socket, false)?;
                server.wait_ready()?;
                assert_ping(&common, &socket)?;
                common.setup_evidence.readiness_lines += 1;
                common.setup_evidence.socket_rpcs += 1;
                Ok(Self::Warm { common, server })
            }
            Scenario::Restored => {
                let state = common.path("restored-state");
                fs::create_dir_all(&state)?;
                let socket = common.path("restored-setup.sock");
                let session = common.session_name("restored");
                let args = headless_args(&session, &socket, Some(&state));
                let mut server = RunningHeadless::start(&common, args, &socket, false)?;
                server.wait_ready()?;
                assert_ping(&common, &socket)?;
                let created = json_cli(
                    &common,
                    &socket,
                    &["workspace", "create", "--name", "bench-restored"],
                )?;
                let terminal_id = find_key_string(&created, "terminal_id")
                    .context("workspace create did not return a terminal_id")?;
                let topology = json_cli(&common, &socket, &["workspace", "list"])?;
                if !json_contains_string(&topology, &terminal_id) {
                    bail!("restored fixture topology omitted terminal {terminal_id}");
                }
                server.shutdown_and_wait(&common)?;
                common.setup_evidence.readiness_lines += 1;
                common.setup_evidence.socket_rpcs += 4;
                common.setup_evidence.process_exits += 1;
                Ok(Self::Restored { common, state, terminal_id })
            }
            Scenario::Incompatible => {
                let state = common.path("incompatible-state");
                fs::create_dir_all(&state)?;
                let socket = common.path("incompatible-setup.sock");
                let session = common.session_name("incompatible");
                let args = headless_args(&session, &socket, Some(&state));
                let mut server = RunningHeadless::start(&common, args, &socket, false)?;
                server.wait_ready()?;
                assert_ping(&common, &socket)?;
                server.shutdown_and_wait(&common)?;
                let database = find_named_file(&state, "workspace-registry.sqlite3")?
                    .context("valid state did not create workspace-registry.sqlite3")?;
                let connection = Connection::open(&database)?;
                let valid_schema: String = connection.query_row(
                    "SELECT value FROM meta WHERE key = 'schema_version'",
                    [],
                    |row| row.get(0),
                )?;
                let valid_schema: i64 =
                    valid_schema.parse().context("valid fixture schema is not an integer")?;
                if valid_schema >= INCOMPATIBLE_SCHEMA {
                    bail!("valid schema {valid_schema} is not below the rejection fixture");
                }
                let changed = connection.execute(
                    "UPDATE meta SET value = ?1 WHERE key = 'schema_version'",
                    [INCOMPATIBLE_SCHEMA.to_string()],
                )?;
                if changed != 1 {
                    bail!("schema mutation updated {changed} rows");
                }
                drop(connection);
                let expected = format!(
                    "unsupported workspace registry schema {INCOMPATIBLE_SCHEMA}; newest supported is {valid_schema}"
                );
                common.setup_evidence.readiness_lines += 1;
                common.setup_evidence.socket_rpcs += 2;
                common.setup_evidence.process_exits += 1;
                Ok(Self::Incompatible { common, state, database, expected })
            }
        }
    }

    pub fn setup_evidence(&self) -> Evidence {
        self.common().setup_evidence.clone()
    }

    pub fn cleanup(&mut self) -> Result<Evidence> {
        let mut evidence = Evidence::default();
        match self {
            Self::Warm { common, server } => {
                server.shutdown_and_wait(common)?;
                evidence.socket_rpcs += 1;
                evidence.process_exits += 1;
            }
            Self::Restored { common, state, terminal_id } => {
                let socket = common.path("restored-cleanup.sock");
                let session = common.session_name("restored");
                let args = headless_args(&session, &socket, Some(state));
                let mut server = RunningHeadless::start(common, args, &socket, false)?;
                server.wait_ready()?;
                json_cli(common, &socket, &["terminal", terminal_id, "close"])?;
                server.shutdown_and_wait(common)?;
                evidence.readiness_lines += 1;
                evidence.socket_rpcs += 2;
                evidence.process_exits += 1;
            }
            _ => {}
        }
        Ok(evidence)
    }

    fn common(&self) -> &Common {
        match self {
            Self::Cold(common) | Self::Headless(common) => common,
            Self::Warm { common, .. }
            | Self::Restored { common, .. }
            | Self::Incompatible { common, .. } => common,
        }
    }
}

pub fn run_sample(fixture: &mut Fixture) -> Result<RunResult> {
    match fixture {
        Fixture::Cold(common) => run_cold(common),
        Fixture::Warm { common, server } => run_warm(common, server),
        Fixture::Headless(common) => run_headless(common),
        Fixture::Restored { common, state, terminal_id } => {
            run_restored(common, state, terminal_id)
        }
        Fixture::Incompatible { common, state, database, expected } => {
            run_incompatible(common, state, database, expected)
        }
    }
}

struct Common {
    target: Target,
    root: TemporaryRoot,
    config: PathBuf,
    next_id: u64,
    wrap_measured_process: bool,
    setup_evidence: Evidence,
}

impl Common {
    fn new(target: Target, scenario: Scenario, wrap_measured_process: bool) -> Result<Self> {
        let root = TemporaryRoot::new()?;
        let config = root.path.join("config.json");
        fs::write(&config, b"{}")?;
        for directory in ["home", "config", "data", "cache", "state", "tmp"] {
            fs::create_dir_all(root.path.join(directory))?;
        }
        Ok(Self {
            target,
            root,
            config,
            next_id: 1,
            wrap_measured_process,
            setup_evidence: Evidence::default(),
        })
    }

    fn path(&self, name: &str) -> PathBuf {
        self.root.path.join(name)
    }

    fn next_path(&mut self, stem: &str) -> Result<PathBuf> {
        let path = self.path(&format!("{stem}-{}", self.next_id));
        self.next_id += 1;
        fs::create_dir_all(&path)?;
        Ok(path)
    }

    fn session_name(&self, scenario: &str) -> String {
        format!("bench-{scenario}")
    }

    fn apply_std_env(&self, command: &mut Command) {
        command.env_clear();
        copy_base_environment(|key, value| {
            command.env(key, value);
        });
        for (key, value) in self.environment() {
            command.env(key, value);
        }
        command.current_dir(&self.root.path);
    }

    fn apply_pty_env(&self, command: &mut PtyCommand) {
        command.env_clear();
        copy_base_environment(|key, value| {
            command.env(key, value);
        });
        for (key, value) in self.environment() {
            command.env(key, value);
        }
        command.cwd(&self.root.path);
    }

    fn environment(&self) -> Vec<(String, String)> {
        let path = |name: &str| self.path(name).to_string_lossy().into_owned();
        vec![
            ("HOME".into(), path("home")),
            ("USERPROFILE".into(), path("home")),
            ("XDG_CONFIG_HOME".into(), path("config")),
            ("XDG_DATA_HOME".into(), path("data")),
            ("XDG_CACHE_HOME".into(), path("cache")),
            ("XDG_STATE_HOME".into(), path("state")),
            ("LOCALAPPDATA".into(), path("data")),
            ("APPDATA".into(), path("config")),
            ("TMPDIR".into(), path("tmp")),
            ("TEMP".into(), path("tmp")),
            ("TMP".into(), path("tmp")),
            ("CMUX_TUI_CONFIG".into(), self.config.to_string_lossy().into_owned()),
            ("TERM".into(), "xterm-256color".into()),
            ("COLORTERM".into(), "truecolor".into()),
            ("LANG".into(), "C.UTF-8".into()),
        ]
    }

    fn std_command(&self, args: &[String], wrapped: bool) -> Result<Command> {
        let mut command = if wrapped && !self.target.launcher.is_empty() {
            let mut command = Command::new(&self.target.launcher[0]);
            command.args(&self.target.launcher[1..]);
            command.arg(&self.target.binary);
            command
        } else {
            Command::new(&self.target.binary)
        };
        command.args(args);
        self.apply_std_env(&mut command);
        Ok(command)
    }

    fn pty_command(&self, args: &[String], wrapped: bool) -> Result<PtyCommand> {
        let (program, prefix) = if wrapped && !self.target.launcher.is_empty() {
            (self.target.launcher[0].clone(), self.target.launcher[1..].to_vec())
        } else {
            (self.target.binary.to_string_lossy().into_owned(), Vec::new())
        };
        let mut command = PtyCommand::new(program);
        if !prefix.is_empty() {
            command.args(prefix);
            command.args([self.target.binary.to_string_lossy().into_owned()]);
        }
        command.args(args.to_vec());
        self.apply_pty_env(&mut command);
        Ok(command)
    }
}

fn copy_base_environment(mut set: impl FnMut(String, String)) {
    for key in ["PATH", "SHELL", "SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "DEVELOPER_DIR"] {
        if let Ok(value) = env::var(key) {
            set(key.to_string(), value);
        }
    }
}

struct TemporaryRoot {
    _directory: tempfile::TempDir,
    path: PathBuf,
}

impl TemporaryRoot {
    fn new() -> Result<Self> {
        let directory = tempfile::Builder::new().prefix("ct").tempdir()?;
        let path = directory.path().to_path_buf();
        Ok(Self { _directory: directory, path })
    }
}

fn run_cold(common: &mut Common) -> Result<RunResult> {
    let run = common.next_path("cold")?;
    let socket = run.join("mux.sock");
    let session = format!("{}-{}", common.session_name("cold"), common.next_id);
    let marker = format!("[{session}] ");
    let args = vec![
        "--ephemeral".into(),
        "--session".into(),
        session,
        "--socket".into(),
        socket.to_string_lossy().into_owned(),
    ];
    run_pty(common, args, marker, Some(&socket))
}

fn run_warm(common: &mut Common, _server: &mut RunningHeadless) -> Result<RunResult> {
    let session = common.session_name("warm");
    let marker = format!("[{session}] ");
    let socket = common.path("warm.sock");
    let args = vec![
        "attach".into(),
        "--session".into(),
        session,
        "--socket".into(),
        socket.to_string_lossy().into_owned(),
    ];
    run_pty(common, args, marker, None)
}

fn run_pty(
    common: &Common,
    args: Vec<String>,
    marker: String,
    identity_socket: Option<&Path>,
) -> Result<RunResult> {
    let pair = cmux_pty::open(PtySize { rows: 24, cols: 80, pixel_width: 640, pixel_height: 384 })?;
    let command = common.pty_command(&args, common.wrap_measured_process)?;
    let started = Instant::now();
    let mut spawned = pair.spawn(command)?;
    let reader = spawned.master.try_clone_reader()?;
    let writer = Arc::new(Mutex::new(spawned.master.take_writer()?));
    let mut killer = spawned.child.clone_killer();
    let (event_sender, event_receiver) = mpsc::channel();
    let writer_for_reader = writer.clone();
    let marker_bytes = marker.into_bytes();
    let reader_thread = thread::Builder::new()
        .name("startup-benchmark-pty-reader".into())
        .spawn(move || read_pty(reader, writer_for_reader, marker_bytes, event_sender))?;
    let (status_sender, status_receiver) = mpsc::channel();
    let status_thread =
        thread::Builder::new().name("startup-benchmark-pty-wait".into()).spawn(move || {
            let status = spawned.child.wait();
            let _ = status_sender.send(status);
        })?;

    let observed_at = match event_receiver.recv_timeout(EVENT_TIMEOUT) {
        Ok(PtyEvent::Marker(at)) => at,
        Ok(PtyEvent::Ended) => {
            killer.kill().ok();
            let reader = reader_thread.join().map_err(|_| anyhow!("PTY reader panicked"))??;
            bail!("PTY ended before render marker: {}", String::from_utf8_lossy(&reader.output));
        }
        Ok(PtyEvent::Failed(error)) => {
            killer.kill().ok();
            bail!("PTY reader failed before render marker: {error}");
        }
        Err(error) => {
            killer.kill().ok();
            bail!("render marker deadline expired: {error}");
        }
    };
    if let Some(socket) = identity_socket {
        assert_ping(common, socket)?;
    }
    {
        let mut writer = writer.lock().map_err(|_| anyhow!("PTY writer lock poisoned"))?;
        writer.write_all(b"\x02d")?;
        writer.flush()?;
    }
    let status = match status_receiver.recv_timeout(PROCESS_TIMEOUT) {
        Ok(status) => status?,
        Err(error) => {
            killer.kill()?;
            bail!("interactive process did not exit after detach: {error}");
        }
    };
    status_thread.join().map_err(|_| anyhow!("PTY wait thread panicked"))?;
    let reader = reader_thread.join().map_err(|_| anyhow!("PTY reader panicked"))??;
    if !status.success() {
        bail!(
            "interactive process exited with {status}: {}",
            String::from_utf8_lossy(&reader.output)
        );
    }
    Ok(RunResult {
        duration_ns: duration_ns(observed_at.duration_since(started))?,
        evidence: Evidence {
            render_markers: 1,
            frame_completions: 1,
            process_exits: 1,
            terminal_probe_responses: reader.probe_responses,
            socket_rpcs: usize::from(identity_socket.is_some()),
            frame_cursor_shows: if reader.cursor_visibility == Some(CursorVisibility::Show) {
                1
            } else {
                0
            },
            frame_cursor_hides: if reader.cursor_visibility == Some(CursorVisibility::Hide) {
                1
            } else {
                0
            },
            ..Evidence::default()
        },
    })
}

fn run_headless(common: &mut Common) -> Result<RunResult> {
    let run = common.next_path("headless")?;
    let socket = run.join("mux.sock");
    let session = format!("{}-{}", common.session_name("headless"), common.next_id);
    let args = headless_args(&session, &socket, None);
    let mut server = RunningHeadless::start(common, args, &socket, common.wrap_measured_process)?;
    server.wait_ready()?;
    assert_ping(common, &socket)?;
    let duration = server.started.elapsed();
    server.shutdown_and_wait(common)?;
    Ok(RunResult {
        duration_ns: duration_ns(duration)?,
        evidence: Evidence {
            readiness_lines: 1,
            socket_rpcs: 2,
            process_exits: 1,
            ..Evidence::default()
        },
    })
}

fn run_restored(common: &mut Common, state: &Path, terminal_id: &str) -> Result<RunResult> {
    let run = common.next_path("restored-run")?;
    let socket = run.join("mux.sock");
    let session = common.session_name("restored");
    let args = headless_args(&session, &socket, Some(state));
    let mut server = RunningHeadless::start(common, args, &socket, common.wrap_measured_process)?;
    server.wait_ready()?;
    let topology = json_cli(common, &socket, &["workspace", "list"])?;
    if !json_contains_string(&topology, terminal_id) {
        bail!("restored topology omitted saved terminal {terminal_id}");
    }
    let duration = server.started.elapsed();
    server.shutdown_and_wait(common)?;
    Ok(RunResult {
        duration_ns: duration_ns(duration)?,
        evidence: Evidence {
            readiness_lines: 1,
            socket_rpcs: 2,
            restored_topologies: 1,
            process_exits: 1,
            ..Evidence::default()
        },
    })
}

fn run_incompatible(
    common: &mut Common,
    state: &Path,
    database: &Path,
    expected: &str,
) -> Result<RunResult> {
    let run = common.next_path("incompatible-run")?;
    let socket = run.join("mux.sock");
    let session = common.session_name("incompatible");
    let args = headless_args(&session, &socket, Some(state));
    let command = common.std_command(&args, common.wrap_measured_process)?;
    let captured = run_captured(command)?;
    if captured.status.success() {
        bail!("incompatible state unexpectedly started successfully");
    }
    let stderr = String::from_utf8_lossy(&captured.stderr);
    if !stderr.contains(expected) {
        bail!("incompatible state error did not contain {expected:?}: {stderr}");
    }
    let connection = Connection::open(database)?;
    let stored: String =
        connection.query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| {
            row.get(0)
        })?;
    if stored != INCOMPATIBLE_SCHEMA.to_string() {
        bail!("schema rejection changed stored schema to {stored}");
    }
    Ok(RunResult {
        duration_ns: duration_ns(captured.duration)?,
        evidence: Evidence { schema_rejections: 1, process_exits: 1, ..Evidence::default() },
    })
}

fn headless_args(session: &str, socket: &Path, state: Option<&Path>) -> Vec<String> {
    let mut args = vec![
        "--headless".into(),
        "--session".into(),
        session.into(),
        "--socket".into(),
        socket.to_string_lossy().into_owned(),
    ];
    if let Some(state) = state {
        args.push("--state".into());
        args.push(state.to_string_lossy().into_owned());
    } else {
        args.push("--ephemeral".into());
    }
    args
}

struct RunningHeadless {
    child: Option<Child>,
    socket: PathBuf,
    started: Instant,
    events: mpsc::Receiver<StreamEvent>,
    reader: Option<thread::JoinHandle<std::io::Result<Vec<u8>>>>,
}

impl RunningHeadless {
    fn start(common: &Common, args: Vec<String>, socket: &Path, wrapped: bool) -> Result<Self> {
        let mut command = common.std_command(&args, wrapped)?;
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
        let started = Instant::now();
        let mut child = command.spawn()?;
        let stderr = child.stderr.take().context("headless stderr pipe missing")?;
        let needle =
            format!("cmux-tui: headless, control socket at {}", socket.display()).into_bytes();
        let (sender, events) = mpsc::channel();
        let reader = thread::Builder::new()
            .name("startup-benchmark-stderr".into())
            .spawn(move || read_until_event(stderr, needle, sender))?;
        Ok(Self {
            child: Some(child),
            socket: socket.to_path_buf(),
            started,
            events,
            reader: Some(reader),
        })
    }

    fn wait_ready(&mut self) -> Result<Instant> {
        match self.events.recv_timeout(EVENT_TIMEOUT) {
            Ok(StreamEvent::Found(at)) => Ok(at),
            Ok(StreamEvent::Ended) => {
                let output = self.terminate_and_read();
                bail!(
                    "headless process exited before readiness: {}",
                    String::from_utf8_lossy(&output)
                );
            }
            Ok(StreamEvent::Failed(error)) => {
                let output = self.terminate_and_read();
                bail!(
                    "headless stderr failed before readiness ({error}): {}",
                    String::from_utf8_lossy(&output)
                );
            }
            Err(error) => {
                let output = self.terminate_and_read();
                bail!(
                    "headless readiness deadline expired ({error}): {}",
                    String::from_utf8_lossy(&output)
                );
            }
        }
    }

    fn shutdown_and_wait(&mut self, common: &Common) -> Result<()> {
        json_cli(common, &self.socket, &["session", "current", "shutdown"])?;
        let child = self.child.as_mut().context("headless process already reaped")?;
        let status = wait_child(child, PROCESS_TIMEOUT)?;
        let output = self.join_reader()?;
        self.child = None;
        if !status.success() {
            bail!("headless process exited with {status}: {}", String::from_utf8_lossy(&output));
        }
        Ok(())
    }

    fn join_reader(&mut self) -> Result<Vec<u8>> {
        self.reader
            .take()
            .context("headless reader already joined")?
            .join()
            .map_err(|_| anyhow!("headless stderr reader panicked"))?
            .map_err(Into::into)
    }

    fn terminate_and_read(&mut self) -> Vec<u8> {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.child = None;
        self.reader
            .take()
            .and_then(|reader| reader.join().ok())
            .and_then(Result::ok)
            .unwrap_or_default()
    }
}

impl Drop for RunningHeadless {
    fn drop(&mut self) {
        if let Some(child) = self.child.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

enum StreamEvent {
    Found(Instant),
    Ended,
    Failed(String),
}

fn read_until_event(
    mut reader: impl Read,
    needle: Vec<u8>,
    sender: mpsc::Sender<StreamEvent>,
) -> std::io::Result<Vec<u8>> {
    let mut output = Vec::new();
    let mut found = false;
    let mut buffer = [0_u8; 4096];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                if !found {
                    let _ = sender.send(StreamEvent::Ended);
                }
                return Ok(output);
            }
            Ok(read) => {
                append_bounded(&mut output, &buffer[..read]);
                if !found && contains(&output, &needle) {
                    found = true;
                    let _ = sender.send(StreamEvent::Found(Instant::now()));
                }
            }
            Err(error) => {
                let _ = sender.send(StreamEvent::Failed(error.to_string()));
                return Err(error);
            }
        }
    }
}

enum PtyEvent {
    Marker(Instant),
    Ended,
    Failed(String),
}

struct PtyReadResult {
    output: Vec<u8>,
    probe_responses: usize,
    cursor_visibility: Option<CursorVisibility>,
}

fn read_pty(
    mut reader: Box<dyn Read + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    marker: Vec<u8>,
    sender: mpsc::Sender<PtyEvent>,
) -> std::io::Result<PtyReadResult> {
    let mut output = Vec::new();
    let mut probes = ProbeTracker::default();
    let mut frame_marker = FrameMarkerTracker::new(marker);
    let mut frame_seen = false;
    let mut buffer = [0_u8; 4096];
    loop {
        match reader.read(&mut buffer) {
            Ok(0) => {
                if !frame_seen {
                    let _ = sender.send(PtyEvent::Ended);
                }
                return Ok(PtyReadResult {
                    output,
                    probe_responses: probes.responses,
                    cursor_visibility: frame_marker.visibility,
                });
            }
            Ok(read) => {
                append_bounded(&mut output, &buffer[..read]);
                for response in probes.observe(&output) {
                    let mut writer = writer.lock().map_err(|_| {
                        std::io::Error::other("terminal response writer lock poisoned")
                    })?;
                    writer.write_all(response)?;
                    writer.flush()?;
                }
                if !frame_seen && frame_marker.observe(&output).is_some() {
                    frame_seen = true;
                    let _ = sender.send(PtyEvent::Marker(Instant::now()));
                }
            }
            Err(error) => {
                let _ = sender.send(PtyEvent::Failed(error.to_string()));
                return Err(error);
            }
        }
    }
}

struct FrameMarkerTracker {
    marker: Vec<u8>,
    marker_end: Option<usize>,
    visibility: Option<CursorVisibility>,
}

impl FrameMarkerTracker {
    fn new(marker: Vec<u8>) -> Self {
        Self { marker, marker_end: None, visibility: None }
    }

    fn observe(&mut self, output: &[u8]) -> Option<CursorVisibility> {
        if self.visibility.is_some() {
            return self.visibility;
        }
        if self.marker_end.is_none() {
            self.marker_end = find(output, &self.marker).map(|offset| offset + self.marker.len());
        }
        let Some(marker_end) = self.marker_end else {
            return None;
        };
        let Some(after_marker) = output.get(marker_end..) else {
            return None;
        };
        self.visibility = match (find(after_marker, b"\x1b[?25h"), find(after_marker, b"\x1b[?25l"))
        {
            (Some(show), Some(hide)) if show < hide => Some(CursorVisibility::Show),
            (Some(_), Some(_)) => Some(CursorVisibility::Hide),
            (Some(_), None) => Some(CursorVisibility::Show),
            (None, Some(_)) => Some(CursorVisibility::Hide),
            (None, None) => None,
        };
        self.visibility
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CursorVisibility {
    Show,
    Hide,
}

#[derive(Default)]
struct ProbeTracker {
    foreground: bool,
    background: bool,
    window: bool,
    kitty: bool,
    da1: bool,
    keyboard: bool,
    responses: usize,
}

impl ProbeTracker {
    fn observe(&mut self, output: &[u8]) -> Vec<&'static [u8]> {
        let probes: [(&[u8], &[u8], &mut bool); 6] = [
            (b"\x1b]10;?\x1b\\", b"\x1b]10;rgb:eeee/dddd/cccc\x1b\\", &mut self.foreground),
            (b"\x1b]11;?\x1b\\", b"\x1b]11;rgb:1111/2222/3333\x1b\\", &mut self.background),
            (b"\x1b[14t", b"\x1b[4;384;640t", &mut self.window),
            (
                b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\",
                b"\x1b_Gi=31;EINVAL\x1b\\",
                &mut self.kitty,
            ),
            (b"\x1b[c", b"\x1b[?1;2c", &mut self.da1),
            (b"\x1b[?u", b"\x1b[?0u", &mut self.keyboard),
        ];
        let mut responses = Vec::new();
        for (request, response, sent) in probes {
            if !*sent && contains(output, request) {
                *sent = true;
                self.responses += 1;
                responses.push(response);
            }
        }
        responses
    }
}

fn append_bounded(output: &mut Vec<u8>, bytes: &[u8]) {
    output.extend_from_slice(bytes);
    if output.len() > MAX_CAPTURE_BYTES {
        output.drain(..output.len() - MAX_CAPTURE_BYTES);
    }
}

fn contains(haystack: &[u8], needle: &[u8]) -> bool {
    find(haystack, needle).is_some()
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        return None;
    }
    haystack.windows(needle.len()).position(|window| window == needle)
}

struct Captured {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    duration: Duration,
}

fn run_captured(mut command: Command) -> Result<Captured> {
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let started = Instant::now();
    let mut child = command.spawn()?;
    let stdout = child.stdout.take().context("stdout pipe missing")?;
    let stderr = child.stderr.take().context("stderr pipe missing")?;
    let stdout_reader = thread::spawn(move || read_bounded(stdout));
    let stderr_reader = thread::spawn(move || read_bounded(stderr));
    let status = wait_child(&mut child, PROCESS_TIMEOUT)?;
    let duration = started.elapsed();
    let stdout = stdout_reader.join().map_err(|_| anyhow!("stdout reader panicked"))??;
    let stderr = stderr_reader.join().map_err(|_| anyhow!("stderr reader panicked"))??;
    Ok(Captured { status, stdout, stderr, duration })
}

fn read_bounded(mut reader: impl Read) -> std::io::Result<Vec<u8>> {
    let mut output = Vec::new();
    let mut buffer = [0_u8; 4096];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            return Ok(output);
        }
        append_bounded(&mut output, &buffer[..read]);
    }
}

fn wait_child(child: &mut Child, timeout: Duration) -> Result<ExitStatus> {
    if let Some(status) = child.wait_timeout(timeout)? {
        return Ok(status);
    }
    child.kill()?;
    let status = child.wait()?;
    bail!("process exceeded {timeout:?} and was killed with {status}")
}

fn assert_ping(common: &Common, socket: &Path) -> Result<()> {
    let value = json_cli(common, socket, &["session", "current", "ping"])?;
    if value.get("alive").and_then(Value::as_bool) != Some(true) {
        bail!("session ping did not return alive=true: {value}");
    }
    if value.get("build_commit").and_then(Value::as_str) != Some(common.target.sha.as_str()) {
        bail!("session ping build_commit did not match {}: {value}", common.target.sha);
    }
    if value.get("ghostty_commit").and_then(Value::as_str)
        != Some(common.target.ghostty_sha.as_str())
    {
        bail!("session ping ghostty_commit did not match {}: {value}", common.target.ghostty_sha);
    }
    Ok(())
}

fn git_sha(path: &Path) -> Result<String> {
    let output = Command::new("git")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "HEAD"])
        .output()
        .with_context(|| format!("run git in {}", path.display()))?;
    if !output.status.success() {
        bail!(
            "git rev-parse failed in {}: {}",
            path.display(),
            String::from_utf8_lossy(&output.stderr)
        );
    }
    Ok(String::from_utf8(output.stdout)?.trim().to_string())
}

fn json_cli(common: &Common, socket: &Path, args: &[&str]) -> Result<Value> {
    let mut command = common.std_command(&[], false)?;
    command.args(["--json", "--socket"]);
    command.arg(socket);
    command.args(args);
    let captured = run_captured(command)?;
    if !captured.status.success() {
        bail!(
            "socket RPC {:?} failed with {}: {}",
            args,
            captured.status,
            String::from_utf8_lossy(&captured.stderr)
        );
    }
    serde_json::from_slice(&captured.stdout).with_context(|| {
        format!(
            "socket RPC {:?} returned invalid JSON: {}",
            args,
            String::from_utf8_lossy(&captured.stdout)
        )
    })
}

fn find_key_string(value: &Value, key: &str) -> Option<String> {
    match value {
        Value::Object(object) => object
            .get(key)
            .and_then(Value::as_str)
            .map(str::to_string)
            .or_else(|| object.values().find_map(|child| find_key_string(child, key))),
        Value::Array(array) => array.iter().find_map(|child| find_key_string(child, key)),
        _ => None,
    }
}

fn json_contains_string(value: &Value, expected: &str) -> bool {
    match value {
        Value::String(value) => value == expected,
        Value::Array(array) => array.iter().any(|value| json_contains_string(value, expected)),
        Value::Object(object) => object.values().any(|value| json_contains_string(value, expected)),
        _ => false,
    }
}

fn find_named_file(root: &Path, name: &str) -> Result<Option<PathBuf>> {
    for entry in fs::read_dir(root)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() {
            if let Some(found) = find_named_file(&path, name)? {
                return Ok(Some(found));
            }
        } else if path.file_name().and_then(|value| value.to_str()) == Some(name) {
            return Ok(Some(path));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn probe_tracker_answers_each_observed_query_once() {
        let mut tracker = ProbeTracker::default();
        let first = tracker.observe(b"\x1b]10;?\x1b\\ noise \x1b[c");
        assert_eq!(first.len(), 2);
        assert_eq!(tracker.responses, 2);
        assert!(tracker.observe(b"\x1b]10;?\x1b\\ noise \x1b[c").is_empty());
    }

    #[test]
    fn frame_marker_requires_a_later_cursor_visibility_escape_across_reads() {
        let mut tracker = FrameMarkerTracker::new(b"[bench-cold-1] ".to_vec());
        assert_eq!(tracker.observe(b"prefix [bench-cold"), None);
        assert_eq!(tracker.observe(b"prefix [bench-cold-1] frame bytes"), None);
        assert_eq!(tracker.observe(b"prefix [bench-cold-1] frame bytes\x1b[?25"), None);
        assert_eq!(
            tracker.observe(b"prefix [bench-cold-1] frame bytes\x1b[?25h"),
            Some(CursorVisibility::Show)
        );
    }

    #[test]
    fn recursive_json_checks_use_values_not_serialized_substrings() {
        let value =
            serde_json::json!({"terminal": {"id": "term:exact"}, "other": "term:exact-more"});
        assert!(json_contains_string(&value, "term:exact"));
        assert!(!json_contains_string(&value, "term:exa"));
        assert_eq!(find_key_string(&value, "id").as_deref(), Some("term:exact"));
    }
}
