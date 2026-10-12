//! Exercise the SSH launch boundary without depending on Codex credentials:
//! capture the real wrapper's argv, then run its hooks as a shared daemon would.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const TERMINAL_ONE: &str = "term_00000000000000000000000000000001";
const TERMINAL_TWO: &str = "term_00000000000000000000000000000002";

struct Launch {
    root: tempfile::TempDir,
    socket: PathBuf,
    listener: UnixListener,
}

impl Launch {
    fn new() -> Self {
        // macOS's socket path limit is shorter than its default temp directory.
        let root = tempfile::tempdir_in("/tmp").unwrap();
        let socket = root.path().join("mux '''.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let bin = root.path().join("bin");
        fs::create_dir(&bin).unwrap();
        fs::write(bin.join("codex"), "#!/bin/sh\nprintf '%s\\0' \"$@\"\n").unwrap();
        fs::set_permissions(bin.join("codex"), fs::Permissions::from_mode(0o700)).unwrap();
        Self { root, socket, listener }
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command.args(["agent", "codex-wrapper"]).env_clear();
        command.env("HOME", self.root.path());
        command.env("XDG_DATA_HOME", self.root.path().join("data"));
        command.env("PATH", format!("{}:/usr/bin:/bin", self.root.path().join("bin").display()));
        command.env("CMUX_TUI_SOCKET", &self.socket);
        command.env("CMUX_TUI_TERMINAL_ID", TERMINAL_ONE);
        command
    }

    fn argv(&self, command: &mut Command) -> Vec<String> {
        let output = command.output().unwrap();
        assert!(output.status.success(), "wrapper failed: {output:?}");
        assert!(output.stderr.is_empty(), "{}", String::from_utf8_lossy(&output.stderr));
        output
            .stdout
            .strip_suffix(&[0])
            .unwrap_or(&output.stdout)
            .split(|byte| *byte == 0)
            .map(|part| String::from_utf8(part.to_vec()).unwrap())
            .collect()
    }

    fn event(&self) -> serde_json::Value {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match self.listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error)
                    if error.kind() == std::io::ErrorKind::WouldBlock
                        && Instant::now() < deadline =>
                {
                    std::thread::sleep(Duration::from_millis(10));
                }
                result => panic!("hook must reach this session: {result:?}"),
            }
        };
        stream.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let mut line = String::new();
        BufReader::new(&stream).read_line(&mut line).unwrap();
        let request: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(request["operation"], "session.journal.append");
        let response = serde_json::json!({
            "protocol":"cmux.protocol/2", "type":"response", "id":request["id"],
            "ok":true, "result":{"value":{"sequence":"1"}}
        });
        writeln!(stream, "{response}").unwrap();
        request["params"]["event"].clone()
    }
}

fn settings(argv: &[String]) -> toml::Value {
    let text = argv
        .windows(2)
        .filter(|pair| pair[0] == "-c")
        .map(|pair| pair[1].as_str())
        .collect::<Vec<_>>()
        .join("\n");
    toml::from_str(&text).unwrap()
}

fn hook_command(config: &toml::Value, event: &str) -> String {
    config
        .get("hooks")
        .and_then(|hooks| hooks.get(event))
        .and_then(|groups| groups.get(0))
        .and_then(|group| group.get("hooks"))
        .and_then(|handlers| handlers.get(0))
        .and_then(|handler| handler.get("command"))
        .and_then(toml::Value::as_str)
        .unwrap_or_else(|| panic!("launch must supply a contextual {event} hook: {config}"))
        .to_owned()
}

fn run_hook(command: &str, stale_socket: Option<&Path>, session: &str) {
    let mut process = Command::new("/bin/sh");
    process.args(["-c", command]).env_clear();
    if let Some(socket) = stale_socket {
        process
            .env("CMUX_TUI_SOCKET", socket)
            .env("CMUX_TUI_TERMINAL_ID", "term_wrong")
            .env("CMUX_TUI_HOOK", "/missing/old-helper");
    }
    let mut child = process
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(), "{{\"session_id\":\"{session}\"}}").unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(output.stdout, b"{}\n");
}

