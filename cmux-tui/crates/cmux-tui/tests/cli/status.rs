//! `cmux status set|clear|list|run` and the loading flags of `workspace
//! status set` through the CLI and a real daemon
//! (plans/cmux-next/status-indicators.md section 5): the daemon removes an
//! owned entry when its owner process or terminal ends or its TTL passes,
//! re-arms those watches after a restart, and refuses an owner it cannot
//! verify.
#![cfg(unix)]

use super::*;

/// Runs the CLI against `server` with `--json --socket` and returns the raw
/// output (no success assertion). `terminal` routes it as a cmux terminal
/// would instead: `CMUX_TUI_SOCKET` plus `CMUX_TUI_TERMINAL_ID`.
fn status_output(server: &HeadlessServer, terminal: Option<&str>, args: &[&str]) -> Output {
    let mut command = Command::new(bin());
    command
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG");
    match terminal {
        Some(terminal) => {
            command
                .arg("--json")
                .env("CMUX_TUI_SOCKET", &server.socket)
                .env("CMUX_TUI_TERMINAL_ID", terminal);
        }
        None => {
            command.env_remove("CMUX_TUI_SOCKET").arg("--json").arg("--socket").arg(&server.socket);
        }
    }
    command.args(args).output().unwrap()
}

/// The entries of `workspace`, from `cmux status list`.
fn entries(server: &HeadlessServer, workspace: &str) -> Vec<serde_json::Value> {
    let output = status_output(server, None, &["status", "list", "--target", workspace]);
    if !output.status.success() {
        let listed = status_output(server, None, &["workspace", "list"]);
        panic!(
            "status list --target {workspace} failed: {}\nworkspaces: {}",
            String::from_utf8_lossy(&output.stderr),
            String::from_utf8_lossy(&listed.stdout)
        );
    }
    let listed = json_output(&output);
    let snapshots = match &listed {
        serde_json::Value::Array(items) => items.clone(),
        other => vec![other.clone()],
    };
    snapshots
        .iter()
        .find(|snapshot| {
            snapshot["workspace"] == workspace
                || snapshot["workspace_id"] == workspace
                || snapshots.len() == 1
        })
        .and_then(|snapshot| snapshot["entries"].as_array().cloned())
        .unwrap_or_default()
}

fn entry(server: &HeadlessServer, workspace: &str, key: &str) -> Option<serde_json::Value> {
    entries(server, workspace).into_iter().find(|entry| entry["key"] == key)
}

/// Waits (bounded) until `key` is gone from `workspace`.
#[track_caller]
fn assert_cleared(server: &HeadlessServer, workspace: &str, key: &str, why: &str) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if entry(server, workspace, key).is_none() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("{key} was not cleared after {why}: {:?}", entries(server, workspace));
}

fn spawn_sleeper() -> Child {
    Command::new("/bin/sleep").arg("300").stdin(Stdio::null()).spawn().unwrap()
}

/// Stops the daemon (SIGKILL, so no shutdown path runs) and starts a new
/// one on the same socket and state directory.
fn restart_daemon(server: &mut HeadlessServer) {
    let _ = server.child.kill();
    let _ = server.child.wait();
    let _ = fs::remove_file(&server.socket);
    let mut child = Command::new(bin())
        .args(["--headless", "--socket"])
        .arg(&server.socket)
        .arg("--state")
        .arg(&server.state)
        .env("CMUX_TUI_CONFIG", server.dir.join("config.json"))
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if let Some(mut pipe) = child.stderr.take() {
        let sink = server.stderr.clone();
        std::thread::spawn(move || {
            let mut chunk = [0_u8; 4096];
            while let Ok(read) = Read::read(&mut pipe, &mut chunk) {
                if read == 0 {
                    break;
                }
                sink.lock().unwrap().extend_from_slice(&chunk[..read]);
            }
        });
    }
    server.child = child;
    server.wait_for_socket();
}

