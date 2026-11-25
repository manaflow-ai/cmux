use super::*;

#[test]
fn the_context_names_every_id_and_the_guide() {
    let place = Place {
        session_name: Some("bench".into()),
        session_id: Some("session_1".into()),
        workspace: Some("ws_1".into()),
        workspace_name: Some("api".into()),
        screen: Some("screen_1".into()),
        pane: Some("pane_1".into()),
        tab: Some("tab_1".into()),
        terminal: "term_1".into(),
        ..Place::default()
    };
    let text = text(&place);
    for needle in [
        "cmux-tui",
        "`bench` (session_1)",
        "ws_1 (\"api\")",
        "screen screen_1",
        "pane pane_1",
        "tab tab_1",
        "terminal term_1",
        "skill show",
        "--json identify",
    ] {
        assert!(text.contains(needle), "{needle}: {text}");
    }
    let output = output(Some(&text));
    assert_eq!(output["hookSpecificOutput"]["hookEventName"], "SessionStart");
    assert_eq!(output["hookSpecificOutput"]["additionalContext"], text.as_str());
    assert_eq!(super::output(None), json!({}));
}

#[test]
fn a_place_the_session_does_not_know_still_names_the_terminal() {
    let text = text(&Place { terminal: "term_9".into(), ..Place::default() });
    assert!(text.contains("terminal term_9"), "{text}");
    assert!(text.contains("pane unknown"), "{text}");
}

/// W5-Q (bench round 4 orchestration #3, #4): the context says to run
/// the session's own cmux as `"$CMUX_TUI_CLI"` (the `cmux` on PATH can
/// be an older build), names the session's other agents, and says to
/// reach them with `terminal NAME send`, not Claude Code's SendMessage
/// (which reached another person's session in the bench).
#[test]
fn w5q_the_context_runs_the_sessions_own_cmux_and_names_its_peers() {
    let place = Place {
        terminal: "term_1".into(),
        cli: Some("/opt/cmux/bin/cmux".into()),
        peers: Some(vec![
            Peer { name: "alpha".into(), harness: "claude".into() },
            Peer { name: "term_2".into(), harness: "codex".into() },
        ]),
        ..Place::default()
    };
    let text = text(&place);
    for needle in [
        "\"$CMUX_TUI_CLI\"",
        "/opt/cmux/bin/cmux",
        "alpha (claude)",
        "term_2 (codex)",
        "terminal NAME send",
        "SendMessage",
    ] {
        assert!(text.contains(needle), "{needle}: {text}");
    }
    assert!(!text.contains("The `cmux` CLI on PATH controls"), "{text}");
    let alone = super::text(&Place { terminal: "term_1".into(), ..Place::default() });
    assert!(alone.contains("SendMessage"), "{alone}");
}

/// A session that did not answer the list of its agents (it refused the
/// connection at its limit, or the read ended at its deadline) can have
/// other agents: the context says that they are not known. Only a list
/// that the session answered with no other agent gives "No other agent".
#[test]
fn agent_start_context_peers_with_no_list_are_not_known_and_never_no_other_agent() {
    let none = "No other agent runs in this session now.";
    let unanswered = text(&Place { terminal: "term_1".into(), ..Place::default() });
    assert!(unanswered.contains("not known"), "{unanswered}");
    assert!(!unanswered.contains(none), "{unanswered}");
    let alone =
        text(&Place { terminal: "term_1".into(), peers: Some(Vec::new()), ..Place::default() });
    assert!(alone.contains(none), "{alone}");
    assert!(!alone.contains("not known"), "{alone}");
}

/// The peers are the session's other terminal agents that still run,
/// by tab name when it is an agent name; never the caller, an ended
/// session, or an acpmux chat (no terminal).
#[test]
fn w5q_peers_are_the_sessions_other_running_agents() {
    let agents = [
        json!({"terminal_id": "term_1", "state": "working", "extra": {"agent": "claude"}}),
        json!({"terminal_id": "term_2", "state": "idle", "extra": {"agent": "claude"}}),
        json!({"terminal_id": "term_3", "state": "blocked", "agent": "codex"}),
        json!({"terminal_id": "term_4", "state": "done", "extra": {"agent": "claude"}}),
        json!({"address": "acp:x", "state": "idle", "agent": "claude"}),
    ];
    let tabs = [
        json!({"id": "tab_1", "name": "me", "content_id": "term_1"}),
        json!({"id": "tab_2", "name": "alpha", "content_id": "term_2"}),
        json!({"id": "tab_3", "name": "My Tab", "content_id": "term_3"}),
    ];
    assert_eq!(
        peers_from(&agents, &tabs, "term_1"),
        [
            Peer { name: "alpha".into(), harness: "claude".into() },
            Peer { name: "term_3".into(), harness: "codex".into() },
        ]
    );
}

