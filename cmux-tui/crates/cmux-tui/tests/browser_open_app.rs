//! `tab create browser` and `browser open` in a session a cmux app owns go
//! through the app's `openBrowser` action, never straight to the daemon.
//!
//! nxbct-v1 dogfood (cmux-lawrence-2): `cmux tab create browser --url …`
//! made a daemon-rendered browser tab that the app does not draw (blank
//! pane, `kind none`, invariant violations rising), and `cmux browser open`
//! from an SSH shell landed on the daemon's shared active pane, in another
//! workspace than the one the app's window showed
//! (plans/cmux-next/state-ownership.md, section 3).
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

const WORKSPACE: &str = "ws_11111111111111111111111111111111";
const SCREEN: &str = "screen_22222222222222222222222222222222";
const PANE: &str = "pane_33333333333333333333333333333333";
const SHOWN_TAB: &str = "tab_44444444444444444444444444444444";
const CALLER_TERMINAL: &str = "term_55555555555555555555555555555555";
const CALLER_TAB: &str = "tab_66666666666666666666666666666666";
const NEW_TAB: &str = "tab_77777777777777777777777777777777";
const NEW_BROWSER: &str = "browser_88888888888888888888888888888888";
const URL: &str = "http://127.0.0.1:8765/opener-a.html";
const HOME_REFUSAL: &str = "openBrowser unavailable: This page has no tabs.";
static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

#[test]
fn tab_create_browser_in_an_app_session_opens_through_the_apps_open_browser() {
    let run = Run::new(true).cli(&["--json", "tab", "create", "browser", "--url", URL], None);
    assert!(run.output.status.success(), "{}", run.stderr());
    assert_eq!(
        run.daemon_operations().iter().filter(|op| *op == "tab.create_browser").count(),
        0,
        "the daemon made a daemon-rendered browser tab: {:?}",
        run.daemon
    );
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["method"], "action.run");
    assert_eq!(call["params"]["action"], "openBrowser");
    // No engine and no profile: the app's `browser.defaultEngine` and its
    // profile cascade decide, the same as a tab opened from the tab strip
    // (nxcap-v3: a CLI tab was WebKit with Chromium as the default engine).
    assert_eq!(call["params"]["args"], json!({"url": URL}), "{call}");
    assert!(call["params"]["idempotency_key"].is_string(), "{call}");
    // The reply is the created path `tab.create_browser` answers.
    let reply: Value = serde_json::from_slice(&run.output.stdout).expect("JSON reply");
    assert_eq!(reply["value"]["kind"], "browser", "{reply}");
    assert_eq!(reply["value"]["tab_id"], NEW_TAB, "{reply}");
    assert_eq!(reply["value"]["browser_id"], NEW_BROWSER, "{reply}");
    assert_eq!(reply["value"]["pane_id"], PANE, "{reply}");
    assert_eq!(reply["value"]["screen_id"], SCREEN, "{reply}");
    assert_eq!(reply["value"]["workspace_id"], WORKSPACE, "{reply}");
}

#[test]
fn browser_open_from_a_caller_with_no_terminal_targets_the_apps_focused_pane() {
    // An SSH shell: no CMUX_TUI_TERMINAL_ID. The app's front window decides,
    // not the daemon's shared active pane.
    let run = Run::new(true).cli(&["--json", "browser", "open", URL], None);
    assert!(run.output.status.success(), "{}", run.stderr());
    assert!(
        !run.daemon_operations().contains(&"tab.create_browser".to_string()),
        "{:?}",
        run.daemon
    );
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["params"]["action"], "openBrowser");
    assert!(
        call["params"].get("target").is_none(),
        "no target means the app's focused pane: {call}"
    );
}

#[test]
fn browser_open_from_a_terminal_targets_the_callers_pane() {
    let run = Run::new(true).cli(&["--json", "browser", "open", URL], Some(CALLER_TERMINAL));
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["params"]["target"], format!("tab:{CALLER_TAB}"), "{call}");
    assert!(
        !run.daemon_operations().contains(&"tab.create_browser".to_string()),
        "{:?}",
        run.daemon
    );
}