/// An entry owned by a process stays while the process runs, is removed by
/// the daemon when it exits, and survives a daemon restart in between (the
/// new daemon re-arms the watch; a retried set replays its stored result).
/// An owner that exits while the daemon is down is removed at the next
/// start, and a TTL removes its entry on time.
#[test]
fn status_entries_auto_clear_with_their_owner_and_replay_after_a_daemon_restart() {
    let mut server = HeadlessServer::start("status-owner-pid");
    state_cli(&server, None, &["workspace", "create", "--name", "alpha", "--empty"]);
    let workspace = workspace_id_named(&server, "alpha");
    let mut owner = spawn_sleeper();
    let mut early = spawn_sleeper();
    let owner_pid = owner.id().to_string();
    let early_pid = early.id().to_string();

    let set = |server: &HeadlessServer, extra: &[&str]| {
        let mut args = vec!["--idempotency-key", "status-owner-build", "status", "set", "build"];
        args.extend(["--label", "Building", "--target", workspace.as_str()]);
        args.extend(["--progress", "40%", "--style", "native", "--pid", owner_pid.as_str()]);
        args.extend(extra);
        let output = status_output(server, None, &args);
        assert_success(&output);
        json_output(&output)
    };
    let first = set(&server, &[]);
    assert_eq!(first["replayed"], false, "{first}");
    let build = entry(&server, &workspace, "build").expect("build entry");
    assert_eq!(build["text"], "Building", "{build}");
    assert_eq!(build["state"], "busy", "{build}");
    assert_eq!(build["progress"], 0.4, "{build}");
    assert_eq!(build["style"], "native", "{build}");
    assert_eq!(build["owner"]["pid"].to_string(), owner_pid, "{build}");

    let output = status_output(
        &server,
        None,
        &["status", "set", "early", "--label", "Early", "--target", &workspace],
    );
    assert_success(&output);
    let output = status_output(
        &server,
        None,
        &[
            "workspace",
            &workspace,
            "status",
            "set",
            "early",
            "Early",
            "--state",
            "waiting",
            "--pid",
            &early_pid,
        ],
    );
    assert_success(&output);
    assert_eq!(entry(&server, &workspace, "early").expect("early entry")["state"], "waiting");

    // `early`'s owner exits while no daemon runs.
    let _ = server.child.kill();
    let _ = server.child.wait();
    early.kill().unwrap();
    early.wait().unwrap();
    restart_daemon(&mut server);
    assert_cleared(&server, &workspace, "early", "its owner exited while the daemon was down");
    let build = entry(&server, &workspace, "build").expect("build survives the restart");
    assert_eq!(build["state"], "busy", "{build}");

    // The same idempotency key after the restart replays the stored result.
    let replay = set(&server, &[]);
    assert_eq!(replay["replayed"], true, "{replay}");

    owner.kill().unwrap();
    owner.wait().unwrap();
    assert_cleared(&server, &workspace, "build", "its owner process exited");

    let output = status_output(
        &server,
        None,
        &[
            "status", "set", "done", "--label", "Done", "--target", &workspace, "--state",
            "success", "--ttl", "5s",
        ],
    );
    assert_success(&output);
    let done = entry(&server, &workspace, "done").expect("done entry");
    assert!(done["expires_at_ms"].is_string(), "{done}");
    assert_cleared(&server, &workspace, "done", "its TTL passed");

    // A plain line has no owner and no TTL: it stays until cleared.
    let output = status_output(
        &server,
        None,
        &["status", "set", "note", "--label", "Note", "--target", &workspace],
    );
    assert_success(&output);
    assert!(entry(&server, &workspace, "note").unwrap()["state"].is_null());
    let output = status_output(&server, None, &["status", "clear", "note", "--target", &workspace]);
    assert_success(&output);
    assert!(entry(&server, &workspace, "note").is_none());
}

