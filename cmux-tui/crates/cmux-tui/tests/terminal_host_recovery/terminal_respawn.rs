//! cx-6so.49 L2: a placed terminal whose shell is gone with its host (a
//! SIGKILL of both, a host that died while no daemon ran) gets a new shell
//! under the same terminal id and a new incarnation. Its tab never reads
//! dead, the new shell starts below the previous screen and one dim marker
//! line, an agent session it ran resumes (unless "Resume Agents After
//! Restart" is off), a command it ran never runs again and the marker line
//! names it, and a real process end or a close stays ended.

use std::io::Write as _;

use super::pty_custody::{kill_shell_then_host, send_line, wait_for_dead_host};
use super::*;

const MARKER: &str = "session restored (previous process ended)";

/// A terminal running the user's default shell, with shell integration, in
/// a new workspace named `name`: (internal terminal id, incarnation,
/// surface).
fn start_default_shell(harness: &RecoveryHarness, name: &str) -> (String, String, u64) {
    let created =
        request(&harness.socket, serde_json::json!({"id":1,"cmd":"new-workspace","name":name}));
    let surface = created["surface"].as_u64().expect("new-workspace returned no surface");
    let tab = tab_named(harness, name);
    let terminal_id = tab["terminal_id"].as_str().expect("tab has no terminal id").to_string();
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default().to_string();
    (terminal_id, incarnation, surface)
}

fn tab_named(harness: &RecoveryHarness, name: &str) -> serde_json::Value {
    let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == name)
        .and_then(first_tab)
        .cloned()
        .unwrap_or_else(|| panic!("workspace {name} has no tab: {tree}"))
}

fn screen(harness: &RecoveryHarness, surface: u64) -> String {
    request(&harness.socket, serde_json::json!({"cmd":"read-screen","surface":surface}))["text"]
        .as_str()
        .unwrap_or_default()
        .to_string()
}

/// The number the shell prints after `<tag>-` for `echo <tag>-<expr>`.
fn echo_value(harness: &RecoveryHarness, surface: u64, tag: &str, expr: &str) -> String {
    send_line(&harness.socket, surface, &format!("echo {tag}-{expr}-end"));
    let needle = format!("{tag}-");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let text = screen(harness, surface);
        // The echoed command line shows the expression; the output does not.
        // A line the shell is still drawing (`dir-$(b`) has no `-end` yet:
        // only a value closed by `-end` on its own line, with no `$` left
        // unexpanded, is the output.
        let value = text.match_indices(&needle).find_map(|(at, _)| {
            let line = text[at + needle.len()..].lines().next()?;
            let (value, _) = line.split_once("-end")?;
            (!value.contains(expr) && !value.contains('$') && !value.is_empty())
                .then(|| value.to_string())
        });
        if let Some(value) = value {
            return value;
        }
        assert!(Instant::now() < deadline, "the shell printed no {needle}: {text}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Wait until `terminal_id` runs an incarnation other than `old`.
fn wait_for_respawn(harness: &RecoveryHarness, terminal_id: &str, old: &str) -> String {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
        if resolved["lifecycle"] == "running" && !incarnation.is_empty() && incarnation != old {
            return incarnation.to_string();
        }
        assert!(Instant::now() < deadline, "{terminal_id} was not respawned: {resolved}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn respawn_lines(harness: &RecoveryHarness, terminal_id: &str) -> Vec<serde_json::Value> {
    let log = harness.host_root().parent().map(|dir| dir.join("terminal-losses.jsonl"));
    log.and_then(|log| fs::read_to_string(log).ok())
        .unwrap_or_default()
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .filter(|line| line["terminal_id"] == terminal_id && line["event"] == "terminal_respawned")
        .collect()
}

/// The respawn lines for `terminal_id` once at least `count` exist. The
/// daemon appends a line after it commits the new incarnation, so a reader
/// that saw the terminal running can still be ahead of the log.
fn wait_for_respawn_lines(
    harness: &RecoveryHarness,
    terminal_id: &str,
    count: usize,
) -> Vec<serde_json::Value> {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let lines = respawn_lines(harness, terminal_id);
        if lines.len() >= count || Instant::now() >= deadline {
            return lines;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn kill_current_shell_and_host(harness: &RecoveryHarness, terminal_id: &str) {
    let (record_path, record) = load_terminal_host_records(&harness.host_root())
        .unwrap_or_default()
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal_id)
        .expect("the terminal has no host record");
    kill_shell_then_host(&record_path, &record);
}

/// a. Shell and host SIGKILLed under a running daemon: the same terminal
/// runs a new shell in the old directory, below the old screen and the
/// marker, and its tab is never removed.
#[test]
fn a_killed_shell_and_host_respawn_the_terminal_in_place() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("respawn-live");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "live");
    // Short, so `echo` of it never wraps on an 80-column screen.
    let cwd = PathBuf::from(format!("/tmp/cmux-rsp-{}", std::process::id()));
    fs::create_dir_all(&cwd).expect("create the shell's directory");
    let cwd = fs::canonicalize(&cwd).expect("canonical directory");
    let cwd_text = cwd.to_string_lossy().into_owned();
    send_line(&harness.socket, surface, &format!("cd '{cwd_text}'"));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while tab_named(&harness, "live")["cwd"].as_str() != Some(cwd_text.as_str()) {
        assert!(Instant::now() < deadline, "the shell never reported {cwd_text}");
        std::thread::sleep(Duration::from_millis(50));
    }
    send_line(&harness.socket, surface, "echo before-respawn-marker");
    wait_for_screen(&harness.socket, surface, "before-respawn-marker\n");
    let old_pid = echo_value(&harness, surface, "first", "$$");

    kill_current_shell_and_host(&harness, &terminal_id);
    let new_incarnation = wait_for_respawn(&harness, &terminal_id, &incarnation);

    let tab = tab_named(&harness, "live");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, MARKER);
    assert!(text.contains("before-respawn-marker"), "the old screen is gone: {text}");
    let new_pid = echo_value(&harness, surface, "second", "$$");
    assert_ne!(new_pid, old_pid, "the same shell answered");
    assert_eq!(echo_value(&harness, surface, "dir", "$PWD"), cwd_text);
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["old_incarnation"], incarnation.as_str());
    assert_eq!(lines[0]["new_incarnation"], new_incarnation.as_str());
    assert_eq!(lines[0]["cause"], "died_without_exit_status");
    assert_eq!(lines[0]["prefilled"], "none");
    let _ = fs::remove_dir_all(&cwd);
}

