use std::collections::VecDeque;
use std::env;
use std::fs;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow, bail};
use cmux_pty::{PtyCommand, PtySize};
use cmux_tui_core::platform::transport;
use rusqlite::Connection;
use serde_json::Value;
use sha2::{Digest, Sha256};
use wait_timeout::ChildExt;

use super::lifecycle::FixtureRoot;
use super::{
    Evidence, LifecycleRecorder, PhaseMetric, RunPhases, RunResult, Scenario, SuiteDeadline,
    TargetKind, duration_ns,
};
#[cfg(target_os = "macos")]
use crate::startup_benchmark_protocol::macos_account_identity;
#[cfg(windows)]
use crate::startup_benchmark_protocol::{
    PRODUCT_STARTED_TIMEOUT, parse_product_started_line, read_product_started_control_line,
};
use crate::startup_benchmark_protocol::{
    STARTUP_LINE_TIMEOUT, SupervisorStartupLine, TimingPage, arm_line, monotonic_ns,
    parse_supervisor_startup_line, read_control_line, write_control_line,
};

const EVENT_TIMEOUT: Duration = Duration::from_secs(30);
const PROCESS_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_CAPTURE_BYTES: usize = 2 * 1024 * 1024;
const MAX_STATE_SCAN_DEPTH: usize = 8;
const MAX_STATE_SCAN_ENTRIES: usize = 4_096;
const INCOMPATIBLE_SCHEMA: i64 = 2_147_483_647;
static LAUNCH_SEQUENCE: AtomicUsize = AtomicUsize::new(1);

#[derive(Debug, Clone)]
pub struct Target {
    pub kind: TargetKind,
    pub binary: PathBuf,
    pub source: PathBuf,
    pub sha: String,
    pub expected_binary_sha256: String,
    pub observed_sha: String,
    pub ghostty_sha: String,
    pub zig_version: String,
    pub rust_toolchain: String,
    pub embedded_identity_verified: bool,
    version: String,
    pub launcher: Vec<String>,
    pub supervisor_binary: PathBuf,
    pub supervisor_binary_sha256: String,
    #[cfg(windows)]
    pub windows_bootstrap_binary: PathBuf,
    #[cfg(windows)]
    pub windows_bootstrap_sha256: String,
    pub trusted_source: PathBuf,
    pub trusted_sha: String,
}

impl Target {
    pub fn new(input: TargetInput) -> Result<Self> {
        let TargetInput {
            kind,
            binary,
            source,
            sha,
            expected_binary_sha256,
            launcher,
            supervisor_binary,
            supervisor_binary_sha256,
            #[cfg(windows)]
            windows_bootstrap_binary,
            #[cfg(windows)]
            windows_bootstrap_sha256,
            trusted_source,
            trusted_sha,
        } = input;
        let observed_sha = git_sha(&source)?;
        if observed_sha != sha {
            bail!(
                "{} source SHA mismatch: requested {sha}, observed {observed_sha}",
                kind.as_str()
            );
        }
        let ghostty_sha = git_sha(&source.join("ghostty"))?;
        let observed_binary_sha256 = binary_sha256(&binary)?;
        if observed_binary_sha256 != expected_binary_sha256 {
            bail!(
                "{} binary SHA-256 mismatch: expected {expected_binary_sha256}, observed {observed_binary_sha256}",
                kind.as_str()
            );
        }
        let zig_version = source_zig_version(&source)?;
        let rust_toolchain = source_rust_toolchain(&source)?;
        let observed_supervisor_sha256 = binary_sha256(&supervisor_binary)?;
        if observed_supervisor_sha256 != supervisor_binary_sha256 {
            bail!(
                "trusted supervisor SHA-256 mismatch: expected {supervisor_binary_sha256}, observed {observed_supervisor_sha256}"
            );
        }
        #[cfg(windows)]
        if binary_sha256(&windows_bootstrap_binary)? != windows_bootstrap_sha256 {
            bail!("trusted Windows bootstrap SHA-256 mismatch before execution");
        }
        let observed_trusted_sha = git_sha(&trusted_source)?;
        if observed_trusted_sha != trusted_sha {
            bail!(
                "trusted source SHA mismatch: requested {trusted_sha}, observed {observed_trusted_sha}"
            );
        }
        if kind == TargetKind::Baseline {
            assert_git_ancestor(&trusted_source, &sha, &trusted_sha)?;
        }
        Ok(Self {
            kind,
            binary,
            source,
            sha,
            expected_binary_sha256,
            observed_sha,
            ghostty_sha,
            zig_version,
            rust_toolchain,
            embedded_identity_verified: false,
            version: String::new(),
            launcher,
            supervisor_binary,
            supervisor_binary_sha256,
            #[cfg(windows)]
            windows_bootstrap_binary,
            #[cfg(windows)]
            windows_bootstrap_sha256,
            trusted_source,
            trusted_sha,
        })
    }

    pub fn verify_product_identity(mut self, fixture_parent: &Path) -> Result<Self> {
        let mut common = Common::new(self.clone(), Scenario::Cold, false, fixture_parent)?;
        let command = common.std_command(&["--version".into()], false)?;
        let captured = run_captured(command, SuiteDeadline::unbounded())
            .with_context(|| format!("read version from {}", self.binary.display()))?;
        if !captured.status.success() {
            bail!(
                "{} --version failed: {}",
                self.binary.display(),
                String::from_utf8_lossy(&captured.stderr)
            );
        }
        let output = String::from_utf8(captured.stdout)?;
        let version =
            output.trim().strip_prefix("cmux ").map(str::to_string).with_context(|| {
                format!("unexpected {} --version output: {output:?}", self.binary.display())
            })?;
        self.embedded_identity_verified = validate_binary_identity(
            &version,
            &self.sha,
            &self.ghostty_sha,
            self.kind == TargetKind::Candidate,
        )
        .with_context(|| format!("validate {} binary identity", self.kind.as_str()))?;
        self.version = version;
        common.root.mark_quiescent();
        Ok(self)
    }

    pub fn verify_integrity(&self) -> Result<()> {
        let binary = binary_sha256(&self.binary)?;
        if binary != self.expected_binary_sha256 {
            bail!("{} product binary changed after execution", self.kind.as_str());
        }
        if git_sha(&self.source)? != self.sha {
            bail!("{} product source changed after execution", self.kind.as_str());
        }
        if git_sha(&self.source.join("ghostty"))? != self.ghostty_sha {
            bail!("{} Ghostty source changed after execution", self.kind.as_str());
        }
        if git_sha(&self.trusted_source)? != self.trusted_sha {
            bail!("trusted benchmark source changed after execution");
        }
        if binary_sha256(&self.supervisor_binary)? != self.supervisor_binary_sha256 {
            bail!("trusted supervisor changed after execution");
        }
        #[cfg(windows)]
        if binary_sha256(&self.windows_bootstrap_binary)? != self.windows_bootstrap_sha256 {
            bail!("trusted Windows bootstrap changed after execution");
        }
        Ok(())
    }
}

pub struct TargetInput {
    pub kind: TargetKind,
    pub binary: PathBuf,
    pub source: PathBuf,
    pub sha: String,
    pub expected_binary_sha256: String,
    pub launcher: Vec<String>,
    pub supervisor_binary: PathBuf,
    pub supervisor_binary_sha256: String,
    #[cfg(windows)]
    pub windows_bootstrap_binary: PathBuf,
    #[cfg(windows)]
    pub windows_bootstrap_sha256: String,
    pub trusted_source: PathBuf,
    pub trusted_sha: String,
}

pub struct Fixture(FixtureState);

enum FixtureState {
    Cold(Box<Common>),
    Warm { common: Box<Common>, server: Box<RunningHeadless> },
    Headless(Box<Common>),
    Restored { common: Box<Common>, state: PathBuf, terminal_id: String },
    Incompatible { common: Box<Common>, state: PathBuf, database: PathBuf, expected: String },
}

impl Fixture {
    pub fn new(
        target: Target,
        scenario: Scenario,
        wrap_measured_process: bool,
        fixture_parent: &Path,
        deadline: SuiteDeadline,
    ) -> Result<Self> {
        deadline.ensure("preparing a startup fixture")?;
        let mut common = Common::new(target, scenario, wrap_measured_process, fixture_parent)?;
        match scenario {
            Scenario::Cold => Ok(Self(FixtureState::Cold(Box::new(common)))),
            Scenario::Headless => Ok(Self(FixtureState::Headless(Box::new(common)))),
            Scenario::Warm => {
                let socket = common.path("warm.sock");
                let session = common.session_name("warm");
                let args = headless_args(&session, &socket, None);
                let mut server = RunningHeadless::start(&common, args, &socket, false, deadline)?;
                server.wait_ready(deadline)?;
                assert_ping(&common, &socket, deadline)?;
                common.setup_evidence.readiness_lines += 1;
                common.setup_evidence.socket_rpcs += 1;
                Ok(Self(FixtureState::Warm { common: Box::new(common), server: Box::new(server) }))
            }
            Scenario::Restored => {
                let state = common.path("restored-state");
                fs::create_dir_all(&state)?;
                let socket = common.path("restored-setup.sock");
                let session = common.session_name("restored");
                let args = headless_args(&session, &socket, Some(&state));
                let mut server = RunningHeadless::start(&common, args, &socket, false, deadline)?;
                server.wait_ready(deadline)?;
                assert_ping(&common, &socket, deadline)?;
                let created = json_cli(
                    &common,
                    &socket,
                    &["workspace", "create", "--name", "bench-restored"],
                    deadline,
                )?;
                let terminal_id = find_key_string(&created.value, "terminal_id")
                    .context("workspace create did not return a terminal_id")?;
                let topology = json_cli(&common, &socket, &["terminal", "list"], deadline)?;
                if !terminal_list_contains_id(&topology.value, &terminal_id) {
                    bail!("restored fixture terminal list omitted {terminal_id}");
                }
                server.shutdown_and_wait(&common, deadline)?;
                common.setup_evidence.readiness_lines += 1;
                common.setup_evidence.socket_rpcs += 4;
                common.setup_evidence.process_exits += 1;
                Ok(Self(FixtureState::Restored { common: Box::new(common), state, terminal_id }))
            }
            Scenario::Incompatible => {
                let state = common.path("incompatible-state");
                fs::create_dir_all(&state)?;
                let socket = common.path("incompatible-setup.sock");
                let session = common.session_name("incompatible");
                let args = headless_args(&session, &socket, Some(&state));
                let mut server = RunningHeadless::start(&common, args, &socket, false, deadline)?;
                server.wait_ready(deadline)?;
                assert_ping(&common, &socket, deadline)?;
                server.shutdown_and_wait(&common, deadline)?;
                let database = find_named_regular_file(&state, "workspace-registry.sqlite3")?
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
                    "cannot open session \"{session}\" with cmux {}: its saved state is incompatible with this build",
                    common.target.version
                );
                common.setup_evidence.readiness_lines += 1;
                common.setup_evidence.socket_rpcs += 2;
                common.setup_evidence.process_exits += 1;
                Ok(Self(FixtureState::Incompatible {
                    common: Box::new(common),
                    state,
                    database,
                    expected,
                }))
            }
        }
    }

    pub fn setup_evidence(&self) -> Evidence {
        self.common().setup_evidence.clone()
    }

    pub fn cleanup(&mut self) -> Result<Evidence> {
        let deadline = SuiteDeadline::unbounded();
        let mut evidence = Evidence::default();
        match &mut self.0 {
            FixtureState::Warm { common, server } => {
                server.shutdown_and_wait(common, deadline)?;
                evidence.socket_rpcs += 1;
                evidence.process_exits += 1;
            }
            FixtureState::Restored { common, state, terminal_id } => {
                let socket = common.path("restored-cleanup.sock");
                let session = common.session_name("restored");
                let args = headless_args(&session, &socket, Some(state));
                let mut server = RunningHeadless::start(common, args, &socket, false, deadline)?;
                server.wait_ready(deadline)?;
                let topology = json_cli(common, &socket, &["terminal", "list"], deadline)?;
                evidence.socket_rpcs += 1;
                match restored_cleanup_plan(&topology.value, terminal_id)? {
                    RestoredCleanupPlan::AlreadyQuiescent => {}
                }
                server.shutdown_and_wait(common, deadline)?;
                evidence.readiness_lines += 1;
                evidence.socket_rpcs += 1;
                evidence.process_exits += 1;
            }
            _ => {}
        }
        self.common_mut().root.mark_quiescent();
        Ok(evidence)
    }

    pub fn defer_root(&mut self, recorder: &mut LifecycleRecorder) -> Result<PhaseMetric> {
        self.common_mut().root.defer(recorder)
    }

    fn common(&self) -> &Common {
        match &self.0 {
            FixtureState::Cold(common) | FixtureState::Headless(common) => common,
            FixtureState::Warm { common, .. }
            | FixtureState::Restored { common, .. }
            | FixtureState::Incompatible { common, .. } => common,
        }
    }

    fn common_mut(&mut self) -> &mut Common {
        match &mut self.0 {
            FixtureState::Cold(common) | FixtureState::Headless(common) => common,
            FixtureState::Warm { common, .. }
            | FixtureState::Restored { common, .. }
            | FixtureState::Incompatible { common, .. } => common,
        }
    }
}

pub fn run_sample(fixture: &mut Fixture, deadline: SuiteDeadline) -> Result<RunResult> {
    deadline.ensure("starting a startup sample")?;
    match &mut fixture.0 {
        FixtureState::Cold(common) => run_cold(common, deadline),
        FixtureState::Warm { common, server } => run_warm(common, server, deadline),
        FixtureState::Headless(common) => run_headless(common, deadline),
        FixtureState::Restored { common, state, terminal_id } => {
            run_restored(common, state, terminal_id, deadline)
        }
        FixtureState::Incompatible { common, state, database, expected } => {
            run_incompatible(common, state, database, expected, deadline)
        }
    }
}

struct LaunchControl {
    timing: TimingPage,
    nonce: String,
    control_path: PathBuf,
    accept_receiver: mpsc::Receiver<io::Result<Box<dyn transport::Stream>>>,
    accept_thread: Option<thread::JoinHandle<()>>,
}

