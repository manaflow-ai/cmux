//! A creation that names no place stays in the caller's own workspace
//! (Lawrence 2026-11-12: agents opened tabs, browsers, diff viewers and
//! terminals in the workspace the person had focused, or in Home).
//!
//! The real `cmux` runs against a real daemon whose caller is in workspace
//! `alpha` while the person has `beta` focused. Where a test needs the app's
//! answer about the caller, a fake app control socket gives it
//! (`system.identify`), as the app that owns the daemon would.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use serde_json::{Value, json};

use super::caller_selector::{Split, caller_in_alpha_beta_focused};
use super::*;

const AGENT_SESSION: &str = "acp_agent_session_own_ws";

/// Who runs the command, as its environment says.
#[derive(Default)]
struct Who<'a> {
    terminal: Option<&'a str>,
    agent: bool,
    home_chat: bool,
    workspace_key: Option<&'a str>,
    /// The control socket of the app that owns the daemon (`--app-socket`).
    app: Option<&'a Path>,
    /// An app the environment names (`CMUX_SOCKET_PATH`) that does not own
    /// the daemon: the person's Mac app, reached from a Cloud machine.
    relayed_app: Option<&'a Path>,
}

impl<'a> Who<'a> {
    fn terminal(terminal: &'a str) -> Self {
        Self { terminal: Some(terminal), ..Self::default() }
    }

    fn agent() -> Self {
        Self { agent: true, ..Self::default() }
    }

    fn with_app(mut self, app: &'a FakeApp) -> Self {
        self.app = Some(&app.socket);
        self
    }
}

/// `cmux` in the session of `server`, with the environment of `who`.
fn cmux(server: &HeadlessServer, who: &Who<'_>) -> Command {
    let mut command = Command::new(bin());
    if let Some(app) = who.app {
        command.arg("--app-socket").arg(app);
    }
    command.env("LC_ALL", "C").env("CMUX_TUI_SOCKET", &server.socket);
    for key in [
        "CMUX_MUX_SOCKET",
        "CMUX_TUI_TERMINAL_ID",
        "CMUX_AGENT_SESSION",
        "CMUX_CALLER_HOME_CHAT",
        "CMUX_WORKSPACE_ID",
        "CMUX_SOCKET_PATH",
        "CMUX_BUNDLE_ID",
        "CMUX_TAG",
        "CMUX_CHIEF_OWNER_SOCKET",
    ] {
        command.env_remove(key);
    }
    if let Some(terminal) = who.terminal {
        command.env("CMUX_TUI_TERMINAL_ID", terminal);
    }
    if who.agent {
        command.env("CMUX_AGENT_SESSION", AGENT_SESSION);
    }
    if who.home_chat {
        command.env("CMUX_CALLER_HOME_CHAT", "1");
    }
    if let Some(key) = who.workspace_key {
        command.env("CMUX_WORKSPACE_ID", key);
    }
    if let Some(app) = who.relayed_app {
        command.env("CMUX_SOCKET_PATH", app);
    }
    command
}

/// `cmux --json [global…] args…` in the session of `server`, run by `who`.
fn output(server: &HeadlessServer, who: &Who<'_>, global: &[&str], args: &[&str]) -> Output {
    cmux(server, who).arg("--json").args(global).args(args).output().unwrap()
}

/// One `cmux_exec` script through `cmux mcp serve` run by `who`: what the
/// script returned.
fn mcp_exec(server: &HeadlessServer, who: &Who<'_>, script: &str) -> Value {
    let config = server.dir.join("cmux-next-mcp.json");
    fs::write(&config, r#"{"mcp":{"enabled":true}}"#).unwrap();
    let mut command = cmux(server, who);
    command
        .args(["mcp", "serve"])
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if who.app.is_none() {
        // No app answers in this session.
        command.env("CMUX_SOCKET_PATH", server.dir.join("no-app.sock"));
    }
    let mut child = command.spawn().unwrap();
    {
        let mut stdin = child.stdin.take().unwrap();
        for message in [
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
                "params": {"protocolVersion": "2025-06-18", "capabilities": {},
                    "clientInfo": {"name": "caller-place", "version": "1"}}}),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                "params": {"name": "cmux_exec", "arguments": {"script": script}}}),
        ] {
            writeln!(stdin, "{message}").unwrap();
        }
    }
    let output = child.wait_with_output().unwrap();
    let reply = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .find(|message| message["id"] == 2)
        .unwrap_or_else(|| panic!("no reply: {}", String::from_utf8_lossy(&output.stderr)));
    assert_eq!(reply["result"]["isError"], false, "{reply}");
    reply["result"]["structuredContent"]["result"].clone()
}

