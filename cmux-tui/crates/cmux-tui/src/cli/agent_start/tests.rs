use std::cell::{Cell, RefCell};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::command::RequestPlan;
use super::super::mcp::{CallFailure, FailureKind};
use super::super::terminal_talk::send::Daemon;
use super::super::wire::request_value;
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

/// W3-H review (main #39226): a resume runs the recorded launcher, not the
/// recorded extra arguments: `agent start alpha -- 'Fix the test'` must not
/// send the first prompt again (and `codex '<prompt>' resume <id>` would not
/// resume).
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

/// An agent that quit (its hooks reported the session's end) has no agent
/// record left; resume reads the session id the daemon kept on the terminal.
#[test]
fn w3h_resume_reads_the_session_id_kept_on_the_terminal_after_the_session_ended() {
    let mut snapshot = snapshot();
    if let Some(old) = snapshot.pointer_mut("/terminals/1") {
        old["extra"] = json!({"agent": "claude-code", "agent_session_id": SESSION});
    }
    let daemon = Fake::new(|operation, params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "agent.list" if params["terminal_id"] == OLD || params["terminal"] == OLD => json!([]),
        // The resumed Claude Code reports its session start (W5-R: a resume
        // of a hooked harness is ready on that report, not on its input box).
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
    // The split's shell ends (its terminal closes, taking its tab; a tab
    // close alone left the shell running with no tab, W5-O); the agent's tab
    // is focused.
    assert_eq!(
        daemon.sent("terminal.close")[0]["terminal"],
        "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e"
    );
    assert!(daemon.sent("tab.close").is_empty());
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
    // The workspace's shell (its tab's terminal) ends with its tab.
    assert_eq!(daemon.sent("terminal.close")[0]["terminal"], CALLER);
    assert!(daemon.sent("tab.close").is_empty());
}

/// Review (lead's reviewer, #38436): two `agent start` runs at once on a
/// daemon with no client. The snapshot read after `workspace create` already
/// holds alpha's workspace too, focused. beta's pane and the shell tab to close
/// come from the create receipt (its ids, else the pane of its workspace),
/// never from focus, so beta never closes alpha's tab.
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

/// Claude's folder-trust dialog with the cursor on "No, exit".
const TRUST_NO_SELECTED: &str = "\
 Accessing workspace:

 /Users/me/new-project

 Quick safety check: Is this a project you created or one you trust?

   1. Yes, I trust this folder
 ❯ 2. No, exit

 Enter to confirm · Esc to cancel";

/// `agent start` that ends at `screen`, a folder-trust dialog.
fn start_at_trust(screen: &'static str) -> Value {
    let snapshot = snapshot();
    let daemon = Fake::new(move |operation, _params, count| match operation {
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
        "terminal.screen.read" => json!({"text": screen}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options { cmd: Some("sr2 claude".into()), ..Options::default() };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "beta", &options)).expect("start");
    assert_eq!(exit, super::BLOCKED_EXIT, "{report}");
    assert_eq!(report["dialog"], "folder_trust", "{report}");
    report
}

/// W5-Q (bench round 4 orchestration friction 7): the folder-trust result
/// lists the dialog's options, which one is selected, and the keys that
/// accept the folder from there; the reason says to ask the person first.
#[test]
fn w5q_folder_trust_result_lists_the_options_and_the_keys_that_accept_it() {
    let report = start_at_trust(TRUST_NO_SELECTED);
    assert_eq!(
        report["options"],
        json!([
            {"number": 1, "label": "Yes, I trust this folder", "selected": false},
            {"number": 2, "label": "No, exit", "selected": true},
        ]),
        "{report}"
    );
    assert_eq!(report["accept_keys"], json!(["up", "enter"]), "{report}");
    assert_eq!(report["accept_label"], "Yes, I trust this folder", "{report}");
    let reason = report["reason"].as_str().unwrap_or_default();
    assert!(reason.contains("cmux terminal beta keys up enter"), "{reason}");
    assert!(reason.contains("Yes, I trust this folder"), "{reason}");

    // The cursor already on "Yes": Enter alone accepts.
    let report = start_at_trust(TRUST);
    assert_eq!(report["options"][0]["selected"], true, "{report}");
    assert_eq!(report["accept_keys"], json!(["enter"]), "{report}");
}

/// W5-Q review (PR C): a folder-trust dialog whose options cmux cannot read
/// still names the terminal to answer, never the placeholder `NAME`.
#[test]
fn w5q_folder_trust_without_options_names_the_terminal() {
    let report = start_at_trust(
        " Do you trust the files in this folder?\n\n /Users/me/new-project\n\n Enter to confirm",
    );
    assert_eq!(report["dialog"], "folder_trust", "{report}");
    let reason = report["reason"].as_str().unwrap_or_default();
    assert!(!reason.contains("NAME"), "{reason}");
    assert!(reason.contains("cmux terminal beta keys"), "{reason}");
}

/// W5-Q: a ready agent has no dialog options.
#[test]
fn w5q_a_ready_start_has_no_dialog_options() {
    let snapshot = snapshot();
    let daemon = Fake::new(move |operation, _params, _count| match operation {
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
        "terminal.screen.read" => json!({"text": COMPOSER}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options { cmd: Some("sr2 claude".into()), ..Options::default() };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "beta", &options)).expect("start");
    assert_eq!(exit, 0, "{report}");
    assert_eq!(report["options"], Value::Null, "{report}");
    assert_eq!(report["accept_keys"], Value::Null, "{report}");
}

const CALLER_PANE: &str = "pane_11111111111111111111111111111111";
const ALPHA_PANE: &str = "pane_22222222222222222222222222222222";
const BETA_PANE: &str = "pane_33333333333333333333333333333333";
const OUTER_SPLIT: &str = "split_000000000000000000000000000000a1";
const INNER_SPLIT: &str = "split_000000000000000000000000000000a2";

/// The screen after the second start split alpha's pane in half: caller
/// 1/2, alpha 1/4, beta 1/4.
fn halved_layout() -> Value {
    json!({
        "version": 1,
        "screen_id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
        "root": {
            "kind": "split", "split_id": OUTER_SPLIT, "direction": "horizontal", "ratio": 0.5,
            "first": {"kind": "leaf", "pane_id": CALLER_PANE, "tab_ids": []},
            "second": {
                "kind": "split", "split_id": INNER_SPLIT, "direction": "horizontal", "ratio": 0.5,
                "first": {"kind": "leaf", "pane_id": ALPHA_PANE, "tab_ids": []},
                "second": {"kind": "leaf", "pane_id": BETA_PANE, "tab_ids": []},
            },
        },
    })
}

/// The widths along the row after a start: `ratios` set on the splits of a
/// row `caller | (alpha | beta)` laid out by [`halved_layout`].
fn row_widths(ratios: &std::collections::BTreeMap<String, f64>) -> [f64; 3] {
    let outer = ratios.get(OUTER_SPLIT).copied().unwrap_or(0.5);
    let inner = ratios.get(INNER_SPLIT).copied().unwrap_or(0.5);
    [outer, (1.0 - outer) * inner, (1.0 - outer) * (1.0 - inner)]
}

/// The `pane.split_ratio.set` ratios a start sent, by split id.
fn sent_ratios<F: Fn(&str, &Value, usize) -> Value>(
    daemon: &Fake<F>,
) -> std::collections::BTreeMap<String, f64> {
    daemon
        .sent("pane.split_ratio.set")
        .iter()
        .map(|set| {
            let split = set["split_id"].as_str().unwrap_or_default().to_owned();
            (split, set["ratio"].as_f64().unwrap_or(f64::NAN))
        })
        .collect()
}

/// W5-Q review (PR C, the column rule): a new agent pane takes its width
/// only from the pane it splits. The person's 0.7 editor column keeps 0.7
/// when the orchestrator next to it starts an agent.
#[test]
fn w5q_start_split_keeps_the_persons_column_width() {
    // The editor tab has no agent name: the person made it.
    let snapshot = snapshot_with_tab_name(ALPHA_PANE, None);
    let daemon = Fake::new(move |operation, _params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "pane.split" => created(
            BETA_PANE,
            "tab_50505050505050505050505050505050",
            "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e",
        ),
        "pane.run" => created(BETA_PANE, "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0", NEW),
        // editor 0.7 | (orchestrator | beta), the orchestrator split in half.
        "screen.layout.export" => json!({"version": 1, "root": {
            "kind": "split", "split_id": OUTER_SPLIT, "direction": "horizontal", "ratio": 0.7,
            "first": {"kind": "leaf", "pane_id": ALPHA_PANE, "tab_ids": []},
            "second": {"kind": "split", "split_id": INNER_SPLIT, "direction": "horizontal",
                "ratio": 0.5,
                "first": {"kind": "leaf", "pane_id": CALLER_PANE, "tab_ids": []},
                "second": {"kind": "leaf", "pane_id": BETA_PANE, "tab_ids": []}}}}),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options { cmd: Some("sr2 claude".into()), ..Options::default() };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "beta", &options)).expect("start");
    assert_eq!(exit, 0, "{report}");
    let ratios = sent_ratios(&daemon);
    assert_eq!(ratios.get(OUTER_SPLIT), None, "the editor column changed: {ratios:?}");
}

/// [`snapshot`] with the tab in `pane` named `name`.
fn snapshot_with_tab_name(pane: &str, name: Option<&str>) -> Value {
    let mut snapshot = snapshot();
    if let Some(tabs) = snapshot["tabs"].as_array_mut() {
        for tab in tabs.iter_mut().filter(|tab| tab["pane_id"] == pane) {
            tab["name"] = json!(name);
        }
    }
    snapshot
}

/// Marks the terminals `ids` of `snapshot` as agent start launches
/// (`extra.agent_start`, from the daemon's stored spawn argv).
fn mark_agent_start(snapshot: &mut Value, ids: &[&str]) {
    if let Some(terminals) = snapshot["terminals"].as_array_mut() {
        for terminal in
            terminals.iter_mut().filter(|terminal| ids.iter().any(|id| terminal["id"] == *id))
        {
            terminal["extra"] = json!({"agent_start": true});
        }
    }
}

/// W5-Q review (PR C, the column rule): a pane a person made keeps its
/// width even when its tab has a valid agent name. Agent start splits the
/// caller's pane; the person's `alpha` pane right of it (named like an
/// agent, but its terminal runs a plain shell) keeps its half.
#[test]
fn w5q_start_split_keeps_a_person_pane_with_an_agent_name() {
    let snapshot = snapshot();
    let daemon = Fake::new(move |operation, _params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "pane.split" => created(
            BETA_PANE,
            "tab_50505050505050505050505050505050",
            "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e",
        ),
        "pane.run" => created(BETA_PANE, "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0", NEW),
        // (caller 0.25 | beta 0.25) | alpha 0.5: the split halved the caller.
        "screen.layout.export" => json!({"version": 1, "root": {
            "kind": "split", "split_id": OUTER_SPLIT, "direction": "horizontal", "ratio": 0.5,
            "first": {"kind": "split", "split_id": INNER_SPLIT, "direction": "horizontal",
                "ratio": 0.5,
                "first": {"kind": "leaf", "pane_id": CALLER_PANE, "tab_ids": []},
                "second": {"kind": "leaf", "pane_id": BETA_PANE, "tab_ids": []}},
            "second": {"kind": "leaf", "pane_id": ALPHA_PANE, "tab_ids": []}}}),
        // A process read would show a shell; the snapshot has no agent start
        // mark on the person's terminal, which is what counts.
        "terminal.process.get" => json!({"pid": 77, "argv": ["/bin/zsh", "-l"]}),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options { cmd: Some("sr2 claude".into()), ..Options::default() };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "beta", &options)).expect("start");
    assert_eq!(exit, 0, "{report}");
    let ratios = sent_ratios(&daemon);
    assert!(ratios.is_empty(), "a pane's width changed: {ratios:?}");
}

/// The widths of caller, alpha, beta and gamma after `agent start gamma
/// --pane beta --split right` in the row caller 1/2 | (alpha 1/4 | (beta
/// 1/8 | gamma 1/8)), alpha's terminal having the lifecycle word `alpha`
/// and, with `agent_state`, an agent record in that state.
/// [`three_agent_row_widths`]'s `alpha` for a terminal record with no
/// `lifecycle` field at all.
const NO_LIFECYCLE: &str = "<no lifecycle field>";

fn three_agent_row_widths(alpha: &str, agent_state: Option<&str>) -> [f64; 4] {
    const GAMMA_PANE: &str = "pane_44444444444444444444444444444444";
    const BETA_SPLIT: &str = "split_000000000000000000000000000000a3";
    // The beta pane is an agent pane an earlier start made.
    let mut snapshot = snapshot();
    if let Some(panes) = snapshot["panes"].as_array_mut() {
        panes.push(json!({"id": BETA_PANE, "screen_id": "screen_d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1d1",
            "focused": false}));
    }
    if let Some(tabs) = snapshot["tabs"].as_array_mut() {
        tabs.push(json!({"id": "tab_b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1", "name": "beta",
            "content_id": "term_b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1", "pane_id": BETA_PANE}));
    }
    if let Some(terminals) = snapshot["terminals"].as_array_mut() {
        terminals
            .push(json!({"id": "term_b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1", "lifecycle": "running",
            "tab_id": "tab_b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"}));
    }
    // alpha's and beta's terminals run agent start launches; alpha's
    // terminal is `alpha` (running or exited, kept with --on-exit keep).
    if let Some(terminals) = snapshot["terminals"].as_array_mut() {
        for terminal in terminals.iter_mut().filter(|terminal| terminal["id"] == OLD) {
            match alpha {
                NO_LIFECYCLE => {
                    if let Some(terminal) = terminal.as_object_mut() {
                        terminal.remove("lifecycle");
                    }
                }
                word => terminal["lifecycle"] = json!(word),
            }
        }
    }
    mark_agent_start(&mut snapshot, &[OLD, "term_b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"]);
    if let Some(state) = agent_state {
        snapshot["agents"] = json!([{"terminal_id": OLD, "state": state, "status": state,
            "updated_at_ms": "900", "extra": {"agent": "claude"}}]);
    }
    let daemon = Fake::new(move |operation, _params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "pane.split" => created(
            GAMMA_PANE,
            "tab_50505050505050505050505050505050",
            "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e",
        ),
        "pane.run" => created(GAMMA_PANE, "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0", NEW),
        // caller 1/2 | (alpha 1/4 | (beta 1/8 | gamma 1/8)).
        "screen.layout.export" => json!({"version": 1, "root": {
            "kind": "split", "split_id": OUTER_SPLIT, "direction": "horizontal", "ratio": 0.5,
            "first": {"kind": "leaf", "pane_id": CALLER_PANE, "tab_ids": []},
            "second": {"kind": "split", "split_id": INNER_SPLIT, "direction": "horizontal",
                "ratio": 0.5,
                "first": {"kind": "leaf", "pane_id": ALPHA_PANE, "tab_ids": []},
                "second": {"kind": "split", "split_id": BETA_SPLIT, "direction": "horizontal",
                    "ratio": 0.5,
                    "first": {"kind": "leaf", "pane_id": BETA_PANE, "tab_ids": []},
                    "second": {"kind": "leaf", "pane_id": GAMMA_PANE, "tab_ids": []}}}}}),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options {
        cmd: Some("sr2 claude".into()),
        pane: Some(BETA_PANE.into()),
        split: Some("right".into()),
        ..Options::default()
    };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "gamma", &options)).expect("start");
    assert_eq!(exit, 0, "{report}");
    let ratios = sent_ratios(&daemon);
    let outer = ratios.get(OUTER_SPLIT).copied().unwrap_or(0.5);
    let inner = ratios.get(INNER_SPLIT).copied().unwrap_or(0.5);
    let beta = ratios.get(BETA_SPLIT).copied().unwrap_or(0.5);
    let rest = 1.0 - outer;
    [outer, rest * inner, rest * (1.0 - inner) * beta, rest * (1.0 - inner) * (1.0 - beta)]
}

