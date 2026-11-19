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
/// The pane of the column right of the caller (`AppMode::RightColumn`).
const RIGHT_PANE: &str = "pane_99999999999999999999999999999999";
const NEW_BROWSER: &str = "browser_88888888888888888888888888888888";
const URL: &str = "http://127.0.0.1:8765/opener-a.html";
const OTHER_MACHINE: &str = "machine_99999999999999999999999999999999";
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
fn browser_open_from_a_terminal_with_an_older_app_targets_its_own_tab() {
    // An app from before `caller_placement` answers `new_column` for every
    // caller and opens a run with no target in the focused pane: the run
    // names the terminal's own tab, as for every app version.
    let run = Run::new(true).cli(&["--json", "browser", "open", URL], Some(CALLER_TERMINAL));
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.runs()[..] else { panic!("one app run expected: {:?}", run.app) };
    assert_eq!(call["params"]["target"], format!("tab:{CALLER_TAB}"), "{call}");
    assert!(
        !run.daemon_operations().contains(&"tab.create_browser".to_string()),
        "{:?}",
        run.daemon
    );
}

#[test]
fn a_plain_terminals_browser_targets_its_own_tab_never_the_panes_shown_tab() {
    // For a terminal no agent runs in, the app answers `beside: {pane: <its
    // own pane>, placement: "own_pane"}`. That pane is not a column right of
    // the terminal: naming it made the run target the pane's SHOWN tab, and
    // the app opened the browser in the terminal's pane. The run targets the
    // terminal's own tab and names the terminal; the app then opens the
    // browser where a Cmd-click there opens a link, right of the terminal.
    for args in [
        &["--json", "browser", "open", URL][..],
        &["--json", "tab", "create", "browser", "--url", URL][..],
    ] {
        let run = Run::app(AppMode::PlacesTerminals).cli(args, Some(CALLER_TERMINAL));
        assert!(run.output.status.success(), "{}", run.stderr());
        let [call] = run.runs()[..] else { panic!("one app run expected: {:?}", run.app) };
        assert_eq!(call["params"]["action"], "openBrowser", "{call}");
        assert_eq!(call["params"]["target"], format!("tab:{CALLER_TAB}"), "{call}");
        assert_eq!(call["params"]["caller"], json!({"terminal_id": CALLER_TERMINAL}), "{call}");
        assert!(
            !run.daemon
                .iter()
                .any(|r| r["operation"] == "tab.get" && r["params"]["tab"] == "current"),
            "the shown tab of a pane was read: {:?}",
            run.daemon
        );
        assert!(
            !run.daemon_operations().contains(&"tab.create_browser".to_string()),
            "{:?}",
            run.daemon
        );
    }
}

#[test]
fn an_app_that_places_callers_gets_no_pane_for_a_browser_right_of_a_terminal_pane() {
    // The caller has one terminal pane on its right, and the app says so in
    // `beside`. Naming that pane made the browser a tab in it: the app's own
    // rule (a split below a lone pane of another kind, another agent's home,
    // the person's link placement setting) never ran. The run carries the
    // caller alone: the terminal's own tab, or the agent session.
    let args = ["--json", "browser", "open", URL];
    let run = Run::app(AppMode::PlacesCallersRightColumn)
        .cli_as(&args, Caller::Terminal(CALLER_TERMINAL));
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.runs()[..] else { panic!("one app run expected: {:?}", run.app) };
    assert_eq!(call["params"]["target"], format!("tab:{CALLER_TAB}"), "{call}");
    assert_eq!(call["params"]["caller"], json!({"terminal_id": CALLER_TERMINAL}), "{call}");

    let run = Run::app(AppMode::PlacesCallersRightColumn).cli_as(&args, Caller::Agent);
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.runs()[..] else { panic!("one app run expected: {:?}", run.app) };
    assert!(call["params"].get("target").is_none(), "{call}");
    assert_eq!(call["params"]["caller"]["agent_session"], "acp_agent_session_a", "{call}");

    for caller in [Caller::Terminal(CALLER_TERMINAL), Caller::Agent] {
        let run = Run::app(AppMode::PlacesCallersRightColumn).cli_as(&args, caller);
        assert!(
            !run.daemon.iter().any(|r| r["params"]["pane"] == RIGHT_PANE),
            "the pane on the right was named: {:?}",
            run.daemon
        );
    }
}

