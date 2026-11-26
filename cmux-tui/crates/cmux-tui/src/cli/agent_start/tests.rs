use std::cell::{Cell, RefCell};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::command::RequestPlan;
use super::super::wire::request_value;
use super::daemon::{self, CallFailure, Daemon};
use super::launch::{self, Launch};
use super::readiness::{self, Gate, Look, Readiness, Reads, WaitOptions};
use super::{Clock, Command, Env, Options, ResumeTarget, parse, resume, resume_launch, start};

const OLD: &str = "term_0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d0d";
const NEW: &str = "term_a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const CALLER: &str = "term_ca11e2ca11e2ca11e2ca11e2ca11e2ca";
const SESSION: &str = "5b0e7c1e-0d6c-4f39-9a51-2f2b1c3d4e5f";

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

const TRUST: &str = "\
 Accessing workspace:

 /Users/me/new-project

 Quick safety check: Is this a project you created or one you trust? (Like your own code, a
 well-known open source project, or work from your team). If not, take a moment to review
 what's in this folder first.

 ❯ 1. Yes, I trust this folder
   2. No, exit

 Enter to confirm · Esc to cancel";

const COMPOSER: &str = "\
 ✻ Welcome to Claude Code!

────────────────────────────────────────────────────────────────────────────────
> \u{a0}
────────────────────────────────────────────────────────────────────────────────
  ? for shortcuts";

#[test]
fn w3h_the_folder_trust_dialog_is_blocked_with_a_reason_never_ready() {
    let trust = Look { screen: TRUST, exited: false, hook_state: None };
    let Readiness::Blocked(dialog) = readiness::assess(&trust) else {
        panic!("trust dialog: {:?}", readiness::assess(&trust));
    };
    assert_eq!(dialog.id, "folder_trust");
    assert!(dialog.reason.contains("trust this folder"), "{}", dialog.reason);
    // A hook that already says idle does not hide the dialog.
    let hooked = Look { hook_state: Some("idle"), ..trust };
    assert_eq!(readiness::assess(&hooked), Readiness::Blocked(dialog));
    // The older wording and Codex's are the same dialog.
    for screen in [
        "Do you trust the files in this folder?\n 1. Yes, proceed\n 2. No, exit",
        "> You are in /w\n  Do you trust the contents of this directory? Working with untrusted",
        "  1. Yes, allow Codex to work in this folder without asking for approval",
    ] {
        assert_eq!(readiness::startup_dialog(screen).map(|dialog| dialog.id), Some("folder_trust"));
    }
    let bypass =
        "WARNING: Claude Code running in Bypass Permissions mode\n 1. No, exit\n 2. Yes, I accept";
    assert_eq!(
        readiness::startup_dialog(bypass).map(|dialog| dialog.id),
        Some("bypass_permissions_warning")
    );
    assert_eq!(
        readiness::startup_dialog("Select login method:\n ❯ 1. Claude account with subscription")
            .map(|dialog| dialog.id),
        Some("login")
    );
    assert_eq!(readiness::startup_dialog(COMPOSER), None);
}

/// W3-H review: dialog phrases count only at the bottom of the screen, where
/// a dialog takes the input box's place. An agent that runs and printed
/// "update now" or "press enter to continue" is not blocked.
#[test]
fn w3h_dialog_words_in_agent_output_do_not_block_a_running_agent() {
    let above_the_input_box = format!(
        " ⏺ The tool says: Update now? Press Enter to continue. Yes, I accept.\n{COMPOSER}"
    );
    assert_eq!(readiness::startup_dialog(&above_the_input_box), None);
    let look = Look { screen: &above_the_input_box, exited: false, hook_state: None };
    assert_eq!(readiness::assess(&look), Readiness::Ready);
    // Far above the bottom rows, while the agent works (no input box drawn).
    let mut scrolled = String::from(" ⏺ Run `brew upgrade` or choose Update now in the app.\n");
    for line in 0..30 {
        scrolled.push_str(&format!(" output line {line}\n"));
    }
    scrolled.push_str(" ✻ Working… (esc to interrupt)\n");
    assert_eq!(readiness::startup_dialog(&scrolled), None);
    // The same words as the dialog at the bottom are a dialog.
    let update =
        format!("{scrolled}\n Update available\n ❯ 1. Update now\n   2. Skip until next version");
    assert_eq!(readiness::startup_dialog(&update).map(|dialog| dialog.id), Some("update_prompt"));
}