/// W5-Q review (PR C): agent panes that agent start made in one row share
/// their space equally, and the person's pane keeps its width: the third
/// agent pane is not an eighth of the screen.
#[test]
fn w5q_start_split_evens_only_the_agent_panes_of_its_row() {
    let widths = three_agent_row_widths("running", None);
    assert!((widths[0] - 0.5).abs() < 0.001, "the caller's pane changed: {widths:?}");
    for width in &widths[1..] {
        assert!((width - 1.0 / 6.0).abs() < 0.01, "alpha, beta, gamma widths {widths:?}");
    }
}

/// W5-Q follow-up (lead decision): the lifecycle words `session.snapshot`
/// writes for a live terminal (`launching`, which covers the daemon's
/// adopting state, and `running`) count as a running agent, whatever the
/// agent's own state (`working`, `idle`, `blocked`, `done`, `unknown`): the
/// agent pane shares space with the new one.
#[test]
fn w5q_start_split_evens_every_live_agent_pane() {
    let live = ["running", "launching", "adopting"];
    let states =
        [None, Some("working"), Some("idle"), Some("blocked"), Some("done"), Some("unknown")];
    for lifecycle in live {
        for state in states {
            let widths = three_agent_row_widths(lifecycle, state);
            assert!((widths[0] - 0.5).abs() < 0.001, "{lifecycle} {state:?}: {widths:?}");
            for width in &widths[1..] {
                assert!(
                    (width - 1.0 / 6.0).abs() < 0.01,
                    "{lifecycle} {state:?}: alpha, beta, gamma widths {widths:?}"
                );
            }
        }
    }
}