/// A loading entry set from inside a terminal is owned by that terminal and
/// removed when it closes; `status run` marks its run busy, owned by its own
/// process, records the outcome, and exits with the command's status; a
/// killed `status run` leaves no busy entry behind.
#[test]
fn status_run_and_terminal_owners_clear_through_a_real_daemon() {
    let server = HeadlessServer::start("status-run");
    state_cli(&server, None, &["workspace", "create", "--name", "beta"]);
    let workspace = workspace_id_named(&server, "beta");
    let snapshot = state_cli_topology(&server);
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .map(|terminal| terminal["id"].as_str().unwrap().to_string())
        .find(|terminal| workspace_of_terminal(&snapshot, terminal) == workspace)
        .expect("beta has a terminal");
    // A second tab keeps beta open when the owner terminal closes.
    let tab = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == terminal.as_str())
        .and_then(|item| item["tab_id"].as_str())
        .unwrap()
        .to_string();
    let pane = snapshot["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"] == tab.as_str())
        .and_then(|item| item["pane_id"].as_str())
        .unwrap()
        .to_string();
    state_cli(&server, None, &["tab", "create", "terminal", "--pane", &pane]);

    let output = status_output(
        &server,
        Some(&terminal),
        &["status", "set", "--label", "Compiling", "--target", &workspace, "--state", "busy"],
    );
    assert_success(&output);
    let key = format!("cli:{terminal}");
    let compiling = entry(&server, &workspace, &key).expect("terminal-owned entry");
    assert_eq!(compiling["owner"]["terminal"], terminal.as_str(), "{compiling}");
    assert_eq!(compiling["target_terminal"], terminal.as_str(), "{compiling}");

    let failed = Command::new(bin())
        .arg("--socket")
        .arg(&server.socket)
        .args(["status", "run", "--label", "Tests", "--target", &workspace, "--badge-ttl", "1h"])
        .args(["--", "/bin/sh", "-c", "exit 3"])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap();
    assert_eq!(failed.status.code(), Some(3), "{}", String::from_utf8_lossy(&failed.stderr));
    let run = entries(&server, &workspace)
        .into_iter()
        .find(|entry| entry["text"] == "Tests")
        .expect("status run entry");
    assert_eq!(run["state"], "error", "{run}");
    assert_eq!(run["exit_code"], 3, "{run}");
    assert!(run["duration_ms"].is_string(), "{run}");
    assert!(run["expires_at_ms"].is_string(), "{run}");
    assert!(run["owner"].is_null(), "a finished run has no owner: {run}");

    // The command kills `status run` itself once its busy entry shows: the
    // entry must not stay behind.
    let gate = server.dir.join("doomed.fifo");
    let made = Command::new("/usr/bin/mkfifo").arg(&gate).status().unwrap();
    assert!(made.success());
    let script = format!("read go < '{}'; kill -KILL $PPID", gate.display());
    let mut doomed_run = Command::new(bin())
        .arg("--socket")
        .arg(&server.socket)
        .args(["status", "run", "--label", "Doomed", "--target", &workspace])
        .args(["--", "/bin/sh", "-c", &script])
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let doomed_key = format!("run:{}", doomed_run.id());
    let deadline = Instant::now() + Duration::from_secs(15);
    let busy = loop {
        if let Some(entry) = entry(&server, &workspace, &doomed_key) {
            break entry;
        }
        assert!(Instant::now() < deadline, "status run never marked Doomed busy");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(busy["state"], "busy", "{busy}");
    assert_eq!(busy["owner"]["pid"], doomed_run.id(), "{busy}");
    fs::write(&gate, "go\n").unwrap();
    assert!(!doomed_run.wait().unwrap().success());
    assert_cleared(&server, &workspace, &doomed_key, "status run was killed");

    let output = status_output(&server, None, &["terminal", &terminal, "close"]);
    assert_success(&output);
    assert_cleared(&server, &workspace, &key, "its owner terminal closed");
}