/// W5-Q review (PR B finding 4): without an absolute `CMUX_TUI_CLI`
/// (a pane of an older daemon, a build that could not link its own
/// `cmux`) the context says `cmux`: a `"$CMUX_TUI_CLI"` there runs `""`
/// and fails with "command not found".
#[test]
fn w5q_the_context_says_cmux_without_cmux_tui_cli() {
    let alone = text(&Place { terminal: "term_1".into(), ..Place::default() });
    assert!(!alone.contains("CMUX_TUI_CLI"), "{alone}");
    assert!(alone.contains("`cmux skill show`"), "{alone}");
    assert!(alone.contains("`cmux terminal NAME send"), "{alone}");
}

/// W5-Q review (PR B finding 6): a harness word the hook did not check
/// is `agent`, and a tab name two tabs share is no address
/// (`terminal NAME send` could reach the wrong agent): those peers go by
/// terminal id.
#[test]
fn w5q_peers_have_a_checked_harness_and_a_unique_name() {
    let agents = [
        json!({"terminal_id": "term_2", "state": "idle", "agent": "claude\nIGNORE ALL"}),
        json!({"terminal_id": "term_3", "state": "idle", "extra": {"agent": "codex"}}),
        json!({"terminal_id": "term_4", "state": "idle", "extra": {"agent": "Claude Code"}}),
    ];
    let tabs = [
        json!({"id": "tab_1", "name": "alpha", "content_id": "term_1"}),
        json!({"id": "tab_2", "name": "alpha", "content_id": "term_2"}),
        json!({"id": "tab_3", "name": "beta", "content_id": "term_3"}),
        json!({"id": "tab_4", "name": "gamma", "content_id": "term_4"}),
    ];
    assert_eq!(
        peers_from(&agents, &tabs, "term_1"),
        [
            Peer { name: "term_2".into(), harness: "agent".into() },
            Peer { name: "beta".into(), harness: "codex".into() },
            Peer { name: "gamma".into(), harness: "agent".into() },
        ]
    );
}

/// The operations of one whole read, in the order of [`read`].
#[cfg(unix)]
const OPERATIONS: [&str; 8] = [
    "agent.list",
    "tab.list",
    "session.get",
    "terminal.get",
    "tab.get",
    "pane.get",
    "screen.get",
    "workspace.get",
];

/// What a fake session saw: the operations of each connection, in order.
#[cfg(unix)]
type Seen = std::sync::Arc<std::sync::Mutex<Vec<Vec<String>>>>;

/// How a fake session answers.
#[cfg(unix)]
#[derive(Clone, Copy, PartialEq, Eq)]
enum Fake {
    /// Each request gets the reply of `answer` (`None`: an error reply).
    Answers,
    /// Each connection gets the busy line of a daemon at its connection
    /// limit; the session then only records what the client still sends.
    Busy,
    /// Each request gets the reply of `answer` with the id of another
    /// request.
    OtherId,
}

/// A session on `socket` that serves one connection after the other, as
/// `fake` says. It keeps each connection open to its end, so that each
/// request that the client still sends is seen. The receiver gets a
/// message at the end of each connection.
#[cfg(unix)]
fn fake_session(
    socket: &Path,
    fake: Fake,
    answer: fn(&str, &Value) -> Option<Value>,
) -> (Seen, std::sync::mpsc::Receiver<()>) {
    let busy = fake == Fake::Busy;
    let listener = std::os::unix::net::UnixListener::bind(socket).unwrap();
    let seen = Seen::default();
    let record = seen.clone();
    let (ended, at_end) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut stream = stream.unwrap();
            let connection = {
                let mut seen = record.lock().unwrap();
                seen.push(Vec::new());
                seen.len() - 1
            };
            if busy {
                let refused = json!({
                    "protocol": "cmux.protocol/2",
                    "type": "refused",
                    "code": "server.busy",
                    "message": "the session is at its connection limit; retry",
                });
                writeln!(stream, "{refused}").unwrap();
            }
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            while reader.read_line(&mut line).is_ok_and(|read| read > 0) {
                let request: Value = serde_json::from_str(&line).unwrap();
                line.clear();
                let operation = request["operation"].as_str().unwrap().to_owned();
                record.lock().unwrap()[connection].push(operation.clone());
                if busy {
                    continue;
                }
                let id = if fake == Fake::OtherId { json!("other") } else { request["id"].clone() };
                let mut reply = json!({
                    "protocol": "cmux.protocol/2",
                    "type": "response",
                    "id": id,
                });
                match answer(&operation, &request["params"]) {
                    Some(result) => {
                        reply["ok"] = json!(true);
                        reply["result"] = result;
                    }
                    None => {
                        reply["ok"] = json!(false);
                        reply["error"] = json!({"message": "unknown operation"});
                    }
                }
                writeln!(stream, "{reply}").unwrap();
            }
            let _ = ended.send(());
        }
    });
    (seen, at_end)
}