/// With no pane on its right, a caller's new terminal gets a new pane. A
/// strip column (`fit`) goes after the caller's whole column: with another
/// agent's pane split off the caller's right, the column landed past that
/// pane, the app's right-of relation never found it, and every creation made
/// one more. A caller that is not docked gets a plain split of its own pane,
/// directly beside it; a docked chat cannot split and keeps the column, as
/// does an app that does not say (`caller.docked`).
#[test]
fn a_new_pane_beside_a_caller_is_a_split_of_its_pane_unless_the_caller_is_docked() {
    for (mode, fit) in [
        (AppMode::NewColumn { docked: Some(false) }, None),
        (AppMode::NewColumn { docked: Some(true) }, Some(true)),
        (AppMode::NewColumn { docked: None }, Some(true)),
    ] {
        let run = Run::app(mode).cli_as(&["--json", "tab", "create", "terminal"], Caller::Agent);
        assert!(run.output.status.success(), "{}", run.stderr());
        let split = run
            .daemon
            .iter()
            .find(|request| request["operation"] == "pane.split")
            .unwrap_or_else(|| panic!("no pane.split: {:?}", run.daemon));
        assert_eq!(split["params"]["pane"], PANE, "{split}");
        assert_eq!(split["params"]["workspace"], WORKSPACE, "{split}");
        assert_eq!(split["params"]["direction"], "right", "{split}");
        assert_eq!(split["params"].get("fit").and_then(Value::as_bool), fit, "{split}");
        assert!(
            !run.daemon_operations().contains(&"tab.create_terminal".to_string()),
            "{:?}",
            run.daemon
        );
    }
}

#[test]
fn with_an_older_app_a_browser_with_no_place_opens_in_the_column_right_of_its_caller() {
    // Lawrence 2026-11-15: an agent's `cmux browser open`, run in a terminal
    // with a column on its right, put the page as a tab over that terminal.
    // An app from before `caller_placement` places agent chats alone, so the
    // CLI names the column's pane, for an agent chat and for a terminal.
    for caller in [Caller::Terminal(CALLER_TERMINAL), Caller::Agent] {
        let run =
            Run::app(AppMode::RightColumn).cli_as(&["--json", "browser", "open", URL], caller);
        assert!(run.output.status.success(), "{}", run.stderr());
        let [call] = run.runs()[..] else { panic!("one app run expected: {:?}", run.app) };
        assert_eq!(call["params"]["target"], format!("tab:{SHOWN_TAB}"), "{call}");
        let lookup = run
            .daemon
            .iter()
            .find(|r| r["operation"] == "tab.get" && r["params"]["pane"] == RIGHT_PANE)
            .unwrap_or_else(|| panic!("no tab.get of the right column's pane: {:?}", run.daemon));
        assert_eq!(lookup["params"]["workspace"], WORKSPACE, "{lookup}");
    }
}

#[test]
fn an_agent_the_app_cannot_place_is_refused_and_opens_nothing() {
    // user, 2026-11-18: the app's `caller_unavailable` refusal became a tab on
    // the daemon's default pane, the focused workspace (Home).
    let run =
        Run::app(AppMode::UnplacedAgent).cli_as(&["--json", "browser", "open", URL], Caller::Agent);
    assert!(!run.output.status.success(), "an unplaced agent's browser opened");
    assert!(run.stderr().contains("caller_unavailable"), "{}", run.stderr());
    let [call] = run.runs()[..] else { panic!("one refused app run expected: {:?}", run.app) };
    assert!(call["params"].get("target").is_none(), "{call}");
    assert!(
        !run.daemon.iter().any(|r| r["operation"] == "tab.get" && r["params"]["tab"] == "current"),
        "the daemon's default pane was read: {:?}",
        run.daemon
    );
}

