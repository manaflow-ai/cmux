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
#[path = "session_context_tests.rs"]
mod tests;