/// W5-Q follow-up (lead decision, the column rule): a lifecycle word cmux
/// does not know (a later protocol's state), `tombstoned`, or none at all
/// counts as the person's pane, so its width stays.
#[test]
fn w5q_start_split_keeps_a_pane_with_an_unknown_lifecycle() {
    for lifecycle in ["suspended", "tombstoned", ""] {
        let widths = three_agent_row_widths(lifecycle, Some("idle"));
        assert!((widths[0] - 0.5).abs() < 0.001, "{lifecycle}: {widths:?}");
        assert!((widths[1] - 0.25).abs() < 0.001, "{lifecycle}: alpha changed: {widths:?}");
        for width in &widths[2..] {
            assert!((width - 0.125).abs() < 0.01, "{lifecycle}: beta, gamma {widths:?}");
        }
    }
}

/// W5-Q follow-up (#39580 review): a marked agent terminal whose record has
/// no `lifecycle` field at all is not live: its pane keeps its width, as a
/// person's pane does.
#[test]
fn w5q_start_split_keeps_a_pane_without_a_lifecycle_field() {
    let widths = three_agent_row_widths(NO_LIFECYCLE, Some("idle"));
    assert!((widths[0] - 0.5).abs() < 0.001, "{widths:?}");
    assert!((widths[1] - 0.25).abs() < 0.001, "alpha changed: {widths:?}");
    for width in &widths[2..] {
        assert!((width - 0.125).abs() < 0.01, "beta, gamma {widths:?}");
    }
}