#[test]
fn w3h_readiness_reads_the_input_box_the_hooks_and_the_exit() {
    let look = |screen, hook_state, exited| Look { screen, exited, hook_state };
    assert_eq!(readiness::assess(&look(COMPOSER, None, false)), Readiness::Ready);
    assert_eq!(readiness::assess(&look("", Some("idle"), false)), Readiness::Ready);
    assert_eq!(readiness::assess(&look(COMPOSER, Some("working"), false)), Readiness::Starting);
    assert_eq!(
        readiness::assess(&look("", Some("blocked"), false)),
        Readiness::Blocked(readiness::AGENT_QUESTION)
    );
    assert_eq!(readiness::assess(&look("Loading…", None, false)), Readiness::Starting);
    assert_eq!(readiness::assess(&look(TRUST, None, true)), Readiness::Exited);
    // A shell prompt without the input box's rules is not an agent.
    assert_eq!(readiness::assess(&look("❯ ls\nfile\n❯ ", None, false)), Readiness::Starting);
    // Codex's footer.
    let codex = "› Ask Codex to do anything\n\n  100% context left · ? for shortcuts";
    assert_eq!(readiness::assess(&look(codex, None, false)), Readiness::Ready);
    // Records older than the start do not count.
    let records = json!([
        {"state": "idle", "updated_at_ms": "100"},
        {"state": "working", "updated_at_ms": "300"},
    ]);
    assert_eq!(readiness::fresh_hook_state(&records, 200), Some("working"));
    assert_eq!(readiness::fresh_hook_state(&records, 400), None);
}

#[test]
fn w3h_ready_and_blocked_hold_only_once_the_screen_stood_still() {
    let start = Instant::now();
    let at = |ms| start + Duration::from_millis(ms);
    let mut gate = Gate::new(Duration::from_secs(1), start);
    assert_eq!(gate.observe("a", Readiness::Ready, at(0)), None);
    assert_eq!(gate.observe("b", Readiness::Ready, at(900)), None, "the screen changed");
    assert_eq!(gate.observe("b", Readiness::Ready, at(1_500)), None);
    assert_eq!(gate.observe("b", Readiness::Ready, at(1_900)), Some(Readiness::Ready));
    assert_eq!(gate.observe("b", Readiness::Exited, at(1_901)), Some(Readiness::Exited));
    assert_eq!(gate.observe("c", Readiness::Starting, at(9_000)), None);
}

#[test]
fn w3h_launch_argv_keeps_each_argument_out_of_the_shell_and_resumes_per_harness() {
    let launch = Launch {
        shell: "/bin/zsh".into(),
        launcher: "sr2 claude".into(),
        args: strings(&["--model", "opus"]),
    };
    let argv = launch.argv();
    assert_eq!(
        argv,
        strings(&["/bin/zsh", "-lc", "sr2 claude \"$@\"", "cmux-agent", "--model", "opus"])
    );
    assert_eq!(Launch::from_argv(&argv), Some(launch));
    assert_eq!(Launch::from_argv(&strings(&["/bin/zsh"])), None);
    assert_eq!(Launch::from_argv(&strings(&["/bin/zsh", "-lc", "claude"])), None);

    assert_eq!(launch::harness_of("sr2 claude").as_deref(), Some("claude"));
    assert_eq!(launch::harness_of("/opt/bin/claude-code --x").as_deref(), Some("claude"));
    assert_eq!(launch::harness_of("codex --model o3").as_deref(), Some("codex"));
    assert_eq!(launch::harness_of("my-agent"), None);
    assert_eq!(launch::launcher_from(Some(" sr2 codex "), Some("claude")), "sr2 codex");
    assert_eq!(launch::launcher_from(None, Some("sr2 claude")), "sr2 claude");
    assert_eq!(launch::launcher_from(None, None), "claude");
    assert_eq!(launch::shell_from(Some("/bin/zsh")), "/bin/zsh");
    assert_eq!(launch::shell_from(Some("/usr/local/bin/fish")), "/bin/sh");
    assert_eq!(launch::shell_from(Some("zsh")), "/bin/sh");

    assert_eq!(launch::resume_args("claude", "s1"), Some(strings(&["--resume", "s1"])));
    assert_eq!(launch::resume_args("claude-code", "s1"), Some(strings(&["--resume", "s1"])));
    assert_eq!(launch::resume_args("codex", "s1"), Some(strings(&["resume", "s1"])));
    assert_eq!(launch::resume_args("opencode", "s1"), Some(strings(&["--session", "s1"])));
    assert_eq!(launch::resume_args("amp", "t1"), Some(strings(&["threads", "continue", "t1"])));
    assert_eq!(launch::resume_args("muse", "s1"), None);
    assert!(launch::valid_session_id(SESSION));
    assert!(!launch::valid_session_id("--dangerously-skip-permissions"));
    assert!(!launch::valid_session_id("a b"));
}

