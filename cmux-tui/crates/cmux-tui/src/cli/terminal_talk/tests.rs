use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use super::super::command::RequestPlan;
use super::super::mcp::{CallFailure, FailureKind};
use super::super::wire::request_value;
use super::reply::{self, Reply};
use super::roster::{self, AgentState};
use super::send::{self, Daemon, Sample, SendRequest, Settle, Verdict, Wait};

fn strings(lines: &[&str]) -> Vec<String> {
    lines.iter().map(|line| (*line).to_owned()).collect()
}

fn snapshot() -> Value {
    json!({
        "workspaces": [{"id": "ws_a", "name": "sr2 costs"}, {"id": "ws_b", "name": null}],
        "screens": [{"id": "screen_a", "workspace_id": "ws_a"},
                    {"id": "screen_b", "workspace_id": "ws_b"}],
        "panes": [{"id": "pane_a", "screen_id": "screen_a"}, {"id": "pane_b", "screen_id": "screen_b"}],
        "tabs": [{"id": "tab_claude", "pane_id": "pane_a"}, {"id": "tab_muse", "pane_id": "pane_b"},
                 {"id": "tab_shell", "pane_id": "pane_a"}, {"id": "tab_codex", "pane_id": "pane_b"}],
        "terminals": [
            {"id": "term_c1a0de00000000000000000000000001", "tab_id": "tab_claude", "title": "Fix lag", "cwd": "/w",
             "lifecycle": "running"},
            {"id": "term_0005e000000000000000000000000002", "tab_id": "tab_muse", "title": "cmuxterm-hq", "lifecycle": "running",
             "extra": {"program_status": [{"app": "muse", "state": "working",
                                            "updated_at_ms": "500"}]}},
            {"id": "term_5be11000000000000000000000000003", "tab_id": "tab_shell", "title": "zsh", "lifecycle": "running"},
            {"id": "term_c0dec000000000000000000000000004", "tab_id": "tab_codex", "title": "codex", "lifecycle": "running"},
        ],
        "agents": [
            {"terminal_id": "term_c1a0de00000000000000000000000001", "state": "idle", "source": "hook", "updated_at_ms": "900",
             "title": "Fix lag in screen recording", "extra": {"agent": "claude"}},
            {"terminal_id": "term_c0dec000000000000000000000000004", "state": "blocked", "source": "hook",
             "updated_at_ms": "100", "extra": {"agent": "codex"}},
        ],
    })
}

#[test]
fn agent_rows_name_harness_state_title_and_workspace_and_skip_plain_shells() {
    let rows = roster::agent_rows(&snapshot());
    let summary: Vec<(&str, &str, &str, Option<&str>)> = rows
        .iter()
        .map(|row| {
            (
                row.terminal.as_str(),
                row.harness.as_str(),
                row.state.as_str(),
                row.workspace.as_deref(),
            )
        })
        .collect();
    assert_eq!(
        summary,
        [
            ("term_c0dec000000000000000000000000004", "codex", "waiting-for-input", None),
            ("term_0005e000000000000000000000000002", "muse", "busy", None),
            ("term_c1a0de00000000000000000000000001", "claude", "idle", Some("sr2 costs")),
        ]
    );
    assert_eq!(rows[2].title.as_deref(), Some("Fix lag in screen recording"));
    let mut ended = snapshot();
    ended["agents"][0]["state"] = json!("done");
    let rows = roster::agent_rows(&ended);
    assert_eq!(rows.last().map(|row| row.state), Some(AgentState::Ended));
    let rows = roster::agent_rows(&snapshot());
    assert_eq!(rows[2].workspace_id.as_deref(), Some("ws_a"));
    assert_eq!(rows[1].source, "program_status");
    let shown = rows[2].to_json(1_900);
    assert_eq!(shown["age_ms"], "1000");
    assert_eq!(shown["state"], "idle");
}

#[test]
fn agent_table_has_one_header_and_one_line_per_agent() {
    let rows = roster::agent_rows(&snapshot());
    let table = roster::table(&rows, 61_000);
    let lines: Vec<&str> = table.lines().collect();
    assert_eq!(lines.len(), 4, "{table}");
    assert!(lines[0].starts_with("TERMINAL"), "{table}");
    assert!(lines[0].contains("HARNESS") && lines[0].contains("STATE"), "{table}");
    assert!(lines[3].contains("claude") && lines[3].contains("1m"), "{table}");
}