/// W5-Q review 3 (PR C): an agent pane whose agent exited (kept with
/// --on-exit keep) counts as the person's: it keeps its width, and only the
/// running agent panes next to the new one share their space.
#[test]
fn w5q_start_split_keeps_an_exited_agent_pane_width() {
    let widths = three_agent_row_widths("exited", None);
    assert!((widths[0] - 0.5).abs() < 0.001, "the caller's pane changed: {widths:?}");
    assert!((widths[1] - 0.25).abs() < 0.001, "the exited alpha pane changed: {widths:?}");
    for width in &widths[2..] {
        assert!((width - 0.125).abs() < 0.01, "beta, gamma widths {widths:?}");
    }
}

/// W5-Q (bench round 4 orchestration friction 6), as the column rule
/// reads it: the second agent splits the first agent's pane, and the two
/// agent panes share that pane's width; the caller's pane keeps its half.
#[test]
fn w5q_start_split_gives_each_pane_of_its_row_the_same_width() {
    let snapshot = snapshot();
    let daemon = Fake::new(move |operation, _params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "pane.split" => created(
            BETA_PANE,
            "tab_50505050505050505050505050505050",
            "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e",
        ),
        "pane.run" => created(BETA_PANE, "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0", NEW),
        "screen.layout.export" => halved_layout(),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options {
        cmd: Some("sr2 claude".into()),
        pane: Some(ALPHA_PANE.into()),
        split: Some("right".into()),
        ..Options::default()
    };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "beta", &options)).expect("start");
    assert_eq!(exit, 0, "{report}");
    let widths = row_widths(&sent_ratios(&daemon));
    assert!((widths[0] - 0.5).abs() < 0.001, "the caller's pane changed: {widths:?}");
    for width in &widths[1..] {
        assert!((width - 0.25).abs() < 0.01, "alpha, beta widths {widths:?}");
    }
}