fn run(server: &HeadlessServer, who: &Who<'_>, args: &[&str]) -> Value {
    let output = output(server, who, &[], args);
    assert_success(&output);
    json_output(&output)
}

/// The workspace that holds `pane`.
fn workspace_of_pane(server: &HeadlessServer, pane: &str) -> String {
    let shown = state_cli(server, None, &["pane", pane, "show"]);
    let screen = shown["screen_id"].as_str().unwrap_or_else(|| panic!("{shown}"));
    let screen = state_cli(server, None, &["screen", screen, "show"]);
    screen["workspace_id"].as_str().unwrap_or_else(|| panic!("{screen}")).to_owned()
}

fn screen_of_pane(server: &HeadlessServer, pane: &str) -> String {
    let shown = state_cli(server, None, &["pane", pane, "show"]);
    shown["screen_id"].as_str().unwrap_or_else(|| panic!("{shown}")).to_owned()
}

/// The `pane_id` of a creation's answer (`{value: {pane_id}}`).
fn created_pane(created: &Value) -> &str {
    created["value"]["pane_id"].as_str().unwrap_or_else(|| panic!("no pane: {created}"))
}

/// The person's focus never moved: `beta` is still the focused workspace.
fn assert_beta_still_focused(server: &HeadlessServer, beta: &str) {
    let focused = state_cli(server, None, &["workspace", "current", "show"]);
    assert_eq!(focused["id"], beta, "the focus moved: {focused}");
}

/// The key of `workspace` in the UUID form a chat's `CMUX_WORKSPACE_ID` has.
fn workspace_key(server: &HeadlessServer, workspace: &str) -> String {
    let listed = state_cli(server, None, &["workspace", "list"]);
    let key = listed
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"] == workspace)
        .and_then(|row| row["extra"]["key"].as_str())
        .unwrap_or_else(|| panic!("no key for {workspace}: {listed}"))
        .replace('-', "")
        .to_uppercase();
    assert_eq!(key.len(), 32, "{key}");
    format!("{}-{}-{}-{}-{}", &key[..8], &key[8..12], &key[12..16], &key[16..20], &key[20..])
}

/// A cmux app control socket that answers `system.identify` with one
/// identity and refuses every other method, as an app with no such method.
struct FakeApp {
    socket: PathBuf,
    done: Arc<AtomicBool>,
    received: Arc<Mutex<Vec<Value>>>,
    listener: Option<JoinHandle<()>>,
}

impl FakeApp {
    fn start(server: &HeadlessServer, name: &str, identity: Value) -> Self {
        let socket = server.dir.join(format!("{name}.sock"));
        let listener = UnixListener::bind(&socket).unwrap();
        listener.set_nonblocking(true).unwrap();
        let done = Arc::new(AtomicBool::new(false));
        let received = Arc::new(Mutex::new(Vec::new()));
        let (stop, log) = (done.clone(), received.clone());
        let handle = std::thread::spawn(move || {
            loop {
                match listener.accept() {
                    Ok((stream, _)) => {
                        let (log, identity) = (log.clone(), identity.clone());
                        std::thread::spawn(move || answer(stream, &identity, &log));
                    }
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        if stop.load(Ordering::Relaxed) {
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(10));
                    }
                    Err(error) => panic!("app accept: {error}"),
                }
            }
        });
        Self { socket, done, received, listener: Some(handle) }
    }

    /// The `caller` of every `system.identify` the app got.
    fn identify_callers(&self) -> Vec<Value> {
        self.received
            .lock()
            .unwrap()
            .iter()
            .filter(|request| request["method"] == "system.identify")
            .map(|request| request["params"]["caller"].clone())
            .collect()
    }
}

impl Drop for FakeApp {
    fn drop(&mut self) {
        self.done.store(true, Ordering::Relaxed);
        if let Some(handle) = self.listener.take() {
            let _ = handle.join();
        }
    }
}