/// The daemon refuses an owner it cannot verify, and stores nothing: a
/// terminal of no session it runs, a process that is not running, and a
/// process id the CLI rejects outright.
#[test]
fn status_set_refuses_a_forged_owner() {
    let server = HeadlessServer::start("status-forged-owner");
    state_cli(&server, None, &["workspace", "create", "--name", "gamma", "--empty"]);
    let workspace = workspace_id_named(&server, "gamma");

    let forged_terminal = format!("term_{}", "0".repeat(32));
    let output = status_output(
        &server,
        Some(&forged_terminal),
        &[
            "status", "set", "forged", "--label", "Forged", "--target", &workspace, "--state",
            "busy",
        ],
    );
    assert!(!output.status.success(), "a forged owner terminal was accepted");
    let error = json_error(&output);
    assert_eq!(error["code"], "validation.invalid", "{error}");
    assert!(error["message"].as_str().unwrap_or_default().contains("owner.terminal"), "{error}");

    let mut gone = Command::new("/usr/bin/true").spawn().unwrap();
    let gone_pid = gone.id().to_string();
    gone.wait().unwrap();
    let output = status_output(
        &server,
        None,
        &[
            "status", "set", "ghost", "--label", "Ghost", "--target", &workspace, "--state",
            "busy", "--pid", &gone_pid,
        ],
    );
    assert!(!output.status.success(), "an exited owner process was accepted");
    let error = json_error(&output);
    assert_eq!(error["code"], "validation.invalid", "{error}");
    assert!(error["message"].as_str().unwrap_or_default().contains("not running"), "{error}");

    let output = status_output(
        &server,
        None,
        &["status", "set", "init", "--label", "Init", "--target", &workspace, "--pid", "1"],
    );
    assert_eq!(output.status.code(), Some(2), "{}", String::from_utf8_lossy(&output.stderr));

    assert_eq!(entries(&server, &workspace), Vec::<serde_json::Value>::new());
}

/// cx-uf8b (nxdog94 preflight): the root help lists `status`, `status --help`
/// and `status set --help` print the status usage (they printed the root
/// help), and `status set KEY TEXT`, the `workspace status set` form, sets the
/// entry (it failed with "status takes set, clear, list or run").
#[test]
fn status_is_in_the_help_and_takes_the_positional_text_form() {
    // The `cmux` name (the app's bundled CLI) prints its own root help.
    let dir = std::env::temp_dir().join(format!("cmux-status-help-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let cmux = dir.join("cmux");
    let _ = std::fs::remove_file(&cmux);
    std::os::unix::fs::symlink(bin(), &cmux).unwrap();
    let run = |program: &std::path::Path, args: &[&str]| {
        let output = Command::new(program)
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .args(args)
            .output()
            .unwrap();
        assert_success(&output);
        String::from_utf8(output.stdout).unwrap()
    };
    for program in [std::path::Path::new(bin()), cmux.as_path()] {
        let root = run(program, &["--help"]);
        assert!(
            root.lines().any(|line| line.starts_with("  status ")),
            "{program:?} root help lists no status scope:\n{root}"
        );
        for args in [&["status", "--help"][..], &["status", "set", "--help"], &["help", "status"]] {
            let text = run(program, args);
            assert!(text.contains("cmux status set [KEY] (TEXT | --label"), "{args:?}:\n{text}");
            assert!(text.contains("cmux status run"), "{args:?}:\n{text}");
            assert!(!text.contains("GLOBAL OPTIONS"), "{args:?} printed the root help:\n{text}");
        }
    }
    let _ = std::fs::remove_dir_all(&dir);

    let server = HeadlessServer::start("status-positional-text");
    state_cli(&server, None, &["workspace", "create", "--name", "delta", "--empty"]);
    let workspace = workspace_id_named(&server, "delta");
    let output = status_output(
        &server,
        None,
        &["status", "set", "build", "Building pf94", "--target", &workspace, "--state", "busy"],
    );
    assert_success(&output);
    let build = entry(&server, &workspace, "build").expect("build entry");
    assert_eq!(build["text"], "Building pf94", "{build}");
    assert_eq!(build["state"], "busy", "{build}");

    let output = status_output(
        &server,
        None,
        &["status", "set", "build", "Twice", "--label", "Twice", "--target", &workspace],
    );
    assert_eq!(output.status.code(), Some(2), "{}", String::from_utf8_lossy(&output.stderr));
    assert_eq!(entry(&server, &workspace, "build").unwrap()["text"], "Building pf94");
}
