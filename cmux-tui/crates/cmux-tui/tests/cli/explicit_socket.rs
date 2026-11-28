//! A socket the caller names is the only socket the CLI tries (cx-siev).
//!
//! 2026-10-10: two workers ran `cmux --socket <link socket> capabilities`
//! and got the answer of the person's running app: the app route ignored
//! `--socket` and used the app that the inherited environment named. Here a
//! real headless daemon is the caller's session, and recording sockets
//! stand in for the person's app: at the default app path, and at the
//! `CMUX_SOCKET_PATH` a terminal of that app passes down. Every explicit
//! route that cannot be served fails with a typed error, and no recording
//! socket ever sees a connection.

use super::*;

use std::sync::{Arc, Mutex};

/// A socket that records every request line. `answers_as_app` replies to
/// each line as the cmux app does (`system.ping` gets `pong`).
struct Recorder {
    path: PathBuf,
    lines: Arc<Mutex<Vec<String>>>,
}

impl Recorder {
    fn bind(path: PathBuf, answers_as_app: bool) -> Self {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let listener = UnixListener::bind(&path).unwrap();
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink = lines.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { return };
                let sink = sink.clone();
                std::thread::spawn(move || {
                    let mut writer = stream.try_clone().unwrap();
                    for line in BufReader::new(stream).lines() {
                        let Ok(line) = line else { return };
                        sink.lock().unwrap().push(line.clone());
                        if !answers_as_app {
                            return;
                        }
                        let id = serde_json::from_str::<serde_json::Value>(&line)
                            .ok()
                            .and_then(|request| request.get("id").cloned())
                            .unwrap_or(serde_json::Value::Null);
                        let reply = serde_json::json!({
                            "id": id, "ok": true,
                            "result": {"pong": true, "protocol_version": 1, "methods": []},
                        });
                        if writeln!(writer, "{reply}").is_err() {
                            return;
                        }
                    }
                });
            }
        });
        Self { path, lines }
    }

    fn lines(&self) -> Vec<String> {
        self.lines.lock().unwrap().clone()
    }
}

/// The caller's own session (a real headless daemon at the default `main`
/// path of a private runtime directory) and the person's app.
/// Fields drop in order: the daemon stops before [`Cleanup`] removes the
/// directory.
struct World {
    base: PathBuf,
    home: PathBuf,
    daemon: HeadlessServer,
    /// The person's app at the default app control path under `HOME`.
    default_app: Recorder,
    /// The person's app as a terminal of that app names it.
    inherited_app: Recorder,
    _cleanup: Cleanup,
}

struct Cleanup(PathBuf);