fn answer(stream: UnixStream, identity: &Value, log: &Mutex<Vec<Value>>) {
    stream.set_nonblocking(false).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    let mut line = String::new();
    while reader.read_line(&mut line).unwrap_or(0) > 0 {
        let request: Value = serde_json::from_str(&line).unwrap();
        line.clear();
        let response = if request["method"] == "system.identify" {
            json!({"id": request["id"], "ok": true, "result": identity})
        } else {
            json!({"id": request["id"], "ok": false, "error": {"code": "method_not_found",
                "message": format!("Unknown method {}", request["method"]), "data": {}}})
        };
        log.lock().unwrap().push(request);
        if writeln!(writer, "{response}").and_then(|()| writer.flush()).is_err() {
            break;
        }
    }
}

/// The app's `caller` for the chat (or terminal) in the fixture's pane.
fn caller_in(split: &Split, screen: &str) -> Value {
    json!({"is_caller": true, "workspace": split.alpha, "screen": screen, "pane": split.pane})
}

#[test]
fn a_terminals_tab_with_no_place_opens_in_its_own_pane_not_the_focused_one() {
    let split = caller_in_alpha_beta_focused("place-tab");
    let Split { server, terminal, pane, alpha, beta } = &split;

    let created = run(server, &Who::terminal(terminal), &["tab", "create", "terminal"]);
    assert_eq!(created_pane(&created), pane, "{created}");
    assert_eq!(created["value"]["workspace_id"], alpha.as_str(), "{created}");

    // A shell outside cmux has no place of its own: the session's active pane.
    let outside = run(server, &Who::default(), &["tab", "create", "terminal"]);
    assert_eq!(outside["value"]["workspace_id"], beta.as_str(), "{outside}");
    assert_beta_still_focused(server, beta);
}

#[test]
fn a_terminals_pane_and_screen_with_no_place_stay_in_its_own_workspace() {
    let split = caller_in_alpha_beta_focused("place-pane-screen");
    let Split { server, terminal, pane, alpha, beta } = &split;
    let who = Who::terminal(terminal);

    let new_pane = run(server, &who, &["pane", "create"]);
    assert_eq!(new_pane["value"]["workspace_id"], alpha.as_str(), "{new_pane}");
    assert_eq!(new_pane["value"]["screen_id"], screen_of_pane(server, pane), "{new_pane}");
    assert_ne!(created_pane(&new_pane), pane, "{new_pane}");

    let new_screen = run(server, &who, &["screen", "create", "--name", "logs"]);
    assert_eq!(new_screen["value"]["workspace_id"], alpha.as_str(), "{new_screen}");

    let outside = run(server, &Who::default(), &["pane", "create"]);
    assert_eq!(outside["value"]["workspace_id"], beta.as_str(), "{outside}");
    assert_beta_still_focused(server, beta);
}

/// `browser profile open` with no `--pane` opened sign-in links in the
/// focused pane, Home's right pane in the reported case.
#[test]
fn a_profile_browser_tab_with_no_pane_opens_in_the_callers_own_pane() {
    let split = caller_in_alpha_beta_focused("place-profile");
    let Split { server, terminal, pane, beta, .. } = &split;
    let open = [
        "browser",
        "profile",
        "open",
        "https://example.com/",
        "--profile",
        "default",
        "--engine",
        "webkit",
        "--background",
        "true",
    ];

    let opened = run(server, &Who::terminal(terminal), &open);
    assert_eq!(created_pane(&opened), pane, "{opened}");

    let outside = run(server, &Who::default(), &open);
    assert_eq!(workspace_of_pane(server, created_pane(&outside)), *beta, "{outside}");
    assert_beta_still_focused(server, beta);
}