/// b. The host dies while no daemon runs (a reboot): the next daemon
/// respawns the terminal with the screen of its last checkpoint.
#[test]
fn a_host_that_died_without_a_daemon_is_respawned_at_the_next_start() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("respawn-restart");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "reboot");
    send_line(&harness.socket, surface, "echo checkpoint-marker");
    wait_for_screen(&harness.socket, surface, "checkpoint-marker\n");
    // A capture refuses while the shell still writes (its prompt, its
    // integration reports); a retry under the same key is the client's part.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let checkpoint = request_response(
            &harness.socket,
            serde_json::json!({
                "protocol":"cmux.protocol/2",
                "type":"request",
                "id":"respawn-checkpoint",
                "operation":"session.journal.checkpoint.create",
                "idempotency_key":"respawn-checkpoint",
                "params":{"machine":"current","session":"current"},
            }),
        );
        if checkpoint["ok"] == true {
            break;
        }
        assert!(Instant::now() < deadline, "{checkpoint}");
        std::thread::sleep(Duration::from_millis(100));
    }
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    harness.sigkill();
    // SAFETY: the record PID is the harness-owned terminal host.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    harness.restart();

    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "reboot");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, MARKER);
    assert!(text.contains("checkpoint-marker"), "the checkpoint screen is gone: {text}");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["cause"], "dead_before_adoption");
}

/// b2. A reboot with no checkpoint made by a client: the daemon gets
/// `SIGTERM`, then its host dies. The next daemon respawns the terminal with
/// the screen it had when the daemon stopped, also while another terminal
/// keeps writing (a build log, an agent's spinner).
#[test]
fn a_terminated_daemon_keeps_the_screen_for_a_respawn_after_a_reboot() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("respawn-reboot-screen");
    let (_, _, busy) = start_default_shell(&harness, "busy");
    send_line(&harness.socket, busy, "while :; do echo busy; sleep 0.005; done");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "reboot");
    // The output, not the echoed command line, carries the marker.
    send_line(&harness.socket, surface, "printf 'shutdown-%s\\n' marker");
    wait_for_screen(&harness.socket, surface, "shutdown-marker\n");
    let (_, record) = wait_for_host_records(&harness.host_root(), 2)
        .into_iter()
        .find(|(_, record)| record.terminal_id == terminal_id)
        .expect("the terminal has no host record");
    harness.terminate();
    // SAFETY: the record PID is the harness-owned terminal host.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    harness.restart();

    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "reboot");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    let text = wait_for_screen(&harness.socket, surface, MARKER);
    assert!(text.contains("shutdown-marker"), "the screen at shutdown is gone: {text}");
}

