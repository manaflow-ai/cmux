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
            ("term_c0dec000000000000000000000000004", "codex", "blocked", None),
            ("term_0005e000000000000000000000000002", "muse", "working", None),
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
fn agent_rows_carry_the_shared_status_and_done_until_seen() {
    let rows = roster::agent_rows(&snapshot());
    let statuses: Vec<Option<String>> =
        rows.iter().map(|row| row.to_json(0)["status"].as_str().map(str::to_string)).collect();
    assert_eq!(
        statuses.iter().map(Option::as_deref).collect::<Vec<_>>(),
        [Some("blocked"), Some("working"), Some("idle")]
    );

    // An unread notification on the idle claude terminal: its turn finished
    // and nobody viewed it, so it is done and sorts above working.
    let mut unseen = snapshot();
    unseen["notifications"] = json!([
        {"id": "notification_1", "terminal_id": "term_c1a0de00000000000000000000000001",
         "unread": true, "title": "Claude finished"},
        {"id": "notification_2", "terminal_id": "term_c0dec000000000000000000000000004",
         "unread": false, "title": "Codex needs approval"},
    ]);
    let rows = roster::agent_rows(&unseen);
    let summary: Vec<(&str, &str, &str)> = rows
        .iter()
        .map(|row| (row.harness.as_str(), row.status_word(), row.state.as_str()))
        .collect();
    assert_eq!(
        summary,
        [
            ("codex", "blocked", "blocked"),
            ("claude", "done", "idle"),
            ("muse", "working", "working")
        ],
        "the send wait's state uses the shared words"
    );
    let table = roster::table(&rows, 1_000);
    assert!(table.lines().nth(2).is_some_and(|line| line.contains(" done ")), "{table}");

    let mut ended = snapshot();
    ended["agents"][0]["state"] = json!("done");
    let ended = roster::agent_rows(&ended);
    let last = ended.last().unwrap();
    assert_eq!((last.status_word(), last.to_json(0)["status"].clone()), ("ended", json!("ended")));
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
    assert_eq!(AgentState::from_record("working"), Some(AgentState::Working));
    assert_eq!(AgentState::from_record("blocked"), Some(AgentState::Blocked));
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
        reply_after(&screen, message),
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
        reply_after(&screen, "what is 2+2?"),
        Reply { text: "• 4".to_owned(), anchored: true }
    );
}

#[test]
fn reply_after_without_the_echo_answers_the_screen_less_its_footer() {
    let screen = strings(&["output", "more", "──────────────────────", "❯ ", "──────────"]);
    assert_eq!(
        reply_after(&screen, "never typed"),
        Reply { text: "output\nmore".to_owned(), anchored: false }
    );
}

#[test]
fn reply_anchor_finds_a_long_message_by_its_end_when_its_start_scrolled_away() {
    let message = format!("{} the actual question at the end?", "context ".repeat(40));
    let screen = strings(&["context context the actual question at the end?", "", "answer"]);
    assert_eq!(reply_after(&screen, &message).text, "answer");
}

/// The reply of a send that read no screen before it.
fn reply_after(lines: &[String], message: &str) -> Reply {
    reply::reply_since(lines, message, None, lines)
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
    assert_eq!(settle.observe(&dialog, later), Verdict::Done(AgentState::Blocked));
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
    /// What `agent list --terminal` answers while the send waits.
    agents: Value,
    /// The `extra` of the terminal record `terminal.get` answers.
    extra: Value,
}