#[test]
fn an_agent_chat_no_app_places_uses_the_workspace_its_environment_names() {
    let split = caller_in_alpha_beta_focused("place-workspace-key");
    let Split { server, alpha, beta, .. } = &split;
    let key = workspace_key(server, alpha);
    let chat = Who { workspace_key: Some(&key), ..Who::agent() };

    let tab = run(server, &chat, &["tab", "create", "terminal"]);
    assert_eq!(tab["value"]["workspace_id"], alpha.as_str(), "{tab}");
    let new_pane = run(server, &chat, &["pane", "create"]);
    assert_eq!(new_pane["value"]["workspace_id"], alpha.as_str(), "{new_pane}");
    // `current` is that workspace too, never the focused one.
    let current = run(server, &chat, &["workspace", "current", "show"]);
    assert_eq!(current["id"], alpha.as_str(), "{current}");
    // An agent it starts opens there as well.
    let started = run(
        server,
        &chat,
        &["agent", "start", "helper", "--cmd", "sleep 600", "--no-wait", "--no-focus"],
    );
    assert_eq!(started["workspace_id"], alpha.as_str(), "{started}");

    // A key this session does not have (another session's, or a closed
    // workspace) names no place: the daemon's default.
    let stale = Who { workspace_key: Some("00000000-0000-4000-8000-000000000000"), ..Who::agent() };
    let elsewhere = run(server, &stale, &["tab", "create", "terminal"]);
    assert_eq!(elsewhere["value"]["workspace_id"], beta.as_str(), "{elsewhere}");
    assert_beta_still_focused(server, beta);
}

#[test]
fn a_terminal_the_daemon_no_longer_shows_keeps_the_daemon_default() {
    let split = caller_in_alpha_beta_focused("place-stale-terminal");
    let Split { server, beta, .. } = &split;
    let gone = Who::terminal("term_00000000000000000000000000000000");
    let created = run(server, &gone, &["tab", "create", "terminal"]);
    assert_eq!(created["value"]["workspace_id"], beta.as_str(), "{created}");
}

#[test]
fn a_request_to_another_session_keeps_that_sessions_default() {
    let split = caller_in_alpha_beta_focused("place-other-session");
    let Split { server, terminal, .. } = &split;
    let other = HeadlessServer::start("place-other-session-target");
    state_cli(&other, None, &["workspace", "create", "--name", "theirs"]);
    let theirs = workspace_id_named(&other, "theirs");
    state_cli(&other, None, &["workspace", &theirs, "focus"]);
    let tabs = |server: &HeadlessServer| {
        state_cli(server, None, &["session", "current", "snapshot"])["tabs"]
            .as_array()
            .map_or(0, Vec::len)
    };
    let before = tabs(server);

    // The caller's terminal belongs to its own session: `--socket` names
    // another one, whose daemon has none of the caller's ids.
    let socket = other.socket.display().to_string();
    let routed = output(
        server,
        &Who::terminal(terminal),
        &["--socket", &socket],
        &["tab", "create", "terminal"],
    );
    assert_success(&routed);
    let created = json_output(&routed);
    assert_eq!(created["value"]["workspace_id"], theirs.as_str(), "{created}");
    assert_eq!(tabs(server), before, "the caller's own session got the tab");
}

#[test]
fn an_agents_terminal_with_no_place_opens_beside_its_chat() {
    let split = caller_in_alpha_beta_focused("place-agent-beside");
    let Split { server, pane, alpha, beta, .. } = &split;
    let screen = screen_of_pane(server, pane);
    let caller = caller_in(&split, &screen);

    // No column right of the chat yet: the terminal makes it.
    let app = FakeApp::start(
        server,
        "app-new-column",
        json!({"caller": caller, "beside": {"pane": null, "placement": "new_column"}}),
    );
    let chat = Who::agent().with_app(&app);
    let first = run(server, &chat, &["tab", "create", "terminal", "--name", "dev"]);
    let column = created_pane(&first).to_owned();
    assert_ne!(column, *pane, "{first}");
    assert_eq!(workspace_of_pane(server, &column), *alpha, "{first}");
    assert_eq!(app.identify_callers(), vec![json!({"agent_session": AGENT_SESSION})]);
    drop(app);

    // With the column there, the next terminal is a tab in it.
    let app = FakeApp::start(
        server,
        "app-existing-column",
        json!({"caller": caller, "beside": {"pane": column, "placement": "existing_column",
            "panes": [{"id": column, "kinds": ["terminal"]}]}}),
    );
    let chat = Who::agent().with_app(&app);
    let second = run(server, &chat, &["tab", "create", "terminal"]);
    assert_eq!(created_pane(&second), column, "{second}");
    assert_beta_still_focused(server, beta);
}