#[test]
fn a_named_pane_wins_over_the_callers_terminal() {
    let run = Run::new(true).cli(
        &["--json", "tab", "create", "browser", "--url", URL, "--pane", PANE],
        Some(CALLER_TERMINAL),
    );
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["params"]["target"], format!("tab:{SHOWN_TAB}"), "{call}");
    let lookup = run
        .daemon
        .iter()
        .find(|request| request["operation"] == "tab.get" && request["params"]["pane"] == PANE)
        .unwrap_or_else(|| panic!("no tab.get of the named pane: {:?}", run.daemon));
    // The daemon refuses `tab: current` without every parent: the CLI reads
    // the named pane's own screen and workspace first.
    assert_eq!(lookup["params"]["tab"], "current", "{lookup}");
    assert_eq!(lookup["params"]["screen"], SCREEN, "{lookup}");
    assert_eq!(lookup["params"]["workspace"], WORKSPACE, "{lookup}");
}

#[test]
fn a_named_screen_opens_in_its_shown_pane() {
    let run = Run::new(true).cli(
        &["--json", "tab", "create", "browser", "--url", URL, "--screen", SCREEN],
        Some(CALLER_TERMINAL),
    );
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["params"]["target"], format!("tab:{SHOWN_TAB}"), "{call}");
}

#[test]
fn a_name_is_set_on_the_tab_the_app_opened() {
    let run = Run::new(true)
        .cli(&["--json", "tab", "create", "browser", "--url", URL, "--name", "docs"], None);
    assert!(run.output.status.success(), "{}", run.stderr());
    let rename = run
        .daemon
        .iter()
        .find(|request| request["operation"] == "tab.rename")
        .unwrap_or_else(|| panic!("no tab.rename: {:?}", run.daemon));
    assert_eq!(rename["params"]["tab"], NEW_TAB);
    assert_eq!(rename["params"]["name"], "docs");
    assert!(rename["idempotency_key"].is_string(), "{rename}");
}

#[test]
fn without_an_app_the_daemon_creates_the_tab() {
    let run = Run::new(false).cli(&["--json", "browser", "open", URL], None);
    assert!(run.output.status.success(), "{}", run.stderr());
    assert_eq!(run.daemon_operations(), vec!["tab.create_browser".to_string()]);
    assert!(run.app.is_empty());
}

#[test]
fn another_machines_browser_tab_stays_with_its_daemon() {
    let run =
        Run::new(true).cli(&["--json", "--machine", "m_remote", "browser", "open", URL], None);
    assert!(run.output.status.success(), "{}", run.stderr());
    assert_eq!(run.daemon_operations(), vec!["tab.create_browser".to_string()]);
    assert!(run.app.is_empty(), "{:?}", run.app);
}

#[test]
fn browser_open_from_a_terminal_in_the_shown_workspace_opens_in_that_pane() {
    // A cmux terminal pane of the workspace the window shows runs the
    // command: the tab goes to that pane, with no fallback and no reveal.
    let run =
        Run::app(AppMode::Home).cli(&["--json", "browser", "open", URL], Some(CALLER_TERMINAL));
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["params"]["action"], "openBrowser");
    assert_eq!(call["params"]["target"], format!("tab:{CALLER_TAB}"), "{call}");
    assert!(
        !run.daemon.iter().any(|r| r["operation"] == "tab.get" && r["params"]["tab"] == "current"),
        "the caller's pane, not the daemon default: {:?}",
        run.daemon
    );
}

