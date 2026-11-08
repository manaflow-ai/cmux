//! What an agent learns about cmux when its session starts in a cmux
//! terminal: that it runs in cmux, the ids of its session, workspace, screen,
//! pane, tab and terminal, and that `cmux skill show` prints the guide.
//!
//! It goes to the model as the `SessionStart` hook's `additionalContext`.
//! Claude Code gets it from the extra `SessionStart` hook the `claude` shim
//! adds (`cmux-tui agent session-context`, claude_wrapper.rs), which runs the
//! build that spawned the pane; Codex from the shim's own `SessionStart` hook
//! (`CMUX_TUI_HOOK_ROUTE=launch`). Hooks installed by `agent hook install`
//! add nothing here, so no agent gets it twice.

use super::*;

/// The whole read (six local requests) stays far below the hook timeouts.
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
    /// The other agents of the session, as [`peers_from`] finds them.
    pub peers: Vec<Peer>,
}

/// Another agent of the caller's session.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub(crate) struct Peer {
    /// Its tab's name when that is an agent name, else its terminal id.
    pub name: String,
    /// `claude`, `codex`, ...
    pub harness: String,
}

/// The session's agents other than `own_terminal` from `agent.list` and
/// `tab.list` records. Not yet: none (W5-Q).
pub(crate) fn peers_from(_agents: &[Value], _tabs: &[Value], _own_terminal: &str) -> Vec<Peer> {
    Vec::new()
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

/// Reads the place of `terminal` from the session at `socket`. Only the
/// terminal is required; the rest is filled as far as the session answers.
pub(crate) fn read(socket: &Path, terminal: &str) -> Place {
    let deadline = Instant::now() + DEADLINE;
    let get = |operation: &str, key: &str, id: &str| {
        inbox::request(socket, operation, json!({ key: id }), false, deadline).ok()
    };
    let text = |record: &Option<Value>, key: &str| {
        record
            .as_ref()
            .and_then(|record| record.get(key))
            .and_then(Value::as_str)
            .map(str::to_owned)
    };
    let mut place = Place { terminal: terminal.to_owned(), ..Place::default() };
    let session = inbox::request(socket, "session.get", json!({}), false, deadline).ok();
    place.session_name = text(&session, "name");
    place.session_id = text(&session, "id");
    let terminal_record = get("terminal.get", "terminal", terminal);
    let Some(tab) = text(&terminal_record, "tab_id") else { return place };
    let tab_record = get("tab.get", "tab", &tab);
    place.tab = Some(tab);
    let Some(pane) = text(&tab_record, "pane_id") else { return place };
    let pane_record = get("pane.get", "pane", &pane);
    place.pane = Some(pane);
    let Some(screen) = text(&pane_record, "screen_id") else { return place };
    let screen_record = get("screen.get", "screen", &screen);
    place.screen = Some(screen);
    let Some(workspace) = text(&screen_record, "workspace_id") else { return place };
    let workspace_record = get("workspace.get", "workspace", &workspace);
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
    format!(
        "cmux: you run in a cmux terminal (a cmux-tui pane). Session {session}; workspace \
         {workspace}; screen {}; pane {}; tab {}; terminal {}. The `cmux` CLI on PATH controls \
         this session, and `current` names your own pane, not the one the person looks at. \
         Run `cmux skill show` for the full agent guide (identity, targeting, `terminal send \
         --wait`, `screen wait`, reads, errors, cleanup) and `cmux --json identify` to check \
         where you are. Do not move the person's focus, type into your own terminal, or close \
         panes you did not open.",
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
    let text = terminal
        .filter(|terminal| terminal.starts_with("term_"))
        .map(|terminal| text(&read(socket, terminal)));
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
            "cmux skill show",
            "cmux --json identify",
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
            peers: vec![
                Peer { name: "alpha".into(), harness: "claude".into() },
                Peer { name: "term_2".into(), harness: "codex".into() },
            ],
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
        assert!(alone.contains("\"$CMUX_TUI_CLI\""), "{alone}");
        assert!(alone.contains("SendMessage"), "{alone}");
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