#[test]
fn agent_states_map_records_and_program_status_words() {
    assert_eq!(AgentState::from_record("working"), Some(AgentState::Busy));
    assert_eq!(AgentState::from_record("blocked"), Some(AgentState::WaitingForInput));
    assert_eq!(AgentState::from_record("done"), Some(AgentState::Idle));
    assert_eq!(AgentState::from_record("ended"), Some(AgentState::Ended));
    assert_eq!(AgentState::from_record("nonsense"), None);
}

#[test]
fn paste_mode_follows_the_last_toggle_in_the_vt_state() {
    assert!(reply::paste_mode_on(b"\x1b[?1h\x1b[?2004h"));
    assert!(!reply::paste_mode_on(b"\x1b[?2004h\x1b[?2004l"));
    assert!(reply::paste_mode_on(b"\x1b[?2004l\x1b[?2004h"));
    assert!(!reply::paste_mode_on(b"plain"));
}

#[test]
fn input_bytes_paste_multi_line_messages_as_one_and_leave_enter_out() {
    assert_eq!(
        reply::input_bytes("line one\nline two\n", true),
        b"\x1b[200~line one\nline two\x1b[201~".to_vec()
    );
    // A paste end inside the message cannot end the paste early.
    assert_eq!(reply::input_bytes("a\x1b[201~b", true), b"\x1b[200~ab\x1b[201~".to_vec());
    assert_eq!(reply::input_bytes("ls -la\r\n", false), b"ls -la".to_vec());
}

#[test]
fn reply_after_reads_a_claude_code_answer_without_its_input_box() {
    let screen = strings(&[
        "⏺ Earlier answer.",
        "",
        "> please summarize the failing test in a sentence and name the",
        "  file it lives in",
        "",
        "⏺ The failing test is pinned_columns_tests.rs:232; it expects",
        "  three columns and gets two.",
        "",
        "✻ Brewed for 1m 38s · done 10:33 PM",
        "",
        "─────────────────────────────────────────────",
        "> ",
        "─────────────────────────────────────────────",
        "  ⏵⏵ bypass permissions on (shift+tab to cycle)",
    ]);
    let message = "please summarize the failing test in a sentence and name the file it lives in";
    assert_eq!(
        reply::reply_after(&screen, message),
        Reply {
            text: "⏺ The failing test is pinned_columns_tests.rs:232; it expects\n  three \
                   columns and gets two."
                .to_owned(),
            anchored: true,
        }
    );
}

#[test]
fn reply_after_reads_a_codex_answer_without_its_composer() {
    let screen = strings(&[
        "› what is 2+2?",
        "",
        "• 4",
        "",
        "› Ask Codex to do anything",
        "",
        "  gpt-5-codex high · 98% context left",
    ]);
    assert_eq!(
        reply::reply_after(&screen, "what is 2+2?"),
        Reply { text: "• 4".to_owned(), anchored: true }
    );
}

#[test]
fn reply_after_without_the_echo_answers_the_screen_less_its_footer() {
    let screen = strings(&["output", "more", "──────────────────────", "❯ ", "──────────"]);
    assert_eq!(
        reply::reply_after(&screen, "never typed"),
        Reply { text: "output\nmore".to_owned(), anchored: false }
    );
}

#[test]
fn reply_anchor_finds_a_long_message_by_its_end_when_its_start_scrolled_away() {
    let message = format!("{} the actual question at the end?", "context ".repeat(40));
    let screen = strings(&["context context the actual question at the end?", "", "answer"]);
    assert_eq!(reply::reply_after(&screen, &message).text, "answer");
}

fn idle_sample(screen: &str) -> Sample {
    Sample { screen: screen.to_owned(), ..Sample::default() }
}

#[test]
fn settle_waits_for_a_still_screen_and_no_busy_signal() {
    let start = Instant::now();
    let at = |ms: u64| start + Duration::from_millis(ms);
    let mut settle = Settle::new(Wait::Idle, Duration::from_millis(100), start);
    assert_eq!(settle.observe(&idle_sample("1"), at(10)), Verdict::Pending);
    assert_eq!(settle.observe(&idle_sample("2"), at(50)), Verdict::Pending);
    // Still for only 90 ms.
    assert_eq!(settle.observe(&idle_sample("2"), at(140)), Verdict::Pending);
    let busy = Sample { busy: true, ..idle_sample("2") };
    assert_eq!(settle.observe(&busy, at(400)), Verdict::Pending);
    assert_eq!(settle.observe(&idle_sample("2"), at(410)), Verdict::Done(AgentState::Idle));
}