/// cmux-lawrence-2 GUI check of 772c55184089: the app starts on the Home
/// page (no panes). From an SSH shell both verbs failed with
/// `openBrowser unavailable: This page has no tabs.`; before 772c the daemon
/// opened the tab on its default pane.
fn assert_opens_on_the_daemon_default_pane_when_the_window_shows_a_page(args: &[&str]) {
    let run = Run::app(AppMode::Home).cli(args, None);
    assert!(run.output.status.success(), "{}", run.stderr());
    let actions: Vec<_> = run.app.iter().map(|c| c["params"]["action"].clone()).collect();
    let [first, second, reveal] = run.app.as_slice() else {
        panic!("openBrowser, openBrowser on the default pane, tab.focus expected: {actions:?}")
    };
    assert_eq!(first["params"]["action"], "openBrowser");
    assert!(first["params"].get("target").is_none(), "{first}");
    // The daemon's default pane (the pre-772c target), still through the
    // app's openBrowser so engine and profile rules stay the same.
    assert_eq!(second["params"]["action"], "openBrowser");
    assert_eq!(second["params"]["target"], format!("tab:{SHOWN_TAB}"), "{second}");
    assert_eq!(second["params"]["args"], json!({"url": URL}), "{second}");
    assert_ne!(second["params"]["idempotency_key"], first["params"]["idempotency_key"]);
    // The window leaves the page and shows the new tab.
    assert_eq!(reveal["params"]["action"], "tab.focus");
    assert_eq!(reveal["params"]["target"], NEW_TAB, "{reveal}");
    assert!(
        !run.daemon_operations().contains(&"tab.create_browser".to_string()),
        "{:?}",
        run.daemon
    );
    let reply: Value = serde_json::from_slice(&run.output.stdout).expect("JSON reply");
    assert_eq!(reply["value"]["tab_id"], NEW_TAB, "{reply}");
}

#[test]
fn browser_open_from_ssh_with_the_window_on_a_page_uses_the_daemon_default_pane() {
    assert_opens_on_the_daemon_default_pane_when_the_window_shows_a_page(&[
        "--json", "browser", "open", URL,
    ]);
}

#[test]
fn tab_create_browser_from_ssh_with_the_window_on_a_page_uses_the_daemon_default_pane() {
    assert_opens_on_the_daemon_default_pane_when_the_window_shows_a_page(&[
        "--json", "tab", "create", "browser", "--url", URL,
    ]);
}

#[test]
fn an_app_refusal_prints_the_refusal_and_no_retry_note() {
    // The app never ran openBrowser: there is nothing whose outcome is
    // unknown, so no `mutation.outcome_unknown` and no retry key.
    for json_mode in [true, false] {
        let mut args = vec!["browser", "open", URL];
        if json_mode {
            args.insert(0, "--json");
        }
        let run = Run::app(AppMode::Refuse).cli(&args, Some(CALLER_TERMINAL));
        assert!(!run.output.status.success(), "the refusal must fail the command");
        let printed = format!("{}{}", String::from_utf8_lossy(&run.output.stdout), run.stderr());
        assert!(printed.contains("This page has no tabs."), "{printed}");
        assert!(!printed.contains("outcome_unknown"), "{printed}");
        assert!(!printed.contains("idempotency"), "{printed}");
    }
}

#[test]
fn a_tab_the_window_cannot_show_still_opens_and_says_why() {
    let run = Run::app(AppMode::HomeNoReveal).cli(&["--json", "browser", "open", URL], None);
    assert!(run.output.status.success(), "the tab exists: {}", run.stderr());
    let reply: Value = serde_json::from_slice(&run.output.stdout).expect("JSON reply");
    assert_eq!(reply["value"]["tab_id"], NEW_TAB, "{reply}");
    let stderr = run.stderr();
    let lines: Vec<_> = stderr.lines().collect();
    assert_eq!(
        lines,
        vec![format!(
            "cmux: tab opened in {WORKSPACE}, but the window could not show it: \
             no window lists this workspace"
        )],
        "{stderr}"
    );
}

struct Run {
    dir: PathBuf,
    app: Option<AppMode>,
}