impl LaunchControl {
    fn new(root: &Path) -> Result<(Self, PathBuf)> {
        let sequence = LAUNCH_SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let stem = format!("c-{sequence:020}");
        let control_path = root.join(format!("{stem}.sock"));
        let timing = TimingPage::create(root.join(format!("{stem}.time")))?;
        let nonce = timing.nonce_hex();
        let listener = match transport::listen(&control_path) {
            Ok(listener) => listener,
            Err(error) => {
                let _ = fs::remove_file(timing.path());
                return Err(error).context("bind supervisor control socket");
            }
        };
        let (sender, accept_receiver) = mpsc::channel();
        let accept_thread = thread::Builder::new()
            .name("startup-benchmark-supervisor-control".into())
            .spawn(move || {
                let _ = sender.send(listener.accept());
            })?;
        Ok((
            Self {
                timing,
                nonce,
                control_path: control_path.clone(),
                accept_receiver,
                accept_thread: Some(accept_thread),
            },
            control_path,
        ))
    }

    fn arm(&mut self, deadline: SuiteDeadline) -> Result<()> {
        let public_line_deadline = deadline
            .instant(STARTUP_LINE_TIMEOUT, "running the bounded supervisor startup protocol")?;
        let timeout = public_line_deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("supervisor control accept deadline expired")?;
        let mut stream = self
            .accept_receiver
            .recv_timeout(timeout)
            .context("supervisor READY deadline expired")??;
        if let Some(thread) = self.accept_thread.take() {
            thread.join().map_err(|_| anyhow!("supervisor control thread panicked"))?;
        }
        let mut line =
            read_supervisor_startup_line(&mut stream, public_line_deadline, &self.nonce)?;
        if line == SupervisorStartupLine::Setup {
            line = read_supervisor_startup_line(&mut stream, public_line_deadline, &self.nonce)?;
        }
        match line {
            SupervisorStartupLine::Ready => {}
            SupervisorStartupLine::Failure { checkpoint_name } => {
                let checkpoint = checkpoint_name
                    .map(|name| self.control_path.parent().unwrap_or(Path::new(".")).join(name));
                bail!(
                    "product supervisor startup failed; checkpoint: {}",
                    checkpoint
                        .as_deref()
                        .map_or_else(|| "unavailable".into(), |path| path.display().to_string())
                );
            }
            SupervisorStartupLine::Setup => {
                bail!("product supervisor sent duplicate SETUP events")
            }
        }
        let timeout = public_line_deadline
            .checked_duration_since(Instant::now())
            .filter(|remaining| !remaining.is_zero())
            .context("supervisor ARM deadline expired")?;
        stream.set_write_timeout(Some(timeout))?;
        write_control_line(&mut stream, &arm_line(&self.nonce))?;
        #[cfg(windows)]
        {
            let product_started_deadline = deadline.instant(
                PRODUCT_STARTED_TIMEOUT,
                "waiting for bounded supervisor product-started evidence",
            )?;
            let remaining = product_started_deadline
                .checked_duration_since(Instant::now())
                .filter(|remaining| !remaining.is_zero())
                .context("supervisor product-started deadline expired")?;
            stream.set_read_timeout(Some(remaining))?;
            let line = read_product_started_control_line(&mut stream)?;
            if let Err(product_started) = parse_product_started_line(&line, &self.nonce, None) {
                match parse_supervisor_startup_line(&line, &self.nonce) {
                    Ok(SupervisorStartupLine::Failure { checkpoint_name }) => bail!(
                        "product supervisor failed after ARM; checkpoint: {}",
                        checkpoint_name.unwrap_or_else(|| "unavailable".into())
                    ),
                    _ => {
                        return Err(product_started)
                            .context("validate supervisor product-started evidence");
                    }
                }
            }
        }
        stream.shutdown(std::net::Shutdown::Both)?;
        Ok(())
    }

    fn measured_duration(&self, event_ns: u64) -> Result<Duration> {
        Ok(Duration::from_nanos(self.timing.measured_duration_ns(event_ns)?))
    }
}

fn read_supervisor_startup_line(
    stream: &mut Box<dyn transport::Stream>,
    deadline: Instant,
    nonce: &str,
) -> Result<SupervisorStartupLine> {
    let remaining = deadline
        .checked_duration_since(Instant::now())
        .filter(|remaining| !remaining.is_zero())
        .context("supervisor startup line deadline expired")?;
    stream.set_read_timeout(Some(remaining))?;
    parse_supervisor_startup_line(&read_control_line(stream)?, nonce)
}

impl Drop for LaunchControl {
    fn drop(&mut self) {
        if self.accept_thread.is_some() {
            if let Ok(stream) = transport::connect(&self.control_path) {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
            let _ = self.accept_receiver.recv_timeout(PROCESS_TIMEOUT);
            if let Some(thread) = self.accept_thread.take() {
                let _ = thread.join();
            }
        }
        let _ = fs::remove_file(&self.control_path);
        let _ = fs::remove_file(self.timing.path());
    }
}

struct PreparedStdCommand {
    command: Command,
    control: LaunchControl,
    cleanup: SupervisorCleanup,
}

struct PreparedPtyCommand {
    command: PtyCommand,
    control: LaunchControl,
    cleanup: SupervisorCleanup,
}

struct SupervisorCleanup {
    #[cfg(target_os = "macos")]
    user: String,
    #[cfg(target_os = "macos")]
    group: String,
    #[cfg(target_os = "macos")]
    nonce: String,
    complete: bool,
}

impl SupervisorCleanup {
    fn new(fixture_root: &Path, nonce: &str) -> Result<Self> {
        let _ = fixture_root;
        #[cfg(not(target_os = "macos"))]
        let _ = nonce;
        #[cfg(target_os = "macos")]
        let (user, _) = macos_account_identity(
            nonce,
            &env::var("CMUX_BENCH_MACOS_ACCOUNT_PREFIX")
                .context("CMUX_BENCH_MACOS_ACCOUNT_PREFIX is required")?,
            env::var("CMUX_BENCH_MACOS_UID_BASE")
                .context("CMUX_BENCH_MACOS_UID_BASE is required")?
                .parse()?,
        )?;
        Ok(Self {
            #[cfg(target_os = "macos")]
            user,
            #[cfg(target_os = "macos")]
            group: env::var("CMUX_BENCH_MACOS_GROUP")
                .context("CMUX_BENCH_MACOS_GROUP is required")?,
            #[cfg(target_os = "macos")]
            nonce: nonce.to_string(),
            complete: false,
        })
    }

    fn finish(&mut self) -> Result<()> {
        if self.complete {
            return Ok(());
        }
        #[cfg(target_os = "macos")]
        {
            if !macos_account_exists(&self.user)? {
                self.complete = true;
                return Ok(());
            }
            let uid = macos_account_uid(&self.user)?;
            match macos_account_nonce(&self.user)? {
                Some(nonce) if nonce == self.nonce => {}
                None if uid.is_none() => {}
                Some(nonce) => bail!(
                    "macOS benchmark account {} belongs to a different launch nonce {nonce}",
                    self.user
                ),
                None => {
                    bail!("macOS benchmark account {} has a UID but no launch nonce", self.user)
                }
            }
            if let Some(uid) = uid {
                let identity = uid.to_string();
                let pids = macos_user_processes(&identity)?;
                let exits = MacosExitWatch::new(&pids)?;
                let mut kill = Command::new("sudo");
                kill.args(["-n", "pkill", "-KILL", "-u", &identity]);
                let killed = run_trusted_captured(
                    kill,
                    SuiteDeadline::at(Instant::now() + PROCESS_TIMEOUT),
                )?;
                if !killed.status.success() && killed.status.code() != Some(1) {
                    bail!("macOS benchmark-user kill failed with {}", killed.status);
                }
                exits.wait(PROCESS_TIMEOUT)?;
                let remaining = macos_user_processes(&identity)?;
                if !remaining.is_empty() {
                    bail!(
                        "processes survived harness-owned cleanup for macOS benchmark user {}: {:?}",
                        self.user,
                        remaining
                    );
                }
            }
            let mut remove_group = Command::new("sudo");
            remove_group.args([
                "-n",
                "dseditgroup",
                "-o",
                "edit",
                "-d",
                &self.user,
                "-t",
                "user",
                &self.group,
            ]);
            let _ = run_trusted_captured(
                remove_group,
                SuiteDeadline::at(Instant::now() + PROCESS_TIMEOUT),
            );
            let mut remove_user = Command::new("sudo");
            remove_user.args(["-n", "dscl", ".", "-delete", &format!("/Users/{}", self.user)]);
            let removed = run_trusted_captured(
                remove_user,
                SuiteDeadline::at(Instant::now() + PROCESS_TIMEOUT),
            )?;
            if !removed.status.success() || macos_account_exists(&self.user)? {
                bail!("macOS benchmark account cleanup failed for {}", self.user);
            }
        }
        self.complete = true;
        Ok(())
    }
}

#[cfg(target_os = "macos")]
fn macos_user_processes(user: &str) -> Result<Vec<u32>> {
    let mut list = Command::new("pgrep");
    list.args(["-u", user]);
    let captured = run_trusted_captured(list, SuiteDeadline::at(Instant::now() + PROCESS_TIMEOUT))?;
    if !captured.status.success() {
        if captured.status.code() == Some(1) {
            return Ok(Vec::new());
        }
        bail!("list macOS benchmark-user processes failed with {}", captured.status);
    }
    String::from_utf8(captured.stdout)?
        .lines()
        .map(|line| line.parse::<u32>().context("parse macOS benchmark-user PID"))
        .collect()
}

#[cfg(target_os = "macos")]
fn macos_account_exists(user: &str) -> Result<bool> {
    let mut command = Command::new("dscl");
    command.args([".", "-read", &format!("/Users/{user}")]);
    let captured =
        run_trusted_captured(command, SuiteDeadline::at(Instant::now() + PROCESS_TIMEOUT))?;
    Ok(captured.status.success())
}

#[cfg(target_os = "macos")]
fn macos_account_uid(user: &str) -> Result<Option<u32>> {
    let mut command = Command::new("dscl");
    command.args([".", "-read", &format!("/Users/{user}"), "UniqueID"]);
    let captured =
        run_trusted_captured(command, SuiteDeadline::at(Instant::now() + PROCESS_TIMEOUT))?;
    if !captured.status.success() {
        return Ok(None);
    }
    let output = String::from_utf8(captured.stdout)?;
    output
        .trim()
        .strip_prefix("UniqueID: ")
        .map(str::parse)
        .transpose()
        .context("parse macOS benchmark account UniqueID")
}

#[cfg(target_os = "macos")]
fn macos_account_nonce(user: &str) -> Result<Option<String>> {
    let mut command = Command::new("dscl");
    command.args([".", "-read", &format!("/Users/{user}"), "dsAttrTypeNative:cmuxBenchmarkNonce"]);
    let captured =
        run_trusted_captured(command, SuiteDeadline::at(Instant::now() + PROCESS_TIMEOUT))?;
    if !captured.status.success() {
        return Ok(None);
    }
    let output = String::from_utf8(captured.stdout)?;
    Ok(output.trim().split_once(": ").map(|(_, value)| value.to_string()))
}

#[cfg(target_os = "macos")]
struct MacosExitWatch {
    queue: std::os::fd::OwnedFd,
    registrations: usize,
}

#[cfg(target_os = "macos")]
impl MacosExitWatch {
    fn new(pids: &[u32]) -> Result<Self> {
        use std::os::fd::{FromRawFd, OwnedFd};

        // SAFETY: kqueue returns a new owned descriptor or -1.
        let raw = unsafe { libc::kqueue() };
        if raw == -1 {
            return Err(io::Error::last_os_error()).context("create process-exit kqueue");
        }
        // SAFETY: raw is a unique descriptor returned by kqueue above.
        let queue = unsafe { OwnedFd::from_raw_fd(raw) };
        let mut registrations = 0;
        for pid in pids {
            let change = libc::kevent {
                ident: *pid as usize,
                filter: libc::EVFILT_PROC,
                flags: libc::EV_ADD | libc::EV_ONESHOT,
                fflags: libc::NOTE_EXIT,
                data: 0,
                udata: std::ptr::null_mut(),
            };
            // SAFETY: change is initialized, the queue is live, and no event output is requested.
            let result = unsafe {
                libc::kevent(
                    std::os::fd::AsRawFd::as_raw_fd(&queue),
                    &change,
                    1,
                    std::ptr::null_mut(),
                    0,
                    std::ptr::null(),
                )
            };
            if result == 0 {
                registrations += 1;
            } else if io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH) {
                return Err(io::Error::last_os_error())
                    .context(format!("register exit event for PID {pid}"));
            }
        }
        Ok(Self { queue, registrations })
    }

    fn wait(self, timeout: Duration) -> Result<()> {
        use std::os::fd::AsRawFd;

        let deadline =
            Instant::now().checked_add(timeout).context("macOS process-exit deadline overflow")?;
        let mut remaining = self.registrations;
        while remaining > 0 {
            let duration = deadline
                .checked_duration_since(Instant::now())
                .filter(|value| !value.is_zero())
                .context("macOS benchmark-user process-exit deadline expired")?;
            let timeout = libc::timespec {
                tv_sec: duration.as_secs().try_into()?,
                tv_nsec: i64::from(duration.subsec_nanos()),
            };
            let mut events = Vec::with_capacity(remaining);
            for _ in 0..remaining {
                events.push(libc::kevent {
                    ident: 0,
                    filter: 0,
                    flags: 0,
                    fflags: 0,
                    data: 0,
                    udata: std::ptr::null_mut(),
                });
            }
            // SAFETY: the queue is live and events has writable capacity for remaining events.
            let count = unsafe {
                libc::kevent(
                    self.queue.as_raw_fd(),
                    std::ptr::null(),
                    0,
                    events.as_mut_ptr(),
                    i32::try_from(events.len())?,
                    &timeout,
                )
            };
            if count == -1 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                return Err(error).context("wait for macOS benchmark-user process exits");
            }
            if count == 0 {
                bail!("macOS benchmark-user process-exit deadline expired");
            }
            remaining -= usize::try_from(count)?;
        }
        Ok(())
    }
}

impl Drop for SupervisorCleanup {
    fn drop(&mut self) {
        if !self.complete {
            let _ = self.finish();
        }
    }
}

struct Common {
    target: Target,
    root: FixtureRoot,
    config: PathBuf,
    wrap_measured_process: bool,
    setup_evidence: Evidence,
}

impl Common {
    fn new(
        target: Target,
        _scenario: Scenario,
        wrap_measured_process: bool,
        fixture_parent: &Path,
    ) -> Result<Self> {
        let root = FixtureRoot::new(fixture_parent)?;
        let config = root.path().join("config.json");
        fs::write(&config, b"{}")?;
        for directory in ["home", "config", "data", "cache", "state", "tmp"] {
            fs::create_dir_all(root.path().join(directory))?;
        }
        Ok(Self {
            target,
            root,
            config,
            wrap_measured_process,
            setup_evidence: Evidence::default(),
        })
    }