/// The process exists and is not a zombie.
fn host_running(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the PID exists.
    if unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat"))
        && let Some(state) = stat.rsplit(')').next().and_then(|rest| rest.split_whitespace().next())
    {
        return state != "Z";
    }
    true
}

/// b3. The owner stays gone longer than the host orphan grace (a crash or
/// an update relaunch while the Mac is unattended): the host ends its shell
/// with an `owner-gone` record (cx-3ryj). That is a host that died without
/// a daemon, so the next daemon respawns the terminal instead of leaving its
/// tab on "Terminal lost: its host process ended".
#[test]
fn a_host_that_ended_at_the_orphan_grace_is_respawned_at_the_next_start() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("respawn-orphan");
    harness.extra_env.push(("CMUX_TUI_HOST_ORPHAN_GRACE_SECS".into(), "2".into()));
    harness.restart();
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "orphan");
    send_line(&harness.socket, surface, "echo orphan-marker");
    wait_for_screen(&harness.socket, surface, "orphan-marker\n");
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    harness.sigkill();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(20));
    while host_running(record.host_pid) {
        assert!(Instant::now() < deadline, "the orphaned host outlived its grace");
        std::thread::sleep(Duration::from_millis(50));
    }
    harness.restart();

    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "orphan");
    assert_eq!(tab["dead"], false, "{tab}");
    let surface = tab["surface"].as_u64().expect("the respawned tab has a surface");
    wait_for_screen(&harness.socket, surface, MARKER);
}

/// b4. #21088: after an update the new daemon cannot adopt a host of the
/// earlier build (here: a record version it cannot read), and that host then
/// dies without recording its shell's end (a SIGTERM from the Dock, a kill).
/// The tab must respawn like any other host loss, not stay on
/// "Terminal, Failed" until the user restarts the shell by hand.
#[test]
fn an_unadoptable_host_that_dies_without_a_record_is_respawned() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("respawn-unadoptable");
    let (terminal_id, incarnation, _) = start_default_shell(&harness, "unadoptable");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    harness.sigkill();
    let mut future: serde_json::Value =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    future["record_version"] = serde_json::json!(99);
    fs::write(&record_path, serde_json::to_vec(&future).unwrap()).unwrap();
    harness.restart();
    let resolved = request(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_ne!(resolved["lifecycle"], "exited", "{resolved}");

    // The host and its shell die with no exit record.
    let host_pid = record.host_pid as libc::pid_t;
    let _ = Command::new("/usr/bin/pkill").args(["-KILL", "-P", &host_pid.to_string()]).status();
    // SAFETY: the record PID is the harness-owned terminal host.
    unsafe { libc::kill(host_pid, libc::SIGKILL) };
    wait_for_process_and_group_absent(host_pid);

    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let tab = tab_named(&harness, "unadoptable");
    assert_eq!(tab["dead"], false, "{tab}");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0]["cause"], "unadoptable_host_ended");
}

/// A respawn harness whose daemon reads settings file `settings` (none:
/// a missing file, the defaults) and finds a `claude` stand-in first on
/// PATH that prints `resumed:` and its arguments.
fn agent_harness(name: &str, settings: Option<&str>) -> RecoveryHarness {
    use std::os::unix::fs::PermissionsExt as _;
    let mut harness = RecoveryHarness::start_unstarted(name);
    let bin_dir = harness.dir.join("agent-bin");
    fs::create_dir_all(&bin_dir).expect("agent bin dir");
    let claude = bin_dir.join("claude");
    fs::write(&claude, "#!/bin/sh\necho \"resumed:$*\"\nsleep 600\n").expect("write claude");
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).expect("chmod");
    let config = harness.dir.join("cmux-next.json");
    if let Some(settings) = settings {
        fs::write(&config, settings).expect("write settings");
    }
    let path = std::env::var("PATH").unwrap_or_default();
    harness.extra_env.extend([
        ("CMUX_NEXT_CONFIG_FILE".to_string(), config.display().to_string()),
        ("PATH".to_string(), format!("{}:{path}", bin_dir.display())),
    ]);
    harness.restart();
    harness
}