#[test]
fn w3h_agent_start_and_resume_parse_names_launchers_and_placement() {
    let words = strings(&[
        "agent",
        "start",
        "alpha",
        "--cmd",
        "sr2 claude",
        "--split=down",
        "--no-focus",
        "--timeout",
        "2m",
        "--",
        "--model",
        "opus",
    ]);
    let Some(Ok(Command::Start { name, options })) = parse(&words) else {
        panic!("{:?}", parse(&words));
    };
    assert_eq!(name, "alpha");
    assert_eq!(options.cmd.as_deref(), Some("sr2 claude"));
    assert_eq!(options.split.as_deref(), Some("down"));
    assert!(!options.focus);
    assert_eq!(options.timeout, Duration::from_secs(120));
    assert_eq!(options.args, strings(&["--model", "opus"]));
    assert_eq!(options.placement(), super::Placement::Split("down".into()));

    let defaults = Options::default();
    assert!(defaults.focus && defaults.wait);
    assert_eq!(defaults.placement(), super::Placement::Split("right".into()));
    let in_pane = Options {
        pane: Some("pane_11111111111111111111111111111111".into()),
        ..Options::default()
    };
    assert_eq!(in_pane.placement(), super::Placement::Tab);

    let resume =
        parse(&strings(&["terminal", OLD, "resume", "--pane", "beta", "--harness", "claude-code"]));
    let Some(Ok(Command::Resume { target, options })) = resume else { panic!("{resume:?}") };
    assert_eq!(target, ResumeTarget::Terminal(OLD.into()));
    assert_eq!(options.harness.as_deref(), Some("claude"));
    assert!(matches!(
        parse(&strings(&["agent", "resume", "alpha"])),
        Some(Ok(Command::Resume { target: ResumeTarget::Agent(_), .. }))
    ));
    let bad: [&[&str]; 6] = [
        &["agent", "start"],
        &["agent", "start", "Alpha"],
        &["agent", "start", "list"],
        &["agent", "start", "a", "--split", "diagonal"],
        &["agent", "start", "a", "--cmd", " "],
        &["agent", "start", "a", "--bogus"],
    ];
    for bad in bad {
        assert!(matches!(parse(&strings(bad)), Some(Err(_))), "{bad:?}");
    }
    assert!(parse(&strings(&["agent", "list"])).is_none());
    assert!(parse(&strings(&["terminal", OLD, "send", "--text", "x"])).is_none());
}

