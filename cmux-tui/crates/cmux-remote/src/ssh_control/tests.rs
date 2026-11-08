//! Shared SSH connection tests against a fake `ssh` that logs every run.
//!
//! The fake becomes a "master" for `ControlMaster=yes` (logging `auth`,
//! the one place a real host would prompt), binds the control socket and
//! prints the ready line the way OpenSSH's `LocalCommand` does. A run with
//! `ControlMaster=no` and a live socket logs `mux`; any other run logs
//! `auth`, which on a password-only host is another password prompt.

use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_remote_protocol::{Lane, LanePolicy, SessionId};

use super::*;
use crate::provider::{
    ConnectRequest, LinkRequest, SshProvider, SshProviderConfig, TransportProvider,
};
use crate::ssh_bootstrap::{BootstrapOutcome, SshBootstrapConfig, SshBootstrapper};

#[derive(Clone, Copy)]
enum Mode {
    /// Authenticates after `delay_ms` and serves clients.
    Serve { delay_ms: u64 },
    /// Like `Serve`, but keeps stdout open after the ready line, as OpenSSH
    /// before 7.7 does.
    ServeKeepingStdout,
    /// Fails authentication after `delay_ms` (wrong password three times).
    Fail { delay_ms: u64 },
}

struct FakeSsh {
    _directory: tempfile::TempDir,
    binary: PathBuf,
    log: PathBuf,
}

impl FakeSsh {
    fn new(mode: Mode) -> Self {
        let directory = tempfile::tempdir().unwrap();
        let binary = directory.path().join("ssh");
        let log = directory.path().join("ssh.log");
        let (fail, delay_ms, keep_stdout) = match mode {
            Mode::Serve { delay_ms } => (false, delay_ms, false),
            Mode::ServeKeepingStdout => (false, 0, true),
            Mode::Fail { delay_ms } => (true, delay_ms, false),
        };
        let probe = serde_json::json!({
            "app": "cmux-tui",
            "version": "test",
            "build_identity": "test-build",
            "remote_protocol": cmux_remote_protocol::REMOTE_PROTOCOL_VERSION,
            "os": "test",
            "arch": "test",
        });
        let script = format!(
            r#"#!/usr/bin/env python3
import os, signal, socket, sys, time
LOG = {log:?}
FAIL = {fail}
DELAY = {delay}
KEEP_STDOUT = {keep_stdout}
PROBE = {probe:?}
args = sys.argv[1:]
def option(name):
    found = None
    for index, value in enumerate(args):
        if value == "-o" and index + 1 < len(args) and args[index + 1].startswith(name + "="):
            found = found or args[index + 1].split("=", 1)[1]
    return found
def log(line):
    with open(LOG, "a") as handle:
        handle.write(line + "\n")
command = args[args.index("--") + 2:] if "--" in args else []
master = option("ControlMaster")
path = option("ControlPath")
if master == "yes":
    log("auth master")
    with open(LOG + ".pid", "w") as handle:
        handle.write(str(os.getpid()))
    time.sleep(DELAY / 1000)
    if FAIL:
        sys.exit(255)
    assert "-N" in args and option("LocalCommand") == "echo cmux-ssh-master-ready"
    server = socket.socket(socket.AF_UNIX)
    server.bind(path)
    server.listen(8)
    def terminate(*_):
        log("master terminated")
        if os.path.exists(path):
            os.unlink(path)
        os._exit(0)
    signal.signal(signal.SIGTERM, terminate)
    print("shell startup noise", flush=True)
    print("cmux-ssh-master-ready", flush=True)
    if not KEEP_STDOUT:
        os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
    while True:
        signal.pause()
if master == "no" and path and os.path.exists(path):
    log("mux " + " ".join(command))
else:
    log("auth direct " + " ".join(command))
if "remote-probe" in command:
    print(PROBE)
"#,
            log = log.to_string_lossy(),
            fail = if fail { "True" } else { "False" },
            keep_stdout = if keep_stdout { "True" } else { "False" },
            delay = delay_ms,
            probe = probe.to_string(),
        );
        write_executable(&binary, script.as_bytes());
        Self { _directory: directory, binary, log }
    }

    fn target(&self) -> SshTarget {
        SshTarget {
            ssh_binary: self.binary.to_string_lossy().into_owned(),
            destination: "person@password-host".into(),
            port: None,
            extra_args: Vec::new(),
        }
    }

    fn lines(&self) -> Vec<String> {
        std::fs::read_to_string(&self.log).unwrap_or_default().lines().map(str::to_owned).collect()
    }

    fn master_pid(&self) -> Option<libc::pid_t> {
        std::fs::read_to_string(self.log.with_extension("log.pid")).ok()?.trim().parse().ok()
    }

    fn authentications(&self) -> usize {
        self.lines().iter().filter(|line| line.starts_with("auth")).count()
    }
}