    fn path(&self, name: &str) -> PathBuf {
        self.root.path().join(name)
    }

    fn next_path(&mut self) -> Result<(PathBuf, u64)> {
        self.root.next_run_path()
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
        command.current_dir(self.root.path());
    }

    fn apply_pty_env(&self, command: &mut PtyCommand) {
        command.env_clear();
        copy_base_environment(|key, value| {
            command.env(key, value);
        });
        for (key, value) in self.environment() {
            command.env(key, value);
        }
        command.cwd(self.root.path());
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

    fn std_command(&self, args: &[String], wrapped: bool) -> Result<PreparedStdCommand> {
        let (control, control_path) = LaunchControl::new(self.root.path())?;
        let supervisor_args = self.supervisor_args(args, &control, &control_path);
        let mut command = if wrapped && !self.target.launcher.is_empty() {
            let mut command = Command::new(&self.target.launcher[0]);
            command.args(&self.target.launcher[1..]);
            command.arg(&self.target.supervisor_binary);
            command
        } else {
            Command::new(&self.target.supervisor_binary)
        };
        command.args(supervisor_args);
        self.apply_std_env(&mut command);
        let cleanup = SupervisorCleanup::new(self.root.path(), &control.nonce)?;
        Ok(PreparedStdCommand { command, control, cleanup })
    }

    fn pty_command(&self, args: &[String], wrapped: bool) -> Result<PreparedPtyCommand> {
        let (control, control_path) = LaunchControl::new(self.root.path())?;
        let supervisor_args = self.supervisor_args(args, &control, &control_path);
        let (program, mut prefix) =
            pty_program_and_prefix(&self.target.supervisor_binary, &self.target.launcher, wrapped);
        prefix.extend(supervisor_args);
        let mut command = PtyCommand::new(program);
        command.args(prefix);
        self.apply_pty_env(&mut command);
        let cleanup = SupervisorCleanup::new(self.root.path(), &control.nonce)?;
        Ok(PreparedPtyCommand { command, control, cleanup })
    }

    fn supervisor_args(
        &self,
        product_args: &[String],
        control: &LaunchControl,
        control_path: &Path,
    ) -> Vec<String> {
        let mut args = vec![
            "--control".into(),
            control_path.to_string_lossy().into_owned(),
            "--timing".into(),
            control.timing.path().to_string_lossy().into_owned(),
            "--nonce".into(),
            control.nonce.clone(),
            "--fixture-root".into(),
            self.root.path().to_string_lossy().into_owned(),
            "--target".into(),
            self.target.binary.to_string_lossy().into_owned(),
            "--target-sha256".into(),
            self.target.expected_binary_sha256.clone(),
            "--supervisor-sha256".into(),
            self.target.supervisor_binary_sha256.clone(),
        ];
        #[cfg(windows)]
        args.extend([
            "--windows-bootstrap-binary".into(),
            self.target.windows_bootstrap_binary.to_string_lossy().into_owned(),
            "--windows-bootstrap-sha256".into(),
            self.target.windows_bootstrap_sha256.clone(),
        ]);
        args.push("--".into());
        args.extend(product_args.iter().cloned());
        args
    }
}

fn pty_program_and_prefix(
    binary: &Path,
    launcher: &[String],
    wrapped: bool,
) -> (String, Vec<String>) {
    match (wrapped, launcher.split_first()) {
        (true, Some((program, launcher_args))) => {
            let mut prefix = launcher_args.to_vec();
            prefix.push(binary.to_string_lossy().into_owned());
            (program.clone(), prefix)
        }
        _ => (binary.to_string_lossy().into_owned(), Vec::new()),
    }
}

fn copy_base_environment(mut set: impl FnMut(String, String)) {
    for (key, value) in collect_base_environment(|key| env::var(key).ok()) {
        set(key, value);
    }
}

fn collect_base_environment(
    mut lookup: impl FnMut(&str) -> Option<String>,
) -> Vec<(String, String)> {
    let mut environment = Vec::new();
    for key in [
        "PATH",
        "SHELL",
        "SystemRoot",
        "WINDIR",
        "COMSPEC",
        "PATHEXT",
        "DEVELOPER_DIR",
        "CMUX_BENCH_LINUX_BWRAP",
        "CMUX_BENCH_LINUX_SUDO",
        "CMUX_BENCH_LINUX_UID",
        "CMUX_BENCH_LINUX_GID",
        "CMUX_BENCH_MACOS_ACCOUNT_PREFIX",
        "CMUX_BENCH_MACOS_GROUP",
        "CMUX_BENCH_MACOS_GID",
        "CMUX_BENCH_MACOS_UID_BASE",
        "CMUX_BENCH_MACOS_PROFILE",
        "CMUX_BENCH_WINDOWS_USER",
        "CMUX_BENCH_WINDOWS_PASSWORD",
    ] {
        if let Some(value) = lookup(key) {
            environment.push((key.to_string(), value));
        }
    }
    environment
}

fn run_cold(common: &mut Common, deadline: SuiteDeadline) -> Result<RunResult> {
    let (run, id) = common.next_path()?;
    let socket = run.join("mux.sock");
    let session = format!("{}-{id:020}", common.session_name("cold"));
    let marker = format!("[{session}] ");
    let args = vec![
        "--ephemeral".into(),
        "--session".into(),
        session,
        "--socket".into(),
        socket.to_string_lossy().into_owned(),
    ];
    run_pty(common, args, marker, Some(&socket), deadline)
}

fn run_warm(
    common: &mut Common,
    _server: &mut RunningHeadless,
    deadline: SuiteDeadline,
) -> Result<RunResult> {
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
    run_pty(common, args, marker, None, deadline)
}

fn run_pty(
    common: &Common,
    args: Vec<String>,
    marker: String,
    ping_socket: Option<&Path>,
    deadline: SuiteDeadline,
) -> Result<RunResult> {
    deadline.ensure("spawning an interactive startup process")?;
    let pair = cmux_pty::open(PtySize { rows: 24, cols: 80, pixel_width: 640, pixel_height: 384 })?;
    let prepared = common.pty_command(&args, common.wrap_measured_process)?;
    let PreparedPtyCommand { command, mut control, cleanup } = prepared;
    let spawned = pair.spawn(command)?;
    let master = spawned.master;
    let mut child = spawned.child;
    let reader = master.try_clone_reader()?;
    let writer = Arc::new(Mutex::new(master.take_writer()?));
    let process_tree = PtyProcessTree::from_handles(master.as_ref(), child.as_ref());
    let killer = child.clone_killer();
    let (event_sender, event_receiver) = mpsc::channel();
    let writer_for_reader = writer.clone();
    let marker_bytes = marker.into_bytes();
    let diagnostic = Arc::new(Mutex::new(VecDeque::new()));
    let diagnostic_for_reader = diagnostic.clone();
    let probe_queries = Arc::new(AtomicUsize::new(0));
    let probe_queries_for_reader = probe_queries.clone();
    let probe_responses = Arc::new(AtomicUsize::new(0));
    let probe_responses_for_reader = probe_responses.clone();
    let reader_cancelled = Arc::new(AtomicBool::new(false));
    let reader_cancelled_for_reader = reader_cancelled.clone();
    let reader_event_sender = event_sender.clone();
    let (reader_sender, reader_receiver) = mpsc::channel();
    let reader_thread =
        thread::Builder::new().name("startup-benchmark-pty-reader".into()).spawn(move || {
            let result = read_pty(
                reader,
                PtyReadContext {
                    writer: writer_for_reader,
                    marker: marker_bytes,
                    sender: reader_event_sender,
                    diagnostic: diagnostic_for_reader,
                    probe_queries: probe_queries_for_reader,
                    probe_responses: probe_responses_for_reader,
                    reader_cancelled: reader_cancelled_for_reader,
                },
            );
            let _ = reader_sender.send(result);
        })?;
    let (status_sender, status_receiver) = mpsc::channel();
    let status_event_sender = event_sender;
    let status_thread =
        thread::Builder::new().name("startup-benchmark-pty-wait".into()).spawn(move || {
            let status = child.wait();
            let _ = status_sender.send(status);
            let _ = status_event_sender.send(PtyEvent::Exited);
        })?;
    let mut runtime = PtyRuntime {
        killer,
        process_tree,
        master: Some(master),
        writer: Some(writer),
        status_receiver,
        status_thread: Some(status_thread),
        reader_receiver,
        reader_thread: Some(reader_thread),
        diagnostic,
        probe_queries,
        probe_responses,
        reader_cancelled,
        cleanup,
    };
    if let Err(error) = control.arm(deadline) {
        return runtime.fail(error.context("arm interactive product supervisor"));
    }

    let event_timeout = match deadline.timeout(EVENT_TIMEOUT, "waiting for the PTY render event") {
        Ok(timeout) => timeout,
        Err(error) => return runtime.fail(error),
    };
    let observed_at = match event_receiver.recv_timeout(event_timeout) {
        Ok(PtyEvent::Marker(at)) => at,
        Ok(PtyEvent::Ended) => {
            let (_, reader, _) = runtime.finish(false, SuiteDeadline::unbounded())?;
            return Err(runtime.failure_with_diagnostic(anyhow!(
                "PTY ended before render marker: {}",
                String::from_utf8_lossy(&reader.output)
            )));
        }
        Ok(PtyEvent::Failed(error)) => {
            return runtime.fail(anyhow!("PTY reader failed before render marker: {error}"));
        }
        Ok(PtyEvent::Exited) => {
            let failure = anyhow!("interactive process exited before render marker");
            return match runtime.finish(false, SuiteDeadline::unbounded()) {
                Ok((status, reader, _)) => {
                    Err(runtime.failure_with_diagnostic(failure.context(format!(
                        "status {status}; PTY output: {}",
                        String::from_utf8_lossy(&reader.output)
                    ))))
                }
                Err(cleanup) => Err(runtime.failure_with_diagnostic(
                    failure.context(format!("PTY cleanup also failed: {cleanup:#}")),
                )),
            };
        }
        Err(error) => {
            return runtime.fail(anyhow!("render marker deadline expired: {error}"));
        }
    };
    let validation = if let Some(socket) = ping_socket {
        let validation_started = Instant::now();
        if let Err(error) = assert_ping(common, socket, deadline) {
            return runtime.fail(error.context("validate interactive process socket readiness"));
        }
        PhaseMetric::completed(validation_started.elapsed())?
    } else {
        PhaseMetric::default()
    };
    let detach = runtime.write(b"\x02d");
    if let Err(error) = detach {
        return runtime.fail(error.context("detach interactive benchmark process"));
    }
    let (status, reader, completion) = runtime.finish(false, deadline)?;
    if !status.success() {
        bail!(
            "interactive process exited with {status}: {}",
            String::from_utf8_lossy(&reader.output)
        );
    }
    #[cfg(windows)]
    if !reader.probe_kinds.cpr || reader.probe_responses < 2 {
        bail!(
            "interactive process answered an invalid Windows terminal-probe set: {:?}",
            reader.probe_kinds
        );
    }
    #[cfg(not(windows))]
    if reader.probe_responses < 4 {
        bail!(
            "interactive process answered {} terminal probes, expected at least 4",
            reader.probe_responses
        );
    }
    let measured_event = control.measured_duration(observed_at)?;
    Ok(RunResult {
        duration_ns: duration_ns(measured_event)?,
        evidence: Evidence {
            render_markers: 1,
            frame_completions: 1,
            process_exits: 1,
            supervisor_ready_events: 1,
            supervisor_t0_records: 1,
            containment_cleanups: 1,
            terminal_probe_responses: reader.probe_responses,
            terminal_cpr_responses: usize::from(reader.probe_kinds.cpr),
            terminal_foreground_color_responses: usize::from(reader.probe_kinds.foreground),
            terminal_background_color_responses: usize::from(reader.probe_kinds.background),
            terminal_window_pixel_responses: usize::from(reader.probe_kinds.window),
            terminal_kitty_responses: usize::from(reader.probe_kinds.kitty),
            terminal_da1_responses: usize::from(reader.probe_kinds.da1),
            terminal_keyboard_responses: usize::from(reader.probe_kinds.keyboard),
            socket_rpcs: usize::from(ping_socket.is_some()),
            frame_cursor_shows: if reader.frame_completion == Some(FrameCompletion::Show) {
                1
            } else {
                0
            },
            frame_cursor_hides: if reader.frame_completion == Some(FrameCompletion::Hide) {
                1
            } else {
                0
            },
            frame_cursor_positions: if reader.frame_completion == Some(FrameCompletion::Position) {
                1
            } else {
                0
            },
            ..Evidence::default()
        },
        phases: RunPhases {
            measured_event: PhaseMetric::completed(measured_event)?,
            validation,
            process_exit: PhaseMetric::completed(completion.process_exit)?,
            thread_join: PhaseMetric::completed(completion.thread_join)?,
            ..RunPhases::default()
        },
    })
}

fn run_headless(common: &mut Common, deadline: SuiteDeadline) -> Result<RunResult> {
    let (run, id) = common.next_path()?;
    let socket = run.join("mux.sock");
    let session = format!("{}-{id:020}", common.session_name("headless"));
    let args = headless_args(&session, &socket, None);
    let mut server =
        RunningHeadless::start(common, args, &socket, common.wrap_measured_process, deadline)?;
    server.wait_ready(deadline)?;
    let validation_started = Instant::now();
    let observed_at = assert_ping(common, &socket, deadline)?;
    let validation = validation_started.elapsed();
    let duration = server.measured_duration(observed_at)?;
    let completion = server.shutdown_and_wait(common, deadline)?;
    Ok(RunResult {
        duration_ns: duration_ns(duration)?,
        evidence: Evidence {
            readiness_lines: 1,
            socket_rpcs: 2,
            process_exits: 1,
            supervisor_ready_events: 1,
            supervisor_t0_records: 1,
            containment_cleanups: 1,
            ..Evidence::default()
        },
        phases: RunPhases {
            measured_event: PhaseMetric::completed(duration)?,
            validation: PhaseMetric::completed(validation)?,
            process_exit: PhaseMetric::completed(completion.process_exit)?,
            thread_join: PhaseMetric::completed(completion.thread_join)?,
            ..RunPhases::default()
        },
    })
}

fn run_restored(
    common: &mut Common,
    state: &Path,
    terminal_id: &str,
    deadline: SuiteDeadline,
) -> Result<RunResult> {
    let (run, _) = common.next_path()?;
    let socket = run.join("mux.sock");
    let session = common.session_name("restored");
    let args = headless_args(&session, &socket, Some(state));
    let mut server =
        RunningHeadless::start(common, args, &socket, common.wrap_measured_process, deadline)?;
    server.wait_ready(deadline)?;
    let validation_started = Instant::now();
    let topology = json_cli(common, &socket, &["terminal", "list"], deadline)?;
    let observed_at = restored_topology_endpoint(&topology, terminal_id)?;
    let validation = validation_started.elapsed();
    let duration = server.measured_duration(observed_at)?;
    let completion = server.shutdown_and_wait(common, deadline)?;
    Ok(RunResult {
        duration_ns: duration_ns(duration)?,
        evidence: Evidence {
            readiness_lines: 1,
            socket_rpcs: 2,
            restored_topologies: 1,
            process_exits: 1,
            supervisor_ready_events: 1,
            supervisor_t0_records: 1,
            containment_cleanups: 1,
            ..Evidence::default()
        },
        phases: RunPhases {
            measured_event: PhaseMetric::completed(duration)?,
            validation: PhaseMetric::completed(validation)?,
            process_exit: PhaseMetric::completed(completion.process_exit)?,
            thread_join: PhaseMetric::completed(completion.thread_join)?,
            ..RunPhases::default()
        },
    })
}

fn run_incompatible(
    common: &mut Common,
    state: &Path,
    database: &Path,
    expected: &str,
    deadline: SuiteDeadline,
) -> Result<RunResult> {
    let (run, _) = common.next_path()?;
    let socket = run.join("mux.sock");
    let session = common.session_name("incompatible");
    let args = headless_args(&session, &socket, Some(state));
    let command = common.std_command(&args, common.wrap_measured_process)?;
    let captured = run_captured(command, deadline)?;
    if captured.status.success() {
        bail!("incompatible state unexpectedly started successfully");
    }
    let validation_started = Instant::now();
    let stderr = String::from_utf8_lossy(&captured.stderr);
    let expected = format!("cmux-tui: {expected}");
    validate_primary_diagnostic(&stderr, &expected)?;
    let connection = Connection::open(database)?;
    let stored: String =
        connection.query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| {
            row.get(0)
        })?;
    if stored != INCOMPATIBLE_SCHEMA.to_string() {
        bail!("schema rejection changed stored schema to {stored}");
    }
    let validation = validation_started.elapsed();
    Ok(RunResult {
        duration_ns: duration_ns(captured.duration)?,
        evidence: Evidence {
            schema_rejections: 1,
            process_exits: 1,
            supervisor_ready_events: 1,
            supervisor_t0_records: 1,
            containment_cleanups: 1,
            ..Evidence::default()
        },
        phases: RunPhases {
            measured_event: PhaseMetric::completed(captured.duration)?,
            validation: PhaseMetric::completed(validation)?,
            process_exit: PhaseMetric::completed(captured.duration)?,
            ..RunPhases::default()
        },
    })
}

