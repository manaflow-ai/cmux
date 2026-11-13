//! What an agent learns about cmux when its session starts in a cmux
//! terminal: that it runs in cmux, the ids of its session, workspace, screen,
//! pane, tab and terminal, that `"$CMUX_TUI_CLI"` is the session's own
//! `cmux` (when the pane sets it to an absolute path; else `cmux`) and
//! `skill show` prints the guide, and which other agents run in the session
//! and how to reach them (W5-Q).
//!
//! It goes to the model as the `SessionStart` hook's `additionalContext`.
//! Claude Code gets it from the extra `SessionStart` hook the `claude` shim
//! adds (`cmux-tui agent session-context`, claude_wrapper.rs), which runs the
//! build that spawned the pane; Codex from the shim's own `SessionStart` hook
//! (`CMUX_TUI_HOOK_ROUTE=launch`). Hooks installed by `agent hook install`
//! add nothing here, so no agent gets it twice.

use super::*;

/// The whole read (eight local requests on one connection) stays far below
/// the hook timeouts.
const DEADLINE: Duration = Duration::from_millis(1500);

/// The caller's place; a field the session did not report stays `None`.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Place {
    pub session_name: Option<String>,
    pub session_id: Option<String>,
    pub workspace: Option<String>,
    pub workspace_name: Option<String>,
    pub screen: Option<String>,
    pub pane: Option<String>,
    pub tab: Option<String>,
    pub terminal: String,
    /// `CMUX_TUI_CLI`: the absolute path of the session's own `cmux`.
    pub cli: Option<String>,
    /// The other agents of the session, as [`peers_from`] finds them;
    /// `None` when the session did not answer the list of its agents. That
    /// is not a session with no other agent.
    pub peers: Option<Vec<Peer>>,
}

/// Another agent of the caller's session.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Peer {
    /// Its tab's name when that is an agent name, else its terminal id.
    pub name: String,
    /// `claude`, `codex`, ...
    pub harness: String,
}

/// The most peers the context names; `agent list` shows every one.
const MAX_PEERS: usize = 12;

/// The session's agents other than `own_terminal`, from `agent.list` and
/// `tab.list` records: terminal agents whose session did not end (the
/// daemon's `done`), once per terminal, named by their tab when that is an
/// agent name (`agent start NAME`) no other tab has, else by terminal id.
/// A harness word outside the agent name rule is `agent`.
pub(crate) fn peers_from(agents: &[Value], tabs: &[Value], own_terminal: &str) -> Vec<Peer> {
    let unique = |name: &str| tabs.iter().filter(|tab| name_of(tab) == Some(name)).count() == 1;
    let tab_name = |terminal: &str| {
        tabs.iter()
            .filter(|tab| tab.get("content_id").and_then(Value::as_str) == Some(terminal))
            .find_map(|tab| name_of(tab).filter(|name| agent_name(name) && unique(name)))
            .map(str::to_owned)
    };
    let mut peers: Vec<Peer> = Vec::new();
    let mut seen = Vec::new();
    for agent in agents {
        let Some(terminal) = agent.get("terminal_id").and_then(Value::as_str) else { continue };
        let state = agent.get("state").and_then(Value::as_str).unwrap_or_default();
        if terminal == own_terminal || state == "done" || seen.contains(&terminal) {
            continue;
        }
        seen.push(terminal);
        let harness = agent
            .pointer("/extra/agent")
            .or_else(|| agent.get("agent"))
            .and_then(Value::as_str)
            .filter(|harness| agent_name(harness))
            .unwrap_or("agent")
            .to_owned();
        let name = tab_name(terminal).unwrap_or_else(|| terminal.to_owned());
        peers.push(Peer { name, harness });
        if peers.len() == MAX_PEERS {
            break;
        }
    }
    peers
}

/// A tab record's name.
fn name_of(tab: &Value) -> Option<&str> {
    tab.get("name").and_then(Value::as_str)
}