/// What the fake app's window shows.
#[derive(Clone, Copy)]
enum AppMode {
    /// A workspace with a focused pane: every openBrowser opens `NEW_TAB`.
    Workspace,
    /// The Home page: openBrowser with no target is refused, with a target
    /// it opens `NEW_TAB`.
    Home,
    /// Every openBrowser is refused.
    Refuse,
    /// `Home`, and its window cannot show the new tab (`tab.focus` fails).
    HomeNoReveal,
}

struct Finished {
    output: Output,
    daemon: Vec<Value>,
    app: Vec<Value>,
}

impl Finished {
    fn stderr(&self) -> String {
        String::from_utf8_lossy(&self.output.stderr).into_owned()
    }

    fn daemon_operations(&self) -> Vec<String> {
        self.daemon.iter().filter_map(|r| r["operation"].as_str().map(str::to_owned)).collect()
    }
}

impl Run {
    fn new(with_app: bool) -> Self {
        Self::with(with_app.then_some(AppMode::Workspace))
    }

    fn app(mode: AppMode) -> Self {
        Self::with(Some(mode))
    }

    fn with(app: Option<AppMode>) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let sequence = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        let dir =
            Path::new("/tmp").join(format!("cmux-bopen-{}-{stamp}-{sequence}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Self { dir, app }
    }

    fn cli(self, args: &[&str], caller_terminal: Option<&str>) -> Finished {
        let daemon_socket = self.dir.join("mux.sock");
        let app_socket = self.dir.join("app.sock");
        let daemon = fake_daemon(&daemon_socket);
        let done = Arc::new(AtomicBool::new(false));
        let app = self.app.map(|mode| fake_app(&app_socket, mode, done.clone()));
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        if self.app.is_some() {
            command.arg("--app-socket").arg(&app_socket);
        }
        command
            .args(args)
            // The daemon socket comes from the environment, as in a terminal
            // or a shell of the app's session, so the caller route applies.
            .env("CMUX_TUI_SOCKET", &daemon_socket)
            .env_remove("CMUX_MUX_SOCKET")
            .env_remove("CMUX_TUI_TERMINAL_ID");
        if let Some(terminal) = caller_terminal {
            command.env("CMUX_TUI_TERMINAL_ID", terminal);
        }
        let output = command.output().unwrap();
        done.store(true, Ordering::Relaxed);
        let daemon = daemon.join().unwrap();
        let app = app.map(|handle| handle.join().unwrap()).unwrap_or_default();
        let _ = std::fs::remove_dir_all(&self.dir);
        Finished { output, daemon, app }
    }
}

/// A daemon that answers the reads the CLI makes and `tab.create_browser`,
/// and records every request of the one connection.
fn fake_daemon(socket: &Path) -> JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut requests = Vec::new();
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap_or(0) > 0 {
            let request: Value = serde_json::from_str(&line).expect("CLI sent invalid JSON");
            line.clear();
            let result = match incomplete_chain(&request["params"]) {
                Some(message) => Err(("selector.invalid", message)),
                None => daemon_result(&request).map_err(|message| ("resource.not_found", message)),
            };
            let response = match result {
                Ok(result) => json!({"protocol": "cmux.protocol/2", "type": "response",
                    "id": request["id"], "ok": true, "result": result}),
                Err((code, message)) => json!({"protocol": "cmux.protocol/2", "type": "response",
                    "id": request["id"], "ok": false, "error": {"code": code,
                    "message": message, "details": {}, "retryable": false}}),
            };
            requests.push(request);
            if writeln!(writer, "{response}").and_then(|()| writer.flush()).is_err() {
                break;
            }
        }
        requests
    })
}

/// The real daemon's chain rule (resource_selector.rs): a `current` or
/// name selector needs every structural parent above it; an exact id
/// stands alone.
fn incomplete_chain(params: &Value) -> Option<String> {
    let levels = ["workspace", "screen", "pane", "tab"];
    for (index, kind) in levels.iter().enumerate() {
        let Some(raw) = params[*kind].as_str() else { continue };
        if raw.starts_with(&format!("{}_", if *kind == "workspace" { "ws" } else { kind })) {
            continue;
        }
        if let Some(missing) =
            levels[..index].iter().rev().find(|parent| params[**parent].is_null())
        {
            return Some(format!("{kind} current/name selector requires a {missing} selector"));
        }
    }
    None
}