/// Respawn the terminal of a new shell tab `name` after its claude session
/// `abc-123` started: (terminal id, surface after the respawn).
fn respawn_after_agent_start(harness: &RecoveryHarness, name: &str) -> (String, u64) {
    let (terminal_id, incarnation, surface) = start_default_shell(harness, name);
    let public_id = tab_named(harness, name)["terminal_resource_id"]
        .as_str()
        .expect("tab has no public terminal id")
        .to_string();
    let mut hook = Command::new(bin())
        .args(["__agent-hook", "claude", "SessionStart"])
        .env("CMUX_TUI_SOCKET", &harness.socket)
        .env("CMUX_TUI_TERMINAL_ID", &public_id)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .expect("spawn the agent hook");
    hook.stdin
        .take()
        .expect("hook stdin")
        .write_all(b"{\"session_id\":\"abc-123\"}\n")
        .expect("write the hook payload");
    assert!(hook.wait().expect("wait for the hook").success());
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let agents = request(&harness.socket, serde_json::json!({"cmd":"list-agents"}));
        let claimed =
            agents["agents"].as_array().into_iter().flatten().any(|agent| {
                agent["surface"].as_u64() == Some(surface) && agent["agent"] == "claude"
            });
        if claimed {
            break;
        }
        assert!(Instant::now() < deadline, "the hook never reached the terminal: {agents}");
        std::thread::sleep(Duration::from_millis(50));
    }
    kill_current_shell_and_host(harness, &terminal_id);
    wait_for_respawn(harness, &terminal_id, &incarnation);
    let surface = tab_named(harness, name)["surface"].as_u64().expect("surface");
    (terminal_id, surface)
}

/// The agent marker line, which names the resume command.
const AGENT_MARKER: &str = "session restored; resume with claude --resume abc-123";

/// c. By default an agent session the terminal ran resumes by itself: the
/// resume runs at the new shell's prompt.
#[cfg(unix)]
#[test]
fn a_respawned_terminal_resumes_its_agent_session() {
    let _exclusive = exclusive_process_test();
    let harness = agent_harness("respawn-agent", None);
    let (terminal_id, surface) = respawn_after_agent_start(&harness, "agent");
    // The pane's `claude` shim (claude_wrapper, cfdde0b6ce7) adds its hooks
    // as `--settings <file>` before the resume's own arguments, and a long
    // line wraps: compare the stand-in's output without whitespace.
    let resumed = |text: &str| {
        let compact = text.split_whitespace().collect::<String>();
        compact.rsplit_once("resumed:").is_some_and(|(_, args)| args.contains("--resumeabc-123"))
    };
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    while !resumed(&screen(&harness, surface)) {
        assert!(Instant::now() < deadline, "the resume did not run: {}", screen(&harness, surface));
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(screen(&harness, surface).contains(AGENT_MARKER), "{}", screen(&harness, surface));
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.first().map(|line| line["prefilled"].clone()), Some("harness".into()));
}