fn validate_primary_diagnostic(stderr: &str, expected: &str) -> Result<()> {
    let primary_diagnostic = stderr.lines().next().unwrap_or_default();
    if primary_diagnostic != expected {
        bail!(
            "incompatible state primary diagnostic was {primary_diagnostic:?}, expected {expected:?}: {stderr}"
        );
    }
    Ok(())
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
    process_tree: CapturedProcessTree,
    socket: PathBuf,
    launch_control: LaunchControl,
    events: mpsc::Receiver<StreamEvent>,
    reader_receiver: mpsc::Receiver<io::Result<Vec<u8>>>,
    reader: Option<thread::JoinHandle<()>>,
    reader_cancelled: Arc<AtomicBool>,
    cleanup: SupervisorCleanup,
}

struct CompletionTimings {
    process_exit: Duration,
    thread_join: Duration,
}

impl RunningHeadless {
    fn start(
        common: &Common,
        args: Vec<String>,
        socket: &Path,
        wrapped: bool,
        deadline: SuiteDeadline,
    ) -> Result<Self> {
        deadline.ensure("spawning a headless startup process")?;
        let prepared = common.std_command(&args, wrapped)?;
        let PreparedStdCommand { mut command, control, cleanup } = prepared;
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            command.process_group(0);
        }
        command.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::piped());
        let mut child = command.spawn()?;
        let process_tree = CapturedProcessTree::new(child.id());
        let stderr = child.stderr.take().context("headless stderr pipe missing")?;
        let needle =
            format!("cmux-tui: headless, control socket at {}", socket.display()).into_bytes();
        let (sender, events) = mpsc::channel();
        let (reader_sender, reader_receiver) = mpsc::channel();
        let reader_cancelled = Arc::new(AtomicBool::new(false));
        let reader_cancelled_for_thread = reader_cancelled.clone();
        let reader =
            match thread::Builder::new().name("startup-benchmark-stderr".into()).spawn(move || {
                let result = read_until_event(stderr, needle, sender, reader_cancelled_for_thread);
                let _ = reader_sender.send(result);
            }) {
                Ok(reader) => reader,
                Err(error) => {
                    let tree_error = process_tree.terminate().err();
                    if tree_error.is_some() {
                        let _ = child.kill();
                    }
                    let _ = child.wait_timeout(PROCESS_TIMEOUT);
                    return Err(error).context("spawn headless stderr reader");
                }
            };
        let mut running = Self {
            child: Some(child),
            process_tree,
            socket: socket.to_path_buf(),
            launch_control: control,
            events,
            reader_receiver,
            reader: Some(reader),
            reader_cancelled,
            cleanup,
        };
        if let Err(error) = running.launch_control.arm(deadline) {
            return running.fail(error.context("arm headless product supervisor"));
        }
        Ok(running)
    }

    fn wait_ready(&mut self, deadline: SuiteDeadline) -> Result<u64> {
        let timeout = match deadline.timeout(EVENT_TIMEOUT, "waiting for headless readiness") {
            Ok(timeout) => timeout,
            Err(error) => return self.fail(error),
        };
        match self.events.recv_timeout(timeout) {
            Ok(StreamEvent::Found(at)) => Ok(at),
            Ok(StreamEvent::Ended) => {
                self.fail(anyhow!("headless process exited before readiness"))
            }
            Ok(StreamEvent::Failed(error)) => {
                self.fail(anyhow!("headless stderr failed before readiness: {error}"))
            }
            Err(error) => self.fail(anyhow!("headless readiness deadline expired: {error}")),
        }
    }

    fn measured_duration(&self, event_ns: u64) -> Result<Duration> {
        self.launch_control.measured_duration(event_ns)
    }

    fn shutdown_and_wait(
        &mut self,
        common: &Common,
        deadline: SuiteDeadline,
    ) -> Result<CompletionTimings> {
        let exit_started = Instant::now();
        if let Err(error) =
            json_cli(common, &self.socket, &["session", "current", "shutdown"], deadline)
        {
            return self.fail(error.context("request headless shutdown"));
        }
        let status = match self.wait_for_exit(deadline) {
            Ok(status) => status,
            Err(error) => return self.fail(error),
        };
        let process_exit = exit_started.elapsed();
        self.child = None;
        let join_started = Instant::now();
        let output = self.finish_reader(deadline)?;
        self.cleanup.finish()?;
        let thread_join = join_started.elapsed();
        if !status.success() {
            bail!("headless process exited with {status}: {}", String::from_utf8_lossy(&output));
        }
        Ok(CompletionTimings { process_exit, thread_join })
    }

    fn wait_for_exit(&mut self, deadline: SuiteDeadline) -> Result<ExitStatus> {
        let timeout = deadline.timeout(PROCESS_TIMEOUT, "waiting for headless process exit")?;
        let child = self.child.as_mut().context("headless process already reaped")?;
        if let Some(status) = child.wait_timeout(timeout)? {
            return Ok(status);
        }
        deadline.ensure("waiting for headless process exit")?;
        bail!("headless process exceeded {timeout:?}")
    }

    fn cancel_reader(&self) -> io::Result<()> {
        let reader = self
            .reader
            .as_ref()
            .ok_or_else(|| io::Error::other("headless stderr reader already joined"))?;
        cancel_blocking_reader(reader, &self.reader_cancelled)
    }

    fn finish_reader(&mut self, deadline: SuiteDeadline) -> Result<Vec<u8>> {
        let mut wait_error = None;
        let timeout = match deadline.timeout(PROCESS_TIMEOUT, "waiting for headless stderr") {
            Ok(timeout) => timeout,
            Err(error) => {
                wait_error = Some(error);
                Duration::ZERO
            }
        };
        let result = match self.reader_receiver.recv_timeout(timeout) {
            Ok(result) => result,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if wait_error.is_none() {
                    wait_error = Some(anyhow!("headless stderr reader exceeded {timeout:?}"));
                }
                let tree_error = self.process_tree.terminate_after_exit().err();
                let cancel_error = self.cancel_reader().err();
                let recovery = self
                    .reader_receiver
                    .recv_timeout(PROCESS_TIMEOUT)
                    .context("wait for headless stderr after cancellation");
                match recovery {
                    Ok(result) => result,
                    Err(recovery) => {
                        let mut error = recovery;
                        if let Some(tree_error) = tree_error {
                            error = error.context(format!(
                                "process-tree termination also failed: {tree_error}"
                            ));
                        }
                        if let Some(cancel_error) = cancel_error {
                            error = error.context(format!(
                                "stderr-reader cancellation also failed: {cancel_error}"
                            ));
                        }
                        return Err(error);
                    }
                }
            }
            Err(error) => return Err(error).context("wait for headless stderr completion"),
        };
        self.reader
            .take()
            .context("headless stderr reader already joined")?
            .join()
            .map_err(|_| anyhow!("headless stderr reader panicked"))?;
        let output = result.context("read headless stderr")?;
        if let Some(error) = wait_error {
            return Err(
                error.context(format!("headless stderr: {}", String::from_utf8_lossy(&output)))
            );
        }
        Ok(output)
    }

    fn terminate_and_read(&mut self) -> Result<Vec<u8>> {
        let mut process_error = None;
        if let Some(child) = self.child.as_mut() {
            let tree_error = self.process_tree.terminate().err();
            let kill_error = if tree_error.is_some() { child.kill().err() } else { None };
            let status = child.wait_timeout(PROCESS_TIMEOUT)?;
            if status.is_none() || tree_error.is_some() || kill_error.is_some() {
                let mut error = status
                    .map(|status| anyhow!("terminated headless process exited with {status}"))
                    .unwrap_or_else(|| anyhow!("headless process did not exit after termination"));
                if let Some(tree_error) = tree_error {
                    error = error
                        .context(format!("process-tree termination also failed: {tree_error}"));
                }
                if let Some(kill_error) = kill_error {
                    error = error.context(format!("direct child kill also failed: {kill_error}"));
                }
                process_error = Some(error);
            }
        }
        self.child = None;
        self.cancel_reader()?;
        let output = self.finish_reader(SuiteDeadline::unbounded())?;
        self.cleanup.finish()?;
        if let Some(error) = process_error {
            return Err(
                error.context(format!("headless stderr: {}", String::from_utf8_lossy(&output)))
            );
        }
        Ok(output)
    }

    fn fail<T>(&mut self, error: anyhow::Error) -> Result<T> {
        match self.terminate_and_read() {
            Ok(output) => {
                Err(error.context(format!("headless stderr: {}", String::from_utf8_lossy(&output))))
            }
            Err(cleanup) => {
                Err(error.context(format!("headless cleanup also failed: {cleanup:#}")))
            }
        }
    }
}

impl Drop for RunningHeadless {
    fn drop(&mut self) {
        if self.child.is_some() || self.reader.is_some() {
            let _ = self.terminate_and_read();
        }
    }
}

enum StreamEvent {
    Found(u64),
    Ended,
    Failed(String),
}

fn read_until_event(
    mut reader: impl Read,
    needle: Vec<u8>,
    sender: mpsc::Sender<StreamEvent>,
    cancelled: Arc<AtomicBool>,
) -> io::Result<Vec<u8>> {
    let mut output = VecDeque::new();
    let mut pending = Vec::new();
    let mut found = false;
    let mut buffer = [0_u8; 4096];
    loop {
        if cancelled.load(Ordering::Acquire) {
            return Ok(output.into_iter().collect());
        }
        match reader.read(&mut buffer) {
            Ok(0) => {
                if !found {
                    let _ = sender.send(StreamEvent::Ended);
                }
                return Ok(output.into_iter().collect());
            }
            Ok(read) => {
                append_bounded_tail(&mut output, &buffer[..read]);
                if !found {
                    pending.extend_from_slice(&buffer[..read]);
                    if contains(&pending, &needle) {
                        found = true;
                        match monotonic_ns() {
                            Ok(at) => {
                                let _ = sender.send(StreamEvent::Found(at));
                            }
                            Err(error) => {
                                let message = error.to_string();
                                let _ = sender.send(StreamEvent::Failed(message));
                                return Err(error);
                            }
                        }
                    } else {
                        retain_tail(&mut pending, needle.len().saturating_sub(1));
                    }
                }
            }
            Err(_) if cancelled.load(Ordering::Acquire) => {
                return Ok(output.into_iter().collect());
            }
            Err(error) => {
                let _ = sender.send(StreamEvent::Failed(error.to_string()));
                return Err(error);
            }
        }
    }
}

enum PtyEvent {
    Marker(u64),
    Ended,
    Failed(String),
    Exited,
}

struct PtyReadResult {
    output: Vec<u8>,
    probe_responses: usize,
    probe_kinds: ProbeKinds,
    frame_completion: Option<FrameCompletion>,
}

struct PtyRuntime {
    killer: Box<dyn cmux_pty::ChildKiller + Send + Sync>,
    process_tree: PtyProcessTree,
    master: Option<Box<dyn cmux_pty::MasterPty + Send>>,
    writer: Option<Arc<Mutex<Box<dyn Write + Send>>>>,
    status_receiver: mpsc::Receiver<io::Result<cmux_pty::ExitStatus>>,
    status_thread: Option<thread::JoinHandle<()>>,
    reader_receiver: mpsc::Receiver<io::Result<PtyReadResult>>,
    reader_thread: Option<thread::JoinHandle<()>>,
    diagnostic: Arc<Mutex<VecDeque<u8>>>,
    probe_queries: Arc<AtomicUsize>,
    probe_responses: Arc<AtomicUsize>,
    reader_cancelled: Arc<AtomicBool>,
    cleanup: SupervisorCleanup,
}