#[test]
fn codex_wrapper_remote_hooks_keep_each_terminal_under_a_shared_daemon_environment() {
    let launch = Launch::new();
    let stale = Launch::new();
    for (terminal, stale_socket) in
        [(TERMINAL_ONE, None), (TERMINAL_TWO, Some(stale.socket.as_path()))]
    {
        let argv = launch
            .argv(launch.command().env("CMUX_TUI_TERMINAL_ID", terminal).args(["exec", "hello"]));
        let config = settings(&argv);
        assert!(!argv.iter().any(|arg| arg == "--dangerously-bypass-hook-trust"));
        for event in ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"] {
            run_hook(&hook_command(&config, event), stale_socket, terminal);
            let received = launch.event();
            assert_eq!(received["payload"]["native_event"], event);
            assert!(
                received["subjects"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|subject| { subject["kind"] == "terminal" && subject["id"] == terminal }),
                "{received}"
            );
        }
    }
    assert_eq!(stale.listener.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
}

#[test]
fn codex_wrapper_passes_through_management_opt_out_and_missing_routes() {
    let launch = Launch::new();
    for args in [["--version", ""], ["app-server", "--help"]] {
        let args: Vec<_> = args.into_iter().filter(|arg| !arg.is_empty()).collect();
        assert_eq!(launch.argv(launch.command().args(&args)), args);
    }
    for env in [
        "CMUX_TUI_CODEX_HOOKS_DISABLED",
        "CMUX_CODEX_HOOKS_DISABLED",
        "CMUX_TUI_CODEX_WRAPPER_ACTIVE",
    ] {
        assert_eq!(
            launch.argv(launch.command().env(env, "1").args(["exec", "hello"])),
            ["exec", "hello"]
        );
    }
    assert_eq!(
        launch.argv(launch.command().env_remove("CMUX_TUI_SOCKET").args(["exec", "hello"])),
        ["exec", "hello"]
    );
    assert_eq!(
        launch.argv(
            launch.command().env("CMUX_TUI_SOCKET", "/missing/socket").args(["exec", "hello"])
        ),
        ["exec", "hello"]
    );
}

#[test]
fn codex_wrapper_scopes_trust_and_suppresses_only_installed_cmux_hooks() {
    let launch = Launch::new();
    let home = launch.root.path().join("codex ''' home");
    fs::create_dir(&home).unwrap();
    let hooks_path = home.join("hooks.json");
    let contents = serde_json::json!({"hooks":{"Stop":[{"hooks":[
        {"type":"command","command":"echo user-hook"},
        {"type":"command","command":"echo {};#cmux-tui-journal-hook"}
    ]}]}})
    .to_string();
    fs::write(&hooks_path, &contents).unwrap();
    let argv = launch.argv(launch.command().env("CODEX_HOME", &home).args([
        "resume",
        "--last",
        "-c",
        "model=\"test\"",
    ]));
    let config = settings(&argv);
    let state = config["hooks"]["state"].as_table().unwrap();
    let installed_key = format!("{}:stop:0:1", hooks_path.canonicalize().unwrap().display());
    assert_eq!(state[&installed_key]["enabled"].as_bool(), Some(false));
    assert!(
        !state.contains_key(&format!("{}:stop:0:0", hooks_path.canonicalize().unwrap().display()))
    );
    let trust = &state["/<session-flags>/config.toml:stop:0:0"]["trusted_hash"];
    assert!(trust.as_str().unwrap().starts_with("sha256:"));
    assert_eq!(config["model"].as_str(), Some("test"));
    let resume = argv.iter().position(|arg| arg == "resume").unwrap();
    assert_eq!(&argv[resume..], ["resume", "--last"]);
    assert_eq!(fs::read_to_string(hooks_path).unwrap(), contents);
    assert!(!home.join("config.toml").exists(), "per-launch trust must not edit persistent config");
}