#[test]
fn an_app_that_places_terminals_decides_where_a_terminals_new_tab_goes() {
    let split = caller_in_alpha_beta_focused("place-terminal-app");
    let Split { server, terminal, pane, alpha, beta } = &split;
    let screen = screen_of_pane(server, pane);
    let caller = caller_in(&split, &screen);

    // A plain terminal: its own pane.
    let app = FakeApp::start(
        server,
        "app-own-pane",
        json!({"caller_placement": 2, "caller": caller,
            "beside": {"pane": pane, "placement": "own_pane"}}),
    );
    let plain =
        run(server, &Who::terminal(terminal).with_app(&app), &["tab", "create", "terminal"]);
    assert_eq!(created_pane(&plain), pane, "{plain}");
    assert_eq!(app.identify_callers(), vec![json!({"terminal_id": terminal})]);
    drop(app);

    // A terminal that runs an agent: the column right of it.
    let app = FakeApp::start(
        server,
        "app-agent-terminal",
        json!({"caller_placement": 2, "caller": caller,
            "beside": {"pane": null, "placement": "new_column"}}),
    );
    let agent =
        run(server, &Who::terminal(terminal).with_app(&app), &["tab", "create", "terminal"]);
    assert_ne!(created_pane(&agent), pane, "{agent}");
    assert_eq!(agent["value"]["workspace_id"], alpha.as_str(), "{agent}");
    drop(app);

    // An older app answers `beside` for a terminal as for a chat and names
    // no `caller_placement`: the CLI keeps the terminal's own pane.
    let app = FakeApp::start(
        server,
        "app-older",
        json!({"caller": caller, "beside": {"pane": null, "placement": "new_column"}}),
    );
    let older =
        run(server, &Who::terminal(terminal).with_app(&app), &["tab", "create", "terminal"]);
    assert_eq!(created_pane(&older), pane, "{older}");
    assert_beta_still_focused(server, beta);
}

#[test]
fn an_agents_profile_browser_tab_opens_in_a_pane_of_its_own_beside_the_chat() {
    let split = caller_in_alpha_beta_focused("place-agent-profile");
    let Split { server, pane, alpha, beta, .. } = &split;
    let screen = screen_of_pane(server, pane);
    let app = FakeApp::start(
        server,
        "app-profile",
        json!({"caller": caller_in(&split, &screen),
            "beside": {"pane": null, "placement": "new_column"}}),
    );
    let opened = run(
        server,
        &Who::agent().with_app(&app),
        &[
            "browser",
            "profile",
            "open",
            "https://example.com/",
            "--profile",
            "default",
            "--engine",
            "webkit",
        ],
    );
    let column = created_pane(&opened).to_owned();
    assert_ne!(column, *pane, "{opened}");
    assert_eq!(workspace_of_pane(server, &column), *alpha, "{opened}");
    let tab = opened["value"]["tab_id"].as_str().unwrap_or_else(|| panic!("{opened}"));
    let shown = state_cli(server, None, &["tab", tab, "show"]);
    assert_eq!(shown["pane_id"], column.as_str(), "{shown}");
    assert_beta_still_focused(server, beta);
}

/// `cmux agents terminal split` dropped the caller lookup, so a Chief
/// turn's split landed in the pane the person had focused.
#[test]
fn agents_terminal_split_splits_the_callers_pane_not_the_focused_one() {
    let split = caller_in_alpha_beta_focused("place-agents-split");
    let Split { server, terminal, pane, alpha, beta } = &split;
    let split_right = ["agents", "terminal", "split", "right"];

    let receipt = run(server, &Who::terminal(terminal), &split_right);
    assert_eq!(receipt["action"], "terminal.split", "{receipt}");
    assert_eq!(receipt["result"]["value"]["workspace_id"], alpha.as_str(), "{receipt}");

    // A Chief turn has no terminal: the app that owns the daemon says where
    // the Home chat is.
    let screen = screen_of_pane(server, pane);
    let app = FakeApp::start(
        server,
        "app-home",
        json!({"caller": caller_in(&split, &screen),
            "beside": {"pane": null, "placement": "new_column"}}),
    );
    let chief = Who { home_chat: true, app: Some(&app.socket), ..Who::default() };
    let receipt = run(server, &chief, &split_right);
    assert_eq!(receipt["result"]["value"]["workspace_id"], alpha.as_str(), "{receipt}");
    assert!(app.identify_callers().contains(&json!({"home_chat": true})), "the app was not asked");
    assert_beta_still_focused(server, beta);
}