#[test]
fn settle_ends_on_a_dialog_and_on_exit() {
    let start = Instant::now();
    let later = start + Duration::from_millis(200);
    let mut settle = Settle::new(Wait::Idle, Duration::from_millis(100), start);
    let dialog = Sample { waiting_for_input: true, busy: true, ..idle_sample("1") };
    assert_eq!(settle.observe(&dialog, later), Verdict::Done(AgentState::WaitingForInput));
    let mut settle = Settle::new(Wait::Prompt, Duration::from_millis(100), start);
    assert_eq!(settle.observe(&idle_sample("1"), later), Verdict::Pending);
    let prompt = Sample { prompt: true, ..idle_sample("1") };
    assert_eq!(settle.observe(&prompt, later), Verdict::Done(AgentState::Idle));
    let exited = Sample { exited: true, ..idle_sample("1") };
    assert_eq!(settle.observe(&exited, start), Verdict::Exited);
}

#[test]
fn samples_ignore_agent_records_older_than_the_send() {
    let terminal = json!({"id": "term_a", "extra": {}});
    let screen = json!({"revision": "7", "text": "x"});
    let stale = [json!({"terminal_id": "term_a", "state": "working", "updated_at_ms": "10"})];
    assert!(!send::sample(&terminal, &stale, &screen, 100).busy);
    let fresh = [json!({"terminal_id": "term_a", "state": "working", "updated_at_ms": "150"})];
    assert!(send::sample(&terminal, &fresh, &screen, 100).busy);
    let blocked = [json!({"terminal_id": "term_a", "state": "blocked", "updated_at_ms": 150})];
    assert!(send::sample(&terminal, &blocked, &screen, 100).waiting_for_input);
    let running = json!({"id": "term_a", "extra": {"activity": {"state": "running"}}});
    assert!(send::sample(&running, &[], &screen, 100).busy);
}

/// A daemon with one Claude Code terminal whose screen goes through
/// `screens`, one per read, then stays on the last.
struct FakeDaemon {
    snapshot: Value,
    screens: RefCell<Vec<(u64, String)>>,
    sent: RefCell<Vec<(String, Value)>>,
}

impl FakeDaemon {
    fn new(snapshot: Value, screens: &[(u64, &str)]) -> Self {
        Self {
            snapshot,
            screens: RefCell::new(
                screens.iter().map(|(revision, text)| (*revision, (*text).to_owned())).collect(),
            ),
            sent: RefCell::new(Vec::new()),
        }
    }

    fn writes(&self) -> Vec<Vec<u8>> {
        self.sent
            .borrow()
            .iter()
            .filter(|(operation, _)| operation == "terminal.input.write")
            .map(|(_, params)| {
                base64::engine::general_purpose::STANDARD
                    .decode(params["bytes_base64"].as_str().expect("bytes"))
                    .expect("base64")
            })
            .collect()
    }
}

impl Daemon for FakeDaemon {
    fn request(&self, _session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        let request = request_value(&plan).expect("a valid request");
        let operation = request["operation"].as_str().unwrap_or_default().to_owned();
        self.sent.borrow_mut().push((operation.clone(), request["params"].clone()));
        Ok(match operation.as_str() {
            "session.snapshot" => self.snapshot.clone(),
            "terminal.state.read" => json!({
                "state_base64": base64::engine::general_purpose::STANDARD.encode(b"\x1b[?2004h"),
            }),
            "terminal.get" => {
                json!({"id": "term_c1a0de00000000000000000000000001", "lifecycle": "running", "extra": {}})
            }
            "agent.list" => json!([]),
            "terminal.screen.read" => {
                let mut screens = self.screens.borrow_mut();
                let (revision, text) =
                    if screens.len() > 1 { screens.remove(0) } else { screens[0].clone() };
                json!({"revision": revision.to_string(), "text": text})
            }
            "terminal.history.read" => json!({"rows": [], "next": null}),
            _ => json!({}),
        })
    }
}

fn quick(text: &str) -> SendRequest {
    SendRequest {
        settle: Duration::from_millis(40),
        enter_delay: Duration::ZERO,
        poll: Duration::from_millis(5),
        timeout: Duration::from_secs(5),
        ..SendRequest::new("term_c1a0de00000000000000000000000001".into(), text.into())
    }
}