impl PtyRuntime {
    fn write(&self, bytes: &[u8]) -> Result<()> {
        let writer = self.writer.as_ref().context("PTY writer already closed")?;
        let mut writer = writer.lock().map_err(|_| anyhow!("PTY writer lock poisoned"))?;
        writer.write_all(bytes)?;
        writer.flush()?;
        Ok(())
    }

    fn terminate_tree(&mut self) -> io::Result<()> {
        self.process_tree.terminate(self.killer.as_mut())
    }

    fn failure_with_diagnostic(&self, error: anyhow::Error) -> anyhow::Error {
        let output = self
            .diagnostic
            .lock()
            .map(|output| {
                let output: Vec<u8> = output.iter().copied().collect();
                String::from_utf8_lossy(&output).into_owned()
            })
            .unwrap_or_else(|_| "<PTY diagnostic lock poisoned>".into());
        error.context(format!(
            "PTY failure snapshot: queries={} responses={} output={output:?}",
            self.probe_queries.load(Ordering::Relaxed),
            self.probe_responses.load(Ordering::Relaxed)
        ))
    }

    #[cfg(windows)]
    fn cancel_reader_io(&self) -> io::Result<()> {
        let reader = self
            .reader_thread
            .as_ref()
            .ok_or_else(|| io::Error::other("PTY reader thread already joined"))?;
        cancel_blocking_reader(reader, &self.reader_cancelled)
    }

    #[cfg(not(windows))]
    fn cancel_reader_io(&self) -> io::Result<()> {
        let reader = self
            .reader_thread
            .as_ref()
            .ok_or_else(|| io::Error::other("PTY reader thread already joined"))?;
        cancel_blocking_reader(reader, &self.reader_cancelled)
    }

    fn finish(
        &mut self,
        terminate: bool,
        deadline: SuiteDeadline,
    ) -> Result<(cmux_pty::ExitStatus, PtyReadResult, CompletionTimings)> {
        let result = self.finish_process(terminate, deadline);
        let cleanup = self.cleanup.finish();
        match (result, cleanup) {
            (Ok(value), Ok(())) => Ok(value),
            (Err(error), Ok(())) => Err(error),
            (Ok(_), Err(cleanup)) => Err(cleanup),
            (Err(error), Err(cleanup)) => {
                Err(error.context(format!("supervisor cleanup also failed: {cleanup:#}")))
            }
        }
    }

    fn finish_process(
        &mut self,
        terminate: bool,
        deadline: SuiteDeadline,
    ) -> Result<(cmux_pty::ExitStatus, PtyReadResult, CompletionTimings)> {
        // Close the harness writer before waiting. A full-tree termination then
        // closes every slave handle and makes reader completion observable.
        self.writer.take();
        let exit_started = Instant::now();
        let mut kill_error = if terminate { self.terminate_tree().err() } else { None };
        let mut tree_termination_attempted = terminate;
        let mut timed_out = false;
        let mut suite_error = None;
        let exit_timeout = match deadline.timeout(PROCESS_TIMEOUT, "waiting for PTY process exit") {
            Ok(timeout) => timeout,
            Err(error) => {
                suite_error = Some(error);
                Duration::ZERO
            }
        };
        let status = match self.status_receiver.recv_timeout(exit_timeout) {
            Ok(status) => status,
            Err(mpsc::RecvTimeoutError::Timeout) if !terminate => {
                timed_out = true;
                tree_termination_attempted = true;
                if let Err(error) = self.terminate_tree() {
                    kill_error = Some(error);
                }
                match self.status_receiver.recv_timeout(PROCESS_TIMEOUT) {
                    Ok(status) => status,
                    Err(error) => {
                        let error = anyhow!(error).context("reap interactive process after kill");
                        return if let Some(kill) = kill_error {
                            Err(error.context(format!("PTY kill also failed: {kill}")))
                        } else {
                            Err(error)
                        };
                    }
                }
            }
            Err(error) => {
                let error = anyhow!(error).context("wait for interactive process exit");
                return if let Some(kill) = kill_error {
                    Err(error.context(format!("PTY kill also failed: {kill}")))
                } else {
                    Err(error)
                };
            }
        };
        let process_exit = exit_started.elapsed();
        let join_started = Instant::now();
        self.status_thread
            .take()
            .context("PTY wait thread already joined")?
            .join()
            .map_err(|_| anyhow!("PTY wait thread panicked"))?;
        // On ConPTY, process exit alone does not close the readable stream.
        // The runtime owns and closes the master, then explicitly cancels the
        // reader's synchronous I/O after the child is reaped. The reader treats
        // that owner-requested cancellation as EOF.
        self.master.take().context("PTY master already closed")?;
        #[cfg(windows)]
        if let Err(error) = self.cancel_reader_io() {
            kill_error = Some(error);
        }
        let mut reader_timed_out = false;
        let reader_timeout =
            match deadline.timeout(PROCESS_TIMEOUT, "waiting for the PTY reader to finish") {
                Ok(timeout) => timeout,
                Err(error) => {
                    suite_error = Some(error);
                    Duration::ZERO
                }
            };
        let reader = match self.reader_receiver.recv_timeout(reader_timeout) {
            Ok(reader) => reader,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                reader_timed_out = true;
                if !tree_termination_attempted && let Err(error) = self.terminate_tree() {
                    kill_error = Some(error);
                }
                if let Err(error) = self.cancel_reader_io() {
                    kill_error = Some(error);
                }
                self.reader_receiver
                    .recv_timeout(PROCESS_TIMEOUT)
                    .context("wait for PTY reader after full-tree termination")?
            }
            Err(error) => return Err(error).context("wait for PTY reader completion"),
        };
        self.reader_thread
            .take()
            .context("PTY reader thread already joined")?
            .join()
            .map_err(|_| anyhow!("PTY reader panicked"))?;
        let reader = reader.context("read PTY output")?;
        let thread_join = join_started.elapsed();
        if let Some(error) = kill_error {
            return Err(error).context("kill interactive process during cleanup");
        }
        if let Some(error) = suite_error {
            return Err(error);
        }
        if timed_out {
            bail!("interactive process exceeded {exit_timeout:?} after detach and was killed");
        }
        if reader_timed_out {
            bail!("PTY reader exceeded {PROCESS_TIMEOUT:?} and required full-tree termination");
        }
        Ok((
            status.context("wait for interactive process")?,
            reader,
            CompletionTimings { process_exit, thread_join },
        ))
    }

    fn fail<T>(&mut self, error: anyhow::Error) -> Result<T> {
        let cleanup = self.finish(true, SuiteDeadline::unbounded());
        let error = match cleanup {
            Ok(_) => error,
            Err(cleanup) => error.context(format!("PTY cleanup also failed: {cleanup:#}")),
        };
        Err(self.failure_with_diagnostic(error))
    }
}

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    #[link_name = "CancelSynchronousIo"]
    fn cancel_synchronous_io(thread: std::os::windows::io::RawHandle) -> i32;
}

#[cfg(windows)]
fn cancel_blocking_reader(
    thread: &thread::JoinHandle<()>,
    cancelled: &AtomicBool,
) -> io::Result<()> {
    use std::os::windows::io::AsRawHandle;

    cancelled.store(true, Ordering::Release);
    // SAFETY: the live JoinHandle owns the exact reader thread. The call only
    // cancels synchronous I/O issued by that thread.
    let result = unsafe { cancel_synchronous_io(thread.as_raw_handle()) };
    if result != 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    const ERROR_NOT_FOUND: i32 = 1168;
    if error.raw_os_error() == Some(ERROR_NOT_FOUND) { Ok(()) } else { Err(error) }
}

#[cfg(not(windows))]
fn cancel_blocking_reader(
    _thread: &thread::JoinHandle<()>,
    cancelled: &AtomicBool,
) -> io::Result<()> {
    cancelled.store(true, Ordering::Release);
    Ok(())
}

#[derive(Debug, Clone, Copy)]
struct PtyProcessTree {
    #[cfg(windows)]
    child_id: Option<u32>,
    #[cfg(unix)]
    process_group: Option<libc::pid_t>,
}

impl PtyProcessTree {
    fn from_handles(
        _master: &(dyn cmux_pty::MasterPty + Send),
        _child: &(dyn cmux_pty::Child + Send + Sync),
    ) -> Self {
        Self {
            #[cfg(windows)]
            child_id: _child.process_id(),
            #[cfg(unix)]
            process_group: _master.process_group_leader(),
        }
    }

    fn terminate(self, killer: &mut (dyn cmux_pty::ChildKiller + Send + Sync)) -> io::Result<()> {
        #[cfg(unix)]
        if let Some(group) = self.process_group.filter(|group| *group > 0) {
            // SAFETY: a negative, validated process-group id targets every
            // process in the launched PTY session and no process outside it.
            if unsafe { libc::kill(-group, libc::SIGKILL) } == 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ESRCH) {
                return Ok(());
            }
            return Err(error);
        }

        #[cfg(windows)]
        if let Some(child_id) = self.child_id {
            if terminate_windows_process_tree(child_id).is_ok() {
                return Ok(());
            }
        }

        killer.kill()
    }
}

#[cfg(windows)]
fn terminate_windows_process_tree(child_id: u32) -> io::Result<()> {
    let mut child = Command::new("taskkill")
        .args(["/PID", &child_id.to_string(), "/T", "/F"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    match child.wait_timeout(PROCESS_TIMEOUT)? {
        Some(status) if status.success() => Ok(()),
        Some(status) => Err(io::Error::other(format!("taskkill exited with {status}"))),
        None => {
            child.kill()?;
            let status = child
                .wait_timeout(PROCESS_TIMEOUT)?
                .ok_or_else(|| io::Error::other("taskkill did not exit after direct kill"))?;
            Err(io::Error::other(format!(
                "taskkill exceeded {PROCESS_TIMEOUT:?} and was killed with {status}"
            )))
        }
    }
}

struct PtyReadContext {
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    marker: Vec<u8>,
    sender: mpsc::Sender<PtyEvent>,
    diagnostic: Arc<Mutex<VecDeque<u8>>>,
    probe_queries: Arc<AtomicUsize>,
    probe_responses: Arc<AtomicUsize>,
    reader_cancelled: Arc<AtomicBool>,
}

fn read_pty(
    mut reader: Box<dyn Read + Send>,
    context: PtyReadContext,
) -> io::Result<PtyReadResult> {
    let PtyReadContext {
        writer,
        marker,
        sender,
        diagnostic,
        probe_queries,
        probe_responses,
        reader_cancelled,
    } = context;
    let mut output = VecDeque::new();
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
                    output: output.into_iter().collect(),
                    probe_responses: probes.responses,
                    probe_kinds: probes.kinds(),
                    frame_completion: frame_marker.completion,
                });
            }
            Ok(read) => {
                append_bounded_tail(&mut output, &buffer[..read]);
                {
                    let mut diagnostic = diagnostic
                        .lock()
                        .map_err(|_| io::Error::other("PTY diagnostic lock poisoned"))?;
                    append_bounded_tail(&mut diagnostic, &buffer[..read]);
                }
                let responses = probes.observe(&buffer[..read]);
                probe_queries.store(probes.responses, Ordering::Relaxed);
                for response in responses {
                    let mut writer = writer
                        .lock()
                        .map_err(|_| io::Error::other("terminal response writer lock poisoned"))?;
                    writer.write_all(response)?;
                    writer.flush()?;
                    probe_responses.fetch_add(1, Ordering::Relaxed);
                }
                if !frame_seen && frame_marker.observe(&buffer[..read]).is_some() {
                    frame_seen = true;
                    match monotonic_ns() {
                        Ok(at) => {
                            let _ = sender.send(PtyEvent::Marker(at));
                        }
                        Err(error) => {
                            let message = error.to_string();
                            let _ = sender.send(PtyEvent::Failed(message));
                            return Err(error);
                        }
                    }
                }
            }
            Err(error) => {
                if reader_cancelled.load(Ordering::Acquire) {
                    return Ok(PtyReadResult {
                        output: output.into_iter().collect(),
                        probe_responses: probes.responses,
                        probe_kinds: probes.kinds(),
                        frame_completion: frame_marker.completion,
                    });
                }
                let _ = sender.send(PtyEvent::Failed(error.to_string()));
                return Err(error);
            }
        }
    }
}

struct FrameMarkerTracker {
    marker: Vec<u8>,
    pending: Vec<u8>,
    marker_seen: bool,
    completion: Option<FrameCompletion>,
}

impl FrameMarkerTracker {
    fn new(marker: Vec<u8>) -> Self {
        Self { marker, pending: Vec::new(), marker_seen: false, completion: None }
    }