/// Writes an executable without this process holding a write descriptor
/// for it: a sibling test's fork would inherit one and executing the script
/// would fail with ETXTBSY. A short-lived `sh` writes it instead.
fn write_executable(path: &Path, contents: &[u8]) {
    use std::io::Write as _;
    let mut child = std::process::Command::new("/bin/sh")
        .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(contents).unwrap();
    assert!(child.wait().unwrap().success(), "could not write {}", path.display());
}

fn process_running(pid: libc::pid_t) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

fn control_path(arguments: &[String]) -> PathBuf {
    let value = arguments
        .iter()
        .find_map(|argument| argument.strip_prefix("ControlPath="))
        .expect("client arguments name the control path");
    PathBuf::from(value)
}

fn bootstrap(fake: &FakeSsh, share: &SshConnectionShare) -> SshBootstrapper {
    let mut config =
        SshBootstrapConfig::defaults("person@password-host", "test-build", "0.0.0", None);
    config.ssh_binary = fake.binary.to_string_lossy().into_owned();
    config.auto_install = false;
    config.timeout = Duration::from_secs(10);
    config.connection_share = share.clone();
    SshBootstrapper::new(config).unwrap()
}

async fn open_and_close_link(fake: &FakeSsh, share: &SshConnectionShare) {
    let provider = SshProvider::new(SshProviderConfig {
        ssh_binary: fake.binary.to_string_lossy().into_owned(),
        connection_share: share.clone(),
        ..SshProviderConfig::default()
    })
    .unwrap();
    let group = provider
        .connect(ConnectRequest {
            endpoint: url::Url::parse("ssh://person@password-host").unwrap(),
            session: SessionId([7; 16]),
            lane_policy: LanePolicy::Single,
            routing: Default::default(),
        })
        .await
        .unwrap();
    let link = group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await.unwrap();
    link.close().await.unwrap();
}

/// Issue 38157: a connect probes, may install, then opens the carrier. With
/// a share, only the master authenticates; every step reuses it.
#[tokio::test]
async fn probe_install_and_carrier_authenticate_once() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 0 });
    let share = SshConnectionShare::new();
    let bootstrapper = bootstrap(&fake, &share);
    bootstrapper.connect().await.unwrap();
    assert_eq!(bootstrapper.ensure_installed().await.unwrap(), BootstrapOutcome::AlreadyInstalled);
    assert!(bootstrapper.probe().await.unwrap().is_some());
    open_and_close_link(&fake, &share).await;

    let lines = fake.lines();
    assert_eq!(fake.authentications(), 1, "one authentication per connect: {lines:?}");
    assert_eq!(lines.iter().filter(|line| line.starts_with("mux ")).count(), 3, "{lines:?}");
    assert!(lines.iter().any(|line| line.contains("remote-link")), "{lines:?}");
}

/// Without a share (the old behavior and every other caller), each run
/// authenticates: a password host would prompt three times.
#[tokio::test]
async fn without_a_share_each_run_authenticates() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 0 });
    let share = SshConnectionShare::disabled();
    let bootstrapper = bootstrap(&fake, &share);
    bootstrapper.connect().await.unwrap();
    bootstrapper.ensure_installed().await.unwrap();
    bootstrapper.probe().await.unwrap();
    open_and_close_link(&fake, &share).await;
    assert_eq!(fake.authentications(), 3, "{:?}", fake.lines());
}

#[tokio::test]
async fn concurrent_runs_wait_for_one_master() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 200 });
    let share = SshConnectionShare::new();
    let target = fake.target();
    let (first, second) =
        tokio::join!(share.client_arguments(&target), share.client_arguments(&target));
    assert_eq!(first.unwrap(), second.unwrap());
    assert_eq!(fake.authentications(), 1, "{:?}", fake.lines());
}

/// The startup deadline leaves out authentication: the clock covers the
/// whole master handshake and stops when it ends.
#[tokio::test]
async fn auth_clock_records_master_authentication_time() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 300 });
    let share = SshConnectionShare::new();
    let clock = share.auth_clock().expect("an enabled share has a clock");
    assert_eq!(clock.excluded(Instant::now()), Duration::ZERO);
    share.client_arguments(&fake.target()).await.unwrap();
    let spent = clock.excluded(Instant::now());
    assert!(spent >= Duration::from_millis(300), "{spent:?}");
    // Reusing the live master authenticates nothing more.
    share.client_arguments(&fake.target()).await.unwrap();
    assert_eq!(clock.excluded(Instant::now() + Duration::from_secs(5)), spent);
}

#[tokio::test]
async fn failed_authentication_reports_ssh_exit_and_is_not_retried() {
    let fake = FakeSsh::new(Mode::Fail { delay_ms: 0 });
    let share = SshConnectionShare::new();
    let error = bootstrap(&fake, &share).connect().await.unwrap_err();
    assert!(!error.is_retryable_carrier_failure(), "{error}");
    assert!(
        error.to_string().contains("SSH could not connect and authenticate (ssh exited 255)"),
        "{error}"
    );
    assert_eq!(fake.authentications(), 1, "{:?}", fake.lines());
}

