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

#[cfg(target_os = "linux")]
struct RouteOwner(std::process::Child);

#[cfg(target_os = "linux")]
impl Drop for RouteOwner {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

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

/// Applies the `-c` overrides exactly as Codex does (codex-rs/utils/cli
/// `parse_overrides` plus codex-rs/config `apply_toml_override`): the key is
/// everything before the first `=` and is split on EVERY `.`, ignoring TOML
/// quoting, and each override replaces the value at its path. Parsing the
/// overrides as a TOML document instead would honor quoted keys that Codex
/// splits, hiding settings Codex never applies.
fn settings(argv: &[String]) -> toml::Value {
    let mut root = toml::Value::Table(toml::Table::new());
    for pair in argv.windows(2).filter(|pair| pair[0] == "-c") {
        let (path, raw) = pair[1].split_once('=').unwrap();
        let value = toml::from_str::<toml::Table>(&format!("_x_ = {}", raw.trim()))
            .unwrap_or_else(|error| panic!("Codex cannot parse override {:?}: {error}", pair[1]))
            .remove("_x_")
            .unwrap();
        let segments: Vec<&str> = path.trim().split('.').collect();
        let (last, parents) = segments.split_last().unwrap();
        let mut current = &mut root;
        for segment in parents {
            let table = current.as_table_mut().unwrap();
            current =
                table.entry(*segment).or_insert_with(|| toml::Value::Table(toml::Table::new()));
        }
        current.as_table_mut().unwrap().insert((*last).to_owned(), value);
    }
    root
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

/// A headless session whose terminals start `shell` with cmux-tui's shell
/// integration, in an isolated HOME whose startup files prepend `~/bin`
/// (holding a fake `codex`) to PATH, the way `export
/// PATH="$HOME/.local/bin:$PATH"` in a user's rc file does.
struct ShellSession {
    root: tempfile::TempDir,
    socket: PathBuf,
    server: std::process::Child,
}

impl ShellSession {
    fn start(shell: &Path) -> Self {
        let root = tempfile::tempdir_in("/tmp").unwrap();
        let home = root.path().join("home");
        let bin = home.join("bin");
        fs::create_dir_all(&bin).unwrap();
        fs::create_dir_all(home.join(".config/fish")).unwrap();
        // The fake Codex records the argv it was started with, then exits.
        fs::write(
            bin.join("codex"),
            "#!/bin/sh\nprintf '%s\\0' \"$@\" > \"$HOME/codex-argv.tmp\" && mv \"$HOME/codex-argv.tmp\" \"$HOME/codex-argv\"\n",
        )
        .unwrap();
        fs::set_permissions(bin.join("codex"), fs::Permissions::from_mode(0o700)).unwrap();
        // The startup files prepend ~/bin, and a prompt hook prepends it
        // again at every prompt, as tool managers do.
        fs::write(home.join(".zshenv"), "setopt NO_GLOBAL_RCS\n").unwrap();
        let rc = "export PATH=\"$HOME/bin:$PATH\"\nPS1='ready> '\n";
        fs::write(
            home.join(".zshrc"),
            format!(
                "{rc}_reprepend() {{ path=($HOME/bin $path) }}\nprecmd_functions+=(_reprepend)\n"
            ),
        )
        .unwrap();
        fs::write(home.join(".bashrc"), format!("{rc}PROMPT_COMMAND='PATH=\"$HOME/bin:$PATH\"'\n"))
            .unwrap();
        fs::write(
            home.join(".config/fish/config.fish"),
            "set -gx PATH $HOME/bin $PATH\nfunction fish_prompt; echo -n 'ready> '; end\nfunction _reprepend --on-event fish_prompt; set -gx PATH $HOME/bin $PATH; end\n",
        )
        .unwrap();
        let socket = root.path().join("mux.sock");
        let server = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--ephemeral", "--socket"])
            .arg(&socket)
            .env_clear()
            .env("HOME", &home)
            .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
            .env("SHELL", shell)
            .env("XDG_DATA_HOME", root.path().join("data"))
            .env("XDG_STATE_HOME", root.path().join("state"))
            .env("XDG_CONFIG_HOME", home.join(".config"))
            .env("CMUX_TUI_CONFIG", root.path().join("config.json"))
            .env("TMPDIR", root.path())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while cmux_tui_core::platform::transport::connect(&socket).is_err() {
            assert!(
                Instant::now() < deadline,
                "the session never listened at {}",
                socket.display()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { root, socket, server }
    }

    fn cli(&self, args: &[&str]) -> String {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID")
            .output()
            .unwrap();
        assert!(output.status.success(), "cmux-tui {args:?} failed: {output:?}");
        String::from_utf8(output.stdout).unwrap()
    }

    fn home(&self) -> PathBuf {
        self.root.path().join("home")
    }
}

impl Drop for ShellSession {
    fn drop(&mut self) {
        let _ = self.server.kill();
        let _ = self.server.wait();
    }
}

fn integrated_shells() -> Vec<PathBuf> {
    ["zsh", "bash", "fish"]
        .into_iter()
        .filter_map(|name| {
            std::env::split_paths(&std::env::var_os("PATH").unwrap_or_default())
                .chain(["/bin", "/usr/bin", "/opt/homebrew/bin"].map(PathBuf::from))
                .map(|dir| dir.join(name))
                // Apple's /bin/bash 3.2 runs without shell integration.
                .filter(|path| !(cfg!(target_os = "macos") && path == Path::new("/bin/bash")))
                .find(|path| path.is_file())
        })
        .collect()
}

/// The reported failure: Codex 0.162 runs hooks in its shared app-server
/// daemon, which has none of the terminal's `CMUX_TUI_*` variables, so the
/// installed hooks route nowhere. Only the `codex` shim carries the terminal's
/// route into the hook command, and a shell startup file that prepends its own
/// directory to PATH hid the shim. `codex` typed at the prompt must still
/// reach the wrapper, and the hooks it passes must reach this terminal from an
/// empty environment.
#[test]
fn codex_typed_in_a_terminal_reports_to_that_terminal_after_startup_files_reorder_path() {
    let shells = integrated_shells();
    assert!(!shells.is_empty(), "no zsh, bash, or fish to test with");
    for shell in shells {
        let session = ShellSession::start(&shell);
        let created: serde_json::Value = serde_json::from_str(&session.cli(&[
            "--json",
            "workspace",
            "create",
            "--name",
            "codex",
        ]))
        .unwrap();
        let terminal = created["value"]["terminal_id"].as_str().unwrap().to_owned();
        session.cli(&[
            "terminal",
            &terminal,
            "screen",
            "wait",
            "--pattern",
            "ready>",
            "--timeout-ms",
            "15000",
        ]);
        session.cli(&["terminal", &terminal, "write", "--text", "codex exec hello\r"]);
        let argv_file = session.home().join("codex-argv");
        let deadline = Instant::now() + Duration::from_secs(15);
        while !argv_file.exists() {
            assert!(
                Instant::now() < deadline,
                "{}: codex never started; screen: {}",
                shell.display(),
                session.cli(&["terminal", &terminal, "screen", "read"])
            );
            std::thread::sleep(Duration::from_millis(25));
        }
        let argv: Vec<String> = fs::read(&argv_file)
            .unwrap()
            .strip_suffix(&[0])
            .unwrap()
            .split(|byte| *byte == 0)
            .map(|part| String::from_utf8(part.to_vec()).unwrap())
            .collect();
        assert!(
            argv.iter().any(|arg| arg.starts_with("hooks.Stop=")),
            "{}: `codex` bypassed the cmux-tui shim and started without the terminal's hooks: {argv:?}",
            shell.display()
        );
        let config = settings(&argv);
        let mut hook = Command::new("/bin/sh");
        hook.args(["-c", &hook_command(&config, "Stop")]).env_clear();
        let mut child = hook.stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
        writeln!(
            child.stdin.take().unwrap(),
            "{{\"session_id\":\"s1\",\"turn_id\":\"t1\",\"hook_event_name\":\"Stop\"}}"
        )
        .unwrap();
        assert!(child.wait_with_output().unwrap().status.success());
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let notifications: serde_json::Value =
                serde_json::from_str(&session.cli(&["--json", "notification", "list"])).unwrap();
            if notifications.as_array().unwrap().iter().any(|notification| {
                notification["title"] == "Codex finished" && notification["terminal_id"] == terminal
            }) {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "{}: the hook never reached terminal {terminal}: {notifications}",
                shell.display()
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }
}

/// Runs `command` the way Codex's shared app-server daemon
/// (`codex app-server --listen unix:// --managed-daemon`) runs a hook: a
/// process with the daemon's argv starts `$SHELL -lc <command>`, and the
/// shell forks the compound hook command. `extra_shells` adds shells between
/// them (a tool command of a daemon-hosted session that runs its own hooks
/// further down). `env` is the environment the daemon inherited.
fn run_under_codex_daemon(
    command: &str,
    env: &[(&str, &std::ffi::OsStr)],
    daemon: bool,
    extra_shells: usize,
) {
    // Each layer forks the next (`; :` keeps sh from exec'ing it).
    let mut layers = vec![format!("{command}; :")];
    for _ in 0..=extra_shells {
        let index = layers.len() - 1;
        layers.push(format!("/bin/sh -c \"$CDH_LAYER_{index}\"; :"));
    }
    let mut process = Command::new("/bin/sh");
    process.arg("-c").arg(layers.last().unwrap()).env_clear();
    if daemon {
        process.args(["app-server", "--listen", "unix://", "--managed-daemon"]);
    }
    for (index, layer) in layers.iter().enumerate().take(layers.len() - 1) {
        process.env(format!("CDH_LAYER_{index}"), layer);
    }
    for (name, value) in env {
        process.env(name, value);
    }
    let mut child = process.stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
    writeln!(child.stdin.take().unwrap(), "{{\"session_id\":\"s1\",\"hook_event_name\":\"Stop\"}}")
        .unwrap();
    assert!(child.wait_with_output().unwrap().status.success());
}

/// The shared daemon keeps the environment of the shell that started it. An
/// installed hook it runs (daemon, `$SHELL -lc`, hook) must not post to that
/// shell's terminal: the event may come from any Codex session, in another
/// terminal or outside cmux. A hook one shell further down belongs to
/// something a daemon tool started (a cmux-tui server, a test run) and still
/// posts. The wrapper's hooks name their own terminal and always route.
#[test]
fn codex_daemon_hooks_never_post_to_the_terminal_whose_environment_the_daemon_inherited() {
    let launch = Launch::new();
    let helper = std::ffi::OsString::from(env!("CARGO_BIN_EXE_cmux-tui-hook"));
    let inherited: [(&str, &std::ffi::OsStr); 3] = [
        ("CMUX_TUI_HOOK", &helper),
        ("CMUX_TUI_SOCKET", launch.socket.as_os_str()),
        ("CMUX_TUI_TERMINAL_ID", std::ffi::OsStr::new(TERMINAL_ONE)),
    ];
    let installed = "\"$CMUX_TUI_HOOK\" codex Stop";

    run_under_codex_daemon(installed, &inherited, false, 0);
    let received = launch.event();
    assert_eq!(received["payload"]["native_event"], "Stop", "the control run must post");

    run_under_codex_daemon(installed, &inherited, true, 0);
    assert_eq!(
        launch.listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock,
        "a hook in Codex's daemon posted to the terminal that started the daemon"
    );

    run_under_codex_daemon(installed, &inherited, true, 1);
    let received = launch.event();
    assert_eq!(
        received["payload"]["native_event"], "Stop",
        "a hook below a daemon tool's own shell must still post"
    );

    let argv = launch.argv(launch.command().env("CMUX_TUI_TERMINAL_ID", TERMINAL_TWO));
    run_under_codex_daemon(&hook_command(&settings(&argv), "Stop"), &inherited, true, 0);
    let received = launch.event();
    assert!(
        received["subjects"]
            .as_array()
            .unwrap()
            .iter()
            .any(|subject| subject["kind"] == "terminal" && subject["id"] == TERMINAL_TWO),
        "{received}"
    );
}

#[cfg(target_os = "linux")]
#[test]
fn codex_wrapper_resolves_the_attached_tmux_terminal_when_launch_environment_is_missing() {
    let launch = Launch::new();
    // This process stands in for a tmux attach client. Its initial environment
    // is readable through /proc, and the open stdin keeps it alive without a timer.
    let route_owner = RouteOwner(
        Command::new("/bin/cat")
            .env_clear()
            .env("CMUX_TUI_SOCKET", &launch.socket)
            .env("CMUX_TUI_TERMINAL_ID", TERMINAL_TWO)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );

    let tmux_dir = launch.root.path().join("tmux-bin");
    fs::create_dir(&tmux_dir).unwrap();
    let tmux = tmux_dir.join("tmux");
    fs::write(
        &tmux,
        format!(
            "#!/bin/sh\ncase \"$1\" in\ndisplay-message) printf '%b\\n' '$1\\t\\t@1';;\nlist-clients) printf '%b\\n' '{}\\t999\\t$1\\t\\t@1';;\nesac\n",
            route_owner.0.id()
        ),
    )
    .unwrap();
    fs::set_permissions(&tmux, fs::Permissions::from_mode(0o700)).unwrap();

    let mut command = launch.command();
    command
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env("TMUX", "fake-server,1,0")
        .env("TMUX_PANE", "%1")
        .env(
            "PATH",
            format!(
                "{}:{}:/usr/bin:/bin",
                tmux_dir.display(),
                launch.root.path().join("bin").display()
            ),
        )
        .args(["exec", "hello"]);
    let argv = launch.argv(&mut command);
    let config = settings(&argv);
    let hook = hook_command(&config, "SessionStart");
    run_hook(&hook, None, TERMINAL_TWO);
    let received = launch.event();
    assert_eq!(received["payload"]["native_event"], "SessionStart");
    assert!(
        received["subjects"]
            .as_array()
            .unwrap()
            .iter()
            .any(|subject| { subject["kind"] == "terminal" && subject["id"] == TERMINAL_TWO })
    );
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