    fn observe(&mut self, bytes: &[u8]) -> Option<FrameCompletion> {
        if self.completion.is_some() {
            return self.completion;
        }
        self.pending.extend_from_slice(bytes);
        if !self.marker_seen {
            let Some(marker) = find(&self.pending, &self.marker) else {
                retain_tail(&mut self.pending, self.marker.len().saturating_sub(1));
                return None;
            };
            self.pending.drain(..marker + self.marker.len());
            self.marker_seen = true;
        }
        self.completion = first_frame_completion(&self.pending);
        if self.completion.is_none() {
            retain_tail(&mut self.pending, MAX_FRAME_COMPLETION_ESCAPE_LEN - 1);
        }
        self.completion
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum FrameCompletion {
    Show,
    Hide,
    Position,
}

const MAX_FRAME_COMPLETION_ESCAPE_LEN: usize = b"\x1b[65535;65535H".len();

fn first_frame_completion(bytes: &[u8]) -> Option<FrameCompletion> {
    [
        find(bytes, b"\x1b[?25h").map(|index| (index, FrameCompletion::Show)),
        find(bytes, b"\x1b[?25l").map(|index| (index, FrameCompletion::Hide)),
        find_cursor_position(bytes).map(|index| (index, FrameCompletion::Position)),
    ]
    .into_iter()
    .flatten()
    .min_by_key(|(index, _)| *index)
    .map(|(_, completion)| completion)
}

fn find_cursor_position(bytes: &[u8]) -> Option<usize> {
    for start in 0..bytes.len().saturating_sub(1) {
        if bytes.get(start..start + 2) != Some(&b"\x1b["[..]) {
            continue;
        }
        let mut index = start + 2;
        let row_start = index;
        while bytes.get(index).is_some_and(u8::is_ascii_digit) {
            index += 1;
        }
        if index == row_start || index - row_start > 5 || bytes.get(index) != Some(&b';') {
            continue;
        }
        index += 1;
        let column_start = index;
        while bytes.get(index).is_some_and(u8::is_ascii_digit) {
            index += 1;
        }
        if index == column_start || index - column_start > 5 || bytes.get(index) != Some(&b'H') {
            continue;
        }
        return Some(start);
    }
    None
}

#[derive(Default)]
struct ProbeTracker {
    cpr: bool,
    foreground: bool,
    background: bool,
    window: bool,
    kitty: bool,
    da1: bool,
    keyboard: bool,
    responses: usize,
    pending: Vec<u8>,
}

#[derive(Debug, Clone, Copy)]
struct ProbeKinds {
    cpr: bool,
    foreground: bool,
    background: bool,
    window: bool,
    kitty: bool,
    da1: bool,
    keyboard: bool,
}

impl ProbeTracker {
    fn observe(&mut self, bytes: &[u8]) -> Vec<&'static [u8]> {
        self.pending.extend_from_slice(bytes);
        let probes: [(&[u8], &[u8], &mut bool); 7] = [
            (b"\x1b[6n", b"\x1b[1;1R", &mut self.cpr),
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
        let overlap = probes.iter().map(|(request, _, _)| request.len()).max().unwrap_or(1) - 1;
        let mut responses = Vec::new();
        for (request, response, sent) in probes {
            if !*sent && contains(&self.pending, request) {
                *sent = true;
                self.responses += 1;
                responses.push(response);
            }
        }
        retain_tail(&mut self.pending, overlap);
        responses
    }

    fn kinds(&self) -> ProbeKinds {
        ProbeKinds {
            cpr: self.cpr,
            foreground: self.foreground,
            background: self.background,
            window: self.window,
            kitty: self.kitty,
            da1: self.da1,
            keyboard: self.keyboard,
        }
    }
}

fn retain_tail(bytes: &mut Vec<u8>, keep: usize) {
    if bytes.len() > keep {
        bytes.drain(..bytes.len() - keep);
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
    completed_at_ns: u64,
}

fn run_captured(prepared: PreparedStdCommand, deadline: SuiteDeadline) -> Result<Captured> {
    run_captured_inner(prepared.command, Some(prepared.control), Some(prepared.cleanup), deadline)
}

fn run_trusted_captured(command: Command, deadline: SuiteDeadline) -> Result<Captured> {
    run_captured_inner(command, None, None, deadline)
}

fn run_captured_inner(
    command: Command,
    control: Option<LaunchControl>,
    mut cleanup: Option<SupervisorCleanup>,
    deadline: SuiteDeadline,
) -> Result<Captured> {
    let result = run_captured_process(command, control, deadline);
    let cleanup = cleanup.as_mut().map(SupervisorCleanup::finish).transpose();
    match (result, cleanup) {
        (Ok(value), Ok(_)) => Ok(value),
        (Err(error), Ok(_)) => Err(error),
        (Ok(_), Err(cleanup)) => Err(cleanup),
        (Err(error), Err(cleanup)) => {
            Err(error.context(format!("supervisor cleanup also failed: {cleanup:#}")))
        }
    }
}

fn run_captured_process(
    mut command: Command,
    mut control: Option<LaunchControl>,
    deadline: SuiteDeadline,
) -> Result<Captured> {
    deadline.ensure("spawning a captured process")?;
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    let trusted_started = Instant::now();
    let mut child = command.spawn()?;
    let process_tree = CapturedProcessTree::new(child.id());
    let (capture_sender, capture_receiver) = mpsc::channel();
    let stdout_pipe = child.stdout.take().context("captured command omitted stdout pipe")?;
    let stderr_pipe = child.stderr.take().context("captured command omitted stderr pipe")?;
    let mut stdout = match CaptureReader::spawn(
        stdout_pipe,
        "startup-benchmark-stdout-reader",
        CaptureStream::Stdout,
        capture_sender.clone(),
    ) {
        Ok(reader) => reader,
        Err(error) => {
            let _ = process_tree.terminate();
            let _ = child.kill();
            let _ = child.wait_timeout(PROCESS_TIMEOUT);
            return Err(error).context("spawn captured stdout reader");
        }
    };
    let mut stderr = match CaptureReader::spawn(
        stderr_pipe,
        "startup-benchmark-stderr-reader",
        CaptureStream::Stderr,
        capture_sender,
    ) {
        Ok(reader) => reader,
        Err(error) => {
            let _ = process_tree.terminate();
            let _ = child.kill();
            let _ = child.wait_timeout(PROCESS_TIMEOUT);
            let _ = stdout.cancel();
            if capture_receiver.recv_timeout(PROCESS_TIMEOUT).is_ok() {
                let _ = stdout.join();
            }
            return Err(error).context("spawn captured stderr reader");
        }
    };
    if let Some(control) = control.as_mut()
        && let Err(error) = control.arm(deadline)
    {
        let mut error = error.context("arm captured product supervisor");
        if let Err(terminate) = process_tree.terminate() {
            if let Err(kill) = child.kill() {
                error = error.context(format!(
                    "process-tree termination failed: {terminate}; child kill failed: {kill}"
                ));
            } else {
                error = error.context(format!("process-tree termination failed: {terminate}"));
            }
        }
        match child.wait_timeout(PROCESS_TIMEOUT) {
            Ok(Some(_)) => {}
            Ok(None) => error = error.context("captured supervisor did not exit after termination"),
            Err(wait) => error = error.context(format!("reap captured supervisor: {wait}")),
        }
        if let Err(cancel) = stdout.cancel() {
            error = error.context(format!("cancel captured stdout reader: {cancel}"));
        }
        if let Err(cancel) = stderr.cancel() {
            error = error.context(format!("cancel captured stderr reader: {cancel}"));
        }
        let mut stdout_result = None;
        let mut stderr_result = None;
        if let Err(capture) = collect_capture_results(
            &capture_receiver,
            &mut stdout_result,
            &mut stderr_result,
            Instant::now() + PROCESS_TIMEOUT,
        ) {
            error = error.context(format!("collect captured supervisor diagnostics: {capture:#}"));
        }
        if let Err(join) = stdout.join() {
            error = error.context(format!("join captured stdout reader: {join:#}"));
        }
        if let Err(join) = stderr.join() {
            error = error.context(format!("join captured stderr reader: {join:#}"));
        }
        match stdout_result {
            Some(Ok(stdout)) if !stdout.is_empty() => {
                error = error.context(format!(
                    "captured supervisor stdout: {}",
                    String::from_utf8_lossy(&stdout)
                ));
            }
            Some(Err(stdout)) => {
                error = error.context(format!("read captured supervisor stdout: {stdout}"));
            }
            _ => {}
        }
        match stderr_result {
            Some(Ok(stderr)) if !stderr.is_empty() => {
                error = error.context(format!(
                    "captured supervisor stderr: {}",
                    String::from_utf8_lossy(&stderr)
                ));
            }
            Some(Err(stderr)) => {
                error = error.context(format!("read captured supervisor stderr: {stderr}"));
            }
            _ => {}
        }
        return Err(error);
    }
    let mut lifecycle_error = None;
    let mut status = None;
    let process_timeout = match deadline.timeout(PROCESS_TIMEOUT, "waiting for captured process") {
        Ok(timeout) => timeout,
        Err(error) => {
            lifecycle_error = Some(error);
            Duration::ZERO
        }
    };
    let initial_status = match child.wait_timeout(process_timeout) {
        Ok(status) => status,
        Err(error) => {
            record_lifecycle_error(
                &mut lifecycle_error,
                anyhow!(error).context("wait for captured process"),
            );
            None
        }
    };
    let event_ns = monotonic_ns()?;
    if let Some(completed) = initial_status {
        status = Some(completed);
    } else {
        let tree_error = process_tree.terminate().err();
        let kill_error = if tree_error.is_some() { child.kill().err() } else { None };
        let recovery = child.wait_timeout(PROCESS_TIMEOUT);
        match recovery {
            Ok(recovered) => status = recovered,
            Err(error) => record_lifecycle_error(
                &mut lifecycle_error,
                anyhow!(error).context("reap captured process after termination"),
            ),
        }
        let mut error = lifecycle_error.take().unwrap_or_else(|| {
            deadline.ensure("waiting for captured process").err().unwrap_or_else(|| {
                status
                    .as_ref()
                    .map(|status| {
                        anyhow!("process exceeded {process_timeout:?} and was killed with {status}")
                    })
                    .unwrap_or_else(|| {
                        anyhow!(
                            "process exceeded {process_timeout:?} and did not exit after termination"
                        )
                    })
            })
        });
        if let Some(tree_error) = tree_error {
            error = error.context(format!("process-tree termination also failed: {tree_error}"));
        }
        if let Some(kill_error) = kill_error {
            error = error.context(format!("direct child kill also failed: {kill_error}"));
        }
        lifecycle_error = Some(error);
    }
    let duration = match &control {
        Some(control) => control.measured_duration(event_ns)?,
        None => trusted_started.elapsed(),
    };
    let mut stdout_result = None;
    let mut stderr_result = None;
    let capture_deadline =
        match deadline.instant(PROCESS_TIMEOUT, "waiting for captured process output readers") {
            Ok(deadline) => deadline,
            Err(error) => {
                record_lifecycle_error(&mut lifecycle_error, error);
                Instant::now()
            }
        };
    let capture = collect_capture_results(
        &capture_receiver,
        &mut stdout_result,
        &mut stderr_result,
        capture_deadline,
    );
    if let Err(error) = capture {
        let tree_error = process_tree.terminate_after_exit().err();
        let stdout_cancel = stdout.cancel().err();
        let stderr_cancel = stderr.cancel().err();
        let recovery = collect_capture_results(
            &capture_receiver,
            &mut stdout_result,
            &mut stderr_result,
            Instant::now() + PROCESS_TIMEOUT,
        );
        let mut error = error.context("captured output did not complete after child exit");
        if let Some(tree_error) = tree_error {
            error = error.context(format!("process-tree termination also failed: {tree_error}"));
        }
        if let Some(cancel) = stdout_cancel.or(stderr_cancel) {
            error = error.context(format!("capture-reader cancellation also failed: {cancel}"));
        }
        if let Err(recovery) = recovery {
            error = error.context(format!("capture-reader recovery also failed: {recovery:#}"));
            return Err(error);
        }
        record_lifecycle_error(&mut lifecycle_error, error);
    }
    let stdout_join = stdout.join();
    let stderr_join = stderr.join();
    if let Err(join) = stdout_join.and(stderr_join) {
        return Err(join).context("join captured output readers");
    }
    if let Some(error) = lifecycle_error {
        return Err(error);
    }
    let status = status.context("captured process returned no exit status")?;
    let stdout = stdout_result.context("stdout reader returned no result")??;
    let stderr = stderr_result.context("stderr reader returned no result")??;
    Ok(Captured { status, stdout, stderr, duration, completed_at_ns: event_ns })
}

fn record_lifecycle_error(current: &mut Option<anyhow::Error>, error: anyhow::Error) {
    *current = Some(match current.take() {
        Some(current) => current.context(format!("additional lifecycle failure: {error:#}")),
        None => error,
    });
}

#[derive(Clone, Copy)]
enum CaptureStream {
    Stdout,
    Stderr,
}

struct CaptureEvent {
    stream: CaptureStream,
    result: io::Result<Vec<u8>>,
}

fn collect_capture_results(
    receiver: &mpsc::Receiver<CaptureEvent>,
    stdout: &mut Option<io::Result<Vec<u8>>>,
    stderr: &mut Option<io::Result<Vec<u8>>>,
    deadline: Instant,
) -> Result<()> {
    while stdout.is_none() || stderr.is_none() {
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .context("captured reader deadline expired")?;
        let event =
            receiver.recv_timeout(remaining).context("wait for captured reader completion")?;
        let slot = match event.stream {
            CaptureStream::Stdout => &mut *stdout,
            CaptureStream::Stderr => &mut *stderr,
        };
        if slot.replace(event.result).is_some() {
            bail!("captured reader reported completion twice");
        }
    }
    Ok(())
}

struct CaptureReader {
    thread: Option<thread::JoinHandle<()>>,
    cancelled: Arc<AtomicBool>,
}

impl CaptureReader {
    fn spawn(
        reader: impl Read + Send + 'static,
        name: &str,
        stream: CaptureStream,
        sender: mpsc::Sender<CaptureEvent>,
    ) -> Result<Self> {
        let cancelled = Arc::new(AtomicBool::new(false));
        let cancelled_for_reader = cancelled.clone();
        let thread = thread::Builder::new().name(name.into()).spawn(move || {
            let result = read_bounded_stream(reader, cancelled_for_reader);
            let _ = sender.send(CaptureEvent { stream, result });
        })?;
        Ok(Self { thread: Some(thread), cancelled })
    }

    #[cfg(windows)]
    fn cancel(&self) -> io::Result<()> {
        let thread = self
            .thread
            .as_ref()
            .ok_or_else(|| io::Error::other("capture reader thread already joined"))?;
        cancel_blocking_reader(thread, &self.cancelled)
    }

    #[cfg(not(windows))]
    fn cancel(&self) -> io::Result<()> {
        let thread = self
            .thread
            .as_ref()
            .ok_or_else(|| io::Error::other("capture reader thread already joined"))?;
        cancel_blocking_reader(thread, &self.cancelled)
    }

    fn join(&mut self) -> Result<()> {
        self.thread
            .take()
            .context("capture reader thread already joined")?
            .join()
            .map_err(|_| anyhow!("capture reader panicked"))
    }
}

fn read_bounded_stream(mut reader: impl Read, cancelled: Arc<AtomicBool>) -> io::Result<Vec<u8>> {
    let mut output = VecDeque::new();
    let mut buffer = [0_u8; 8192];
    loop {
        if cancelled.load(Ordering::Acquire) {
            return Ok(output.into_iter().collect());
        }
        match reader.read(&mut buffer) {
            Ok(0) => return Ok(output.into_iter().collect()),
            Ok(read) => append_bounded_tail(&mut output, &buffer[..read]),
            Err(_) if cancelled.load(Ordering::Acquire) => {
                return Ok(output.into_iter().collect());
            }
            Err(error) => return Err(error),
        }
    }
}

fn append_bounded_tail(output: &mut VecDeque<u8>, bytes: &[u8]) {
    if bytes.len() >= MAX_CAPTURE_BYTES {
        output.clear();
        output.extend(bytes[bytes.len() - MAX_CAPTURE_BYTES..].iter().copied());
        return;
    }
    let overflow = output.len().saturating_add(bytes.len()).saturating_sub(MAX_CAPTURE_BYTES);
    output.drain(..overflow);
    output.extend(bytes.iter().copied());
}

#[derive(Clone, Copy)]
struct CapturedProcessTree {
    child_id: u32,
}

impl CapturedProcessTree {
    fn new(child_id: u32) -> Self {
        Self { child_id }
    }

    fn terminate(self) -> io::Result<()> {
        terminate_captured_process_tree(self.child_id)
    }

    fn terminate_after_exit(self) -> io::Result<()> {
        #[cfg(unix)]
        return self.terminate();

        // The Windows child PID can be reused after exit. Cancelling the exact
        // owned reader threads closes the harness pipe handles without sending
        // taskkill to a possibly unrelated later process.
        #[cfg(windows)]
        return Ok(());
    }
}

#[cfg(unix)]
fn terminate_captured_process_tree(child_id: u32) -> io::Result<()> {
    let group = child_id as libc::pid_t;
    // SAFETY: process_group(0) created a new group whose leader is the
    // validated direct child. The negative id targets only that group.
    if unsafe { libc::kill(-group, libc::SIGKILL) } == 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        return Ok(());
    }
    Err(error)
}

#[cfg(windows)]
fn terminate_captured_process_tree(child_id: u32) -> io::Result<()> {
    terminate_windows_process_tree(child_id)
}

fn assert_ping(common: &Common, socket: &Path, deadline: SuiteDeadline) -> Result<u64> {
    let response = json_cli(common, socket, &["session", "current", "ping"], deadline)?;
    ping_endpoint(&response)
}

fn ping_endpoint(response: &JsonCliResponse) -> Result<u64> {
    if response.value.get("alive").and_then(Value::as_bool) != Some(true) {
        bail!("session ping did not return alive=true: {}", response.value);
    }
    Ok(response.completed_at_ns)
}

fn restored_topology_endpoint(response: &JsonCliResponse, terminal_id: &str) -> Result<u64> {
    if !terminal_list_contains_id(&response.value, terminal_id) {
        bail!("restored terminal list omitted saved terminal {terminal_id}");
    }
    Ok(response.completed_at_ns)
}

fn git_sha(path: &Path) -> Result<String> {
    let mut command = Command::new("git");
    command.arg("-C").arg(path).args(["rev-parse", "HEAD"]);
    let captured = run_trusted_captured(command, SuiteDeadline::unbounded())
        .with_context(|| format!("run git in {}", path.display()))?;
    if !captured.status.success() {
        bail!(
            "git rev-parse failed in {}: {}",
            path.display(),
            String::from_utf8_lossy(&captured.stderr)
        );
    }
    Ok(String::from_utf8(captured.stdout)?.trim().to_string())
}

fn assert_git_ancestor(repository: &Path, ancestor: &str, descendant: &str) -> Result<()> {
    let mut command = Command::new("git");
    command.arg("-C").arg(repository).args(["merge-base", "--is-ancestor", ancestor, descendant]);
    let captured = run_trusted_captured(command, SuiteDeadline::unbounded())?;
    if !captured.status.success() {
        bail!(
            "measured baseline {ancestor} is not an ancestor of trusted infrastructure {descendant}"
        );
    }
    Ok(())
}

fn binary_sha256(binary: &Path) -> Result<String> {
    let bytes = fs::read(binary).with_context(|| format!("read {}", binary.display()))?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

fn validate_binary_identity(
    version: &str,
    expected_commit: &str,
    expected_ghostty: &str,
    require_stamp: bool,
) -> Result<bool> {
    let Some((crate_version, metadata)) = version.rsplit_once(" (") else {
        if require_stamp {
            bail!("binary version omitted stamped source identities");
        }
        return Ok(false);
    };
    if crate_version.is_empty() {
        bail!("binary version omitted the crate version");
    }
    let metadata =
        metadata.strip_suffix(')').context("binary version has malformed source identities")?;
    let (commit, ghostty) = metadata
        .split_once("; ghostty ")
        .context("binary version omitted the stamped Ghostty identity")?;
    if commit != expected_commit {
        bail!("binary commit is {commit}, expected {expected_commit}");
    }
    if ghostty != expected_ghostty {
        bail!("binary Ghostty commit is {ghostty}, expected {expected_ghostty}");
    }
    Ok(true)
}

fn source_zig_version(source: &Path) -> Result<String> {
    let manifest = source.join("ghostty/build.zig.zon");
    let contents =
        fs::read_to_string(&manifest).with_context(|| format!("read {}", manifest.display()))?;
    parse_minimum_zig_version(&contents).with_context(|| format!("parse {}", manifest.display()))
}

fn parse_minimum_zig_version(manifest: &str) -> Result<String> {
    for line in manifest.lines() {
        let line = line.trim_start();
        let Some(value) = line.strip_prefix(".minimum_zig_version") else {
            continue;
        };
        let value = value
            .trim_start()
            .strip_prefix('=')
            .map(str::trim_start)
            .and_then(|value| value.strip_prefix('"'))
            .and_then(|value| value.split_once('"').map(|(version, _)| version))
            .context("minimum_zig_version has invalid syntax")?;
        let mut components = value.split('.');
        let valid = (0..3).all(|_| {
            components.next().is_some_and(|component| {
                !component.is_empty() && component.bytes().all(|byte| byte.is_ascii_digit())
            })
        }) && components.next().is_none();
        if !valid {
            bail!("minimum_zig_version is not a three-part numeric version: {value:?}");
        }
        return Ok(value.to_string());
    }
    bail!("minimum_zig_version is missing")
}

fn source_rust_toolchain(source: &Path) -> Result<String> {
    let cmux_tui = source.join("cmux-tui");
    let mut command = Command::new("rustup");
    command.args(["show", "active-toolchain"]).current_dir(&cmux_tui);
    let captured = run_trusted_captured(command, SuiteDeadline::unbounded())
        .with_context(|| format!("resolve Rust toolchain in {}", cmux_tui.display()))?;
    if !captured.status.success() {
        bail!(
            "rustup show active-toolchain failed in {}: {}",
            cmux_tui.display(),
            String::from_utf8_lossy(&captured.stderr)
        );
    }
    let output = String::from_utf8(captured.stdout)?;
    output
        .split_whitespace()
        .next()
        .map(str::to_string)
        .with_context(|| format!("rustup returned no active toolchain in {}", cmux_tui.display()))
}

struct JsonCliResponse {
    value: Value,
    completed_at_ns: u64,
}

fn json_cli(
    common: &Common,
    socket: &Path,
    args: &[&str],
    deadline: SuiteDeadline,
) -> Result<JsonCliResponse> {
    // These noun-first requests use cmux_tui_core::platform::transport. Windows provides the
    // local transport through uds_windows; the Unix-only remote-daemon command family is separate.
    let mut product_args =
        vec!["--json".into(), "--socket".into(), socket.to_string_lossy().into_owned()];
    product_args.extend(args.iter().map(|value| (*value).to_string()));
    let command = common.std_command(&product_args, false)?;
    let captured = run_captured(command, deadline)?;
    if captured.status.success() {
        let value: Value = serde_json::from_slice(&captured.stdout).with_context(|| {
            format!(
                "socket RPC {:?} returned invalid JSON: {}",
                args,
                String::from_utf8_lossy(&captured.stdout)
            )
        })?;
        return Ok(JsonCliResponse { value, completed_at_ns: captured.completed_at_ns });
    }
    let error: Value = serde_json::from_slice(&captured.stderr).with_context(|| {
        format!(
            "socket RPC {:?} returned an invalid structured error with {}: {}",
            args,
            captured.status,
            String::from_utf8_lossy(&captured.stderr)
        )
    })?;
    bail!("socket RPC {args:?} failed with exit code {:?}: {error}", captured.status.code())
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

fn terminal_list_contains_id(value: &Value, expected: &str) -> bool {
    value.as_array().is_some_and(|terminals| {
        terminals
            .iter()
            .any(|terminal| terminal.get("id").and_then(Value::as_str) == Some(expected))
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RestoredCleanupPlan {
    AlreadyQuiescent,
}

fn restored_cleanup_plan(value: &Value, owned_terminal_id: &str) -> Result<RestoredCleanupPlan> {
    let terminals = value.as_array().context("restored cleanup terminal list was not an array")?;
    match terminals.as_slice() {
        [] => Ok(RestoredCleanupPlan::AlreadyQuiescent),
        [terminal] if terminal.get("id").and_then(Value::as_str) == Some(owned_terminal_id) => {
            Ok(RestoredCleanupPlan::AlreadyQuiescent)
        }
        _ => bail!(
            "restored cleanup terminal list was neither empty nor the exact owned terminal {owned_terminal_id:?}: {value}"
        ),
    }
}

fn find_named_regular_file(root: &Path, name: &str) -> Result<Option<PathBuf>> {
    find_named_regular_file_bounded(root, name, MAX_STATE_SCAN_DEPTH, MAX_STATE_SCAN_ENTRIES)
}

fn find_named_regular_file_bounded(
    root: &Path,
    name: &str,
    max_depth: usize,
    max_entries: usize,
) -> Result<Option<PathBuf>> {
    let root_metadata = fs::symlink_metadata(root)
        .with_context(|| format!("inspect state root {}", root.display()))?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        bail!("state root is not a link-free directory: {}", root.display());
    }
    let canonical_root = fs::canonicalize(root)
        .with_context(|| format!("canonicalize state root {}", root.display()))?;
    let mut directories = VecDeque::from([(root.to_path_buf(), 0_usize)]);
    let mut entries_seen = 0_usize;

    while let Some((directory, depth)) = directories.pop_front() {
        let entries = fs::read_dir(&directory)
            .with_context(|| format!("read state directory {}", directory.display()))?;
        for entry in entries {
            let entry = entry.with_context(|| {
                format!("read entry in state directory {}", directory.display())
            })?;
            entries_seen =
                entries_seen.checked_add(1).context("state scan entry count overflow")?;
            if entries_seen > max_entries {
                bail!("state scan exceeded {max_entries} entries under {}", root.display());
            }

            let path = entry.path();
            let file_type = entry
                .file_type()
                .with_context(|| format!("inspect state entry {}", path.display()))?;
            if file_type.is_symlink() {
                continue;
            }
            if file_type.is_dir() {
                let child_depth = depth.checked_add(1).context("state scan depth overflow")?;
                if child_depth > max_depth {
                    bail!("state scan exceeded depth {max_depth} at {}", path.display());
                }
                directories.push_back((path, child_depth));
                continue;
            }
            if !file_type.is_file()
                || path.file_name().and_then(|value| value.to_str()) != Some(name)
            {
                continue;
            }

            let canonical_path = fs::canonicalize(&path)
                .with_context(|| format!("canonicalize state file {}", path.display()))?;
            if !canonical_path.starts_with(&canonical_root) {
                bail!(
                    "state file escaped canonical root {}: {}",
                    canonical_root.display(),
                    canonical_path.display()
                );
            }
            let metadata = fs::metadata(&canonical_path).with_context(|| {
                format!("inspect canonical state file {}", canonical_path.display())
            })?;
            if !metadata.is_file() {
                bail!("state path is not a regular file: {}", canonical_path.display());
            }
            return Ok(Some(canonical_path));
        }
    }

    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;

    const SENTINEL_PATH_ENV: &str = "CMUX_STARTUP_TEST_SENTINEL_PATH";
    const START_MARKER_PATH_ENV: &str = "CMUX_STARTUP_TEST_START_MARKER_PATH";
    const SUPERVISOR_PATH_ENV: &str = "CMUX_BENCH_TEST_SUPERVISOR";
    #[cfg(windows)]
    const BOOTSTRAP_PATH_ENV: &str = "CMUX_BENCH_TEST_WINDOWS_BOOTSTRAP";
    const FIXTURE_PARENT_ENV: &str = "CMUX_BENCH_TEST_FIXTURE_PARENT";

    fn current_test_target() -> Target {
        let binary = env::current_exe().unwrap();
        let expected_binary_sha256 = binary_sha256(&binary).expect("hash current test product");
        let supervisor_binary = PathBuf::from(
            env::var_os(SUPERVISOR_PATH_ENV)
                .expect("CMUX_BENCH_TEST_SUPERVISOR must name the built trusted supervisor"),
        );
        let supervisor_binary_sha256 =
            binary_sha256(&supervisor_binary).expect("hash trusted test supervisor");
        #[cfg(windows)]
        let windows_bootstrap_binary = PathBuf::from(
            env::var_os(BOOTSTRAP_PATH_ENV)
                .expect("CMUX_BENCH_TEST_WINDOWS_BOOTSTRAP must name the minimal bootstrap"),
        );
        #[cfg(windows)]
        let windows_bootstrap_sha256 =
            binary_sha256(&windows_bootstrap_binary).expect("hash trusted test bootstrap");
        Target {
            kind: TargetKind::Candidate,
            binary,
            source: env::current_dir().unwrap(),
            sha: "0".repeat(40),
            expected_binary_sha256,
            observed_sha: "0".repeat(40),
            ghostty_sha: "0".repeat(40),
            zig_version: "test".into(),
            rust_toolchain: "test".into(),
            embedded_identity_verified: true,
            version: "test".into(),
            launcher: Vec::new(),
            supervisor_binary,
            supervisor_binary_sha256,
            #[cfg(windows)]
            windows_bootstrap_binary,
            #[cfg(windows)]
            windows_bootstrap_sha256,
            trusted_source: env::current_dir().unwrap(),
            trusted_sha: "0".repeat(40),
        }
    }

    #[test]
    fn direct_launcher_sibling_write_helper() {
        let Ok(sentinel_path) = env::var(SENTINEL_PATH_ENV) else {
            return;
        };
        let start_marker_path = env::var(START_MARKER_PATH_ENV).unwrap();
        fs::write(start_marker_path, b"started").unwrap();
        let _ = fs::write(sentinel_path, b"changed");
    }

    #[test]
    fn direct_product_launch_cannot_change_an_adjacent_sentinel() {
        let parent = PathBuf::from(
            env::var_os(FIXTURE_PARENT_ENV)
                .expect("CMUX_BENCH_TEST_FIXTURE_PARENT must name the sandbox fixture parent"),
        );
        let fixture_parent = tempfile::tempdir_in(parent).unwrap();
        let mut common =
            Common::new(current_test_target(), Scenario::Cold, false, fixture_parent.path())
                .unwrap();
        let start_marker = common.root.path().join("helper-started");
        let sentinel = fixture_parent.path().join("protected-sentinel");
        fs::write(&sentinel, b"protected").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&sentinel, fs::Permissions::from_mode(0o666)).unwrap();
        }

        let helper = "direct_launcher_sibling_write_helper".to_string();
        let mut command = common.std_command(&[helper, "--nocapture".into()], false).unwrap();
        command.command.env(START_MARKER_PATH_ENV, &start_marker);
        command.command.env(SENTINEL_PATH_ENV, &sentinel);
        let captured =
            run_captured(command, SuiteDeadline::at(Instant::now() + STARTUP_LINE_TIMEOUT))
                .unwrap();
        assert!(captured.status.success(), "helper test failed with status {:?}", captured.status);
        common.root.mark_quiescent();

        assert_eq!(fs::read(&start_marker).unwrap(), b"started");
        assert_eq!(
            fs::read(&sentinel).unwrap(),
            b"protected",
            "the product launcher allowed a child to change a sibling of its fixture root"
        );
    }

    #[test]
    fn supervisor_environment_omits_forbidden_runner_secrets() {
        let environment = collect_base_environment(|key| {
            Some(if key == "PATH" { "trusted-path" } else { "trusted-value" }.into())
        });

        assert_eq!(
            environment.iter().find(|(key, _)| key == "PATH").map(|(_, value)| value.as_str()),
            Some("trusted-path")
        );
        assert!(environment.iter().all(|(key, _)| key != "CMUX_BENCH_FORBIDDEN_TEST_SECRET"));
        assert!(environment.iter().all(|(key, _)| key != "GITHUB_TOKEN"));
    }

    #[test]
    fn probe_tracker_answers_each_observed_query_once() {
        let mut tracker = ProbeTracker::default();
        assert!(tracker.observe(b"\x1b[").is_empty());
        assert_eq!(tracker.observe(b"6n"), [b"\x1b[1;1R".as_slice()]);
        assert!(tracker.observe(b"\x1b[6n").is_empty());
        assert!(tracker.observe(b"\x1b]10;?").is_empty());
        let first = tracker.observe(b"\x1b\\ noise \x1b[c");
        assert_eq!(first.len(), 2);
        assert_eq!(tracker.responses, 3);
        assert!(tracker.observe(b"\x1b]10;?\x1b\\ noise \x1b[c").is_empty());
    }

    #[test]
    fn frame_marker_requires_a_later_cursor_visibility_escape_across_reads() {
        let mut tracker = FrameMarkerTracker::new(b"[bench-cold-1] ".to_vec());
        assert_eq!(tracker.observe(b"prefix [bench-cold"), None);
        assert_eq!(tracker.observe(b"-1] frame bytes"), None);
        assert_eq!(tracker.observe(b"\x1b[?25"), None);
        assert_eq!(tracker.observe(b"h"), Some(FrameCompletion::Show));
    }

    #[test]
    fn frame_marker_accepts_a_later_split_cursor_position_escape() {
        let mut tracker = FrameMarkerTracker::new(b"[bench-warm-1] ".to_vec());
        assert_eq!(tracker.observe(b"\x1b[1;1H before [bench-warm"), None);
        assert_eq!(tracker.observe(b"-1] frame bytes \x1b[6;"), None);
        assert_eq!(tracker.observe(b"49H"), Some(FrameCompletion::Position));
    }

    #[test]
    fn frame_marker_survives_more_than_the_diagnostic_capture_limit() {
        let mut tracker = FrameMarkerTracker::new(b"[bench-cold-1] ".to_vec());
        assert_eq!(tracker.observe(b"[bench-cold-1] "), None);
        assert_eq!(tracker.observe(&vec![b'x'; MAX_CAPTURE_BYTES + 1]), None);
        assert_eq!(tracker.observe(b"\x1b[?25l"), Some(FrameCompletion::Hide));
    }

    #[test]
    fn terminal_list_requires_an_exact_top_level_record_id() {
        let value = serde_json::json!([
            {"id": "term:exact", "workspace_ref": "workspace:one"},
            {"id": "term:other", "title": "term:exact-more"}
        ]);
        assert!(terminal_list_contains_id(&value, "term:exact"));
        assert!(!terminal_list_contains_id(&value, "term:exa"));
        assert!(!terminal_list_contains_id(
            &serde_json::json!({"metadata": {"id": "term:exact"}}),
            "term:exact"
        ));
        assert!(!terminal_list_contains_id(
            &serde_json::json!([{"id": "term:other", "terminal_id": "term:exact"}]),
            "term:exact"
        ));
    }

    #[test]
    fn successful_rpc_endpoints_use_the_captured_completion_time() {
        let ping =
            JsonCliResponse { value: serde_json::json!({"alive": true}), completed_at_ns: 41 };
        let topology = JsonCliResponse {
            value: serde_json::json!([{"id": "term:owned"}]),
            completed_at_ns: 73,
        };

        assert_eq!(ping_endpoint(&ping).unwrap(), 41);
        assert_eq!(restored_topology_endpoint(&topology, "term:owned").unwrap(), 73);
        assert!(
            ping_endpoint(&JsonCliResponse {
                value: serde_json::json!({"alive": false}),
                completed_at_ns: 89,
            })
            .is_err()
        );
        assert!(restored_topology_endpoint(&topology, "term:other").is_err());
    }

    #[test]
    fn state_file_scan_returns_only_a_contained_regular_file() {
        let root = tempfile::tempdir().unwrap();
        let session = root.path().join("session");
        fs::create_dir(&session).unwrap();
        let database = session.join("workspace-registry.sqlite3");
        fs::write(&database, b"registry").unwrap();

        let found =
            find_named_regular_file_bounded(root.path(), "workspace-registry.sqlite3", 2, 8)
                .unwrap()
                .unwrap();

        assert_eq!(found, fs::canonicalize(database).unwrap());
        assert!(found.starts_with(fs::canonicalize(root.path()).unwrap()));
    }

    #[cfg(unix)]
    #[test]
    fn state_file_scan_does_not_follow_a_symlink_cycle() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        symlink(root.path(), root.path().join("cycle")).unwrap();

        assert!(
            find_named_regular_file_bounded(root.path(), "workspace-registry.sqlite3", 2, 8,)
                .unwrap()
                .is_none()
        );
    }

    #[cfg(unix)]
    #[test]
    fn state_file_scan_rejects_an_outside_symlink_target() {
        use std::os::unix::fs::symlink;

        let root = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let outside_database = outside.path().join("workspace-registry.sqlite3");
        fs::write(&outside_database, b"outside").unwrap();
        symlink(&outside_database, root.path().join("workspace-registry.sqlite3")).unwrap();

        assert!(
            find_named_regular_file_bounded(root.path(), "workspace-registry.sqlite3", 2, 8,)
                .unwrap()
                .is_none()
        );
        assert_eq!(fs::read(outside_database).unwrap(), b"outside");
    }

    #[test]
    fn state_file_scan_enforces_depth_and_entry_bounds() {
        let depth_root = tempfile::tempdir().unwrap();
        fs::create_dir_all(depth_root.path().join("one/two")).unwrap();
        assert!(
            find_named_regular_file_bounded(depth_root.path(), "workspace-registry.sqlite3", 1, 8,)
                .unwrap_err()
                .to_string()
                .contains("exceeded depth 1")
        );

        let entry_root = tempfile::tempdir().unwrap();
        fs::write(entry_root.path().join("one"), b"one").unwrap();
        fs::write(entry_root.path().join("two"), b"two").unwrap();
        assert!(
            find_named_regular_file_bounded(entry_root.path(), "workspace-registry.sqlite3", 1, 1,)
                .unwrap_err()
                .to_string()
                .contains("exceeded 1 entries")
        );
    }

    #[test]
    fn restored_cleanup_accepts_the_exact_owned_terminal_as_quiescent() {
        let value = serde_json::json!([
            {"id": "term:owned", "workspace_ref": "workspace:one"}
        ]);

        assert_eq!(
            restored_cleanup_plan(&value, "term:owned").unwrap(),
            RestoredCleanupPlan::AlreadyQuiescent
        );
    }

    #[test]
    fn restored_fixture_teardown_accepts_its_owned_durable_terminal() {
        let value = serde_json::json!([
            {"id": "term:owned", "workspace_ref": "workspace:one"}
        ]);

        assert_eq!(
            restored_cleanup_plan(&value, "term:owned").unwrap(),
            RestoredCleanupPlan::AlreadyQuiescent,
            "fixture teardown must use process shutdown when its durable terminal remains listed"
        );
    }

    #[test]
    fn restored_cleanup_accepts_an_empty_terminal_list_as_quiescent() {
        assert_eq!(
            restored_cleanup_plan(&serde_json::json!([]), "term:owned").unwrap(),
            RestoredCleanupPlan::AlreadyQuiescent
        );
    }

    #[test]
    fn restored_cleanup_rejects_a_mismatched_terminal_topology() {
        assert!(
            restored_cleanup_plan(&serde_json::json!([{"id": "term:other"}]), "term:owned")
                .is_err()
        );
        assert!(
            restored_cleanup_plan(
                &serde_json::json!([{"id": "term:owned"}, {"id": "term:other"}]),
                "term:owned"
            )
            .is_err()
        );
    }

    #[test]
    fn restored_cleanup_rejects_invalid_terminal_shapes() {
        assert!(
            restored_cleanup_plan(
                &serde_json::json!({"terminals": [{"id": "term:owned"}]}),
                "term:owned"
            )
            .is_err()
        );
        assert!(
            restored_cleanup_plan(
                &serde_json::json!([{"terminal_id": "term:owned"}]),
                "term:owned"
            )
            .is_err()
        );
        assert!(restored_cleanup_plan(&serde_json::json!([{"id": 7}]), "term:owned").is_err());
    }

    #[test]
    fn captured_output_retains_only_the_bounded_tail() {
        let input: Vec<u8> = (0..MAX_CAPTURE_BYTES + 17).map(|index| index as u8).collect();
        let output =
            read_bounded_stream(io::Cursor::new(&input), Arc::new(AtomicBool::new(false))).unwrap();

        assert_eq!(output.len(), MAX_CAPTURE_BYTES);
        assert_eq!(output, input[input.len() - MAX_CAPTURE_BYTES..]);
    }

    #[test]
    fn headless_stderr_retains_a_bounded_tail_and_finds_split_readiness() {
        let needle = b"ready across a read boundary".to_vec();
        let mut input = vec![b'x'; MAX_CAPTURE_BYTES + 4096 - 5];
        input.extend_from_slice(&needle);
        let (sender, events) = mpsc::channel();

        let output = read_until_event(
            io::Cursor::new(input),
            needle,
            sender,
            Arc::new(AtomicBool::new(false)),
        )
        .unwrap();

        assert!(matches!(events.recv().unwrap(), StreamEvent::Found(_)));
        assert_eq!(output.len(), MAX_CAPTURE_BYTES);
        assert!(output.ends_with(b"ready across a read boundary"));
    }

    #[test]
    fn incompatible_error_requires_the_exact_primary_diagnostic() {
        let expected = "cmux-tui: saved state is incompatible";
        assert!(
            validate_primary_diagnostic(
                "cmux-tui: saved state is incompatible\r\nrecovery",
                expected
            )
            .is_ok()
        );
        assert!(
            validate_primary_diagnostic(
                "cmux-tui: saved state is incompatible with details\n",
                expected
            )
            .is_err()
        );
        assert!(
            validate_primary_diagnostic("prefix cmux-tui: saved state is incompatible\n", expected)
                .is_err()
        );
    }

    #[test]
    fn one_token_pty_launcher_inserts_the_target_binary() {
        let binary = Path::new("/bench/cmux-tui");
        let launcher = ["time".to_string()];

        let (program, prefix) = pty_program_and_prefix(binary, &launcher, true);

        assert_eq!(program, "time");
        assert_eq!(prefix, ["/bench/cmux-tui"]);
    }

    #[test]
    fn multi_token_pty_launcher_keeps_options_before_the_target_binary() {
        let binary = Path::new("/bench/cmux-tui");
        let launcher = ["strace".to_string(), "-ff".to_string(), "-c".to_string()];

        let (program, prefix) = pty_program_and_prefix(binary, &launcher, true);

        assert_eq!(program, "strace");
        assert_eq!(prefix, ["-ff", "-c", "/bench/cmux-tui"]);
    }

    #[test]
    fn zig_manifest_parser_accepts_independent_target_versions() {
        let baseline = ".{\n    .minimum_zig_version = \"0.15.2\",\n}";
        let candidate = ".{\n\t.minimum_zig_version=\"0.16.0\",\n}";

        assert_eq!(parse_minimum_zig_version(baseline).unwrap(), "0.15.2");
        assert_eq!(parse_minimum_zig_version(candidate).unwrap(), "0.16.0");
    }

    #[test]
    fn zig_manifest_parser_rejects_malformed_and_missing_values() {
        assert!(parse_minimum_zig_version(".minimum_zig_version = \"0.16\",").is_err());
        assert!(parse_minimum_zig_version(".minimum_zig_version = 0.16.0,").is_err());
        assert!(parse_minimum_zig_version(".minimum_zig_version = \"0.16.0-dev.1\",").is_err());
        assert!(parse_minimum_zig_version(".minimum_zig_version = \"0.16.0+build.1\",").is_err());
        assert!(parse_minimum_zig_version(".{};").is_err());
    }

    #[test]
    fn binary_identity_requires_exact_stamped_source_commits() {
        let commit = "1111111111111111111111111111111111111111";
        let ghostty = "2222222222222222222222222222222222222222";
        let version = format!("0.1.0 ({commit}; ghostty {ghostty})");
        assert!(validate_binary_identity(&version, commit, ghostty, true).unwrap());
        assert!(
            validate_binary_identity(
                &version,
                "3333333333333333333333333333333333333333",
                ghostty,
                true,
            )
            .is_err()
        );
        assert!(
            validate_binary_identity(
                &version,
                commit,
                "4444444444444444444444444444444444444444",
                true,
            )
            .is_err()
        );
        assert!(validate_binary_identity("0.1.0", commit, ghostty, true).is_err());
        assert!(!validate_binary_identity("0.1.0", commit, ghostty, false).unwrap());
    }
}