#[tokio::test]
async fn caller_connection_sharing_is_left_alone() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 0 });
    let share = SshConnectionShare::new();
    for extra in [
        vec!["-S".to_owned(), "/tmp/theirs".to_owned()],
        vec!["-oControlPath=/tmp/theirs".to_owned()],
        vec!["-o".to_owned(), "ControlMaster=auto".to_owned()],
        vec!["-M".to_owned()],
    ] {
        let target = SshTarget { extra_args: extra.clone(), ..fake.target() };
        assert!(share.client_arguments(&target).await.unwrap().is_empty(), "{extra:?}");
    }
    assert!(fake.lines().is_empty(), "{:?}", fake.lines());
}

#[tokio::test]
async fn dropping_the_share_ends_the_master_and_removes_its_socket() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 0 });
    let share = SshConnectionShare::new();
    let socket = control_path(&share.client_arguments(&fake.target()).await.unwrap());
    let directory = socket.parent().unwrap().to_path_buf();
    assert_eq!(
        std::fs::metadata(&directory).unwrap().permissions().mode() & 0o777,
        0o700,
        "the control socket directory is private"
    );
    drop(share);
    wait_until(|| fake.lines().iter().any(|line| line == "master terminated")).await;
    wait_until(|| !directory.exists()).await;
    assert!(!socket.exists());
}

#[tokio::test]
async fn a_dead_master_is_replaced_by_one_new_authentication() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 0 });
    let share = SshConnectionShare::new();
    let socket = control_path(&share.client_arguments(&fake.target()).await.unwrap());
    // The connection dropped: ssh is gone and its socket with it.
    std::fs::remove_file(&socket).unwrap();
    let replacement = share.client_arguments(&fake.target()).await.unwrap();
    assert_ne!(control_path(&replacement), socket);
    assert_eq!(fake.authentications(), 2, "{:?}", fake.lines());
}

/// OpenSSH before 7.7 keeps stdout open after `LocalCommand`: the ready
/// line alone must be enough.
#[tokio::test]
async fn ready_line_suffices_when_ssh_keeps_stdout_open() {
    let fake = FakeSsh::new(Mode::ServeKeepingStdout);
    let share = SshConnectionShare::new();
    let arguments =
        tokio::time::timeout(Duration::from_secs(10), share.client_arguments(&fake.target()))
            .await
            .expect("the ready line, not EOF, ends the wait")
            .unwrap();
    assert!(control_path(&arguments).exists());
}

/// A cancelled open (a timeout, a shutdown) while ssh still waits for the
/// password ends that ssh, so no stray process keeps prompting.
#[tokio::test]
async fn cancelling_a_pending_master_ends_its_ssh() {
    let fake = FakeSsh::new(Mode::Serve { delay_ms: 30_000 });
    let share = SshConnectionShare::new();
    let target = fake.target();
    let open = share.client_arguments(&target);
    tokio::pin!(open);
    tokio::select! {
        _ = &mut open => panic!("the master cannot be ready yet"),
        () = wait_until(|| fake.master_pid().is_some()) => {}
    }
    let pid = fake.master_pid().unwrap();
    drop(open);
    wait_until(|| !process_running(pid)).await;
}

/// The master sends keepalives, so a silently dead connection is noticed
/// instead of hanging every run through it.
#[test]
fn master_arguments_enable_keepalives() {
    let arguments = master_arguments(Path::new("/tmp/s"));
    assert!(arguments.iter().any(|argument| argument == "ServerAliveInterval=15"));
    assert!(arguments.iter().any(|argument| argument == "ServerAliveCountMax=3"));
}

/// The private master never forwards the local agent or X11, even when
/// the person's arguments ask for it; a port forward they asked for stays.
#[test]
fn private_master_turns_forwarding_off() {
    let arguments = private_master_ssh_arguments(
        None,
        &["-A".to_owned(), "-XY".to_owned()],
        "person@password-host",
    );
    for forbidden in ["-A", "-X", "-Y", "-XY"] {
        assert!(!arguments.iter().any(|argument| argument == forbidden), "{arguments:?}");
    }
    for required in ["ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes"] {
        assert!(arguments.iter().any(|argument| argument == required), "{arguments:?}");
    }
    let forwarding = private_master_ssh_arguments(
        None,
        &["-L".to_owned(), "8080:localhost:80".to_owned()],
        "person@password-host",
    );
    assert!(forwarding.iter().any(|argument| argument == "ForwardAgent=no"), "{forwarding:?}");
    assert!(!forwarding.iter().any(|argument| argument == "ClearAllForwardings=yes"));
}

#[test]
fn control_paths_escape_ssh_percent_tokens() {
    assert_eq!(control_path_value(Path::new("/tmp/a%b")), "/tmp/a%%b");
}

/// Waits for a background process's effect, bounded so a failure ends.
async fn wait_until(mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !condition() {
        assert!(Instant::now() < deadline, "condition not reached within 10s");
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
}