#[test]
fn a_terminal_the_daemon_no_longer_shows_opens_the_tab_at_the_default_place() {
    // A script that outlived its tab: `tab create terminal` from it keeps the
    // daemon's default, and `browser open` failed on the terminal lookup.
    // Both now name no place.
    let stale = "term_00000000000000000000000000000000";
    let run = Run::new(true).cli(&["--json", "browser", "open", URL], Some(stale));
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.runs()[..] else { panic!("one app run expected: {:?}", run.app) };
    assert!(call["params"].get("target").is_none(), "{call}");

    let run = Run::new(false).cli(&["--json", "browser", "open", URL], Some(stale));
    assert!(run.output.status.success(), "{}", run.stderr());
    let create = run
        .daemon
        .iter()
        .find(|request| request["operation"] == "tab.create_browser")
        .unwrap_or_else(|| panic!("no tab.create_browser: {:?}", run.daemon));
    for scope in ["workspace", "screen", "pane"] {
        assert!(create["params"].get(scope).is_none(), "{scope} was named: {create}");
    }
}

#[test]
fn without_an_app_a_terminals_browser_tab_opens_in_its_own_pane() {
    // A plain cmux-tui session or a Cloud machine: the daemon's active pane
    // follows the person's focus, so the CLI names the caller's own pane.
    let run = Run::new(false).cli(&["--json", "browser", "open", URL], Some(CALLER_TERMINAL));
    assert!(run.output.status.success(), "{}", run.stderr());
    let create = run
        .daemon
        .iter()
        .find(|request| request["operation"] == "tab.create_browser")
        .unwrap_or_else(|| panic!("no tab.create_browser: {:?}", run.daemon));
    assert_eq!(create["params"]["workspace"], WORKSPACE, "{create}");
    assert_eq!(create["params"]["screen"], SCREEN, "{create}");
    assert_eq!(create["params"]["pane"], PANE, "{create}");
}

#[test]
fn a_named_pane_wins_over_the_callers_terminal() {
    let run = Run::new(true).cli(
        &["--json", "tab", "create", "browser", "--url", URL, "--pane", PANE],
        Some(CALLER_TERMINAL),
    );
    assert!(run.output.status.success(), "{}", run.stderr());
    // An explicit pane is a script or agent target, often in a workspace the
    // window does not show: the tab opens there and the view stays (no
    // tab.focus; only the implicit default-pane fallback reveals).
    let [call] = run.app.as_slice() else { panic!("one app call expected: {:?}", run.app) };
    assert_eq!(call["params"]["action"], "openBrowser", "{call}");
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
    assert_eq!(call["params"]["action"], "openBrowser", "{call}");
    assert_eq!(call["params"]["target"], format!("tab:{SHOWN_TAB}"), "{call}");
}

#[test]
fn an_explicit_pane_in_a_background_workspace_keeps_the_selected_workspace() {
    // Home mode: the window shows a page, so the implicit fallback would
    // reveal. An explicit --pane is a script or agent target: the tab opens
    // there and the user's selected workspace stays.
    let run = Run::app(AppMode::Home)
        .cli(&["--json", "tab", "create", "browser", "--url", URL, "--pane", PANE], None);
    assert!(run.output.status.success(), "{}", run.stderr());
    let actions: Vec<_> = run.app.iter().map(|c| c["params"]["action"].clone()).collect();
    assert_eq!(
        actions,
        vec![json!("openBrowser")],
        "no tab.focus or workspace select: {actions:?}"
    );
    assert_eq!(run.app[0]["params"]["target"], format!("tab:{SHOWN_TAB}"));
    assert_eq!(selected_workspace(&[]), selected_workspace(&run.app), "{:?}", run.app);
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
    // The caller's terminal is this machine's: another machine's daemon has
    // none of its ids, so the request names no place, with or without an app.
    for (with_app, caller) in
        [(true, None), (true, Some(CALLER_TERMINAL)), (false, Some(CALLER_TERMINAL))]
    {
        // A `machine_…` id is the daemon's own word for a paired machine; any
        // other word makes the CLI ask the app whether it is a Cloud VM
        // (cloud_route.rs), which is not a placement request.
        let run = Run::new(with_app)
            .cli(&["--json", "--machine", OTHER_MACHINE, "browser", "open", URL], caller);
        assert!(run.output.status.success(), "{}", run.stderr());
        assert_eq!(run.daemon_operations(), vec!["tab.create_browser".to_string()]);
        let params = &run.daemon[0]["params"];
        for scope in ["workspace", "screen", "pane"] {
            assert!(params.get(scope).is_none(), "{scope} was named: {params}");
        }
        assert!(run.app.is_empty(), "{:?}", run.app);
    }
}