/// W5-Q: a split in a screen of viewport columns (each column keeps its
/// width) changes no ratio.
#[test]
fn w5q_start_split_in_a_column_screen_changes_no_ratio() {
    let snapshot = snapshot();
    let daemon = Fake::new(move |operation, _params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "pane.split" => created(
            BETA_PANE,
            "tab_50505050505050505050505050505050",
            "term_5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e",
        ),
        "pane.run" => created(BETA_PANE, "tab_b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0", NEW),
        "screen.layout.export" => json!({"version": 1, "root": {"kind": "viewport",
            "base_width": 200.0, "columns": [
                {"column_id": "column_1", "width": 100.0, "root": {"kind": "leaf", "pane_id": CALLER_PANE}},
                {"column_id": "column_2", "width": 100.0, "root": {"kind": "leaf", "pane_id": BETA_PANE}}]}}),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": COMPOSER}),
        "agent.list" => json!([]),
        _ => json!({}),
    });
    let options = Options { cmd: Some("sr2 claude".into()), ..Options::default() };
    let (report, exit) =
        run_with_clock(|clock| start(&daemon, &env(), clock, "beta", &options)).expect("start");
    assert_eq!(exit, 0, "{report}");
    assert!(daemon.sent("pane.split_ratio.set").is_empty());
}