/// Simulate the daemon applying one write then dropping its acknowledgement.
struct LostAckDaemon {
    inner: FakeDaemon,
    keys: RefCell<HashSet<String>>,
    applied: Cell<usize>,
    lose_on: usize,
}

impl LostAckDaemon {
    fn new(lose_on: usize) -> Self {
        Self {
            inner: FakeDaemon::new(snapshot(), &[(1, "")]),
            keys: RefCell::new(HashSet::new()),
            applied: Cell::new(0),
            lose_on,
        }
    }
}

impl Daemon for LostAckDaemon {
    fn request(&self, session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        let wire = request_value(&plan).expect("valid request");
        if wire["operation"] != "terminal.input.write" {
            return self.inner.request(session, plan);
        }
        let key = plan.idempotency_key.clone().expect("each write carries a replay key");
        if !self.keys.borrow_mut().insert(key.clone()) {
            // The owner replays the accepted result instead of applying the bytes twice.
            return Ok(json!({}));
        }
        let result = self.inner.request(session, plan)?;
        let count = self.applied.get() + 1;
        self.applied.set(count);
        if count == self.lose_on {
            return Err(CallFailure {
                kind: FailureKind::InProgress,
                error: json!({"code": "transport.failed", "message": "reply lost",
                              "details": {}, "retryable": true}),
                idempotency_key: Some(key),
            });
        }
        Ok(result)
    }
}

#[test]
fn terminal_send_retry_replays_both_writes_after_either_lost_ack() {
    for lost_at in [1, 2] {
        let daemon = LostAckDaemon::new(lost_at);
        let request = SendRequest {
            wait: Wait::None,
            enter_delay: Duration::ZERO,
            idempotency_key: Some("repeat-this-send".into()),
            ..quick("echo one")
        };
        let failed = send::run(&daemon, None, &request).expect_err("lost acknowledgement");
        assert_eq!(failed.failure.idempotency_key.as_deref(), Some("repeat-this-send"));
        assert_eq!(failed.failure.error["details"]["send_id"], "repeat-this-send");
        assert_eq!(
            failed.failure.error["details"]["phase"],
            if lost_at == 1 { "paste" } else { "enter" }
        );
        let replay = send::run(&daemon, None, &request).expect("replayed the original send");
        assert_eq!(replay["idempotency_key"], "repeat-this-send");
        assert_eq!(replay["sent"], true);
        assert_eq!(daemon.applied.get(), 2, "one paste and one Enter, exactly");
        assert_eq!(daemon.keys.borrow().len(), 2);
        assert_eq!(
            daemon.inner.writes(),
            [b"\x1b[200~echo one\x1b[201~".to_vec(), b"\r".to_vec()],
            "each stage applies once after an uncertain reply"
        );
    }
}

#[test]
fn terminal_send_generated_key_is_returned_on_a_lost_reply() {
    let daemon = LostAckDaemon::new(1);
    let request = SendRequest { wait: Wait::None, enter_delay: Duration::ZERO, ..quick("hello") };
    let failed = send::run(&daemon, None, &request).expect_err("lost acknowledgement");
    let key = failed.failure.idempotency_key.expect("whole-send recovery identity");
    assert_eq!(failed.failure.error["details"]["send_id"], key);
    let replay = SendRequest { idempotency_key: Some(key.clone()), ..request };
    let finished = send::run(&daemon, None, &replay).expect("same send retried");
    assert_eq!(finished["idempotency_key"], key);
    assert_eq!(daemon.applied.get(), 2, "one paste and one Enter");
}

#[test]
fn send_pastes_presses_enter_waits_and_answers_only_the_reply() {
    let answer = "> what is 2+2\n\n⏺ 4\n\n──────────────────────\n> \n──────────────────────";
    let daemon = FakeDaemon::new(
        snapshot(),
        &[(1, "> what is 2+2\n\n✻ Thinking"), (2, "> what is 2+2\n\n✶ Thinking"), (3, answer)],
    );
    let receipt = send::run(&daemon, None, &quick("what is 2+2")).expect("sent");
    assert_eq!(daemon.writes(), [b"\x1b[200~what is 2+2\x1b[201~".to_vec(), b"\r".to_vec()]);
    assert_eq!(receipt["output"], "⏺ 4");
    assert_eq!(receipt["state"], "idle");
    assert_eq!(receipt["timed_out"], false);
    assert_eq!(receipt["anchored"], true);
    assert_eq!(receipt["harness"], "claude");
    assert_eq!(receipt["terminal"], "term_c1a0de00000000000000000000000001");
}