#[test]
fn browser_open_from_a_terminal_in_the_shown_workspace_opens_in_that_pane() {
    // A cmux terminal pane of the workspace the window shows runs the
    // command: the tab goes to that pane, with no fallback and no reveal.
    let run =
        Run::app(AppMode::Home).cli(&["--json", "browser", "open", URL], Some(CALLER_TERMINAL));
    assert!(run.output.status.success(), "{}", run.stderr());
    let [call] = run.runs()[..] else { panic!("one app run expected: {:?}", run.app) };
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
    /// `Workspace`, and the app places terminal callers itself
    /// (`system.identify` reports `caller_placement` 2): for a terminal no
    /// agent runs in, `beside` is its own pane (`own_pane`).
    PlacesTerminals,
    /// `Workspace` (an app from before `caller_placement`), and a column
    /// (`RIGHT_PANE`) is right of the caller.
    RightColumn,
    /// An app that places every caller (`caller_placement` 2), with one
    /// terminal pane (`RIGHT_PANE`) on the caller's right.
    PlacesCallersRightColumn,
    /// An app that places every caller, with no pane right of the caller
    /// (`new_column`), which says whether the caller is docked
    /// (`caller.docked`; `None`: an app from before it said).
    NewColumn { docked: Option<bool> },
    /// The app shows the agent nowhere: `system.identify` finds no caller
    /// and an untargeted openBrowser is refused with `caller_unavailable`.
    UnplacedAgent,
}