/// A scripted `session.events` stream on a fake clock: each item comes `step` after the last,
/// then a tick (`None`) every `tick` until the deadline or until the wait stops it.
struct ScriptedEvents {
    clock: Cell<Instant>,
    opened_from: RefCell<Vec<Option<Value>>>,
    stopped_early: Cell<bool>,
}

impl ScriptedEvents {
    fn new() -> Self {
        Self {
            clock: Cell::new(Instant::now()),
            opened_from: RefCell::new(Vec::new()),
            stopped_early: Cell::new(false),
        }
    }

    /// One `wake_after` call over `items` (or `refused`: no stream opens); the time it took.
    fn wake(
        &self,
        items: &[Value],
        refused: Option<&str>,
        cursor: &mut Option<Value>,
        at_most: Duration,
    ) -> Duration {
        let step = Duration::from_millis(50);
        let started = self.clock.get();
        let now = || self.clock.get();
        let mut sleep = |d: Duration| self.clock.set(self.clock.get() + d);
        readiness::wake_after(
            &mut |from, deadline, tick, on_wake| {
                self.opened_from.borrow_mut().push(from.cloned());
                if let Some(code) = refused {
                    return Err(CallFailure::local(FailureKind::Rejected, code, "refused"));
                }
                for item in items {
                    self.clock.set(self.clock.get() + step);
                    if on_wake(Some(item)) {
                        self.stopped_early.set(true);
                        return Ok(());
                    }
                }
                while self.clock.get() + tick <= deadline {
                    self.clock.set(self.clock.get() + tick);
                    if on_wake(None) {
                        self.stopped_early.set(true);
                        return Ok(());
                    }
                }
                self.clock.set(deadline);
                Ok(())
            },
            cursor,
            at_most,
            &now,
            &mut sleep,
        );
        self.clock.get() - started
    }
}

fn initial_snapshot(cursor: &str) -> Value {
    json!({"kind": "snapshot", "reset_reason": "initial", "cursor": cursor})
}

/// #38981: a change on the daemon's stream wakes the wait long before its fallback look, and
/// the wait keeps the stream's cursor for the next look.
#[test]
fn w5_a_session_event_wakes_the_wait_before_its_fallback_look() {
    let events = ScriptedEvents::new();
    let mut cursor = None;
    let at_most = Duration::from_secs(1);
    let delta = json!({"kind": "batch", "cursor": "c2"});
    let waited = events.wake(&[initial_snapshot("c1"), delta], None, &mut cursor, at_most);
    assert!(events.stopped_early.get(), "the wait closed the stream once it saw the change");
    assert!(waited < at_most / 2, "woke after {waited:?}, not at the {at_most:?} fallback");
    assert_eq!(cursor, Some(json!("c2")));
    assert_eq!(*events.opened_from.borrow(), [None::<Value>]);
}

/// The initial snapshot is no change: with nothing else on the stream the wait takes its whole
/// fallback, and the next look resumes from the snapshot's cursor.
#[test]
fn w5_the_initial_snapshot_alone_waits_out_the_fallback_and_the_next_look_resumes() {
    let events = ScriptedEvents::new();
    let mut cursor = None;
    let at_most = Duration::from_secs(1);
    let waited = events.wake(&[initial_snapshot("c1")], None, &mut cursor, at_most);
    assert!(!events.stopped_early.get());
    assert_eq!(waited, at_most);
    assert_eq!(cursor, Some(json!("c1")));
    let delta = json!({"kind": "batch", "cursor": "c3"});
    let waited = events.wake(&[delta], None, &mut cursor, at_most);
    assert!(waited < at_most / 2, "woke after {waited:?}");
    assert_eq!(*events.opened_from.borrow(), [None, Some(json!("c1"))]);
    assert_eq!(cursor, Some(json!("c3")));
}

/// No stream (an older daemon): the wait sleeps out its fallback. A cursor the daemon refuses
/// as invalid is dropped, so the next look opens from a snapshot.
#[test]
fn w5_no_stream_waits_out_the_fallback_and_an_invalid_cursor_is_dropped() {
    let events = ScriptedEvents::new();
    let at_most = Duration::from_secs(1);
    let mut cursor = Some(json!("ahead"));
    let waited = events.wake(&[], Some("transport.unavailable"), &mut cursor, at_most);
    assert_eq!(waited, at_most);
    assert_eq!(cursor, Some(json!("ahead")), "an unreachable daemon keeps the cursor");
    let waited = events.wake(&[], Some("cursor.invalid"), &mut cursor, at_most);
    assert_eq!(waited, at_most);
    assert_eq!(cursor, None);
}