/// The MCP server follows the same rule as the CLI: a pane, a screen and a
/// profile browser tab an agent makes with no place stay in its workspace.
#[test]
fn mcp_creations_with_no_place_stay_in_the_callers_workspace() {
    let split = caller_in_alpha_beta_focused("place-mcp");
    let Split { server, terminal, pane, alpha, beta } = &split;
    let page = "{url: 'https://example.com/', profile: 'default', engine: 'webkit'}";

    // No app: the daemon knows the caller's terminal.
    let made = mcp_exec(
        server,
        &Who::terminal(terminal),
        &format!(
            "const pane = await cmux.pane_create({{}}); \
             const screen = await cmux.screen_create({{name: 'logs'}}); \
             const page = await cmux.browser_profile_open({page}); \
             return {{pane, screen, page}};"
        ),
    );
    assert_eq!(made["pane"]["value"]["workspace_id"], alpha.as_str(), "{made}");
    assert_eq!(made["screen"]["value"]["workspace_id"], alpha.as_str(), "{made}");
    assert_eq!(made["page"]["value"]["pane_id"], pane.as_str(), "{made}");

    // An agent chat the app places: the page gets a pane beside the chat.
    let screen = screen_of_pane(server, pane);
    let app = FakeApp::start(
        server,
        "app-mcp",
        json!({"caller": caller_in(&split, &screen),
            "beside": {"pane": null, "placement": "new_column"}}),
    );
    let opened = mcp_exec(
        server,
        &Who::agent().with_app(&app),
        &format!("return await cmux.browser_profile_open({page});"),
    );
    let column = created_pane(&opened).to_owned();
    assert_ne!(column, *pane, "{opened}");
    assert_eq!(workspace_of_pane(server, &column), *alpha, "{opened}");
    assert_beta_still_focused(server, beta);
}

/// A Cloud Chief turn reaches the person's Mac app over a relay while its
/// daemon is the machine's own: the Mac's Home chat ids name nothing there
/// (https://github.com/manaflow-ai/cmux/issues/25590), so only the app that
/// owns the request's daemon places a caller.
#[test]
fn an_app_that_does_not_own_the_daemon_never_places_a_chief_turn() {
    let split = caller_in_alpha_beta_focused("place-relayed-app");
    let Split { server, pane, beta, .. } = &split;
    let screen = screen_of_pane(server, pane);
    let app = FakeApp::start(
        server,
        "app-relayed",
        json!({"caller": caller_in(&split, &screen),
            "beside": {"pane": null, "placement": "new_column"}}),
    );
    let chief = Who { home_chat: true, relayed_app: Some(&app.socket), ..Who::default() };

    let created = run(server, &chief, &["tab", "create", "terminal"]);
    assert_eq!(created["value"]["workspace_id"], beta.as_str(), "{created}");
    let shown = run(server, &chief, &["pane", "current", "show"]);
    assert_eq!(workspace_of_pane(server, shown["id"].as_str().unwrap()), *beta, "{shown}");
    assert_eq!(app.identify_callers(), Vec::<Value>::new(), "the relayed app was asked");
}

/// An ACP agent has no terminal, so `agent start` with no `--pane` fell back
/// to the pane the person had focused.
#[test]
fn an_agent_chats_agent_start_opens_beside_its_chat() {
    let split = caller_in_alpha_beta_focused("place-agent-start");
    let Split { server, pane, alpha, beta, .. } = &split;
    let screen = screen_of_pane(server, pane);
    let app = FakeApp::start(
        server,
        "app-agent-start",
        json!({"caller": caller_in(&split, &screen),
            "beside": {"pane": null, "placement": "new_column"}}),
    );
    let started = run(
        server,
        &Who::agent().with_app(&app),
        &["agent", "start", "worker", "--cmd", "sleep 600", "--no-wait", "--no-focus"],
    );
    assert_eq!(started["workspace_id"], alpha.as_str(), "{started}");
    assert_ne!(started["pane_id"], pane.as_str(), "{started}");
    assert_eq!(started["placement"], "split", "{started}");
    assert_beta_still_focused(server, beta);
}