/// Who runs the command.
#[derive(Clone, Copy)]
enum Caller {
    Terminal(&'static str),
    /// An agent chat (`CMUX_AGENT_SESSION`), with no terminal.
    Agent,
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

    /// The app's `action.run` calls (it is also asked who the caller is).
    fn runs(&self) -> Vec<&Value> {
        self.app.iter().filter(|call| call["method"] == "action.run").collect()
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

    fn cli_as(self, args: &[&str], caller: Caller) -> Finished {
        match caller {
            Caller::Terminal(terminal) => self.run(args, Some(terminal), false),
            Caller::Agent => self.run(args, None, true),
        }
    }

    fn cli(self, args: &[&str], caller_terminal: Option<&str>) -> Finished {
        self.run(args, caller_terminal, false)
    }

    fn run(self, args: &[&str], caller_terminal: Option<&str>, agent: bool) -> Finished {
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
            .env_remove("CMUX_AGENT_SESSION")
            .env_remove("CMUX_CALLER_HOME_CHAT")
            .env_remove("CMUX_WORKSPACE_ID")
            .env_remove("CMUX_TUI_TERMINAL_ID");
        if let Some(terminal) = caller_terminal {
            command.env("CMUX_TUI_TERMINAL_ID", terminal);
        }
        if agent {
            command.env("CMUX_AGENT_SESSION", "acp_agent_session_a");
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
            if request["cmd"] == "set-client-info" {
                writeln!(writer, "{}", json!({"id": request["id"], "ok": true, "data": {}}))
                    .and_then(|()| writer.flush())
                    .unwrap();
                continue;
            }
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
        // No earlier try of this request made anything.
        "session.creation.resolve" => Ok(json!({"correlation_key": params["correlation_key"],
            "state": "not_applied", "recovery": "retry_new_idempotency_key"})),
        "pane.split" => Ok(json!({"value": {"kind": "terminal", "workspace_id": WORKSPACE,
            "screen_id": SCREEN, "pane_id": RIGHT_PANE, "tab_id": NEW_TAB,
            "terminal_id": "term_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
            "generation": "g", "revision": "2", "replayed": false})),
        "tab.get" if params["tab"] == NEW_TAB => Ok(json!({"id": NEW_TAB, "pane_id": PANE,
            "content_kind": "browser", "content_id": NEW_BROWSER})),
        "tab.get" if params["tab"] == "current" => Ok(json!({"id": SHOWN_TAB, "pane_id": PANE,
            "content_kind": "terminal", "content_id": "term_99999999999999999999999999999999"})),
        "terminal.get" if params["terminal"] == CALLER_TERMINAL => Ok(json!({
            "id": CALLER_TERMINAL, "tab_id": CALLER_TAB})),
        "tab.get" if params["tab"] == CALLER_TAB => Ok(json!({"id": CALLER_TAB, "pane_id": PANE,
            "content_kind": "terminal", "content_id": CALLER_TERMINAL})),
        "pane.get" => Ok(json!({"id": params["pane"], "screen_id": SCREEN})),
        "screen.get" => Ok(json!({"id": params["screen"], "workspace_id": WORKSPACE})),
        "tab.rename" => Ok(json!({"value": {"id": params["tab"]}, "generation": "g",
            "revision": "3", "replayed": false})),
        other => Err(format!("unexpected {other} {params}")),
    }
}

/// The workspace the fake app's window selects after `calls`: it starts on
/// a background one and moves to the tab's workspace on any call that
/// focuses, selects or shows something.
fn selected_workspace(calls: &[Value]) -> &'static str {
    let moves = |call: &Value| {
        let action = call["params"]["action"].as_str().unwrap_or_default();
        ["focus", "select", "show", "reveal"].iter().any(|verb| action.contains(verb))
    };
    if calls.iter().any(moves) { WORKSPACE } else { "ws_00000000000000000000000000000000" }
}

/// The fake app's answer to one `action.run`.
fn app_response(mode: AppMode, request: &Value) -> Value {
    let params = &request["params"];
    if request["method"] == "system.identify" {
        // An older app answers `beside` for a terminal as for a chat (a new
        // column right of it) and names no `caller_placement`.
        let mut identity = json!({"caller": {"is_caller": true,
            "terminal_id": params["caller"]["terminal_id"], "workspace": WORKSPACE,
            "screen": SCREEN, "pane": PANE, "tab": CALLER_TAB},
            "beside": {"pane": null, "placement": "new_column"}});
        if matches!(mode, AppMode::PlacesTerminals) {
            identity["caller_placement"] = json!(2);
            if params["caller"]["terminal_id"].is_string() {
                identity["beside"] = json!({"pane": PANE, "placement": "own_pane"});
            }
        }
        if matches!(mode, AppMode::RightColumn | AppMode::PlacesCallersRightColumn) {
            identity["beside"] = json!({"pane": RIGHT_PANE, "placement": "existing_column",
                "panes": [{"id": RIGHT_PANE, "kinds": ["terminal"]}]});
        }
        if matches!(mode, AppMode::PlacesCallersRightColumn | AppMode::NewColumn { .. }) {
            identity["caller_placement"] = json!(2);
        }
        if let AppMode::NewColumn { docked: Some(docked) } = mode {
            identity["caller"]["docked"] = json!(docked);
        }
        if matches!(mode, AppMode::UnplacedAgent) {
            identity = json!({"caller": {"is_caller": true,
                "agent_session": params["caller"]["agent_session"], "found": false}});
        }
        return json!({"id": request["id"], "ok": true, "result": identity});
    }
    if matches!(mode, AppMode::UnplacedAgent) && params.get("target").is_none() {
        return json!({"id": request["id"], "ok": false, "error": {"code": "caller_unavailable",
            "message": "The caller's chat or terminal is no longer available",
            "data": {"not_run": true, "state": "rejected"}}});
    }
    let refused = match mode {
        AppMode::Workspace | AppMode::PlacesTerminals | AppMode::RightColumn => false,
        AppMode::PlacesCallersRightColumn | AppMode::NewColumn { .. } => false,
        AppMode::UnplacedAgent => false,
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