/// The wait keeps the daemon's cursor whole, so a cursor with a live position
/// (`session-live-cursor-v1`) goes back as it came. The daemon then sends a look that resumes
/// at rest no item, and the look waits out its fallback: before the live position, each resume
/// got the record of every terminal with a live fact, and the wait woke on each look.
#[test]
fn w5_a_look_resumes_from_the_whole_cursor_and_no_item_is_no_change() {
    let events = ScriptedEvents::new();
    let mut cursor = None;
    let at_most = Duration::from_secs(1);
    let first = json!({"generation": "gen", "revision": "4", "live": "epoch.7"});
    let snapshot = json!({"kind": "snapshot", "reset_reason": "initial", "cursor": first});
    events.wake(&[snapshot], None, &mut cursor, at_most);
    assert_eq!(cursor, Some(first.clone()));
    // At rest the daemon sends nothing after that cursor.
    let waited = events.wake(&[], None, &mut cursor, at_most);
    assert_eq!(waited, at_most, "a resume with no item woke the wait");
    assert!(!events.stopped_early.get());
    assert_eq!(cursor, Some(first.clone()));
    // A terminal's live fact after the cursor is a change, and its cursor is the next one.
    let next = json!({"generation": "gen", "revision": "4", "live": "epoch.8"});
    let live = json!({"kind": "delta", "cursor": next, "previous_revision": "4", "revision": "4"});
    let waited = events.wake(&[live], None, &mut cursor, at_most);
    assert!(waited < at_most / 2, "woke after {waited:?}");
    assert_eq!(cursor, Some(next));
    assert_eq!(*events.opened_from.borrow(), [None, Some(first.clone()), Some(first)]);
}

/// The other daemon of the pair: one with no live position (a build before
/// `session-live-cursor-v1`). Its cursor has two fields, and the wait sends it back unchanged.
#[test]
fn w5_a_look_sends_a_two_field_cursor_back_unchanged() {
    let events = ScriptedEvents::new();
    let mut cursor = None;
    let at_most = Duration::from_secs(1);
    let first = json!({"generation": "gen", "revision": "4"});
    let snapshot = json!({"kind": "snapshot", "reset_reason": "initial", "cursor": first});
    events.wake(&[snapshot], None, &mut cursor, at_most);
    events.wake(&[], None, &mut cursor, at_most);
    assert_eq!(*events.opened_from.borrow(), [None, Some(first)]);
}

/// What sr2 prints before Claude Code starts: no input box yet.
const LAUNCHER_BANNER: &str = "\
sr2 route: gateway http://sr2-gateway.example:4016
sr2 claude2: automatic /compact through cmux terminal term_c7d53df9a7de; log /tmp/claude2.log";

/// A resume whose new terminal shows `screen` and whose `agent list` gives
/// `records`, waited on for at most 5 s.
fn resume_with(screen: &'static str, records: Value) -> (Value, i32) {
    resume_of("claude", screen, records)
}

/// [`resume_with`] for an agent whose hooks reported as `harness`.
fn resume_of(harness: &'static str, screen: &'static str, records: Value) -> (Value, i32) {
    let snapshot = snapshot();
    let daemon = Fake::new(move |operation, params, _count| match operation {
        "session.snapshot" => snapshot.clone(),
        "agent.list" if params["terminal_id"] == OLD || params["terminal"] == OLD => json!([
            {"terminal_id": OLD, "state": "done", "source": "hook", "updated_at_ms": "900",
             "extra": {"agent": harness, "agent_session_id": SESSION}},
        ]),
        "agent.list" => records.clone(),
        "terminal.process.get" => json!({"argv": snapshot["terminals"][1]["argv_for_test"]}),
        "pane.run" => created(
            "pane_22222222222222222222222222222222",
            "tab_e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0e0",
            NEW,
        ),
        "terminal.get" => json!({"id": NEW, "lifecycle": "running"}),
        "terminal.screen.read" => json!({"text": screen}),
        _ => json!({}),
    });
    let options = Options { timeout: Duration::from_secs(5), ..Options::default() };
    let target = ResumeTarget::Agent("alpha".into());
    run_with_clock(|clock| resume(&daemon, &env(), clock, &target, &options)).expect("resume")
}