/// `agent start`'s name rule: a lowercase letter, then up to 31 lowercase
/// letters, digits, `-` or `_`.
fn agent_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && name.chars().count() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

/// Whether the hook for `source`'s `native_event` carries the context: the
/// Codex shim's own `SessionStart` (the route it names, never an installed
/// hook whose command echoes its own `{}`).
pub(super) fn applies(
    source: &str,
    native_event: &str,
    getenv: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> bool {
    source == "codex"
        && native_event == "SessionStart"
        && getenv(HOOK_ROUTE_ENV).is_some_and(|value| value == "launch")
}

/// Reads the place of `terminal` from the session at `socket`, on one
/// connection. Only the terminal is required; the rest is filled as far as
/// the session answers.
pub(crate) fn read(socket: &Path, terminal: &str) -> Place {
    let deadline = Instant::now() + DEADLINE;
    // One connection for the whole read. When the session does not take it,
    // or a request on it gets no answer, each later record is not known.
    let mut connection = inbox::Connection::open(socket, deadline).ok();
    let mut request = |operation: &str, params: Value| {
        connection.as_mut()?.request(operation, params, false).ok()
    };
    let text = |record: &Option<Value>, key: &str| {
        record
            .as_ref()
            .and_then(|record| record.get(key))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let list = |records: Option<Value>| records.and_then(|records| records.as_array().cloned());
    let mut place = Place { terminal: terminal.to_owned(), ..Place::default() };
    let agents = list(request("agent.list", json!({})));
    // Without the tabs the peers still have an address: their terminal id.
    let tabs = list(request("tab.list", json!({}))).unwrap_or_default();
    place.peers = agents.map(|agents| peers_from(&agents, &tabs, terminal));
    let session = request("session.get", json!({}));
    place.session_name = text(&session, "name");
    place.session_id = text(&session, "id");
    let terminal_record = request("terminal.get", json!({"terminal": terminal}));
    let Some(tab) = text(&terminal_record, "tab_id") else { return place };
    let tab_record = request("tab.get", json!({"tab": tab}));
    place.tab = Some(tab);
    let Some(pane) = text(&tab_record, "pane_id") else { return place };
    let pane_record = request("pane.get", json!({"pane": pane}));
    place.pane = Some(pane);
    let Some(screen) = text(&pane_record, "screen_id") else { return place };
    let screen_record = request("screen.get", json!({"screen": screen}));
    place.screen = Some(screen);
    let Some(workspace) = text(&screen_record, "workspace_id") else { return place };
    let workspace_record = request("workspace.get", json!({"workspace": workspace}));
    place.workspace_name = text(&workspace_record, "name");
    place.workspace = Some(workspace);
    place
}

/// The context text for `place`.
pub(crate) fn text(place: &Place) -> String {
    let id = |value: &Option<String>| value.as_deref().unwrap_or("unknown").to_owned();
    let session = match (&place.session_name, &place.session_id) {
        (Some(name), Some(id)) => format!("`{name}` ({id})"),
        (Some(name), None) => format!("`{name}`"),
        (None, Some(id)) => id.clone(),
        (None, None) => "unknown".to_owned(),
    };
    let workspace = match &place.workspace_name {
        Some(name) if !name.is_empty() => format!("{} (\"{name}\")", id(&place.workspace)),
        _ => id(&place.workspace),
    };
    // `"$CMUX_TUI_CLI"` only when the pane set it to an absolute path; else
    // it runs `""` there, and `cmux` is the one to run.
    let (cmux, own) = match &place.cli {
        Some(path) => (
            "\"$CMUX_TUI_CLI\"",
            format!(
                "Run this session's own cmux as `\"$CMUX_TUI_CLI\"` ({path}); a `cmux` on PATH \
                 can be another, older build."
            ),
        ),
        None => ("cmux", "Run cmux as `cmux`.".to_owned()),
    };
    let peers = match place.peers.as_deref() {
        // No list from the session: it can have other agents.
        None => "Which other agents run in this session is not known now: the session gave no \
                 list of them."
            .to_owned(),
        Some([]) => "No other agent runs in this session now.".to_owned(),
        Some(peers) => {
            let names: Vec<String> =
                peers.iter().map(|peer| format!("{} ({})", peer.name, peer.harness)).collect();
            format!("Other agents in this session: {}.", names.join(", "))
        }
    };
    format!(
        "cmux: you run in a cmux terminal (a cmux-tui pane). Session {session}; workspace \
         {workspace}; screen {}; pane {}; tab {}; terminal {}. {own} `current` names your own \
         pane, not the one the person looks at. Run `{cmux} skill show` for the full agent \
         guide (identity, targeting, `terminal send --wait`, `screen wait`, reads, errors, \
         cleanup) and `{cmux} --json identify` to check where you are. {peers} To talk to an \
         agent of this session, use `{cmux} terminal NAME send --text '...' --wait idle` \
         (`{cmux} agent list` names them); Claude Code's SendMessage and other cross-session \
         tools do not reach them and can reach another person's session. Do not move the \
         person's focus, type into your own terminal, or close panes you did not open.",
        id(&place.screen),
        id(&place.pane),
        id(&place.tab),
        place.terminal,
    )
}

/// The `SessionStart` hook output that adds `text` to the model's context;
/// the empty object without one.
pub(crate) fn output(text: Option<&str>) -> Value {
    match text {
        Some(text) => json!({
            "hookSpecificOutput": {
                "hookEventName": "SessionStart",
                "additionalContext": text,
            }
        }),
        None => json!({}),
    }
}

/// Prints the context for the caller `terminal` of the session at `socket`
/// as the hook's one JSON object (the empty object outside a terminal).
pub(crate) fn print(socket: &Path, terminal: Option<&str>) {
    let cli = env::var("CMUX_TUI_CLI")
        .ok()
        .filter(|path| Path::new(path).is_absolute() && !path.contains(['\n', '\r']));
    let text = terminal
        .filter(|terminal| terminal.starts_with("term_"))
        .map(|terminal| text(&Place { cli: cli.clone(), ..read(socket, terminal) }));
    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{}", output(text.as_deref()));
    let _ = stdout.flush();
}

#[cfg(test)]
mod tests {
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
        assert!(unanswered.contains("agent list"), "{unanswered}");
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

    /// A session on `socket` that serves one connection after the other.
    /// With `busy` it answers each connection with the busy line of a daemon
    /// at its connection limit and then only records what the client still
    /// sends; else it answers each request with `answer` (`None`: an error
    /// reply). The receiver gets a message at the end of each connection.
    #[cfg(unix)]
    fn fake_session(
        socket: &Path,
        busy: bool,
        answer: fn(&str, &Value) -> Option<Value>,
    ) -> (Seen, std::sync::mpsc::Receiver<()>) {
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
                    let mut reply = json!({
                        "protocol": "cmux.protocol/2",
                        "type": "response",
                        "id": request["id"],
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
        let (seen, _at_end) = fake_session(&socket, false, answer);
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
        let (seen, _at_end) = fake_session(&socket, false, answer_with_no_agent_list);
        let place = read(&socket, "term_1");
        assert_eq!(place, whole_place());
        assert!(text(&place).contains("not known"), "{}", text(&place));
        assert_eq!(*seen.lock().unwrap(), [OPERATIONS]);
    }

    /// A daemon at its connection limit answers the connection with the busy
    /// line and closes. The read then sends no other request, on this
    /// connection or on a new one, and knows only the terminal.
    #[cfg(unix)]
    #[test]
    fn agent_start_context_read_sends_nothing_after_the_busy_line() {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("s.sock");
        let (seen, at_end) = fake_session(&socket, true, answer);
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
}