/// c0. With "Resume Agents After Restart" off nothing runs or is typed:
/// the marker line shows the resume command.
#[cfg(unix)]
#[test]
fn with_resume_off_a_respawned_terminal_only_shows_the_resume_command() {
    let _exclusive = exclusive_process_test();
    let harness =
        agent_harness("respawn-agent-off", Some(r#"{"sessions": {"resumeAgents": false}}"#));
    let (terminal_id, surface) = respawn_after_agent_start(&harness, "agent");
    wait_for_screen(&harness.socket, surface, AGENT_MARKER);
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.first().map(|line| line["prefilled"].clone()), Some("none".into()));
    std::thread::sleep(Duration::from_secs(1));
    let text = screen(&harness, surface);
    let after = text.rsplit_once(AGENT_MARKER).map(|(_, tail)| tail).unwrap_or_default();
    assert!(!text.contains("resumed:"), "the resume ran: {text}");
    assert!(!after.contains("--resume"), "the resume was typed: {text}");
}

/// c1. A non-interactive agent run (`claude -p`) that reported a session
/// leaves nothing to resume: its respawned terminal offers no agent command.
#[cfg(unix)]
#[test]
fn a_respawned_terminal_does_not_resume_a_non_interactive_agent_run() {
    non_interactive_run_is_not_resumed(
        "print",
        &[
            ("SessionStart", r#"{"session_id":"abc-123"}"#),
            ("UserPromptSubmit", r#"{"session_id":"abc-123","prompt":"hi"}"#),
        ],
    );
}

/// c1b. The first hook of a run that reaches the terminal is not always its
/// session start: each hook is its own connection, so a later hook can be
/// applied first and the start, now older than the terminal's hook fence, is
/// dropped. How the run was started is read at whichever hook comes first.
#[cfg(unix)]
#[test]
fn a_non_interactive_run_whose_first_applied_hook_is_a_prompt_is_not_resumed() {
    non_interactive_run_is_not_resumed(
        "prompt-first",
        &[("UserPromptSubmit", r#"{"session_id":"abc-123","prompt":"hi"}"#)],
    );
}

/// Runs a `claude -p` stand-in that reports `hooks` in order, kills the
/// terminal's shell and host, and checks the respawn offers no agent command.
#[cfg(unix)]
fn non_interactive_run_is_not_resumed(name: &str, hooks: &[(&str, &str)]) {
    use std::os::unix::fs::PermissionsExt as _;
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start(&format!("respawn-{name}"));
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, name);
    let public_id = tab_named(&harness, name)["terminal_resource_id"]
        .as_str()
        .expect("tab has no public terminal id")
        .to_string();
    // A `claude` that reports its hooks as the real ones do, then keeps
    // running in the foreground.
    let dir = tempfile::tempdir().expect("temp dir");
    let claude = dir.path().join("claude");
    let hook = |event: &str, payload: &str| {
        format!(
            "printf '%s\\n' '{payload}' | CMUX_TUI_SOCKET='{}' CMUX_TUI_TERMINAL_ID='{}' '{}' \
             __agent-hook claude {event}\n",
            harness.socket.display(),
            public_id,
            bin()
        )
    };
    let hooks: String = hooks.iter().map(|(event, payload)| hook(event, payload)).collect();
    fs::write(&claude, format!("#!/bin/sh\n{hooks}echo print-run-started\nsleep 600\n"))
        .expect("write the claude stand-in");
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).expect("chmod");
    send_line(&harness.socket, surface, &format!("'{}' -p hi", claude.display()));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while !screen(&harness, surface).contains("print-run-started") {
        assert!(Instant::now() < deadline, "the run never started: {}", screen(&harness, surface));
        std::thread::sleep(Duration::from_millis(50));
    }
    // The hooks reached the terminal before its host dies.
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let agents = request(&harness.socket, serde_json::json!({"cmd":"list-agents"}));
        let claimed =
            agents["agents"].as_array().into_iter().flatten().any(|agent| {
                agent["surface"].as_u64() == Some(surface) && agent["agent"] == "claude"
            });
        if claimed {
            break;
        }
        assert!(Instant::now() < deadline, "the hooks never reached the terminal: {agents}");
        std::thread::sleep(Duration::from_millis(50));
    }

    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.first().map(|line| line["prefilled"].clone()), Some("none".into()));
    let surface = tab_named(&harness, name)["surface"].as_u64().expect("surface");
    std::thread::sleep(Duration::from_secs(1));
    let text = screen(&harness, surface);
    assert!(!text.split_whitespace().collect::<String>().contains("--resume"), "{text}");
}

/// The Muse session of the stand-in in
/// [`a_respawned_terminal_resumes_its_muse_session_without_its_input_frame`].
const MUSE_SESSION: &str = "01a14ec1-9cca-7b72-832c-5148ab7bcd41";

/// c3. Muse Code (dogfood, Oct 27): after the host died, a terminal that ran
/// a Muse session came back as a bare shell under the old screen, Muse's
/// input frame (voice bar, prompt, footer) left in it as if Muse still ran.
/// A Muse session its hooks reported resumes (`muse resume <id>`), and the
/// old input frame is not replayed: the resumed Muse draws its own. The
/// transcript above it stays.
#[cfg(unix)]
#[test]
fn a_respawned_terminal_resumes_its_muse_session_without_its_input_frame() {
    use std::os::unix::fs::PermissionsExt as _;
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("respawn-muse");
    let bin_dir = harness.dir.join("agent-bin");
    fs::create_dir_all(&bin_dir).expect("agent bin dir");
    let path = std::env::var("PATH").unwrap_or_default();
    harness.extra_env.push(("PATH".to_string(), format!("{}:{path}", bin_dir.display())));
    harness.restart();
    let name = "muse";
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, name);
    let public_id = tab_named(&harness, name)["terminal_resource_id"]
        .as_str()
        .expect("tab has no public terminal id")
        .to_string();
    // A `muse` that reports its session start as its hook does, draws a
    // transcript line and its input frame with the cursor on the prompt row,
    // as Muse Code does, and keeps running; `muse resume <id>` prints what it
    // got.
    let muse = format!(
        "#!/bin/sh\n\
         if [ \"$1\" = resume ]; then echo \"resumed:$*\"; exec sleep 600; fi\n\
         printf '%s\\n' '{{\"session_id\":\"{MUSE_SESSION}\"}}' | CMUX_TUI_SOCKET='{socket}' \
         CMUX_TUI_TERMINAL_ID='{public_id}' '{bin}' __agent-hook muse SessionStart\n\
         printf 'muse transcript line\\r\\n\\r\\n\
         \u{2500}\u{2500} Voice input (alt + v to start) \u{2500}\u{2500}\\r\\n\
         \u{276f} \\r\\n\u{2500}\u{2500}\u{2500}\u{2500}\\r\\n  muse-wonder-1.0 \u{b7} high\
         \\033[2A\\r\\033[2C'\n\
         sleep 600\n",
        socket = harness.socket.display(),
        bin = bin(),
    );
    let muse_path = bin_dir.join("muse");
    fs::write(&muse_path, muse).expect("write muse");
    fs::set_permissions(&muse_path, fs::Permissions::from_mode(0o755)).expect("chmod");
    send_line(&harness.socket, surface, "muse");
    wait_for_screen(&harness.socket, surface, "Voice input");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let agents = request(&harness.socket, serde_json::json!({"cmd":"list-agents"}));
        let claimed =
            agents["agents"].as_array().into_iter().flatten().any(|agent| {
                agent["surface"].as_u64() == Some(surface) && agent["agent"] == "muse"
            });
        if claimed {
            break;
        }
        assert!(Instant::now() < deadline, "the hook never reached the terminal: {agents}");
        std::thread::sleep(Duration::from_millis(50));
    }

    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let surface = tab_named(&harness, name)["surface"].as_u64().expect("surface");
    // Long lines wrap: compare without whitespace.
    let compact = |text: &str| text.split_whitespace().collect::<String>();
    let expected = format!("resumed:resume{MUSE_SESSION}");
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    while !compact(&screen(&harness, surface)).contains(&expected) {
        assert!(Instant::now() < deadline, "the resume did not run: {}", screen(&harness, surface));
        std::thread::sleep(Duration::from_millis(50));
    }
    let text = screen(&harness, surface);
    assert!(
        compact(&text).contains(&format!("sessionrestored;resumewithmuseresume{MUSE_SESSION}")),
        "{text}"
    );
    assert!(text.contains("muse transcript line"), "the transcript was dropped: {text}");
    assert!(!text.contains("Voice input"), "the old input frame was replayed: {text}");
    assert!(!text.contains("muse-wonder"), "the old footer was replayed: {text}");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.first().map(|line| line["prefilled"].clone()), Some("harness".into()));
}