/// Bench round 4 (A6, 2 of 2): `agent resume` said ready 2 s after the
/// launch, while the screen still showed the launcher's banner. The ready
/// signal was the screen-detection plugin's fresh `idle` record, a guess
/// from the screen; Claude's own SessionStart hook came 5 s later, and the
/// first message typed before it was never submitted. A resume is ready
/// only once the agent itself reports idle (its hooks: the session id that
/// resume needs came from them).
#[test]
fn w5r_resume_is_ready_only_when_the_agents_own_hook_reports_idle() {
    let plugin_idle = json!([{"terminal_id": NEW, "state": "idle", "source": "plugin",
                              "updated_at_ms": "1500"}]);
    let (report, exit) = resume_with(LAUNCHER_BANNER, plugin_idle.clone());
    assert_eq!(
        report["state"], "timeout",
        "a screen-detection record is no ready signal: {report}"
    );
    assert_eq!(exit, 124, "{report}");
    // An input box on the screen is not enough either: the hook says when
    // the resumed session took its transcript and accepts a message.
    let (report, exit) = resume_with(COMPOSER, plugin_idle);
    assert_eq!(report["state"], "timeout", "resume waits for the hook, not the screen: {report}");
    assert_eq!(exit, 124, "{report}");
    // The agent's SessionStart hook (idle, source hook) after the resume began.
    let hook_idle = json!([
        {"terminal_id": NEW, "state": "idle", "source": "plugin", "updated_at_ms": "1400"},
        {"terminal_id": NEW, "state": "idle", "source": "hook", "updated_at_ms": "1500"},
    ]);
    let (report, exit) = resume_with(COMPOSER, hook_idle);
    assert_eq!(report["state"], "ready", "{report}");
    assert_eq!(exit, 0, "{report}");
}

/// Review 6731023492 item 4: a resume waits for the agent's own idle report
/// only when its harness's hooks report a session start. Amp's report
/// nothing at its start, so its input box makes it ready, as for a start,
/// instead of a wait to the timeout.
#[test]
fn w5r_resume_of_a_harness_without_a_session_start_hook_is_ready_on_its_input_box() {
    let plugin_idle = json!([{"terminal_id": NEW, "state": "idle", "source": "plugin",
                              "updated_at_ms": "1500"}]);
    let (report, exit) = resume_of("amp", COMPOSER, plugin_idle);
    assert_eq!(report["state"], "ready", "amp cannot report its start: {report}");
    assert_eq!(exit, 0, "{report}");
    // Claude's SessionStart hook reports: its resume still waits for it.
    let plugin_idle = json!([{"terminal_id": NEW, "state": "idle", "source": "plugin",
                              "updated_at_ms": "1500"}]);
    let (report, exit) = resume_of("claude", COMPOSER, plugin_idle);
    assert_eq!(report["state"], "timeout", "{report}");
    assert_eq!(exit, 124, "{report}");
}

/// `agent start` has the same race: a fresh screen-detection record says
/// `idle` before the agent drew its input box. Only the agent's own reports
/// (hooks, socket) or its input box make a start ready.
#[test]
fn w5r_start_is_not_ready_on_a_screen_detection_record_alone() {
    let look = |hook_state| Look { screen: LAUNCHER_BANNER, exited: false, hook_state };
    let records = json!([{"terminal_id": NEW, "state": "idle", "source": "plugin",
                          "updated_at_ms": "1500"}]);
    let state = readiness::fresh_hook_state(&records, 1_000);
    assert_eq!(readiness::assess(&look(state)), Readiness::Starting, "state {state:?}");
    let detected = json!([{"terminal_id": NEW, "state": "idle", "source": "detected",
                           "updated_at_ms": "1500"}]);
    let state = readiness::fresh_hook_state(&detected, 1_000);
    assert_eq!(readiness::assess(&look(state)), Readiness::Starting, "state {state:?}");
    // The agent's own hook or socket report still counts.
    for source in ["hook", "socket"] {
        let own = json!([{"terminal_id": NEW, "state": "idle", "source": source,
                          "updated_at_ms": "1500"}]);
        let hook_state = readiness::fresh_hook_state(&own, 1_000);
        let own_look = Look { screen: LAUNCHER_BANNER, exited: false, hook_state };
        assert_eq!(readiness::assess(&own_look), Readiness::Ready, "{source}");
    }
}