/// `terminal <t> wait --until ready [--timeout D]`: main has no other
/// `terminal wait` condition, so any other `--until` is a usage error.
#[test]
fn w3h_terminal_wait_parses_until_ready_and_a_timeout() {
    let wait = parse(&strings(&["terminal", "alpha", "wait", "--until", "ready", "--timeout=30s"]));
    let Some(Ok(Command::WaitReady { selector, timeout })) = wait else { panic!("{wait:?}") };
    assert_eq!(selector, "alpha");
    assert_eq!(timeout, Some(Duration::from_secs(30)));
    assert!(matches!(
        parse(&strings(&["terminal", "alpha", "wait", "--until", "ready"])),
        Some(Ok(Command::WaitReady { timeout: None, .. }))
    ));
    for bad in [
        &["terminal", "alpha", "wait"][..],
        &["terminal", "alpha", "wait", "--until", "idle"][..],
        &["terminal", "alpha", "wait", "--until", "ready", "--timeout", "soon"][..],
        &["terminal", "alpha", "wait", "--until", "ready", "--pattern", "x"][..],
    ] {
        assert!(matches!(parse(&strings(bad)), Some(Err(_))), "{bad:?}");
    }
    assert!(parse(&strings(&["terminal", "alpha", "screen", "wait"])).is_none());
}

/// A daemon that answers by operation and records every request.
struct Fake<F: Fn(&str, &Value, usize) -> Value> {
    answer: F,
    sent: RefCell<Vec<(String, Value)>>,
}

impl<F: Fn(&str, &Value, usize) -> Value> Fake<F> {
    fn new(answer: F) -> Self {
        Self { answer, sent: RefCell::new(Vec::new()) }
    }

    fn sent(&self, operation: &str) -> Vec<Value> {
        let sent = self.sent.borrow();
        sent.iter()
            .filter(|(name, _)| name == operation)
            .map(|(_, params)| params.clone())
            .collect()
    }
}

impl<F: Fn(&str, &Value, usize) -> Value> Daemon for Fake<F> {
    fn request(&self, _session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        let request = request_value(&plan).expect("a valid request");
        let operation = request["operation"].as_str().unwrap_or_default().to_owned();
        let count = self.sent(&operation).len();
        self.sent.borrow_mut().push((operation.clone(), request["params"].clone()));
        Ok((self.answer)(&operation, &request["params"], count))
    }
}

/// The exited agent `alpha` (claude, session [`SESSION`]) in pane_22222222222222222222222222222222, and
/// the caller's shell in pane_11111111111111111111111111111111.
fn snapshot() -> Value {
    let old_argv = Launch {
        shell: "/bin/zsh".into(),
        launcher: "sr2 claude".into(),
        args: strings(&["--resume", "older"]),
    }
    .argv();
    json!({
        "workspaces": [{"id": "ws_f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1", "focused": true}],
        "screens": [{"id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1", "workspace_id": "ws_f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1", "focused": true}],
        "panes": [{"id": "pane_11111111111111111111111111111111", "screen_id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1", "focused": true},
                  {"id": "pane_22222222222222222222222222222222", "screen_id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1", "focused": false}],
        "tabs": [{"id": "tab_c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0", "name": null, "content_id": CALLER, "pane_id": "pane_11111111111111111111111111111111"},
                 {"id": "tab_a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0", "name": "alpha", "content_id": OLD, "pane_id": "pane_22222222222222222222222222222222"}],
        "terminals": [
            {"id": CALLER, "lifecycle": "running", "tab_id": "tab_c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0c0", "cwd": "/home"},
            {"id": OLD, "lifecycle": "exited", "tab_id": "tab_a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0", "cwd": "/w/proj",
             "argv_for_test": old_argv},
        ],
        "agents": [],
    })
}

fn created(pane: &str, tab: &str, terminal: &str) -> Value {
    json!({"kind": "terminal", "workspace_id": "ws_f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1", "screen_id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
           "pane_id": pane, "tab_id": tab, "terminal_id": terminal})
}

fn env() -> Env {
    Env {
        caller_terminal: Some(CALLER.into()),
        cwd: Some("/home".into()),
        shell: "/bin/zsh".into(),
        default_launcher: None,
    }
}