/// c2. A command tab respawned by a later daemon (the daemon was killed,
/// then the host died) never runs or types its command: the marker line
/// names its command line. A command with an argument that looks like a
/// credential is not stored at all: its tab only names the program.
#[test]
fn a_command_tab_names_its_command_after_a_daemon_restart_without_secrets() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("respawn-argv");
    let entropy = "Zx9Qw2Lp7Rt4Vb8Nm3Kj6Hg1Fd5Sa0YcXeUiOo";
    let tabs = [
        ("argv", serde_json::json!(["/bin/sh", "-c", "echo ran-$((6*7)); sleep 600", "cmuxargv"])),
        (
            "secret",
            serde_json::json!([
                "/bin/sh",
                "-c",
                "sleep 600",
                "cmuxsecret",
                "--password",
                "pw-hunter2"
            ]),
        ),
        ("token", serde_json::json!(["/bin/sh", "-c", "sleep 600", "cmuxtoken", entropy])),
        (
            "bearer",
            serde_json::json!([
                "/bin/sh",
                "-c",
                "sleep 600; curl -H 'Authorization: Bearer hunter2'",
                "cmuxbearer"
            ]),
        ),
    ];
    let mut terminals = Vec::new();
    for (index, (name, argv)) in tabs.iter().enumerate() {
        let created = request(
            &harness.socket,
            serde_json::json!({"id":index + 1,"cmd":"run","new_workspace":true,"name":name,"argv":argv}),
        );
        assert!(created["surface"].as_u64().is_some(), "{created}");
        let terminal_id = tab_named(&harness, name)["terminal_id"]
            .as_str()
            .expect("tab has no terminal id")
            .to_string();
        // The command runs before its host dies: a host killed while it
        // still starts is another case (a terminal that never ran).
        let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
        let incarnation = loop {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
            );
            let incarnation = resolved["terminal_incarnation"].as_str().unwrap_or_default();
            if resolved["lifecycle"] == "running" && !incarnation.is_empty() {
                break incarnation.to_string();
            }
            assert!(Instant::now() < deadline, "{name} never ran: {resolved}");
            std::thread::sleep(Duration::from_millis(50));
        };
        if *name == "argv" {
            let surface = created["surface"].as_u64().expect("surface");
            wait_for_screen(&harness.socket, surface, "ran-42");
        }
        terminals.push((*name, terminal_id, incarnation));
    }
    let records = wait_for_host_records(&harness.host_root(), tabs.len());
    harness.sigkill();
    for (_, terminal_id, _) in &terminals {
        let (record_path, record) = records
            .iter()
            .find(|(_, record)| &record.terminal_id == terminal_id)
            .expect("the terminal has no host record");
        // SAFETY: the record PID is the harness-owned terminal host.
        assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
        // A SIGKILL is delivered later: until the host has released its
        // liveness lock, the next daemon would find it alive and adopt it.
        wait_for_dead_host(record_path, record);
    }
    harness.restart();

    for (name, terminal_id, incarnation) in &terminals {
        wait_for_respawn(&harness, terminal_id, incarnation);
        let surface = tab_named(&harness, name)["surface"].as_u64().expect("surface");
        if *name == "argv" {
            // Whitespace dropped: the marker line wraps on the 80-column screen.
            let compact = |text: &str| text.split_whitespace().collect::<String>();
            let named = "itran/bin/sh-c'echoran-$((6*7));sleep600'cmuxargv)";
            let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
            while !compact(&screen(&harness, surface)).contains(named) {
                assert!(
                    Instant::now() < deadline,
                    "no marker naming the command: {}",
                    screen(&harness, surface)
                );
                std::thread::sleep(Duration::from_millis(50));
            }
            let lines = wait_for_respawn_lines(&harness, terminal_id, 1);
            assert_eq!(lines.first().map(|line| line["prefilled"].clone()), Some("none".into()));
            std::thread::sleep(Duration::from_secs(1));
            let text = compact(&screen(&harness, surface));
            let tail = text.rsplit_once(named).map(|(_, tail)| tail).unwrap_or_default();
            assert!(!tail.contains("ran-42"), "the command ran: {text}");
            assert!(!tail.contains("cmuxargv"), "the command was typed: {text}");
        } else {
            // The marker names the program instead: "(previous process ended; it ran sh)".
            let named = "session restored (previous process ended; it ran sh)";
            let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
            while !screen(&harness, surface).contains(named) {
                assert!(
                    Instant::now() < deadline,
                    "{name}: no restore marker naming the program: {}",
                    screen(&harness, surface)
                );
                std::thread::sleep(Duration::from_millis(50));
            }
            std::thread::sleep(Duration::from_secs(1));
            let text = screen(&harness, surface);
            let tail = text
                .rsplit_once(named)
                .map(|(_, tail)| tail.split_whitespace().collect::<String>())
                .unwrap_or_default();
            assert!(
                !tail.contains(&format!("cmux{name}")),
                "{name}: a credential-like command was offered: {tail}"
            );
            for secret in ["hunter2", entropy] {
                assert!(
                    !tail.contains(secret),
                    "{name}: a credential-like argument was offered: {tail}"
                );
            }
        }
    }
}