impl FakeDaemon {
    fn new(snapshot: Value, screens: &[(u64, &str)]) -> Self {
        Self {
            snapshot,
            screens: RefCell::new(
                screens.iter().map(|(revision, text)| (*revision, (*text).to_owned())).collect(),
            ),
            sent: RefCell::new(Vec::new()),
            agents: json!([]),
            extra: json!({}),
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
            "terminal.get" => json!({"id": "term_c1a0de00000000000000000000000001",
                                     "lifecycle": "running", "extra": self.extra}),
            "agent.list" => self.agents.clone(),
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

/// [`send::run_on`] on a fake clock: each sleep moves `now` on, so a stall
/// limit passes with no real wait.
fn send_on_fake_clock(
    daemon: &FakeDaemon,
    request: &SendRequest,
) -> Result<Value, send::SendFailure> {
    let start = Instant::now();
    let elapsed = Cell::new(Duration::ZERO);
    let now = || start + elapsed.get();
    let mut sleep = |step: Duration| elapsed.set(elapsed.get() + step);
    let mut clock =
        super::super::agent_start::Clock { now: &now, sleep: &mut sleep, now_ms: 1_000 };
    send::run_on(daemon, None, request, &mut clock)
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

/// A replay key must identify the same terminal even if a user moves a tab,
/// renames a title or changes which terminal is current.
#[test]
fn keyed_terminal_send_requires_a_full_stable_terminal_id() {
    const TERMINAL: &str = "term_c1a0de00000000000000000000000001";
    for target in ["Fix lag", "tab_claude", "term_c1a0de"] {
        let daemon = FakeDaemon::new(snapshot(), &[(1, "")]);
        let request = SendRequest {
            target: target.to_owned(),
            idempotency_key: Some("one-send".into()),
            wait: Wait::None,
            ..quick("echo once")
        };
        let failure = send::run(&daemon, None, &request).expect_err("mutable selector refused");
        assert_eq!(failure.exit, 2, "{target}: {failure:?}");
        assert_eq!(failure.failure.error["code"], "terminal.send_stable_target_required");
        assert_eq!(failure.failure.error["details"]["terminal"], TERMINAL);
        assert!(daemon.writes().is_empty(), "{target} sent bytes before refusal");
    }
}

/// An unkeyed first attempt can still use a title. If a write's response is
/// lost, the error includes its resolved terminal id to retry with the key.
#[test]
fn lost_ack_title_send_retries_using_the_original_terminal_id() {
    const TERMINAL: &str = "term_c1a0de00000000000000000000000001";
    let daemon = LostAckDaemon::new(1);
    let request = SendRequest {
        target: "Fix lag".into(),
        wait: Wait::None,
        enter_delay: Duration::ZERO,
        ..quick("echo once")
    };
    let failed = send::run(&daemon, None, &request).expect_err("paste applied, reply lost");
    assert_eq!(failed.failure.error["details"]["terminal"], TERMINAL);
    let send_id = failed.failure.idempotency_key.expect("stable recovery id");
    let retry =
        SendRequest { target: TERMINAL.into(), idempotency_key: Some(send_id.clone()), ..request };
    let receipt = send::run(&daemon, None, &retry).expect("replayed original paste, sent Enter");
    assert_eq!(receipt["idempotency_key"], send_id);
    assert_eq!(receipt["terminal"], TERMINAL);
    assert_eq!(daemon.applied.get(), 2, "one paste and one Enter total");
    assert_eq!(daemon.inner.writes().len(), 2);
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

/// Claude Code's screen when a turn stops at a permission dialog: the
/// earlier turns, the message's echo and the dialog. Claude Code renders
/// the message's inline code without its backticks.
const DIALOG_SCREEN: &str = "⏺ OLD_ANSWER_ONE\n\n❯ Reply with exactly ALPHA_OK\n\n⏺ ALPHA_OK\n\n\
❯ Run the shell command touch /tmp/w4i-perm now.\n\n⏺ Bash(touch /tmp/w4i-perm)\n\n\
 Bash command\n   touch /tmp/w4i-perm\n Do you want to proceed?\n ❯ 1. Yes\n   2. No";

/// A daemon whose agent waits on a dialog once the message is in.
fn dialog_daemon(screens: &[(u64, &str)]) -> FakeDaemon {
    let mut daemon = FakeDaemon::new(snapshot(), screens);
    daemon.agents = json!([{"terminal_id": "term_c1a0de00000000000000000000000001",
                            "state": "blocked", "source": "hook",
                            "updated_at_ms": u64::MAX.to_string()}]);
    daemon
}

#[test]
fn send_stopped_at_a_dialog_anchors_a_message_with_inline_code() {
    let before = "⏺ OLD_ANSWER_ONE\n\n❯ Reply with exactly ALPHA_OK\n\n⏺ ALPHA_OK\n\n❯ ";
    let daemon = dialog_daemon(&[(1, before), (2, DIALOG_SCREEN)]);
    let message = "Run the shell command `touch /tmp/w4i-perm` now.";
    let receipt = send::run(&daemon, None, &quick(message)).expect("sent");
    assert_eq!(receipt["state"], "blocked");
    assert_eq!(receipt["anchored"], true, "{receipt}");
    let output = receipt["output"].as_str().unwrap_or_default();
    assert!(output.starts_with("⏺ Bash(touch /tmp/w4i-perm)"), "{output}");
    assert!(output.contains("Do you want to proceed?"), "{output}");
    assert!(!output.contains("ALPHA_OK"), "earlier turns are not the reply: {output}");
}

#[test]
fn send_stopped_at_a_dialog_without_an_echo_answers_only_what_came_after_the_send() {
    // The echo is not on the screen at all (a harness that shows a pasted
    // message as a placeholder this CLI does not know): the earlier turns
    // that were on the screen before the send are still not the reply.
    let before = "⏺ OLD_ANSWER_ONE\n\n⏺ ALPHA_OK\n\n❯ ";
    let after = "⏺ OLD_ANSWER_ONE\n\n⏺ ALPHA_OK\n\n❯ «message 1»\n\n⏺ Bash(touch /tmp/w4i-perm)\n\n\
 Do you want to proceed?\n ❯ 1. Yes\n   2. No";
    let daemon = dialog_daemon(&[(1, before), (2, after)]);
    let receipt = send::run(&daemon, None, &quick("never echoed as typed")).expect("sent");
    assert_eq!(receipt["state"], "blocked");
    assert_eq!(receipt["anchored"], false, "{receipt}");
    let output = receipt["output"].as_str().unwrap_or_default();
    assert!(output.contains("⏺ Bash(touch /tmp/w4i-perm)"), "{output}");
    assert!(!output.contains("OLD_ANSWER_ONE") && !output.contains("ALPHA_OK"), "{output}");
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

/// W6-BC review (real build): a `blocked` that only the screen-detection
/// plugin guessed, from a screen read before the agent redrew, does not
/// refuse a send once the screen shows the agent's input box and no dialog.
#[test]
fn w6bc_a_stale_screen_guess_of_blocked_does_not_refuse_a_send() {
    let mut stale = snapshot();
    stale["agents"][1]["source"] = json!("plugin");
    // The agent's own newest report says its dialog ended.
    stale["terminals"][3]["extra"] =
        json!({"program_status": [{"app": "codex", "state": "idle", "updated_at_ms": "90"}]});
    let screen = "› \n\n  ? for shortcuts                                100% context left";
    let daemon = FakeDaemon::new(stale, &[(1, screen)]);
    let request = SendRequest {
        target: "term_c0dec000000000000000000000000004".into(),
        wait: Wait::None,
        ..quick("yes")
    };
    let sent = send::run(&daemon, None, &request);
    assert!(sent.is_ok(), "{:?}", sent.err().map(|failure| failure.failure.error));
    assert_eq!(daemon.writes().len(), 2);
}

/// W6-BC review 3: a send is refused at a dialog the agent itself
/// reported, even when the plugin's record is newer and the screen shows a
/// hint word, and at a plugin-only agent's radio dialog.
#[test]
fn w6bc_a_send_is_refused_at_a_reported_or_plugin_only_dialog() {
    let target = "term_c0dec000000000000000000000000004";
    let mut reported = snapshot();
    reported["agents"].as_array_mut().expect("agents").push(json!({
        "terminal_id": target, "state": "blocked", "source": "plugin",
        "updated_at_ms": "200", "extra": {"agent": "codex"}}));
    let hint =
        "⏺ I turn accept edits on once you pick.\n Which checks?\n ❯ [ ] 1. Unit\n     [ ] 2. Lint";
    let radio = " Allow execution of: 'touch'?\n ● 1. Yes, allow once\n   2. No, suggest changes (esc)\n ~/p   (99% context left)";
    let mut plugin_only = snapshot();
    plugin_only["agents"][1]["source"] = json!("plugin");
    for (snapshot, screen) in [(reported, hint), (plugin_only, radio)] {
        let daemon = FakeDaemon::new(snapshot, &[(1, screen)]);
        let request = SendRequest { target: target.into(), wait: Wait::None, ..quick("yes") };
        let failure = send::run(&daemon, None, &request).expect_err("refused");
        assert_eq!(failure.exit, 4, "{screen}: {:?}", failure.failure.error);
        assert!(daemon.writes().is_empty(), "{screen}");
    }
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

const SHELL: &str = "term_5be11000000000000000000000000003";

/// A daemon with one zsh terminal: each `terminal.get` answers the next of
/// `records` (then stays on the last), each screen read the next of
/// `screens`. Without `unwrap`, it refuses the `unwrap` field as an older
/// daemon does.
struct ShellDaemon {
    snapshot: Value,
    records: RefCell<Vec<Value>>,
    screens: RefCell<Vec<String>>,
    unwrap: bool,
    sent: RefCell<Vec<(String, Value)>>,
}

impl ShellDaemon {
    fn new(before: Option<Value>, records: Vec<Value>, screens: &[&str], unwrap: bool) -> Self {
        let mut snapshot = snapshot();
        if let Some(before) = before {
            snapshot["terminals"][2]["extra"] = json!({"last_command": before});
        }
        Self {
            snapshot,
            records: RefCell::new(records),
            screens: RefCell::new(screens.iter().map(|screen| (*screen).to_owned()).collect()),
            unwrap,
            sent: RefCell::new(Vec::new()),
        }
    }

    fn reads(&self) -> Vec<Value> {
        self.sent
            .borrow()
            .iter()
            .filter(|(operation, _)| operation == "terminal.screen.read")
            .map(|(_, params)| params.clone())
            .collect()
    }
}

fn next<T: Clone>(items: &RefCell<Vec<T>>) -> T {
    let mut items = items.borrow_mut();
    if items.len() > 1 { items.remove(0) } else { items[0].clone() }
}

impl Daemon for ShellDaemon {
    fn request(&self, _session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        let request = request_value(&plan).expect("a valid request");
        let operation = request["operation"].as_str().unwrap_or_default().to_owned();
        let params = request["params"].clone();
        self.sent.borrow_mut().push((operation.clone(), params.clone()));
        Ok(match operation.as_str() {
            "session.snapshot" => self.snapshot.clone(),
            "terminal.state.read" => json!({"state_base64": ""}),
            "terminal.get" => next(&self.records),
            "agent.list" => json!([]),
            "terminal.screen.read" => {
                if !self.unwrap && params.get("unwrap").is_some() {
                    return Err(CallFailure {
                        kind: FailureKind::Rejected,
                        error: json!({"code": "validation.invalid", "message": "unknown field"}),
                        idempotency_key: None,
                    });
                }
                json!({"revision": "1", "text": next(&self.screens)})
            }
            "terminal.history.read" => json!({"rows": [], "next": null}),
            _ => json!({}),
        })
    }
}

fn shell_record(extra: Value) -> Value {
    json!({"id": SHELL, "lifecycle": "running", "extra": extra})
}

fn shell_send(text: &str) -> SendRequest {
    SendRequest {
        target: SHELL.into(),
        wait: Wait::Prompt,
        settle: Duration::from_secs(30),
        ..quick(text)
    }
}

#[test]
fn read_run_send_wait_prompt_returns_the_typed_commands_exit_status_without_the_settle() {
    let old = json!({"exit_code": 0, "finished_at_ms": "100"});
    let new = json!({"exit_code": 7, "started_at_ms": "200", "finished_at_ms": "210"});
    let daemon = ShellDaemon::new(
        Some(old.clone()),
        vec![
            shell_record(json!({"activity": {"state": "running"}, "last_command": old})),
            shell_record(json!({"prompt": {"since_ms": "211"}, "last_command": new})),
        ],
        &["$ sh -c 'exit 7'", "$ sh -c 'exit 7'\n$"],
        true,
    );
    let started = Instant::now();
    let receipt = send::run(&daemon, None, &shell_send("sh -c 'exit 7'")).expect("sent");
    assert!(started.elapsed() < Duration::from_secs(10), "the finished command ends the wait");
    assert_eq!(receipt["exit_status"], 7);
    assert_eq!(receipt["state"], "idle");
    assert_eq!(receipt["timed_out"], false);
    assert_eq!(super::send_exit_code(&receipt, true), 7);
    assert_eq!(super::send_exit_code(&receipt, false), 0);
    assert!(daemon.reads().iter().all(|read| read["unwrap"] == true), "reads join soft wraps");
}

#[test]
fn read_run_send_without_shell_integration_has_no_exit_status_and_run_exits_unknown() {
    // No OSC 133: no prompt, no last_command; the still screen ends the wait.
    let daemon =
        ShellDaemon::new(None, vec![shell_record(json!({}))], &["$ sh -c 'exit 7'\n$ "], false);
    let request = SendRequest {
        wait: Wait::Idle,
        settle: Duration::from_millis(40),
        ..shell_send("sh -c 'exit 7'")
    };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert!(receipt.get("exit_status").is_none(), "absent, never guessed: {receipt}");
    assert_eq!(super::send_exit_code(&receipt, true), 125);
    // The older daemon refused unwrap once; the rest read plain rows.
    let reads = daemon.reads();
    assert_eq!(reads[0]["unwrap"], true);
    assert!(reads[1..].iter().all(|read| read.get("unwrap").is_none()));
}

#[test]
fn read_run_send_ignores_a_last_command_that_finished_before_the_send() {
    let old = json!({"exit_code": 3, "finished_at_ms": "100"});
    let daemon = ShellDaemon::new(
        Some(old.clone()),
        vec![shell_record(json!({"prompt": {"since_ms": "90"}, "last_command": old}))],
        &["$ true"],
        true,
    );
    let request = SendRequest { settle: Duration::from_millis(40), ..shell_send("true") };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert!(receipt.get("exit_status").is_none(), "the old command's status is not this one's");
}

#[test]
fn read_run_send_pattern_matches_only_output_after_the_typed_command() {
    let message = "for i in 1 2 3; do echo step $i; sleep 1; done; echo BENCH_OK";
    let echo = format!("$ {message}");
    let daemon = ShellDaemon::new(
        None,
        vec![shell_record(json!({"activity": {"state": "running"}}))],
        &[&echo, &format!("{echo}\nstep 1"), &format!("{echo}\nstep 1\nstep 2\nstep 3\nBENCH_OK")],
        true,
    );
    let request = SendRequest { pattern: Some("(?m)^BENCH_OK".into()), ..shell_send(message) };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert_eq!(receipt["matched"], true);
    assert!(receipt["output"].as_str().unwrap().ends_with("BENCH_OK"));
    assert_eq!(daemon.reads().len(), 3, "the echo alone did not match");
    // A pattern that never shows, and the command finishes: no match, exit 1.
    let daemon = ShellDaemon::new(
        None,
        vec![shell_record(
            json!({"prompt": {"since_ms": "5"}, "last_command": {"exit_code": 0, "finished_at_ms": "5"}}),
        )],
        &[&format!("{echo}\nstep 1\n$")],
        true,
    );
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert_eq!(receipt["matched"], false);
    assert_eq!(super::send_exit_code(&receipt, false), 1);
}

#[test]
fn run_argv_types_each_word_quoted_so_it_runs_as_given() {
    let words = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    let typed = |args: &[&str]| {
        let mut flags = words(&["--timeout", "20s", "--"]);
        flags.extend(words(args));
        super::parse_run("term_a", &flags).expect("parsed").text
    };
    // The audit's case: unquoted, `exit 7` ran in the person's shell and ended it.
    assert_eq!(typed(&["sh", "-c", "echo failing; exit 7"]), "sh -c 'echo failing; exit 7'");
    // Spaces, double quotes and runs of spaces survive.
    assert_eq!(typed(&["sh", "-c", "echo a b; echo \"c  d\""]), "sh -c 'echo a b; echo \"c  d\"'");
    // An embedded single quote closes, escapes and reopens.
    assert_eq!(typed(&["echo", "it's"]), "echo 'it'\\''s'");
    // `$`, globs and `~` reach the program as written, never expanded.
    assert_eq!(
        typed(&["printf", "%s\\n", "$HOME", "*.rs", "~/x"]),
        "printf '%s\\n' '$HOME' '*.rs' '~/x'"
    );
    // An empty argument stays one argument.
    assert_eq!(typed(&["printf", "[%s]", ""]), "printf '[%s]' ''");
    // zsh expands a bare `=name`; it is quoted.
    assert_eq!(typed(&["echo", "=ls"]), "echo '=ls'");
    // A command word the shell reads as syntax is quoted: a reserved word or an assignment.
    assert_eq!(typed(&["if", "true"]), "'if' true");
    assert_eq!(typed(&["FOO=bar", "x"]), "'FOO=bar' x");
    assert_eq!(typed(&["env", "FOO=bar", "x"]), "env FOO=bar x");
    // Plain words stay readable.
    assert_eq!(
        typed(&["npm", "test", "--", "--grep=api", "./src/a.rs", "user@host:1"]),
        "npm test -- --grep=api ./src/a.rs user@host:1"
    );
}

#[cfg(unix)]
#[test]
fn run_argv_line_reads_back_as_the_same_argv_in_sh() {
    let argv: Vec<String> =
        ["echo failing; exit 7", "a b", "c  d", "it's", "$HOME", "*", "", "=ls", "x\"y", "--f=1"]
            .iter()
            .map(|word| (*word).to_owned())
            .collect();
    let line = super::shell_line(&argv);
    // The shell splits the typed line into printf's arguments, NUL-terminated.
    let output = std::process::Command::new("sh")
        .arg("-c")
        .arg(format!("printf '%s\\0' {line}"))
        .output()
        .expect("sh runs");
    assert!(output.status.success(), "{line}");
    let words: Vec<String> = String::from_utf8(output.stdout)
        .expect("utf-8")
        .split_terminator('\0')
        .map(str::to_owned)
        .collect();
    assert_eq!(words, argv, "{line}");
}

#[test]
fn run_one_word_after_dashes_is_a_shell_line_typed_as_written() {
    let words = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    let request = super::parse_run("term_a", &words(&["--", "npm test && echo ok; ls $HOME"]))
        .expect("parsed");
    assert_eq!(request.text, "npm test && echo ok; ls $HOME");
    let request = super::parse_run("term_a", &words(&["--", "make"])).expect("parsed");
    assert_eq!(request.text, "make");
    // --text is a shell line too, never quoted.
    let request = super::parse_run("term_a", &words(&["--text", "sh -c 'exit 7' || echo $?"]))
        .expect("parsed");
    assert_eq!(request.text, "sh -c 'exit 7' || echo $?");
    // Nothing after -- is still a usage error.
    assert!(super::parse_run("term_a", &words(&["--"])).is_err());
}

#[test]
fn read_run_run_is_send_wait_prompt_with_exit_status() {
    let words = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    let request =
        super::parse_run("term_a", &words(&["--timeout", "10s", "--", "sh", "-c", "exit 7"]))
            .expect("parsed");
    assert_eq!(request.text, "sh -c 'exit 7'");
    assert_eq!(request.wait, Wait::Prompt);
    assert!(request.exit_with_status);
    assert_eq!(request.timeout, Duration::from_secs(10));
    let request = super::parse_run("term_a", &words(&["--text", "make"])).expect("parsed");
    assert_eq!(request.text, "make");
    assert!(super::parse_run("term_a", &words(&["--wait", "idle", "--", "x"])).is_err());
    assert!(super::parse_run("term_a", &words(&["--text", "a", "--", "b"])).is_err());
    assert!(super::parse_run("term_a", &words(&[])).is_err());
    let send = super::parse_send(
        "term_a",
        &words(&["--text", "x", "--pattern", "ok", "--exit-with-status"]),
    )
    .expect("parsed");
    assert_eq!(send.pattern.as_deref(), Some("ok"));
    assert!(send.exit_with_status);
    // A timeout wins over the status; a signal-sized status wraps as $? does.
    assert_eq!(super::send_exit_code(&json!({"timed_out": true, "exit_status": 0}), true), 124);
    assert_eq!(super::send_exit_code(&json!({"exit_status": 130}), true), 130);
}

#[test]
fn read_run_read_and_wait_flags_send_unwrap_lines_and_new() {
    use super::super::command::{self, CommandPlan};
    let params = |args: &[&str]| {
        let args: Vec<String> = args.iter().map(|arg| (*arg).to_owned()).collect();
        match command::parse(&args, super::super::Surface::CmuxTui) {
            Ok(CommandPlan::Protocol(plan)) => {
                request_value(&plan).expect("request")["params"].clone()
            }
            _ => panic!("{args:?} is a protocol request"),
        }
    };
    let read = params(&["terminal", SHELL, "screen", "read", "--unwrap", "--lines", "5"]);
    assert_eq!((read["unwrap"].clone(), read["lines"].clone()), (json!(true), json!(5)));
    let plain = params(&["terminal", SHELL, "screen", "read"]);
    assert!(plain.get("unwrap").is_none() && plain.get("lines").is_none());
    let wait = params(&["terminal", SHELL, "screen", "wait", "--pattern", "ok", "--new"]);
    assert_eq!(wait["new"], true);
    let copy = params(&["terminal", SHELL, "copy", "--mode", "scrollback", "--unwrap"]);
    assert_eq!(copy["unwrap"], true);
    let args: Vec<String> = ["terminal", SHELL, "screen", "read", "--lines", "0"]
        .iter()
        .map(|a| (*a).to_owned())
        .collect();
    assert!(command::parse(&args, super::super::Surface::CmuxTui).is_err());
}

/// `terminal run -- sh -c 'exit 7'` (bench round 3, T3): the words after
/// `--` are an argv, so the shell must get each one as one word. A plain
/// join made the shell run `sh -c exit 7`, which exits 0.
#[test]
fn w4j_run_gives_the_shell_each_argv_word_as_one_word() {
    let words = |args: &[&str]| args.iter().map(|arg| (*arg).to_owned()).collect::<Vec<_>>();
    let shell = |line: &str| {
        std::process::Command::new("/bin/sh").arg("-c").arg(line).output().expect("sh runs")
    };
    let request =
        super::parse_run("term_a", &words(&["--", "sh", "-c", "exit 7"])).expect("parsed");
    assert_eq!(shell(&request.text).status.code(), Some(7), "typed {:?}", request.text);

    let argv = ["a b", "it's", "say \"hi\"", "$HOME", "*", "back\\slash", "", "tab\there"];
    let mut command = vec!["--", "printf", "%s\\n"];
    command.extend(argv);
    let request = super::parse_run("term_a", &words(&command)).expect("parsed");
    let printed = shell(&request.text);
    assert!(printed.status.success(), "typed {:?}", request.text);
    let printed = String::from_utf8(printed.stdout).expect("utf-8");
    assert_eq!(printed.lines().collect::<Vec<_>>(), argv, "typed {:?}", request.text);

    // One word after -- stays a shell line, as `run -- 'a; b'` was.
    let request =
        super::parse_run("term_a", &words(&["--", "echo AFTER_$((2+2)); exit 3"])).expect("parsed");
    assert_eq!(request.text, "echo AFTER_$((2+2)); exit 3");
    assert_eq!(shell(&request.text).status.code(), Some(3));
}

/// `send --pattern '^BENCH_OK$'` (bench round 3, T2): a pattern is matched
/// line by line, so `^` and `$` anchor at each line without `(?m)`.
#[test]
fn w4j_send_pattern_anchors_match_at_each_line() {
    let message = "for i in 1 2 3; do echo step $i; done; echo BENCH_OK";
    let echo = format!("$ {message}");
    let daemon = ShellDaemon::new(
        None,
        vec![shell_record(json!({"activity": {"state": "running"}}))],
        &[&echo, &format!("{echo}\nstep 1\nstep 2\nstep 3\nBENCH_OK\n$ ")],
        true,
    );
    let request = SendRequest { pattern: Some("^BENCH_OK$".into()), ..shell_send(message) };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert_eq!(receipt["matched"], true, "{receipt}");
    assert_eq!(super::send_exit_code(&receipt, false), 0);
}

/// W5-Q (bench r4 #7): a list row says one word for the agent. `state` is
/// the shared status word (`ended` for a session that ended), never the
/// older `busy` or `waiting-for-input`.
#[test]
fn w5q_terminal_list_agents_state_is_the_shared_status_word() {
    let rows = roster::agent_rows(&snapshot());
    for row in &rows {
        let shown = row.to_json(0);
        assert_eq!(shown["state"].as_str(), Some(row.status_word()), "{shown}");
    }
    let words: Vec<String> =
        rows.iter().map(|row| row.to_json(0)["state"].as_str().unwrap_or("").to_owned()).collect();
    assert_eq!(words, ["blocked", "working", "idle"]);
    let mut ended = snapshot();
    ended["agents"][0]["state"] = json!("done");
    let ended = roster::agent_rows(&ended);
    assert_eq!(ended.last().map(|row| row.to_json(0)["state"].clone()), Some(json!("ended")));
}

/// W5-Q: a send that stops at a dialog and a send refused at a dialog say
/// `blocked`, the word every list shows for that agent.
#[test]
fn w5q_send_at_a_dialog_says_blocked() {
    let before = "⏺ OLD_ANSWER_ONE\n\n❯ Reply with exactly ALPHA_OK\n\n⏺ ALPHA_OK\n\n❯ ";
    let daemon = dialog_daemon(&[(1, before), (2, DIALOG_SCREEN)]);
    let receipt =
        send::run(&daemon, None, &quick("Run the shell command `touch /tmp/w4i-perm` now."))
            .expect("sent");
    assert_eq!(receipt["state"], "blocked", "{receipt}");
    let daemon = FakeDaemon::new(snapshot(), &[(1, "")]);
    let request =
        SendRequest { target: "term_c0dec000000000000000000000000004".into(), ..quick("yes") };
    let failure = send::run(&daemon, None, &request).expect_err("refused");
    assert_eq!(failure.failure.error["details"]["state"], "blocked");
}

/// W5-Q: a send whose wait timed out says the agent still works.
#[test]
fn w5q_send_timeout_says_working() {
    let screens: Vec<(u64, String)> =
        (1..400).map(|n| (n, format!("> q\n\nworking {n}"))).collect();
    let screens: Vec<(u64, &str)> = screens.iter().map(|(n, text)| (*n, text.as_str())).collect();
    let daemon = FakeDaemon::new(snapshot(), &screens);
    let request = SendRequest { timeout: Duration::from_millis(100), ..quick("q") };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert_eq!(receipt["timed_out"], true);
    assert_eq!(receipt["state"], "working");
}

const CLAUDE: &str = "term_c1a0de00000000000000000000000001";

/// Claude Code in a narrow pane: the answer and the turn summary wrap at
/// the pane's width, and the input box follows.
const NARROW_ANSWER: &str = "> What is the capital of Australia?\n\n⏺ Canberr\n  a\n\n✻ Churned\n  for 1s · done\n  2:36 PM\n\n─────────────────\n> \n─────────────────\n  ? for shortcuts";

fn idle_hook_record(extra: Value) -> Value {
    json!([{"terminal_id": CLAUDE, "state": "idle", "source": "hook",
            "updated_at_ms": u64::MAX.to_string(), "extra": extra}])
}

/// W5-Q (bench round 4 orchestration friction 6): `send --wait idle`
/// answers the agent's own last message whole as `reply`, the text its
/// Stop hook gave, not the screen's wrapped lines and footer.
#[test]
fn w5q_send_reply_is_the_agents_whole_last_message() {
    let whole = "Canberra is the capital of Australia.\n\nIt was chosen in 1908 as a compromise \
                 between Sydney and Melbourne.";
    let mut daemon = FakeDaemon::new(
        snapshot(),
        &[(1, "> What is the capital of Australia?\n\n✻ Thinking"), (2, NARROW_ANSWER)],
    );
    daemon.agents = idle_hook_record(json!({
        "agent": "claude",
        "last_reply": "Canberra is the capital of Australia. It was chosen in 1908 as a compromise",
        "last_reply_text": whole,
        "last_reply_at_ms": u64::MAX.to_string(),
    }));
    let receipt =
        send::run(&daemon, None, &quick("What is the capital of Australia?")).expect("sent");
    assert_eq!(receipt["state"], "idle", "{receipt}");
    assert_eq!(receipt["reply"], whole, "{receipt}");
    assert_eq!(receipt["reply_source"], "hook", "{receipt}");
}

/// W5-Q: a reply the daemon kept before this send is an older turn's; the
/// reply then comes from the screen, without the harness's footer, even
/// when the turn summary wrapped in a narrow pane.
#[test]
fn w5q_send_reply_from_the_screen_has_no_footer_and_never_an_older_turn() {
    let mut daemon = FakeDaemon::new(
        snapshot(),
        &[(1, "> What is the capital of Australia?\n\n✻ Thinking"), (2, NARROW_ANSWER)],
    );
    daemon.agents = idle_hook_record(json!({
        "agent": "claude",
        "last_reply": "ALPHA_OK",
        "last_reply_text": "ALPHA_OK",
        "last_reply_at_ms": "1",
    }));
    let receipt =
        send::run(&daemon, None, &quick("What is the capital of Australia?")).expect("sent");
    assert_eq!(receipt["reply_source"], "screen", "{receipt}");
    let reply = receipt["reply"].as_str().unwrap_or_else(|| panic!("a reply: {receipt}"));
    assert!(!reply.contains("ALPHA_OK"), "an older turn's reply: {reply}");
    for footer in ["Churned", "for 1s", "2:36 PM", "─", "? for shortcuts"] {
        assert!(!reply.contains(footer), "footer {footer:?} in the reply: {reply:?}");
        let output = receipt["output"].as_str().unwrap_or_default();
        assert!(!output.contains(footer), "footer {footer:?} in the output: {output:?}");
    }
    assert!(reply.starts_with("⏺ Canberr"), "{reply:?}");
}

/// W5-Q (lead decision on PR A findings 6-7): the send receipt's `status`
/// is the word `terminal list --agents` shows for the same turn: `done`
/// while nobody viewed the finished turn (an unread notification), `idle`
/// once somebody did, `blocked` at a dialog, `working` after a timeout.
/// `state` stays as it was.
#[test]
fn w5q_send_receipt_status_is_the_lists_word_for_the_turn() {
    let answer = "> what is 2+2\n\n⏺ 4\n\n──────────────────────\n> \n──────────────────────";
    let screens = [(1, "> what is 2+2\n\n✻ Thinking"), (2, answer)];
    let receipt = send::run(&FakeDaemon::new(snapshot(), &screens), None, &quick("what is 2+2"))
        .expect("sent");
    assert_eq!(
        (receipt["state"].as_str(), receipt["status"].as_str()),
        (Some("idle"), Some("idle"))
    );

    let mut unseen = snapshot();
    unseen["notifications"] = json!([
        {"id": "notification_1", "terminal_id": "term_c1a0de00000000000000000000000001",
         "unread": true, "title": "Claude finished"},
    ]);
    let listed = roster::agent_rows(&unseen);
    let row = listed
        .iter()
        .find(|row| row.terminal == "term_c1a0de00000000000000000000000001")
        .expect("the claude row");
    assert_eq!(row.status_word(), "done");
    let receipt =
        send::run(&FakeDaemon::new(unseen, &screens), None, &quick("what is 2+2")).expect("sent");
    assert_eq!(receipt["state"], "idle", "{receipt}");
    assert_eq!(receipt["status"], row.status_word(), "{receipt}");

    let before = "⏺ OLD_ANSWER_ONE\n\n❯ Reply with exactly ALPHA_OK\n\n⏺ ALPHA_OK\n\n❯ ";
    let daemon = dialog_daemon(&[(1, before), (2, DIALOG_SCREEN)]);
    let receipt =
        send::run(&daemon, None, &quick("Run the shell command `touch /tmp/w4i-perm` now."))
            .expect("sent");
    assert_eq!(receipt["status"], "blocked", "{receipt}");

    let screens: Vec<(u64, String)> =
        (1..400).map(|n| (n, format!("> q\n\nworking {n}"))).collect();
    let screens: Vec<(u64, &str)> = screens.iter().map(|(n, text)| (*n, text.as_str())).collect();
    let daemon = FakeDaemon::new(snapshot(), &screens);
    let request = SendRequest { timeout: Duration::from_millis(100), ..quick("q") };
    let receipt = send::run(&daemon, None, &request).expect("sent");
    assert_eq!(receipt["status"], "working", "{receipt}");
}

/// A [`FakeDaemon`] whose `session.snapshot` reads after the first answer
/// from `later`, in order: `None` is a failed read.
struct LaterSnapshotDaemon {
    inner: FakeDaemon,
    later: RefCell<std::collections::VecDeque<Option<Value>>>,
    read: Cell<bool>,
}

impl Daemon for LaterSnapshotDaemon {
    fn request(&self, session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        let wire = request_value(&plan).expect("valid request");
        if wire["operation"] != "session.snapshot" || !self.read.replace(true) {
            return self.inner.request(session, plan);
        }
        match self.later.borrow_mut().pop_front().flatten() {
            Some(snapshot) => Ok(snapshot),
            None => Err(CallFailure {
                kind: FailureKind::NotRun,
                error: json!({"code": "transport.failed", "message": "read failed",
                              "details": {}, "retryable": true}),
                idempotency_key: None,
            }),
        }
    }
}

/// W5-Q follow-up (PR A review note 4): the receipt's `status` comes from a
/// snapshot read after the wait. When that read fails, the snapshot from
/// before the send is no answer: its old unread notification said `done`
/// for a turn somebody viewed, and it cannot show the new one. The read is
/// tried once more; when that fails too, a finished turn's `status` is
/// `unknown` (#39602 review: `idle` would claim somebody viewed it).
#[test]
fn w5q_send_receipt_status_never_comes_from_the_snapshot_before_the_send() {
    let answer = "> what is 2+2\n\n⏺ 4\n\n──────────────────────\n> \n──────────────────────";
    let screens = [(1, "> what is 2+2\n\n✻ Thinking"), (2, answer)];
    let mut unread = snapshot();
    unread["notifications"] = json!([
        {"id": "notification_1", "terminal_id": "term_c1a0de00000000000000000000000001",
         "unread": true, "title": "Claude finished"},
    ]);
    let send_with = |before: Value, later: Vec<Option<Value>>| {
        let daemon = LaterSnapshotDaemon {
            inner: FakeDaemon::new(before, &screens),
            later: RefCell::new(later.into()),
            read: Cell::new(false),
        };
        send::run(&daemon, None, &quick("what is 2+2")).expect("sent")
    };

    // An old unread notification before the send; both reads after it fail.
    let receipt = send_with(unread.clone(), vec![None, None]);
    assert_eq!(receipt["status"], "unknown", "the old notification gave the status: {receipt}");

    // The first read after the wait fails; the second one shows the new
    // unread notification of this turn.
    let receipt = send_with(snapshot(), vec![None, Some(unread)]);
    assert_eq!(receipt["status"], "done", "the read was not tried again: {receipt}");
}

/// W5-Q follow-up (PR A review note 3): an ended session's row says
/// `status: "ended"`, the word the send receipt says, not null.
#[test]
fn w5q_an_ended_row_of_terminal_list_agents_says_status_ended() {
    let mut ended = snapshot();
    ended["agents"][0]["state"] = json!("done");
    let rows = roster::agent_rows(&ended);
    let last = rows.last().expect("the ended row");
    assert_eq!(last.status_word(), "ended");
    assert_eq!(last.to_json(0)["status"], "ended", "{}", last.to_json(0));
    assert_eq!(last.to_json(0)["state"], "ended", "{}", last.to_json(0));
}

/// W5-Q follow-up (#39580 review): `terminal list --agents` lists the agents
/// of live terminals, and live is an allow-list of lifecycle words
/// (`running`, `launching`, `adopting`). A terminal with another word or
/// with no `lifecycle` field gets no row.
#[test]
fn w5q_terminal_list_agents_lists_only_terminals_whose_lifecycle_says_they_run() {
    let claude = "term_c1a0de00000000000000000000000001";
    let listed = |lifecycle: Option<&str>| {
        let mut snapshot = snapshot();
        match lifecycle {
            Some(word) => snapshot["terminals"][0]["lifecycle"] = json!(word),
            None => {
                if let Some(terminal) = snapshot["terminals"][0].as_object_mut() {
                    terminal.remove("lifecycle");
                }
            }
        }
        roster::agent_rows(&snapshot).iter().any(|row| row.terminal == claude)
    };
    for live in ["running", "launching", "adopting"] {
        assert!(listed(Some(live)), "lifecycle {live}");
    }
    for not_live in [Some("exited"), Some("tombstoned"), Some("suspended"), Some(""), None] {
        assert!(!listed(not_live), "lifecycle {not_live:?}");
    }
}

/// Claude Code's input box after a resume, empty, and then holding a typed
/// message that Enter did not submit (bench round 4, A6: 2 of 2).
const RESUMED_EMPTY: &str = "⏺ P1_FIRST_OK\n\n\
────────────────────────────────────────────────────────────────────────────────\n\
❯\u{a0}\n\
────────────────────────────────────────────────────────────────────────────────\n\
  ⏵⏵ bypass permissions on (shift+tab to cycle)               ● high · /effort";
const RESUMED_UNSENT: &str = "⏺ P1_FIRST_OK\n\n\
────────────────────────────────────────────────────────────────────────────────\n\
❯\u{a0}Reply with exactly P1_RESUMED_OK\n\
────────────────────────────────────────────────────────────────────────────────\n\
  ⏵⏵ bypass permissions on (shift+tab to cycle)               ● high · /effort";

/// Bench round 4 (A6): the first send after `agent resume` typed the message
/// but Enter did not submit it; send answered rc 0, `state idle`, empty
/// output. A message that still sits in the input box once the screen is
/// still, with no report from the agent since Enter, was not submitted:
/// send says so with a typed error, and the caller can press Enter.
#[test]
fn w5r_send_fails_when_enter_left_the_message_in_the_input_box() {
    let mut daemon = FakeDaemon::new(snapshot(), &[(1, RESUMED_EMPTY), (2, RESUMED_UNSENT)]);
    // Only the screen-detection plugin wrote a record after Enter.
    daemon.agents = json!([{"terminal_id": "term_c1a0de00000000000000000000000001",
                            "state": "idle", "source": "plugin",
                            "updated_at_ms": u64::MAX.to_string()}]);
    let failure = send::run(&daemon, None, &quick("Reply with exactly P1_RESUMED_OK"))
        .expect_err("a message left in the input box is no successful send");
    assert_eq!(failure.failure.error["code"], "send.not_submitted", "{:?}", failure.failure.error);
    assert_eq!(failure.exit, 1);
    let details = &failure.failure.error["details"];
    assert_eq!(details["terminal"], "term_c1a0de00000000000000000000000001", "{details}");
    let message = failure.failure.error["message"].as_str().unwrap_or_default();
    assert!(message.contains("keys enter"), "the error says how to submit it: {message}");
    assert_eq!(daemon.writes().len(), 2, "the paste and one Enter, nothing more");
}

/// The same screen after a submit the agent reported (its UserPromptSubmit
/// hook, `working`, then idle): a turn ran, so the send is no failure even
/// when the input box shows text again.
#[test]
fn w5r_send_with_a_reported_turn_is_submitted() {
    let mut daemon = FakeDaemon::new(snapshot(), &[(1, RESUMED_EMPTY), (2, RESUMED_UNSENT)]);
    daemon.agents = json!([{"terminal_id": "term_c1a0de00000000000000000000000001",
                            "state": "idle", "source": "hook",
                            "updated_at_ms": u64::MAX.to_string()}]);
    let receipt = send::run(&daemon, None, &quick("Reply with exactly P1_RESUMED_OK"))
        .expect("an agent-reported turn is a submitted message");
    assert_eq!(receipt["state"], "idle");
}

/// An empty input box after the send is a submitted message.
#[test]
fn w5r_send_with_an_empty_input_box_is_submitted() {
    let daemon = FakeDaemon::new(snapshot(), &[(1, RESUMED_EMPTY), (2, RESUMED_EMPTY)]);
    let receipt =
        send::run(&daemon, None, &quick("Reply with exactly P1_RESUMED_OK")).expect("submitted");
    assert_eq!(receipt["state"], "idle");
}

/// Lead scope (herdr `agent_prompt_stalled`): any send to an agent that
/// reports through hooks must see the agent leave idle after the submit.
/// Here the terminal's agent is a hook agent (the snapshot's record), the
/// screen settles with an empty input box, and no record comes after Enter:
/// the prompt did not start a turn, so the send fails with the typed error
/// once the stall limit passed, never an empty success.
#[test]
fn w5r_send_to_a_hook_agent_that_never_leaves_idle_is_stalled() {
    // The hooks reported this terminal's agent session (W3-H keeps it on the
    // terminal): its agent reports every turn.
    let mut hooked = snapshot();
    if let Some(terminal) = hooked.pointer_mut("/terminals/0") {
        terminal["extra"] = json!({"agent": "claude", "agent_session_id": "5b0e7c1e-0d6c"});
    }
    let daemon = FakeDaemon::new(hooked, &[(1, RESUMED_EMPTY), (2, RESUMED_EMPTY)]);
    // The default 10 s limit, on a fake clock.
    let request = SendRequest {
        timeout: Duration::from_secs(60),
        poll: Duration::from_millis(500),
        ..quick("Reply with exactly P1_RESUMED_OK")
    };
    let failure = send_on_fake_clock(&daemon, &request).expect_err("no turn started");
    assert_eq!(failure.failure.error["code"], "send.not_submitted", "{:?}", failure.failure.error);
    assert_eq!(failure.failure.error["details"]["reason"], "no_agent_report");
}

/// The stall rule on a fake clock: a hook agent's idle screen is no turn's
/// end before it reported the prompt; at the limit with no report it is
/// stalled; one report (the prompt submit hook) lets the screen decide again.
#[test]
fn w5r_settle_stalls_a_silent_hook_agent_at_the_limit_only() {
    let start = Instant::now();
    let at = |ms| start + Duration::from_millis(ms);
    let stall = Duration::from_secs(10);
    let mut settle =
        Settle::new(Wait::Idle, Duration::from_millis(100), start).expecting_report(stall);
    assert_eq!(settle.observe(&idle_sample("1"), at(0)), Verdict::Pending);
    assert_eq!(
        settle.observe(&idle_sample("1"), at(3_000)),
        Verdict::Pending,
        "silent, before the limit"
    );
    assert_eq!(settle.observe(&idle_sample("1"), at(10_000)), Verdict::Stalled);

    let mut settle =
        Settle::new(Wait::Idle, Duration::from_millis(100), start).expecting_report(stall);
    let reported = Sample { agent_reported: true, busy: true, ..idle_sample("2") };
    assert_eq!(settle.observe(&reported, at(900)), Verdict::Pending, "working");
    assert_eq!(settle.observe(&idle_sample("3"), at(4_000)), Verdict::Pending);
    assert_eq!(settle.observe(&idle_sample("3"), at(12_000)), Verdict::Done(AgentState::Idle));
    assert!(settle.reported());

    // A dialog and an exit still end the wait at once.
    let mut settle =
        Settle::new(Wait::Idle, Duration::from_millis(100), start).expecting_report(stall);
    let dialog = Sample { waiting_for_input: true, ..idle_sample("4") };
    assert_eq!(settle.observe(&dialog, at(200)), Verdict::Done(AgentState::Blocked));
    let exited = Sample { exited: true, ..idle_sample("4") };
    assert_eq!(settle.observe(&exited, at(300)), Verdict::Exited);
}

/// A local command of the harness (`/cost`) runs no hook: it is no stall.
#[test]
fn w5r_send_of_a_slash_command_to_a_hook_agent_is_not_stalled() {
    let mut hooked = snapshot();
    if let Some(terminal) = hooked.pointer_mut("/terminals/0") {
        terminal["extra"] = json!({"agent": "claude", "agent_session_id": "5b0e7c1e-0d6c"});
    }
    let daemon = FakeDaemon::new(hooked, &[(1, RESUMED_EMPTY), (2, RESUMED_EMPTY)]);
    let request = SendRequest {
        stall: Duration::from_millis(50),
        timeout: Duration::from_secs(5),
        ..quick("/cost")
    };
    let receipt = send::run(&daemon, None, &request).expect("a local command is sent");
    assert_eq!(receipt["state"], "idle");
}

/// The terminal keeps its agent's session id after the agent quit (W3-H, for
/// resume); a send to the shell there is no hook agent's prompt.
#[test]
fn w5r_send_after_the_agent_quit_is_not_stalled() {
    let mut quit = snapshot();
    if let Some(terminal) = quit.pointer_mut("/terminals/0") {
        terminal["extra"] = json!({"agent": "claude", "agent_session_id": "5b0e7c1e-0d6c"});
    }
    if let Some(agents) = quit.pointer_mut("/agents") {
        *agents = json!([]);
    }
    let daemon = FakeDaemon::new(quit, &[(1, "$ "), (2, "$ echo hi\nhi\n$ ")]);
    let request = SendRequest {
        stall: Duration::from_millis(50),
        timeout: Duration::from_secs(5),
        ..quick("echo hi")
    };
    let receipt = send::run(&daemon, None, &request).expect("a shell send");
    assert_eq!(receipt["state"], "idle");
}

/// A hooked terminal whose agent's own newest record is `state`, reported by
/// harness `harness` before the send.
fn hooked_with(harness: &str, state: &str) -> Value {
    let mut hooked = snapshot();
    if let Some(terminal) = hooked.pointer_mut("/terminals/0") {
        terminal["extra"] = json!({"agent": harness, "agent_session_id": "5b0e7c1e-0d6c"});
    }
    if let Some(record) = hooked.pointer_mut("/agents/0") {
        record["state"] = json!(state);
        record["extra"] = json!({"agent": harness});
    }
    hooked
}

/// Review B2 (W5-R): a message sent to an agent that works queues; no hook
/// reports it until the running turn ends, so a busy agent is no stall.
#[test]
fn w5r_send_to_a_working_hook_agent_is_not_stalled() {
    let daemon = FakeDaemon::new(hooked_with("claude", "working"), &[(1, RESUMED_EMPTY)]);
    let request = SendRequest {
        timeout: Duration::from_secs(60),
        poll: Duration::from_millis(500),
        ..quick("Also check the tests")
    };
    let outcome = send_on_fake_clock(&daemon, &request);
    assert!(
        outcome.as_ref().is_ok_and(|receipt| receipt["sent"] == true),
        "a queued message to a working agent is sent, not stalled: {:?}",
        outcome.err().map(|failure| failure.failure.error)
    );
}

/// Review M2 (W5-R): a harness with no prompt-submit hook (Copilot,
/// CodeBuddy, Factory, Qoder) reports no turn start, so silence is no stall.
#[test]
fn w5r_send_to_a_harness_without_a_prompt_submit_hook_is_not_stalled() {
    for harness in ["copilot", "codebuddy", "factory", "qoder"] {
        let daemon = FakeDaemon::new(hooked_with(harness, "idle"), &[(1, RESUMED_EMPTY)]);
        let request = SendRequest {
            timeout: Duration::from_secs(60),
            poll: Duration::from_millis(500),
            ..quick("Reply with exactly OK")
        };
        let outcome = send_on_fake_clock(&daemon, &request);
        assert!(
            outcome.is_ok(),
            "{harness}: {:?}",
            outcome.err().map(|failure| failure.failure.error)
        );
    }
}

/// Review (W5-R): Claude Code's `!` (shell) and `#` (memory) input runs no
/// prompt hook, like a `/` command.
#[test]
fn w5r_send_of_bang_and_hash_input_to_a_hook_agent_is_not_stalled() {
    for text in ["!git status", "# always run the linter"] {
        let daemon = FakeDaemon::new(hooked_with("claude", "idle"), &[(1, RESUMED_EMPTY)]);
        let request = SendRequest {
            timeout: Duration::from_secs(60),
            poll: Duration::from_millis(500),
            ..quick(text)
        };
        let outcome = send_on_fake_clock(&daemon, &request);
        assert!(
            outcome.is_ok(),
            "{text}: {:?}",
            outcome.err().map(|failure| failure.failure.error)
        );
    }
}

/// Claude Code 2.1.321's permission dialog after a send, as the bench round
/// 5 evaluator read it (`terminal ct5-beta screen read`).
const PERMISSION_CLAUDE_2_1_321: &str = "\
❯ Run the shell command touch /tmp/bench5-perm-cmuxtui-o now.

⏺ Bash(touch /tmp/bench5-perm-cmuxtui-o)
  ⎿  Waiting…

───────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose \"switch to auto mode\" below
 Create empty file in /tmp
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch /tmp/bench5-perm-cmuxtui-o
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend";

/// A daemon whose Claude Code stops on the 2.1.321 permission dialog after
/// the send, with the hook's OSC 7501 record (`kind permission`, `msg`).
fn permission_daemon() -> FakeDaemon {
    let before = "⏺ Canberra\n\n❯ ";
    let mut daemon = dialog_daemon(&[(1, before), (2, PERMISSION_CLAUDE_2_1_321)]);
    daemon.extra = json!({"program_status": [{
        "app": "claude-code", "id": "", "kind": "permission", "state": "blocked",
        "msg": "approve Bash: touch /tmp/bench5-perm-cmuxtui-o",
        "updated_at_ms": u64::MAX.to_string(),
    }]});
    daemon
}

/// W6-C (bench round 5 orchestration row 4): a send that stops on a dialog
/// has no reply (the screen text was no answer), and says what the dialog
/// asks: its kind and message, its options with the keys that pick each,
/// and the keys that deny it. The CLI exits 4, as a blocked `agent start`.
#[test]
fn w6bc_a_blocked_send_has_no_reply_and_a_structured_dialog() {
    let daemon = permission_daemon();
    let message = "Run the shell command `touch /tmp/bench5-perm-cmuxtui-o` now.";
    let receipt = send::run(&daemon, None, &quick(message)).expect("sent");
    assert_eq!(receipt["state"], "blocked", "{receipt}");
    assert!(receipt["reply"].is_null(), "a dialog is no reply: {receipt}");
    assert!(receipt["reply_source"].is_null(), "{receipt}");
    let dialog = &receipt["dialog"];
    assert_eq!(dialog["kind"], "permission", "{receipt}");
    assert_eq!(dialog["msg"], "approve Bash: touch /tmp/bench5-perm-cmuxtui-o", "{receipt}");
    let options = dialog["options"].as_array().cloned().unwrap_or_default();
    assert_eq!(options.len(), 4, "{receipt}");
    assert_eq!(options[0]["label"], "Yes", "{receipt}");
    assert_eq!(options[0]["keys"], json!(["enter"]), "{receipt}");
    assert_eq!(options[3]["label"], "No", "{receipt}");
    assert_eq!(options[3]["keys"], json!(["down", "down", "down", "enter"]), "{receipt}");
    assert_eq!(dialog["deny_keys"], json!(["escape"]), "{receipt}");
    let reason = receipt["reason"].as_str().unwrap_or_default();
    assert!(reason.contains("keys escape"), "{reason}");
    assert_eq!(super::send_exit_code(&receipt, false), 4, "{receipt}");
}

/// W6-C: a send refused because the agent already waits on a dialog exits
/// 4 too, and its error carries the same dialog object.
#[test]
fn w6bc_a_send_refused_at_a_dialog_exits_4_with_the_dialog() {
    let screen = " Do you want to proceed?\n ❯ 1. Yes\n   2. No";
    let daemon = FakeDaemon::new(snapshot(), &[(1, screen)]);
    let request =
        SendRequest { target: "term_c0dec000000000000000000000000004".into(), ..quick("yes") };
    let failure = send::run(&daemon, None, &request).expect_err("refused");
    assert_eq!(failure.exit, 4, "{:?}", failure.failure.error);
    let dialog = &failure.failure.error["details"]["dialog"];
    assert!(dialog["kind"].is_string(), "{dialog}");
    assert_eq!(dialog["options"][1]["label"], "No", "{dialog}");
    assert_eq!(dialog["deny_keys"], json!(["down", "enter"]), "{dialog}");
    // W6-BC review: the message (all that human mode prints) names the
    // dialog's kind, what it asks and the keys that deny it, and never
    // points at JSON fields that human mode does not show.
    let message = failure.failure.error["message"].as_str().unwrap_or_default();
    let kind = dialog["kind"].as_str().unwrap_or("<no kind>");
    assert!(message.contains(kind), "{message}");
    assert!(message.contains("Do you want to proceed?"), "{message}");
    assert!(message.contains("keys down enter"), "{message}");
    assert!(message.contains("--force"), "{message}");
    assert!(!message.contains("deny_keys") && !message.contains('`'), "{message}");
}