/// A fake clock: `sleep` moves `now` on.
fn run_with_clock<T>(body: impl FnOnce(&mut Clock<'_>) -> T) -> T {
    let start = Instant::now();
    let elapsed = Cell::new(Duration::ZERO);
    let now = || start + elapsed.get();
    let mut sleep = |step: Duration| elapsed.set(elapsed.get() + step);
    let mut clock = Clock { now: &now, sleep: &mut sleep, now_ms: 1_000 };
    body(&mut clock)
}

#[test]
fn w3h_resume_reruns_the_recorded_launcher_with_the_harness_session_and_takes_the_name() {
    let snapshot = snapshot();
    let daemon = Fake::new(|operation, params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "agent.list" if params["terminal_id"] == OLD || params["terminal"] == OLD => json!([
            {"terminal_id": OLD, "state": "done", "updated_at_ms": "900",
             "extra": {"agent": "claude", "agent_session_id": SESSION}},
        ]),
        "agent.list" => json!([{"terminal_id": NEW, "state": "idle", "updated_at_ms": "1500"}]),
        "terminal.process.get" => json!({"argv": snapshot["terminals"][1]["argv_for_test"]}),
        "pane.run" => created(
            "pane_22222222222222222222222222222222",
            "tab_e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0",
            NEW,
        ),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        _ => json!({}),
    });
    let options = Options::default();
    let target = ResumeTarget::Agent("alpha".into());
    let (report, exit) =
        run_with_clock(|clock| resume(&daemon, &env(), clock, &target, &options)).expect("resume");
    assert_eq!(exit, 0, "{report}");
    assert_eq!(report["state"], "ready");
    assert_eq!(report["name"], "alpha");
    assert_eq!(report["terminal_id"], NEW);
    assert_eq!(report["placement"], "tab");
    assert_eq!(report["resumed"]["terminal_id"], OLD);
    assert_eq!(report["resumed"]["agent_session_id"], SESSION);
    assert_eq!(report["resumed"]["tab_closed"], true);
    let runs = daemon.sent("pane.run");
    assert_eq!(runs.len(), 1);
    let run = &runs[0];
    assert_eq!(run["pane"], "pane_22222222222222222222222222222222", "the old tab's pane: {run}");
    assert_eq!(run["name"], "alpha");
    assert_eq!(run["on_exit"], "keep");
    assert_eq!(run["cwd"], "/w/proj");
    assert_eq!(
        run["argv"],
        json!(["/bin/zsh", "-lc", "sr2 claude \"$@\"", "cmux-agent", "--resume", SESSION]),
        "the old --resume is replaced, the id is its own argv word"
    );
    assert!(daemon.sent("pane.split").is_empty());
    let closed = daemon.sent("tab.close");
    assert_eq!(closed.len(), 1);
    assert_eq!(closed[0]["tab"], "tab_a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0");
}

/// An agent that quit (its hooks reported the session's end) has no agent
/// record left; resume reads the session id the daemon kept on the terminal.
#[test]
fn w3h_resume_reads_the_session_id_kept_on_the_terminal_after_the_session_ended() {
    let mut snapshot = snapshot();
    if let Some(old) = snapshot.pointer_mut("/terminals/1") {
        old["extra"] = json!({"agent": "claude-code", "agent_session_id": SESSION});
    }
    let daemon = Fake::new(|operation, _params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "agent.list" => json!([]),
        "terminal.process.get" => json!({"argv": snapshot["terminals"][1]["argv_for_test"]}),
        "pane.run" => created(
            "pane_22222222222222222222222222222222",
            "tab_e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0",
            NEW,
        ),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        _ => json!({}),
    });
    let target = ResumeTarget::Agent("alpha".into());
    let (report, exit) =
        run_with_clock(|clock| resume(&daemon, &env(), clock, &target, &Options::default()))
            .expect("resume");
    assert_eq!(exit, 0, "{report}");
    assert_eq!(report["resumed"]["agent_session_id"], SESSION);
    assert_eq!(report["harness"], "claude");
    let runs = daemon.sent("pane.run");
    assert_eq!(runs.len(), 1);
    assert_eq!(
        runs[0]["argv"],
        json!(["/bin/zsh", "-lc", "sr2 claude \"$@\"", "cmux-agent", "--resume", SESSION])
    );
}