/// d. A real process end is never respawned: the terminal stays exited
/// with its code and its tab goes as before.
#[test]
fn a_shell_that_exits_is_not_respawned() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("respawn-exit");
    let created = request(
        &harness.socket,
        serde_json::json!({"id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,"name":"exit"}),
    );
    let terminal_id = created["terminal_id"].as_str().expect("terminal id").to_string();
    let surface = created["surface"].as_u64().expect("surface");
    send_line(&harness.socket, surface, "exit 3");
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    assert_eq!(resolved["exit"]["outcome"], serde_json::json!({"kind":"exit","code":3}));
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    loop {
        let tree = request(&harness.socket, serde_json::json!({"cmd":"list-workspaces"}));
        let left = tree["workspaces"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|workspace| workspace["name"] == "exit")
            .and_then(first_tab)
            .is_some();
        if !left {
            break;
        }
        assert!(Instant::now() < deadline, "the exited terminal kept its tab: {tree}");
        std::thread::sleep(Duration::from_millis(50));
    }
    std::thread::sleep(Duration::from_secs(1));
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    assert_eq!(resolved["exit"]["outcome"]["code"], 3, "{resolved}");
    assert!(respawn_lines(&harness, &terminal_id).is_empty());
}

// e. The crash-loop bound moved to host_supervisor.rs (cx-6so.49): a
// terminal that keeps losing its host respawns after a backoff, then ends
// as `restart_exhausted`.

/// f. A close that lands after the host died and before the respawn starts
/// wins: the terminal is never respawned.
#[test]
fn a_close_after_a_host_loss_is_never_respawned() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start_unstarted("respawn-close");
    let mut command = harness.daemon_command();
    command.env("CMUX_TUI_TEST_RESPAWN_DELAY_MS", "2000");
    harness.child = Some(command.spawn().expect("spawn the daemon"));
    wait_for_socket(&harness.socket);
    let (terminal_id, incarnation, _) = start_default_shell(&harness, "close");
    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "exited");
    let closed = request_response(
        &harness.socket,
        serde_json::json!({
            "cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
    assert_eq!(closed["ok"], true, "{closed}");
    std::thread::sleep(Duration::from_secs(3));
    assert!(respawn_lines(&harness, &terminal_id).is_empty(), "a closed terminal respawned");
    let resolved = request_response(
        &harness.socket,
        serde_json::json!({"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_ne!(resolved["data"]["lifecycle"], "running", "{resolved}");
    wait_for_no_host_records(&harness.host_root());
}

#[path = "tab_restart.rs"]
mod tab_restart;

/// `resume-command`: a person's resume command is typed on the respawned
/// terminal's new prompt, never run, and wins over what the daemon would
/// offer; reading it back names the stored line, and a clear removes it.
#[test]
fn a_respawned_terminal_offers_the_resume_command_a_person_set() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("respawn-resume");
    let (terminal_id, incarnation, surface) = start_default_shell(&harness, "resume");
    let identify = request(&harness.socket, serde_json::json!({"cmd":"identify"}));
    assert!(
        identify["capabilities"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|cap| cap == "resume-command"),
        "{identify}"
    );
    let set = request(
        &harness.socket,
        serde_json::json!({"cmd":"terminal-resume-command","surface":surface,"command":"  echo resume-ran-$((6*7)) "}),
    );
    assert_eq!(set["terminal_id"], terminal_id.as_str(), "{set}");
    assert_eq!(set["command"], "echo resume-ran-$((6*7))", "{set}");
    let read = request(
        &harness.socket,
        serde_json::json!({"cmd":"terminal-resume-command","terminal_id":terminal_id}),
    );
    assert_eq!(read["command"], "echo resume-ran-$((6*7))", "{read}");
    // The shell is up before its host is killed.
    echo_value(&harness, surface, "up", "$$");

    kill_current_shell_and_host(&harness, &terminal_id);
    wait_for_respawn(&harness, &terminal_id, &incarnation);
    let surface = tab_named(&harness, "resume")["surface"].as_u64().expect("respawned surface");
    let text = wait_for_screen(&harness.socket, surface, "echo resume-ran-$((6*7))");
    assert!(!text.contains("resume-ran-42"), "the resume command ran on its own: {text}");
    let lines = wait_for_respawn_lines(&harness, &terminal_id, 1);
    assert_eq!(lines.first().map(|line| line["prefilled"].clone()), Some("resume".into()));

    let cleared = request(
        &harness.socket,
        serde_json::json!({"cmd":"terminal-resume-command","terminal_id":terminal_id,"command":null}),
    );
    assert!(cleared["command"].is_null(), "{cleared}");
}