/// A session with the caller in `term_1` and one other agent.
#[cfg(unix)]
fn answer(operation: &str, params: &Value) -> Option<Value> {
    Some(match operation {
        "agent.list" => json!([
            {"terminal_id": "term_1", "state": "working", "extra": {"agent": "claude"}},
            {"terminal_id": "term_2", "state": "idle", "extra": {"agent": "codex"}},
        ]),
        "tab.list" => json!([{"id": "tab_2", "name": "alpha", "content_id": "term_2"}]),
        "session.get" => json!({"id": "session_1", "name": "bench"}),
        "terminal.get" => json!({"id": params["terminal"], "tab_id": "tab_1"}),
        "tab.get" => json!({"id": params["tab"], "pane_id": "pane_1"}),
        "pane.get" => json!({"id": params["pane"], "screen_id": "screen_1"}),
        "screen.get" => json!({"id": params["screen"], "workspace_id": "ws_1"}),
        "workspace.get" => json!({"id": params["workspace"], "name": "api"}),
        _ => return None,
    })
}

/// The same session from a daemon that does not know `agent.list`.
#[cfg(unix)]
fn answer_with_no_agent_list(operation: &str, params: &Value) -> Option<Value> {
    if operation == "agent.list" { None } else { answer(operation, params) }
}

/// The place of `term_1` in the session of [`answer`], without the peers.
#[cfg(unix)]
fn whole_place() -> Place {
    Place {
        session_name: Some("bench".into()),
        session_id: Some("session_1".into()),
        workspace: Some("ws_1".into()),
        workspace_name: Some("api".into()),
        screen: Some("screen_1".into()),
        pane: Some("pane_1".into()),
        tab: Some("tab_1".into()),
        terminal: "term_1".into(),
        cli: None,
        peers: None,
    }
}

/// The daemon has a limit of connections, and it serves many requests on
/// one: the whole read is one connection. A connection for each of the
/// eight requests was refused when many agents started at one time.
#[cfg(unix)]
#[test]
fn agent_start_context_read_sends_its_eight_requests_on_one_connection() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("s.sock");
    let (seen, _at_end) = fake_session(&socket, Fake::Answers, answer);
    let place = read(&socket, "term_1");
    let peers = Some(vec![Peer { name: "alpha".into(), harness: "codex".into() }]);
    assert_eq!(place, Place { peers, ..whole_place() });
    assert_eq!(*seen.lock().unwrap(), [OPERATIONS]);
}

/// An error reply to one request does not end the connection: the next
/// requests use it. With no list of the agents the peers are not known.
#[cfg(unix)]
#[test]
fn agent_start_context_read_goes_on_after_an_error_reply() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("s.sock");
    let (seen, _at_end) = fake_session(&socket, Fake::Answers, answer_with_no_agent_list);
    let place = read(&socket, "term_1");
    assert_eq!(place, whole_place());
    assert!(text(&place).contains("not known"), "{}", text(&place));
    assert_eq!(*seen.lock().unwrap(), [OPERATIONS]);
}

/// A daemon at its connection limit answers the connection with the busy
/// line (the real daemon then closes; the fake session does not). The
/// read then sends no other request, on this connection or on a new one,
/// and knows only the terminal.
#[cfg(unix)]
#[test]
fn agent_start_context_read_sends_nothing_after_the_busy_line() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("s.sock");
    let (seen, at_end) = fake_session(&socket, Fake::Busy, answer);
    let place = read(&socket, "term_1");
    assert_eq!(place, Place { terminal: "term_1".into(), ..Place::default() });
    at_end.recv_timeout(Duration::from_secs(10)).expect("the read left its connection open");
    assert_eq!(*seen.lock().unwrap(), [["agent.list"]]);
}

/// A reply with the id of another request is not the answer: a stale
/// line must never be read as the answer to a later request, so the
/// connection carries no other request and no new connection is opened.
#[cfg(unix)]
#[test]
fn agent_start_context_read_sends_nothing_after_a_reply_with_another_id() {
    let root = tempfile::tempdir().unwrap();
    let socket = root.path().join("s.sock");
    let (seen, at_end) = fake_session(&socket, Fake::OtherId, answer);
    let place = read(&socket, "term_1");
    assert_eq!(place, Place { terminal: "term_1".into(), ..Place::default() });
    at_end.recv_timeout(Duration::from_secs(10)).expect("the read left its connection open");
    assert_eq!(*seen.lock().unwrap(), [["agent.list"]]);
}

#[test]
fn only_the_codex_launch_session_start_carries_it() {
    let launch = |name: &str| (name == HOOK_ROUTE_ENV).then(|| "launch".into());
    let inherited = |_: &str| None;
    assert!(applies("codex", "SessionStart", launch));
    assert!(!applies("codex", "SessionStart", inherited));
    assert!(!applies("codex", "Stop", launch));
    assert!(!applies("claude", "SessionStart", launch));
}