#[test]
fn w3h_start_splits_the_callers_pane_runs_a_named_tab_and_reports_the_trust_dialog() {
    let snapshot = snapshot();
    let daemon = Fake::new(|operation, _params, count| match operation {
        "session.snapshot" => snapshot.clone(),
        "pane.split" => created(
            "pane_33333333333333333333333333333333",
            "tab_50505050505050505050505050505050",
            "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e",
        ),
        "pane.run" => created(
            "pane_33333333333333333333333333333333",
            "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0",
            NEW,
        ),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" if count == 0 => json!({"text": "Loading"}),
        "terminal.screen.read" => json!({"text": TRUST}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options { cmd: Some("sr2 claude".into()), ..Options::default() };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "beta", &options)).expect("start");
    assert_eq!(exit, super::BLOCKED_EXIT, "{report}");
    assert_eq!(report["state"], "blocked");
    assert_eq!(report["dialog"], "folder_trust");
    assert!(report["reason"].as_str().is_some_and(|reason| reason.contains("trust")));
    assert_eq!(report["harness"], "claude");
    assert_eq!(report["launcher"], "sr2 claude");
    assert_eq!(report["tab_id"], "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0");
    let split = &daemon.sent("pane.split")[0];
    assert_eq!(
        split["pane"], "pane_11111111111111111111111111111111",
        "the caller's pane: {split}"
    );
    assert_eq!(split["direction"], "right");
    let run = &daemon.sent("pane.run")[0];
    assert_eq!(run["pane"], "pane_33333333333333333333333333333333");
    assert_eq!(run["name"], "beta");
    assert_eq!(run["argv"], json!(["/bin/zsh", "-lc", "sr2 claude \"$@\"", "cmux-agent"]));
    // The split's placeholder shell ends with its terminal (no tabless
    // shell stays); the agent's tab is focused.
    assert_eq!(
        daemon.sent("terminal.close")[0]["terminal"],
        "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e"
    );
    assert!(daemon.sent("tab.close").is_empty(), "{:?}", daemon.sent("tab.close"));
    assert_eq!(daemon.sent("tab.focus")[0]["tab"], "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0");
    // Nothing answered the dialog.
    assert!(daemon.sent("terminal.input.write").is_empty());
    assert!(daemon.sent("terminal.input.keys").is_empty());
}

/// Real-build check: a daemon that no client opened has no pane, and
/// `agent start` failed with "the session has no pane". It now makes a
/// workspace named after the agent and replaces its shell tab.
#[test]
fn w3h_start_in_a_session_with_no_pane_opens_a_workspace_for_the_agent() {
    let empty = json!({"workspaces": [], "screens": [], "panes": [], "tabs": [],
                       "terminals": [], "agents": []});
    let opened = json!({
        "workspaces": [{"id": "ws_f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1", "focused": true}],
        "screens": [{"id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
                     "workspace_id": "ws_f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1", "focused": true}],
        "panes": [{"id": "pane_44444444444444444444444444444444",
                   "screen_id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1", "focused": true}],
        "tabs": [{"id": "tab_5e115e115e115e115e115e115e115e11", "name": null,
                  "content_id": CALLER, "pane_id": "pane_44444444444444444444444444444444"}],
        "terminals": [{"id": CALLER, "lifecycle": "running",
                       "tab_id": "tab_5e115e115e115e115e115e115e115e11"}],
        "agents": [],
    });
    let daemon = Fake::new(|operation, _params, count| match operation {
        "session.snapshot" if count == 0 => empty.clone(),
        "session.snapshot" => opened.clone(),
        "workspace.create" => {
            json!({"revision": "1", "value": {"kind": "workspace", "workspace_id": "ws_f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1"}})
        }
        "pane.run" => created(
            "pane_44444444444444444444444444444444",
            "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0",
            NEW,
        ),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let env = Env { caller_terminal: None, ..env() };
    let options = Options { cmd: Some("sr2 claude".into()), focus: false, ..Options::default() };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env, clock, "alpha", &options)).expect("start");
    assert_eq!(exit, 0, "{report}");
    assert_eq!(report["state"], "ready");
    let workspace = &daemon.sent("workspace.create")[0];
    assert_eq!(workspace["name"], "alpha");
    assert!(daemon.sent("pane.split").is_empty());
    assert_eq!(daemon.sent("pane.run")[0]["pane"], "pane_44444444444444444444444444444444");
    assert_eq!(daemon.sent("terminal.close")[0]["terminal"], CALLER);
    assert!(daemon.sent("tab.close").is_empty(), "{:?}", daemon.sent("tab.close"));
}

/// Review (lead's reviewer, #38436): two `agent start` runs at once on a
/// daemon with no client. The snapshot read after `workspace create` already
/// holds alpha's workspace too, focused. beta's pane and the shell to end
/// come from the create receipt (its ids, else the pane of its workspace),
/// never from focus, so beta never ends alpha's terminal.
#[test]
fn w3h_start_in_an_empty_session_uses_the_workspace_it_created_not_the_focused_one() {
    const WS_A: &str = "ws_a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0";
    const WS_B: &str = "ws_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0";
    const PANE_A: &str = "pane_a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
    const PANE_B: &str = "pane_b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";
    const TAB_A: &str = "tab_a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2";
    const SHELL_B: &str = "tab_b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
    const TERM_A: &str = "term_a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3a3";
    const TERM_B: &str = "term_b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3b3";
    let empty = json!({"workspaces": [], "screens": [], "panes": [], "tabs": [],
                       "terminals": [], "agents": []});
    let both = json!({
        "workspaces": [{"id": WS_A, "focused": true}, {"id": WS_B, "focused": false}],
        "screens": [{"id": "screen_a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4", "workspace_id": WS_A, "focused": true},
                    {"id": "screen_b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4", "workspace_id": WS_B, "focused": true}],
        "panes": [{"id": PANE_A, "screen_id": "screen_a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4a4", "focused": true},
                  {"id": PANE_B, "screen_id": "screen_b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4", "focused": true}],
        "tabs": [{"id": TAB_A, "name": "alpha", "content_id": TERM_A, "pane_id": PANE_A},
                 {"id": SHELL_B, "name": null, "content_id": TERM_B, "pane_id": PANE_B}],
        "terminals": [{"id": TERM_A, "lifecycle": "running", "tab_id": TAB_A},
                      {"id": TERM_B, "lifecycle": "running", "tab_id": SHELL_B}],
        "agents": [],
    });
    let receipts = [
        json!({"generation": "g", "replayed": false, "revision": "3",
               "value": {"kind": "workspace", "workspace_id": WS_B,
                         "screen_id": "screen_b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4b4",
                         "pane_id": PANE_B, "tab_id": SHELL_B, "terminal_id": TERM_B}}),
        json!({"generation": "g", "replayed": false, "revision": "3",
               "value": {"kind": "workspace", "workspace_id": WS_B}}),
    ];
    for receipt in receipts {
        let daemon = Fake::new(|operation, _params, count| match operation {
            "session.snapshot" if count == 0 => empty.clone(),
            "session.snapshot" => both.clone(),
            "workspace.create" => receipt.clone(),
            "pane.run" => created(PANE_B, "tab_e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0", NEW),
            "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
            "terminal.screen.read" => json!({"text": COMPOSER}),
            "agent.list" => json!([]),
            _ => json!({}),
        });
        let env = Env { caller_terminal: None, ..env() };
        let options = Options { cmd: Some("claude".into()), focus: false, ..Options::default() };
        let (report, exit) =
            run_with_clock(|clock| start(&daemon, &env, clock, "beta", &options)).expect("start");
        assert_eq!(exit, 0, "{report}");
        assert_eq!(daemon.sent("pane.run")[0]["pane"], PANE_B, "receipt {receipt}");
        let ended: Vec<Value> =
            daemon.sent("terminal.close").iter().map(|c| c["terminal"].clone()).collect();
        assert_eq!(ended, [json!(TERM_B)], "only beta's shell ends; receipt {receipt}");
        assert!(daemon.sent("tab.close").is_empty(), "receipt {receipt}");
    }
}

/// Real-build check: the daemon answers `pane.split` and `pane.run` with a
/// mutation receipt whose created path is under `value`, and `agent start`
/// failed with "the session did not report the new terminal".
#[test]
fn w3h_the_created_path_is_read_from_the_mutation_receipt() {
    let receipt = json!({
        "generation": "g", "replayed": false, "revision": "3",
        "value": created(
            "pane_33333333333333333333333333333333",
            "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0",
            NEW,
        ),
    });
    let found = super::placement::Created::from_result(&receipt).expect("the receipt's path");
    assert_eq!(found.pane, "pane_33333333333333333333333333333333");
    assert_eq!(found.tab, "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0");
    assert_eq!(found.terminal, NEW);
    assert_eq!(found.workspace.as_deref(), Some("ws_f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1f1"));
}

#[test]
fn w3h_a_name_that_a_running_tab_has_is_refused() {
    let mut snapshot = snapshot();
    snapshot["terminals"][1]["lifecycle"] = json!("running");
    let daemon = Fake::new(|operation, _params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        _ => json!({}),
    });
    let failure =
        run_with_clock(|clock| start(&daemon, &env(), clock, "alpha", &Options::default()))
            .expect_err("taken");
    assert_eq!(failure.error["code"], "agent.name_taken");
    assert!(daemon.sent("pane.run").is_empty());
    // Resume refuses an agent that still runs.
    let failure = run_with_clock(|clock| {
        resume(&daemon, &env(), clock, &ResumeTarget::Agent("alpha".into()), &Options::default())
    })
    .expect_err("running");
    assert_eq!(failure.error["code"], "agent.running");
}