fn daemon_result(request: &Value) -> Result<Value, String> {
    let params = &request["params"];
    let created = json!({"kind": "browser", "workspace_id": WORKSPACE, "screen_id": SCREEN,
        "pane_id": PANE, "tab_id": NEW_TAB, "browser_id": NEW_BROWSER});
    match request["operation"].as_str().unwrap_or_default() {
        "tab.create_browser" => Ok(json!({"value": created, "generation": "g", "revision": "2",
            "replayed": false})),
        "tab.get" if params["tab"] == NEW_TAB => Ok(json!({"id": NEW_TAB, "pane_id": PANE,
            "content_kind": "browser", "content_id": NEW_BROWSER})),
        "tab.get" if params["tab"] == "current" => Ok(json!({"id": SHOWN_TAB, "pane_id": PANE,
            "content_kind": "terminal", "content_id": "term_99999999999999999999999999999999"})),
        "terminal.get" if params["terminal"] == CALLER_TERMINAL => Ok(json!({
            "id": CALLER_TERMINAL, "tab_id": CALLER_TAB})),
        "pane.get" => Ok(json!({"id": params["pane"], "screen_id": SCREEN})),
        "screen.get" => Ok(json!({"id": params["screen"], "workspace_id": WORKSPACE})),
        "tab.rename" => Ok(json!({"value": {"id": params["tab"]}, "generation": "g",
            "revision": "3", "replayed": false})),
        other => Err(format!("unexpected {other} {params}")),
    }
}

/// The fake app's answer to one `action.run`.
fn app_response(mode: AppMode, request: &Value) -> Value {
    let params = &request["params"];
    let refused = match mode {
        AppMode::Workspace => false,
        AppMode::Home | AppMode::HomeNoReveal => {
            params["action"] == "openBrowser" && params.get("target").is_none()
        }
        AppMode::Refuse => true,
    };
    if matches!(mode, AppMode::HomeNoReveal) && params["action"] == "tab.focus" {
        return json!({"id": request["id"], "ok": false, "error": {"code": "unavailable",
            "message": "no window lists this workspace", "data": {}}});
    }
    if refused {
        return json!({"id": request["id"], "ok": false, "error": {"code": "unavailable",
            "message": HOME_REFUSAL,
            "data": {"action": "openBrowser", "reason": "This page has no tabs."}}});
    }
    // The real app maps created ids only after a waited run settles; a run
    // that does not wait answers `created: []` at once.
    let created = if params["action"] == "openBrowser" && params["wait"] == true {
        json!([NEW_TAB])
    } else {
        json!([])
    };
    json!({"id": request["id"], "ok": true, "result": {"action": params["action"], "ran": true,
        "waited": true, "created": created, "replayed": false}})
}

/// An app control socket whose `openBrowser` creates `NEW_TAB` as `mode`
/// allows. It stops waiting for a connection once `done` is set.
fn fake_app(socket: &Path, mode: AppMode, done: Arc<AtomicBool>) -> JoinHandle<Vec<Value>> {
    let listener = UnixListener::bind(socket).unwrap();
    listener.set_nonblocking(true).unwrap();
    let received = Arc::new(Mutex::new(Vec::new()));
    std::thread::spawn(move || {
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
                    let mut reader = BufReader::new(stream.try_clone().unwrap());
                    let mut writer = stream;
                    let mut line = String::new();
                    while reader.read_line(&mut line).unwrap_or(0) > 0 {
                        let request: Value = serde_json::from_str(&line).unwrap();
                        line.clear();
                        let response = app_response(mode, &request);
                        received.lock().unwrap().push(request);
                        if writeln!(writer, "{response}").is_err() {
                            break;
                        }
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    if done.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("app accept: {error}"),
            }
        }
        std::mem::take(&mut *received.lock().unwrap())
    })
}