impl Drop for Cleanup {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

impl World {
    fn start(name: &str) -> Self {
        let base = unique_temp_dir(name);
        let runtime = cmux_tui_core::platform::runtime_dir_for_base(&base);
        fs::create_dir_all(&runtime).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let home = base.join("home");
        let state_dir = base.join("daemon");
        fs::create_dir_all(&state_dir).unwrap();
        let socket = runtime.join("main.sock");
        let state = state_dir.join("state");
        let child = Command::new(bin())
            .args(["--headless", "--session", "main", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(&state)
            .env("CMUX_TUI_CONFIG", state_dir.join("config.json"))
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let daemon = HeadlessServer::adopt(child, socket, state, state_dir);
        daemon.wait_for_socket();
        let default_app = Recorder::bind(home.join(".local/state/cmux/cmux.sock"), true);
        let inherited_app = Recorder::bind(base.join("inherited-app.sock"), true);
        let cleanup = Cleanup(base.clone());
        Self { base, home, daemon, default_app, inherited_app, _cleanup: cleanup }
    }

    /// `cmux --json ARGS` with only this world's variables: the person's
    /// app terminal env (`CMUX_BUNDLE_ID`, `CMUX_SOCKET_PATH`) unless
    /// `extra` replaces it.
    fn cmux(&self, args: &[&str], extra: &[(&str, &str)]) -> Output {
        let mut command = Command::new(bin());
        command
            .arg("--json")
            .args(args)
            .env_clear()
            .env("PATH", "/usr/bin:/bin")
            .env("HOME", &self.home)
            .env("LANG", "en_US.UTF-8")
            .env("XDG_RUNTIME_DIR", &self.base)
            .env("CMUX_BUNDLE_ID", "com.cmuxterm.app")
            .env("CMUX_SOCKET_PATH", &self.inherited_app.path)
            .envs(extra.iter().copied())
            .stdin(Stdio::null());
        command.output().unwrap()
    }

    /// The person's app saw no connection at all.
    fn assert_app_untouched(&self, what: &str) {
        assert_eq!(self.default_app.lines(), Vec::<String>::new(), "{what}: default app reached");
        assert_eq!(
            self.inherited_app.lines(),
            Vec::<String>::new(),
            "{what}: inherited CMUX_SOCKET_PATH app reached"
        );
    }

    fn dead_path(&self) -> PathBuf {
        self.base.join("dead.sock")
    }
}

/// The typed error on stderr (`--json`), and the exit code.
fn failure_code(output: &Output) -> (Option<i32>, String) {
    let stderr = String::from_utf8_lossy(&output.stderr);
    let code = stderr
        .lines()
        .find_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .and_then(|error| error["code"].as_str().map(str::to_owned))
        .unwrap_or_else(|| format!("<no typed error: {stderr}>"));
    (output.status.code(), code)
}

#[test]
fn a_named_socket_that_is_dead_fails_typed_and_reaches_no_other_socket() {
    let world = World::start("explicit-dead");
    let dead = world.dead_path();
    let dead = dead.to_str().unwrap();
    for verb in ["capabilities", "identify", "ping"] {
        let output = world.cmux(&["--socket", dead, verb], &[]);
        assert_eq!(failure_code(&output), (Some(3), "socket.unreachable".into()), "{verb}");
        world.assert_app_untouched(&format!("--socket <dead> {verb}"));
    }
    let output = world.cmux(&["--socket", dead, "workspace", "list"], &[]);
    assert_eq!(failure_code(&output), (Some(3), "socket.unreachable".into()));
    // An unknown verb pair may name an app action; a dead named socket has none.
    let output = world.cmux(&["--socket", dead, "frobnicate", "widgets"], &[]);
    assert_eq!(output.status.code(), Some(2), "{}", String::from_utf8_lossy(&output.stderr));
    world.assert_app_untouched("--socket <dead> daemon and action-fallback commands");
}

#[test]
fn a_daemon_socket_named_for_an_app_command_is_the_wrong_kind_and_the_app_is_untouched() {
    let world = World::start("explicit-kind");
    let daemon = world.daemon.socket.to_str().unwrap().to_owned();
    for verb in ["capabilities", "identify"] {
        let output = world.cmux(&["--socket", &daemon, verb], &[]);
        assert_eq!(failure_code(&output), (Some(3), "socket.wrong_kind".into()), "{verb}");
    }
    for words in [&["app", "capabilities"][..], &["window", "list"][..]] {
        let mut args = vec!["--socket", daemon.as_str()];
        args.extend_from_slice(words);
        let output = world.cmux(&args, &[]);
        assert_eq!(failure_code(&output), (Some(3), "socket.wrong_kind".into()), "{words:?}");
    }
    world.assert_app_untouched("--socket <daemon> app commands");

    // A daemon command on the named daemon runs there, and its app half
    // (focus follow) never reaches an app that does not own that daemon.
    let created =
        world.cmux(&["--socket", &daemon, "workspace", "create", "--name", "w", "--empty"], &[]);
    assert_success(&created);
    let created = serde_json::from_slice::<serde_json::Value>(&created.stdout).unwrap();
    let id = created["value"]["workspace_id"].as_str().expect("workspace_id").to_owned();
    let focused = world.cmux(&["--socket", &daemon, "workspace", &id, "focus"], &[]);
    assert_success(&focused);
    world.assert_app_untouched("--socket <daemon> workspace focus");

    // The daemon is fine after the refused app requests.
    assert_success(&world.cmux(&["--socket", &daemon, "workspace", "list"], &[]));
}

#[test]
fn a_daemon_named_by_session_or_env_reaches_no_app_that_does_not_own_it() {
    let world = World::start("explicit-route");
    let output = world.cmux(&["--session", "main", "capabilities"], &[]);
    assert_eq!(failure_code(&output), (Some(3), "socket.no_app".into()));
    world.assert_app_untouched("--session main capabilities");

    // `CMUX_TUI_SOCKET` names the daemon and nothing names an app: the app
    // `CMUX_BUNDLE_ID` would name (the default path under HOME) is not used.
    let daemon = world.daemon.socket.to_str().unwrap().to_owned();
    let env = [("CMUX_SOCKET_PATH", ""), ("CMUX_TUI_SOCKET", daemon.as_str())];
    let output = world.cmux(&["capabilities"], &env);
    assert_eq!(failure_code(&output), (Some(3), "socket.no_app".into()));
    let created = world.cmux(&["workspace", "create", "--name", "e", "--empty"], &env);
    assert_success(&created);
    let created = serde_json::from_slice::<serde_json::Value>(&created.stdout).unwrap();
    let id = created["value"]["workspace_id"].as_str().expect("workspace_id").to_owned();
    assert_success(&world.cmux(&["workspace", &id, "focus"], &env));
    world.assert_app_untouched("CMUX_TUI_SOCKET daemon, capabilities and focus");
}

#[test]
fn a_named_app_socket_is_the_only_app_reached() {
    let world = World::start("explicit-app");
    let own_app = Recorder::bind(world.base.join("own-app.sock"), true);
    let own = own_app.path.to_str().unwrap().to_owned();
    // The classic CLI's `--socket` names the app socket: still served.
    let output = world.cmux(&["--socket", &own, "capabilities"], &[]);
    assert_success(&output);
    let daemon = world.daemon.socket.to_str().unwrap().to_owned();
    let output = world.cmux(&["--socket", &daemon, "--app-socket", &own, "identify"], &[]);
    assert_success(&output);
    let methods: Vec<String> = own_app
        .lines()
        .iter()
        .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap()["method"].to_string())
        .collect();
    assert_eq!(
        methods,
        ["\"system.ping\"", "\"system.capabilities\"", "\"system.identify\""],
        "the named app socket got the kind check and both requests"
    );
    world.assert_app_untouched("named app socket");
}

#[test]
fn cmux_socket_path_is_never_replaced_by_a_default_socket() {
    let world = World::start("explicit-env");
    let dead = world.dead_path();
    let dead = dead.to_str().unwrap();
    // The app the env names is down: the call fails, the default app path
    // under HOME (which `CMUX_BUNDLE_ID` alone would name) is not tried.
    let output = world.cmux(&["capabilities"], &[("CMUX_SOCKET_PATH", dead)]);
    assert_eq!(failure_code(&output), (Some(3), "app.unreachable".into()));
    // A daemon command with only an app socket named: no default session
    // (`main` here listens at the default path) is chosen for it.
    let output =
        world.cmux(&["workspace", "list"], &[("CMUX_BUNDLE_ID", ""), ("CMUX_SOCKET_PATH", dead)]);
    assert_eq!(failure_code(&output), (Some(2), "socket.no_daemon".into()));
    world.assert_app_untouched("CMUX_SOCKET_PATH <dead>");
    // `CMUX_TUI_SOCKET` names a dead daemon: typed, and the default `main`
    // session is not used in its place.
    let output = world.cmux(&["workspace", "list"], &[("CMUX_TUI_SOCKET", dead)]);
    assert_eq!(failure_code(&output), (Some(3), "socket.unreachable".into()));
    world.assert_app_untouched("CMUX_TUI_SOCKET <dead>");
}

#[test]
fn with_no_explicit_socket_discovery_still_finds_the_default_session() {
    let world = World::start("explicit-none");
    let mut command = Command::new(bin());
    let output = command
        .args(["--json", "workspace", "list"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &world.home)
        .env("XDG_RUNTIME_DIR", &world.base)
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_success(&output);
    assert!(serde_json::from_slice::<serde_json::Value>(&output.stdout).unwrap().is_array());
    world.assert_app_untouched("implicit discovery");
}

/// The `socket.no_daemon` messages (localization/cli_connection.rs).
const NO_DAEMON_EN: &str =
    "CMUX_SOCKET_PATH names a cmux app socket, and nothing names that app's session";
const NO_DAEMON_JA: &str = "CMUX_SOCKET_PATH は cmux アプリのソケットを指定していますが";

/// The first JSON object on stderr.
fn stderr_error(output: &Output) -> serde_json::Value {
    String::from_utf8_lossy(&output.stderr)
        .lines()
        .find_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .unwrap_or(serde_json::Value::Null)
}

/// Every CLI path that resolves the daemon socket reports the resolver's
/// own `socket.no_daemon` (code, exit 2, en/ja message) when only
/// `CMUX_SOCKET_PATH` is set, never "invalid session name", and connects
/// nowhere (cx-siev follow-up).
#[test]
fn cmux_socket_path_alone_fails_with_no_daemon_on_every_daemon_path() {
    let world = World::start("explicit-no-daemon");
    let app = world.inherited_app.path.to_str().unwrap().to_owned();
    let only_app = [("CMUX_BUNDLE_ID", ""), ("CMUX_SOCKET_PATH", app.as_str())];
    let commands: &[&[&str]] = &[
        &["raw", "command", "--request-json", r#"{"id":"r","cmd":"ping"}"#],
        &["script", "run", "-e", "1"],
        &["apps", "run", "notes", "list"],
        &["agent", "inbox"],
        &["server", "status"],
        &["workspace", "list"],
    ];
    for words in commands {
        let output = world.cmux(words, &only_app);
        assert_eq!(failure_code(&output), (Some(2), "socket.no_daemon".into()), "{words:?}");
        let message = stderr_error(&output)["message"].as_str().unwrap_or_default().to_owned();
        assert!(message.starts_with(NO_DAEMON_EN), "{words:?}: {message}");
        let mut japanese = only_app.to_vec();
        japanese.push(("LANG", "ja_JP.UTF-8"));
        let output = world.cmux(words, &japanese);
        assert_eq!(failure_code(&output), (Some(2), "socket.no_daemon".into()), "{words:?} ja");
        let message = stderr_error(&output)["message"].as_str().unwrap_or_default().to_owned();
        assert!(message.starts_with(NO_DAEMON_JA), "{words:?} ja: {message}");
        world.assert_app_untouched(&format!("CMUX_SOCKET_PATH alone: {words:?}"));
    }

    // `cmux mcp serve`: the tool call reports the same typed error. The
    // server's action watch may subscribe to the app the env names; no
    // daemon request ever goes to an app socket.
    let config = world.base.join("cmux-next.json");
    fs::write(&config, r#"{"mcp":{"enabled":true}}"#).unwrap();
    let mut child = Command::new(bin())
        .args(["mcp", "serve"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", &world.home)
        .env("LANG", "en_US.UTF-8")
        .env("XDG_RUNTIME_DIR", &world.base)
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .envs(only_app)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut stdin = child.stdin.take().unwrap();
        for message in [
            serde_json::json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "explicit-socket", "version": "1"}}}),
            serde_json::json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            serde_json::json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": {"name": "workspace_list", "arguments": {}}}),
        ] {
            writeln!(stdin, "{message}").unwrap();
        }
    }
    let output = child.wait_with_output().unwrap();
    let reply = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<serde_json::Value>(line).ok())
        .find(|message| message["id"] == 2)
        .unwrap_or_else(|| {
            panic!("no tools/call reply: {}", String::from_utf8_lossy(&output.stderr))
        });
    let result = &reply["result"];
    assert_eq!(result["isError"], true, "{reply}");
    let error = &result["structuredContent"]["error"];
    assert_eq!(error["code"], "socket.no_daemon", "{reply}");
    assert!(error["message"].as_str().unwrap_or_default().starts_with(NO_DAEMON_EN), "{reply}");
    assert_eq!(result["structuredContent"]["state"], "not_run", "{reply}");
    assert_eq!(world.default_app.lines(), Vec::<String>::new(), "mcp: default app reached");
    for line in world.inherited_app.lines() {
        let method = serde_json::from_str::<serde_json::Value>(&line).unwrap()["method"].clone();
        assert_eq!(method, "events.stream", "mcp: a daemon request reached the app: {line}");
    }
}