#[test]
fn w3h_the_wait_times_out_while_the_agent_still_starts() {
    let daemon = Fake::new(|operation, _params, _count| match operation {
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": "Loading"}),
        _ => json!([]),
    });
    let reads = Reads {
        show: super::plan(&["terminal", NEW, "show"]).unwrap(),
        agents: super::plan(&["agent", "list", "--terminal", NEW]).unwrap(),
        screen: super::plan(&["terminal", NEW, "screen", "read"]).unwrap(),
    };
    let options = WaitOptions::new(Duration::from_secs(5), 0);
    let outcome =
        run_with_clock(|clock| readiness::wait(&daemon, &reads, options, clock.now, clock.sleep))
            .expect("wait");
    assert_eq!(outcome.readiness, None);
    assert_eq!(outcome.last, Readiness::Starting);
    assert_eq!(outcome.waited, Duration::from_secs(5));
    let mut report = json!({});
    assert_eq!(super::apply_outcome(&mut report, &outcome, "alpha"), 124);
    assert_eq!(report["state"], "timeout");
    assert_eq!(report["waited_ms"], "5000");
}

/// W3-H review: a resume runs the recorded launcher, not the recorded extra
/// arguments: `agent start alpha -- 'Fix the test'` must not send the first
/// prompt again (and `codex '<prompt>' resume <id>` would not resume).
#[test]
fn w3h_resume_does_not_send_the_first_prompt_again() {
    let recorded = Launch {
        shell: "/bin/zsh".into(),
        launcher: "codex --model o3".into(),
        args: strings(&["Fix the failing test", "resume", "older"]),
    };
    let launch = resume_launch(Some(recorded), &env(), &Options::default(), "codex", SESSION)
        .expect("resume launch");
    assert_eq!(launch.launcher, "codex --model o3");
    assert_eq!(launch.args, strings(&["resume", SESSION]));
    let options = Options { args: strings(&["--yolo"]), ..Options::default() };
    let recorded =
        Launch { shell: "/bin/zsh".into(), launcher: "claude".into(), args: strings(&["hello"]) };
    let launch = resume_launch(Some(recorded), &env(), &options, "claude", SESSION).unwrap();
    assert_eq!(launch.args, strings(&["--yolo", "--resume", SESSION]));
}

/// W3-H review: `current` and `focused` are the daemon's to resolve (on main
/// `current` is the focused object, not the caller); other selectors pass.
#[test]
fn w3h_current_and_focused_terminals_come_from_the_daemon() {
    let daemon = Fake::new(|operation, params, _count| match operation {
        "terminal.get" => json!({"id": NEW, "asked": params}),
        _ => json!({}),
    });
    assert_eq!(daemon::terminal_keyword(&daemon, "current").unwrap(), NEW);
    assert_eq!(daemon::terminal_keyword(&daemon, "alpha").unwrap(), "alpha");
    assert_eq!(daemon.sent("terminal.get").len(), 1);
}
