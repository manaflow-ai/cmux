#[cfg(unix)]
use crate::test_exec::write_executable;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::*;

static NEXT_TEST_DIRECTORY: AtomicU64 = AtomicU64::new(1);

struct TestDirectory {
    path: PathBuf,
}

impl TestDirectory {
    fn new() -> Self {
        let sequence = NEXT_TEST_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        // Darwin limits Unix-domain socket paths to 103 bytes. macOS's
        // per-user temporary directory can consume most of that budget.
        let base = if cfg!(target_os = "macos") {
            Path::new("/tmp").to_path_buf()
        } else {
            std::env::temp_dir()
        };
        let path = base.join(format!("cmux-pt-{}-{sequence}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir(&path).expect("create transport test directory");
        Self { path }
    }

    fn script(&self, name: &str, body: &str) -> PathBuf {
        let path = self.path.join(name);
        write_executable(&path, format!("#!/bin/sh\nset -eu\n{body}\n"));
        path
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}

fn wait_for_nonempty_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while fs::metadata(path).map_or(true, |metadata| metadata.len() == 0) {
        assert!(Instant::now() < deadline, "timed out waiting for {}", path.display());
        thread::sleep(Duration::from_millis(10));
    }
}

fn wait_for_file(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !path.exists() {
        assert!(Instant::now() < deadline, "timed out waiting for {}", path.display());
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn command_connector_executes_literal_argv_without_a_shell_or_token_leak() {
    let directory = TestDirectory::new();
    let arguments = directory.path.join("arguments");
    let environment = directory.path.join("environment");
    let complete = directory.path.join("complete");
    let injected = directory.path.join("injected");
    let script = directory.script(
        "record",
        "arguments=$1; environment=$2; complete=$3; shift 3; printf '%s\\n' \"$@\" > \"$arguments.tmp\"; mv \"$arguments.tmp\" \"$arguments\"; env > \"$environment.tmp\"; mv \"$environment.tmp\" \"$environment\"; printf 'done\\n' > \"$complete\"; while IFS= read -r _line; do :; done",
    );
    let metacharacters = format!("$(touch {}) ; touch {}", injected.display(), injected.display());
    let connector = CommandProviderConnector::new([
        script.into_os_string(),
        arguments.clone().into_os_string(),
        environment.clone().into_os_string(),
        complete.clone().into_os_string(),
        OsString::from(&metacharacters),
    ])
    .expect("create command connector");

    let connection = connector.connect().expect("open command control");
    let (token, control, _) = connection.into_parts();
    wait_for_file(&complete);
    let recorded_arguments = fs::read_to_string(arguments).expect("read recorded arguments");
    let recorded_environment = fs::read_to_string(environment).expect("read environment");
    assert!(recorded_arguments.lines().any(|argument| argument == metacharacters));
    assert_eq!(recorded_arguments.lines().last(), Some("control"));
    assert!(!injected.exists(), "metacharacters were evaluated by a shell");
    assert!(!recorded_arguments.contains(token.expose()));
    assert!(!recorded_environment.contains(token.expose()));
    drop(control);
}

#[test]
fn command_connector_does_not_inherit_provider_capability_secrets() {
    const CHILD_MARKER: &str = "CMUX_PROVIDER_ENV_TEST_CHILD";
    if std::env::var_os(CHILD_MARKER).is_some() {
        let directory = TestDirectory::new();
        let environment = directory.path.join("environment");
        let complete = directory.path.join("complete");
        let script = directory.script(
            "record-environment",
            "environment=$1; complete=$2; env > \"$environment.tmp\"; mv \"$environment.tmp\" \"$environment\"; printf 'done\\n' > \"$complete\"; while IFS= read -r _line; do :; done",
        );
        let connector = CommandProviderConnector::new([
            script.into_os_string(),
            environment.clone().into_os_string(),
            complete.clone().into_os_string(),
        ])
        .expect("create command connector");
        let connection = connector.connect().expect("open command control");
        let (_, control, _) = connection.into_parts();
        wait_for_file(&complete);
        let recorded_environment = fs::read_to_string(environment).expect("read environment");
        assert!(
            !recorded_environment
                .lines()
                .any(|line| line.starts_with("CMUX_MACHINE_PROVIDER_TOKEN=")),
            "machine provider token reached child environment"
        );
        assert!(
            !recorded_environment
                .lines()
                .any(|line| line.starts_with("CMUX_PROVIDER_WORKSPACE_AUTHORITY=")),
            "provider workspace authority reached child environment"
        );
        drop(control);
        return;
    }

    let helper_test = format!(
        "{}::command_connector_does_not_inherit_provider_capability_secrets",
        module_path!()
    );
    let output =
        Command::new(std::env::current_exe().expect("locate provider environment test binary"))
            .arg("--exact")
            .arg(&helper_test)
            .arg("--nocapture")
            .env(CHILD_MARKER, "1")
            .env("CMUX_MACHINE_PROVIDER_TOKEN", "provider-token-test")
            .env("CMUX_PROVIDER_WORKSPACE_AUTHORITY", "provider-authority-test")
            .output()
            .expect("run provider environment test helper");
    assert!(
        output.status.success(),
        "provider environment test helper failed:\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn command_connector_uses_fresh_bearers_and_processes_for_every_descriptor() {
    let directory = TestDirectory::new();
    let records = directory.path.join("records");
    let script = directory.script(
        "record-process",
        "records=$1; shift; printf '%s:%s\\n' \"$$\" \"$1\" >> \"$records\"; while IFS= read -r _line; do :; done",
    );
    let connector =
        CommandProviderConnector::new([script.into_os_string(), records.clone().into_os_string()])
            .expect("create command connector");

    let first = connector.connect().expect("open first generation");
    let (first_token, first_control, first_streams) = first.into_parts();
    let first_stream = first_streams.open().expect("open first stream");
    let second_stream = first_streams.open().expect("open second stream");
    let second = connector.connect().expect("open second generation");
    let (second_token, second_control, _) = second.into_parts();
    assert_ne!(first_token.expose(), second_token.expose());
    assert!(first_token.expose().len() >= 32);

    let deadline = Instant::now() + Duration::from_secs(10);
    let lines = loop {
        let lines = fs::read_to_string(&records).unwrap_or_default();
        if lines.lines().count() >= 4 {
            break lines;
        }
        assert!(Instant::now() < deadline, "timed out waiting for command records");
        thread::sleep(Duration::from_millis(10));
    };
    let mut process_ids =
        lines.lines().map(|line| line.split_once(':').expect("pid and role")).collect::<Vec<_>>();
    process_ids.sort_unstable();
    process_ids.dedup();
    assert_eq!(process_ids.len(), 4, "each descriptor must own a distinct process");
    assert_eq!(lines.lines().filter(|line| line.ends_with(":control")).count(), 2);
    assert_eq!(lines.lines().filter(|line| line.ends_with(":stream")).count(), 2);
    drop((first_stream, second_stream, first_control, second_control));
}

#[test]
fn dropping_command_io_kills_and_reaps_its_child() {
    let directory = TestDirectory::new();
    let pid_path = directory.path.join("pid");
    let script = directory.script(
        "block",
        "pid_path=$1; shift; printf '%s' \"$$\" > \"$pid_path\"; while IFS= read -r _line; do :; done",
    );
    let connector =
        CommandProviderConnector::new([script.into_os_string(), pid_path.clone().into_os_string()])
            .expect("create command connector");
    let connection = connector.connect().expect("start provider child");
    let (_, control, _) = connection.into_parts();
    wait_for_nonempty_file(&pid_path);
    let pid = fs::read_to_string(&pid_path)
        .expect("read child pid")
        .parse::<i32>()
        .expect("parse child pid");
    drop(control);

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let alive = unsafe { libc::kill(pid, 0) } == 0;
        if !alive {
            break;
        }
        assert!(Instant::now() < deadline, "provider child {pid} survived cleanup");
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn dropping_command_io_terminates_background_descendants_without_blocking() {
    let directory = TestDirectory::new();
    let descendant_path = directory.path.join("descendant-pid");
    let script = directory.script(
        "background-descendant",
        "descendant_path=$1; shift; sleep 300 & descendant=$!; printf '%s' \"$descendant\" > \"$descendant_path\"; exit 0",
    );
    let connector = CommandProviderConnector::new([
        script.into_os_string(),
        descendant_path.clone().into_os_string(),
    ])
    .expect("create command connector");
    let connection = connector.connect().expect("start provider child");
    let (_, control, _) = connection.into_parts();
    wait_for_nonempty_file(&descendant_path);
    let descendant = fs::read_to_string(&descendant_path)
        .expect("read descendant pid")
        .parse::<i32>()
        .expect("parse descendant pid");
    assert_eq!(unsafe { libc::kill(descendant, 0) }, 0, "provider descendant must be alive");

    let (finished_tx, finished_rx) = mpsc::sync_channel(1);
    let cleanup = thread::spawn(move || {
        drop(control);
        let _ = finished_tx.send(());
    });
    let completed = finished_rx.recv_timeout(Duration::from_secs(2)).is_ok();
    if !completed {
        let _ = unsafe { libc::kill(descendant, libc::SIGKILL) };
        finished_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("cleanup finishes after the leaked descendant is killed");
    }
    cleanup.join().expect("join provider cleanup");

    assert!(completed, "provider cleanup blocked on a descendant-owned diagnostic pipe");
    let deadline = Instant::now() + Duration::from_secs(5);
    while unsafe { libc::kill(descendant, 0) } == 0 {
        assert!(Instant::now() < deadline, "provider descendant {descendant} survived cleanup");
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn detached_stderr_holder() {
    let Some(pid_path) = std::env::var_os("CMUX_TEST_DETACHED_STDERR_HOLDER") else {
        return;
    };
    let session = unsafe { libc::setsid() };
    assert!(session > 0, "detach provider test descendant");
    fs::write(pid_path, std::process::id().to_string()).expect("record detached descendant pid");
    thread::sleep(Duration::from_secs(300));
}

#[test]
fn dropping_command_io_cancels_diagnostics_from_a_detached_descendant() {
    let directory = TestDirectory::new();
    let descendant_path = directory.path.join("detached-descendant-pid");
    let helper_test = concat!(
        "machine_provider_client::machine_provider_transport::tests::",
        "detached_stderr_holder"
    );
    let script = directory.script(
        "detached-descendant",
        &format!(
            "test_binary=$1; descendant_path=$2; shift 2; \
                 CMUX_TEST_DETACHED_STDERR_HOLDER=\"$descendant_path\" \
                 \"$test_binary\" --exact \"{helper_test}\" --nocapture & \
                 descendant=$!; \
                 while [ ! -s \"$descendant_path\" ]; do \
                   kill -0 \"$descendant\" 2>/dev/null || exit 1; \
                   sleep 1; \
                 done; \
                 exit 0"
        ),
    );
    let test_binary = std::env::current_exe().expect("locate provider test binary");
    let connector = CommandProviderConnector::new([
        script.into_os_string(),
        test_binary.into_os_string(),
        descendant_path.clone().into_os_string(),
    ])
    .expect("create command connector");
    let connection = connector.connect().expect("start provider child");
    let (_, control, _) = connection.into_parts();
    wait_for_nonempty_file(&descendant_path);
    let descendant = fs::read_to_string(&descendant_path)
        .expect("read detached descendant pid")
        .parse::<i32>()
        .expect("parse detached descendant pid");
    assert_eq!(unsafe { libc::kill(descendant, 0) }, 0, "detached descendant must be alive");

    let (finished_tx, finished_rx) = mpsc::sync_channel(1);
    let cleanup = thread::spawn(move || {
        drop(control);
        let _ = finished_tx.send(());
    });
    let completed = finished_rx.recv_timeout(Duration::from_secs(2)).is_ok();
    if !completed {
        let _ = unsafe { libc::kill(descendant, libc::SIGKILL) };
        finished_rx
            .recv_timeout(Duration::from_secs(5))
            .expect("cleanup finishes after the detached descendant is killed");
    }
    cleanup.join().expect("join provider cleanup");

    let _ = unsafe { libc::kill(descendant, libc::SIGKILL) };
    assert!(completed, "provider cleanup waited for detached descendant diagnostics");
}

#[test]
fn command_stderr_is_drained_bounded_sanitized_and_token_redacted() {
    let directory = TestDirectory::new();
    let ready = directory.path.join("ready");
    let script = directory.script(
        "stderr",
        "ready=$1; shift; IFS= read -r secret; printf '%s\\n' \"$secret\" >&2; printf ready > \"$ready\"; i=0; while [ $i -lt 20000 ]; do printf 'unsafe\\033[31m diagnostic '; i=$((i + 1)); done >&2; while IFS= read -r _line; do :; done",
    );
    let connector =
        CommandProviderConnector::new([script.into_os_string(), ready.clone().into_os_string()])
            .expect("create command connector");
    let connection = connector.connect().expect("start provider child");
    let (token, mut control, _) = connection.into_parts();
    control
        .writer
        .write_all(format!("{}\n", token.expose()).as_bytes())
        .expect("send token-shaped input");
    control.writer.flush().expect("flush token-shaped input");
    wait_for_nonempty_file(&ready);

    let deadline = Instant::now() + Duration::from_secs(10);
    let diagnostic = loop {
        let diagnostic = control.diagnostic().unwrap_or_default();
        if diagnostic.contains("[truncated]") {
            break diagnostic;
        }
        assert!(Instant::now() < deadline, "timed out draining provider stderr");
        thread::sleep(Duration::from_millis(10));
    };
    assert!(diagnostic.len() <= COMMAND_DIAGNOSTIC_BYTES + 32);
    assert!(!diagnostic.contains('\u{1b}'));
    assert!(!diagnostic.contains(token.expose()));
    drop(control);
}

#[test]
fn ssh_connector_uses_one_private_master_path_and_fixed_remote_commands() {
    let directory = TestDirectory::new();
    let records = directory.path.join("ssh-arguments");
    let fake_ssh = directory.script(
        "ssh",
        "records=$(dirname \"$0\")/ssh-arguments; printf '%s\\t%s\\n' \"$$\" \"$*\" >> \"$records\"; while IFS= read -r _line; do :; done",
    );

    let connector =
        SshProviderConnector::with_program(fake_ssh, "cmux.cloud").expect("create SSH connector");
    let connection = connector.connect().expect("open SSH control");
    let (token, control, streams) = connection.into_parts();
    let stream = streams.open().expect("open SSH stream");
    let deadline = Instant::now() + Duration::from_secs(10);
    let lines = loop {
        let lines = fs::read_to_string(&records).unwrap_or_default();
        if lines.lines().count() >= 2 {
            break lines;
        }
        assert!(Instant::now() < deadline, "timed out waiting for SSH argv records");
        thread::sleep(Duration::from_millis(10));
    };
    let lines = lines.lines().collect::<Vec<_>>();
    let control_line =
        lines.iter().find(|line| line.ends_with("cmux provider control")).expect("control command");
    let stream_line =
        lines.iter().find(|line| line.ends_with("cmux provider stream")).expect("stream command");
    assert!(control_line.contains("ControlMaster=yes"));
    assert!(stream_line.contains("ControlMaster=no"));
    let control_path = control_line
        .split_whitespace()
        .find(|argument| argument.starts_with("ControlPath="))
        .expect("control path");
    assert!(stream_line.split_whitespace().any(|argument| argument == control_path));
    let path = PathBuf::from(control_path.trim_start_matches("ControlPath="));
    let control_directory = path.parent().expect("control directory").to_path_buf();
    let directory_mode =
        fs::metadata(&control_directory).expect("control directory metadata").permissions().mode()
            & 0o777;
    assert_eq!(directory_mode, 0o700);
    assert!(!lines.join("\n").contains(token.expose()));
    drop((stream, control, streams));
    assert!(!control_directory.exists());
}

#[test]
fn cloud_ssh_connector_emits_host_user_port_identity_and_exact_remote_command() {
    let directory = TestDirectory::new();
    let records = directory.path.join("cloud-ssh-arguments");
    let fake_ssh = directory.script(
        "cloud-ssh",
        "records=$(dirname \"$0\")/cloud-ssh-arguments; temporary=$records.$$; printf '%s\\n' \"$@\" > \"$temporary\"; mv \"$temporary\" \"$records\"; while IFS= read -r _line; do :; done",
    );
    let identity = directory.path.join("cloud identity");
    let connector = SshProviderConnector::cloud_with_program(
        fake_ssh,
        "edge.example.com",
        Some("dev"),
        Some(2200),
        Some(identity.clone()),
    )
    .expect("create configured cloud SSH connector");

    let connection = connector.connect().expect("open cloud SSH control");
    let (token, control, _) = connection.into_parts();
    wait_for_nonempty_file(&records);
    let arguments = fs::read_to_string(records).expect("read cloud SSH argv");
    let arguments = arguments.lines().collect::<Vec<_>>();

    for option in [
        "BatchMode=yes",
        "StrictHostKeyChecking=yes",
        "ForwardAgent=no",
        "ForwardX11=no",
        "ClearAllForwardings=yes",
    ] {
        assert!(arguments.windows(2).any(|pair| pair == ["-o", option]), "{arguments:?}");
    }
    assert!(arguments.windows(2).any(|pair| pair == ["-p", "2200"]));
    assert!(
        arguments
            .windows(2)
            .any(|pair| { pair[0] == "-i" && pair[1] == identity.to_string_lossy().as_ref() })
    );
    let tail = ["--", "dev@edge.example.com", "cmux", "provider", "control"];
    assert!(arguments.windows(5).any(|window| window == tail));
    assert!(!arguments.iter().any(|argument| argument.contains(token.expose())));
    drop(control);
}

#[test]
fn unix_connector_preserves_fixed_token_and_opens_distinct_sockets() {
    use std::os::unix::net::UnixListener;

    let directory = TestDirectory::new();
    let socket_path = directory.path.join("provider.sock");
    let listener = UnixListener::bind(&socket_path).expect("bind provider socket");
    let connector = UnixProviderConnector::new(
        socket_path,
        BearerToken::new("fixed-token").expect("fixed token"),
    );
    let connection = connector.connect().expect("connect Unix control");
    let (token, control, streams) = connection.into_parts();
    let (_accepted_control, _) = listener.accept().expect("accept control");
    let stream = streams.open().expect("connect Unix stream");
    let (_accepted_stream, _) = listener.accept().expect("accept stream");
    assert_eq!(token.expose(), "fixed-token");
    drop((stream, control));
}

#[test]
fn generated_unix_connector_uses_a_fresh_client_side_bearer_per_generation() {
    use std::os::unix::net::UnixListener;

    let directory = TestDirectory::new();
    let socket_path = directory.path.join("generated-provider.sock");
    let listener = UnixListener::bind(&socket_path).expect("bind provider socket");
    let connector = UnixProviderConnector::generated(socket_path);

    let first = connector.connect().expect("connect first generation");
    let (_first_socket, _) = listener.accept().expect("accept first generation");
    let second = connector.connect().expect("connect second generation");
    let (_second_socket, _) = listener.accept().expect("accept second generation");
    let (first_token, first_control, _) = first.into_parts();
    let (second_token, second_control, _) = second.into_parts();

    assert_ne!(first_token.expose(), second_token.expose());
    assert!(first_token.expose().len() >= 32);
    assert!(second_token.expose().len() >= 32);
    drop((first_control, second_control));
}

#[test]
fn rejects_ssh_option_injection_in_destination() {
    assert!(SshProviderConnector::new("-oProxyCommand=bad").is_err());
    assert!(SshProviderConnector::new(OsString::new()).is_err());
    assert!(SshProviderConnector::cloud("-oProxyCommand=bad", None, None, None).is_err());
    assert!(SshProviderConnector::cloud("cmux.cloud", Some("bad user"), None, None).is_err());
    assert!(SshProviderConnector::cloud("cmux.cloud", None, Some(0), None).is_err());
}

#[test]
fn deadline_interrupts_a_blocked_provider_pipe() {
    let directory = TestDirectory::new();
    let script = directory.script("block-forever", "while IFS= read -r _line; do :; done");
    let connector =
        CommandProviderConnector::new([script.into_os_string()]).expect("create command connector");
    let connection = connector.connect().expect("open command control");
    let (_, control, _) = connection.into_parts();
    let ProviderIoParts { reader, writer: _writer, guard } = control.into_parts();
    let deadline = guard.deadline(Duration::from_millis(25)).expect("start deadline");
    let mut reader = BufReader::new(reader);
    let mut line = String::new();
    assert_eq!(reader.read_line(&mut line).expect("deadline closes pipe"), 0);
    assert!(deadline.timed_out());
}