#[test]
fn send_with_wait_none_answers_after_enter() {
    let daemon = FakeDaemon::new(snapshot(), &[(1, "")]);
    let request = SendRequest { wait: Wait::None, ..quick("hello") };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert_eq!(receipt["sent"], true);
    assert!(receipt.get("output").is_none());
    assert!(!daemon.sent.borrow().iter().any(|(operation, _)| operation == "terminal.screen.read"));
}

#[test]
fn send_refuses_an_agent_that_waits_on_a_dialog_unless_forced() {
    let daemon = FakeDaemon::new(snapshot(), &[(1, "")]);
    let request =
        SendRequest { target: "term_c0dec000000000000000000000000004".into(), ..quick("yes") };
    let failure = send::run(&daemon, None, &request).expect_err("refused");
    assert_eq!(failure.failure.error["code"], "agent.waiting_for_input");
    assert!(daemon.writes().is_empty());
    let forced = SendRequest { force: true, wait: Wait::None, ..request };
    send::run(&daemon, None, &forced).expect("forced");
    assert_eq!(daemon.writes().len(), 2);
}

#[test]
fn send_finds_terminals_by_tab_prefix_and_title() {
    let snapshot = snapshot();
    let id = |target: &str| {
        send::find_terminal(&snapshot, target).map(|terminal| terminal["id"].clone()).ok()
    };
    assert_eq!(id("tab_muse"), Some(json!("term_0005e000000000000000000000000002")));
    assert_eq!(id("term_c1a"), Some(json!("term_c1a0de00000000000000000000000001")));
    assert_eq!(id("Fix lag"), Some(json!("term_c1a0de00000000000000000000000001")));
    assert_eq!(id("term_"), None, "ambiguous");
    assert_eq!(id("nothing"), None);
}

#[test]
fn send_times_out_with_the_output_so_far() {
    let screens: Vec<(u64, String)> =
        (1..400).map(|n| (n, format!("> q\n\nworking {n}"))).collect();
    let screens: Vec<(u64, &str)> = screens.iter().map(|(n, text)| (*n, text.as_str())).collect();
    let daemon = FakeDaemon::new(snapshot(), &screens);
    let request = SendRequest { timeout: Duration::from_millis(100), ..quick("q") };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert_eq!(receipt["timed_out"], true);
    assert!(receipt["output"].as_str().unwrap_or_default().starts_with("working"));
}

#[test]
fn send_flags_parse_with_defaults() {
    let words = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    let request = super::parse_send("term_a", &words(&["--text", "hi"])).expect("parsed");
    assert_eq!(request.wait, Wait::Idle);
    assert_eq!(request.timeout, send::DEFAULT_TIMEOUT);
    assert_eq!(request.settle, send::DEFAULT_SETTLE);
    let request = super::parse_send(
        "term_a",
        &words(&[
            "--text=a b",
            "--wait",
            "prompt",
            "--timeout",
            "30s",
            "--settle=500ms",
            "--force",
        ]),
    )
    .expect("parsed");
    assert_eq!((request.text.as_str(), request.wait), ("a b", Wait::Prompt));
    assert_eq!(request.timeout, Duration::from_secs(30));
    assert_eq!(request.settle, Duration::from_millis(500));
    assert!(request.force);
    assert!(super::parse_send("term_a", &words(&["--wait", "soon", "--text", "x"])).is_err());
    assert!(super::parse_send("term_a", &words(&[])).is_err());
    assert!(super::parse_send("term_a", &words(&["--text", "  "])).is_err());
    assert!(super::parse_list(&words(&["--agents"])).is_ok());
    assert!(super::parse_list(&words(&["--agents", "--bogus"])).is_err());
}

#[test]
fn claude_code_plugin_records_name_the_claude_harness() {
    let mut snapshot = snapshot();
    snapshot["agents"][0]["extra"]["agent"] = json!("claude-code");
    let rows = roster::agent_rows(&snapshot);
    assert!(rows.iter().any(|row| row.harness == "claude" && row.source == "hook"));
}
