//! Where a creation goes when it names no place: the caller's own workspace,
//! never the one the person has focused (Lawrence 2026-11-12: agents opened
//! tabs, browsers, diff viewers and terminals in the focused workspace or in
//! Home). One rule, shared by the CLI and the MCP server, for every caller:
//!
//! - An agent chat (`CMUX_AGENT_SESSION`) or a Chief turn
//!   (`CMUX_CALLER_HOME_CHAT=1`): beside its chat. The app's `beside` answer
//!   (`system.identify`) names the column right of the chat; a tab goes
//!   there, and with no such column a split right of the chat makes it.
//!   Within that column a tab goes to the pane that already holds one of its
//!   kind; a lone pane of another kind (a browser for a terminal) gets a
//!   split below it, the column's lower pane; two or more panes, the lowest.
//!   Never a third column (Leo 2026-10-31: "imo in this case, just open it
//!   on the existing. you only need the rightmost botom auto split when
//!   there's a terminal that gets opened when there's already a browser, and
//!   vice versa"), the app's RightColumnPlacement rule.
//! - A cmux terminal (`CMUX_TUI_TERMINAL_ID`): an app that places terminal
//!   callers ([`app_places_terminals`]) answers the same `beside` for it (the
//!   column right of a terminal that runs an agent, the terminal's own pane
//!   for a plain one). With an older app, or none, the terminal's own pane,
//!   found from the daemon.
//! - An agent chat the app cannot place: the workspace its environment names
//!   (`CMUX_WORKSPACE_ID`), when the request's session has it.
//! - No caller, a caller that cannot be found, or a request to another
//!   session or machine: the daemon's default.
//!
//! This module only decides; each transport sends the requests
//! ([`cli`] for the CLI, mcp/placement.rs for the MCP server).

#![cfg_attr(not(unix), allow(dead_code))]

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value, json};

#[cfg(unix)]
pub(super) mod cli;

/// The parent selectors a creation may name.
pub(super) const PARENTS: [&str; 3] = ["workspace", "screen", "pane"];

/// Where a creation with no place goes, from the app's identity answer.
#[derive(Debug, PartialEq)]
pub(super) enum Placement {
    /// A tab in the existing column right of the chat.
    Pane { workspace: String, pane: String },
    /// The column right of the chat is one pane of another kind: a new pane
    /// split below it, in that column.
    SplitBelow { workspace: String, pane: String },
    /// No column yet: split right of the chat's pane as a new column.
    NewColumn { workspace: String, chat_pane: String },
}

/// Whether a creation names no place, so it goes to the caller's own.
pub(super) fn names_no_place(params: &Map<String, Value>) -> bool {
    PARENTS.iter().all(|key| params.get(*key).is_none())
}

/// The kind of tab a creation makes, for the column's same-kind rule.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    Terminal,
    Browser,
}

impl Kind {
    /// The word the app's `beside.panes[].kinds` uses for it.
    fn word(self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::Browser => "browser",
        }
    }
}

/// The placement `identity` (the app's `system.identify` answer) gives a new
/// terminal, or `None` when the app does not place the caller.
pub(super) fn placement(identity: &Value) -> Option<Placement> {
    placement_of(identity, Kind::Terminal)
}

/// [`placement`] for a new tab of `kind`.
pub(super) fn placement_of(identity: &Value, kind: Kind) -> Option<Placement> {
    let caller = identity.get("caller")?;
    if caller.get("found").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let workspace = caller.get("workspace").and_then(Value::as_str)?.to_owned();
    let beside = identity.get("beside");
    if let Some(pane) = beside.and_then(|beside| beside.get("pane")).and_then(Value::as_str) {
        // `panes`: the whole column, top to bottom, with the kinds each holds (an app
        // that does not list it keeps the first pane, as before). A plain terminal's
        // `own_pane` answer lists none: the tab goes into that pane.
        let column: Vec<(&str, bool)> = beside
            .and_then(|beside| beside.get("panes"))
            .and_then(Value::as_array)
            .map(|panes| {
                panes
                    .iter()
                    .filter_map(|entry| {
                        let id = entry.get("id").and_then(Value::as_str)?;
                        let same = entry
                            .get("kinds")
                            .and_then(Value::as_array)
                            .is_some_and(|kinds| kinds.iter().any(|held| held == kind.word()));
                        Some((id, same))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let chosen = match column.as_slice() {
            [] => Placement::Pane { workspace, pane: pane.to_owned() },
            panes => {
                if let Some((same, _)) = panes.iter().rev().find(|(_, same)| *same) {
                    Placement::Pane { workspace, pane: (*same).to_owned() }
                } else if let [(only, _)] = panes {
                    Placement::SplitBelow { workspace, pane: (*only).to_owned() }
                } else {
                    let lowest = panes.last().map_or(pane, |(id, _)| *id);
                    Placement::Pane { workspace, pane: lowest.to_owned() }
                }
            }
        };
        return Some(chosen);
    }
    let chat_pane = caller.get("pane").and_then(Value::as_str)?.to_owned();
    Some(Placement::NewColumn { workspace, chat_pane })
}

/// Who runs the command, from its environment.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Caller {
    /// `CMUX_AGENT_SESSION`: an agent chat (acpmux sets it for the agent and
    /// its cmux MCP server), which the app places.
    pub agent_session: bool,
    /// `CMUX_CALLER_HOME_CHAT=1`: a Chief turn, whose chat is the Home chat.
    pub home_chat: bool,
    /// `CMUX_TUI_TERMINAL_ID`: the cmux terminal the command runs in.
    pub terminal: Option<String>,
    /// `CMUX_WORKSPACE_ID`: the key of the workspace an agent chat works in
    /// (acpmux gives each workspace agent its own), for a chat the app
    /// cannot place.
    pub workspace_key: Option<String>,
}

impl Caller {
    pub(super) fn from_env(env: impl Fn(&str) -> Option<String>) -> Self {
        let set = |key: &str| env(key).filter(|value| !value.is_empty());
        Self {
            agent_session: set("CMUX_AGENT_SESSION").is_some(),
            // The Chief host names a turn only with "1" (app.rs `caller_from`).
            home_chat: set("CMUX_CALLER_HOME_CHAT").as_deref() == Some("1"),
            terminal: set("CMUX_TUI_TERMINAL_ID"),
            workspace_key: set("CMUX_WORKSPACE_ID"),
        }
    }

    /// The caller of this process.
    pub(super) fn of_process() -> Self {
        Self::from_env(|key| std::env::var(key).ok())
    }

    /// A chat the app places: an agent chat or a Chief turn.
    pub(super) fn is_chat(&self) -> bool {
        self.agent_session || self.home_chat
    }

    /// Whether anything names a caller.
    pub(super) fn is_known(&self) -> bool {
        self.is_chat() || self.terminal.is_some()
    }

    /// The workspace key that stands in for an agent chat the app cannot
    /// place. A terminal caller and a Chief turn have a place of their own
    /// (the terminal's pane, the Home chat), so the key never moves them.
    pub(super) fn fallback_workspace_key(&self) -> Option<&str> {
        self.workspace_key.as_deref().filter(|_| self.agent_session && !self.home_chat)
    }
}

/// The `caller_placement` an app reports in `system.identify` from the
/// version that places terminal callers itself: `beside` for a terminal is
/// the column right of it when it runs an agent and its own pane
/// (`own_pane`) when it does not, and an `openBrowser` run with no target
/// and a terminal caller goes there too.
pub(super) const APP_PLACES_TERMINALS: u64 = 2;

/// Whether `identity` comes from an app that places terminal callers. An
/// older app reports no `caller_placement`; its `beside` for a terminal is
/// always the column right of it, wrong for a person's own terminal.
pub(super) fn app_places_terminals(identity: &Value) -> bool {
    identity
        .get("caller_placement")
        .and_then(Value::as_u64)
        .is_some_and(|version| version >= APP_PLACES_TERMINALS)
}

/// Where the owning app puts a new tab of `kind` that `caller` creates with
/// no place: a chat is always placed by the app; a terminal only by an app
/// that places terminals. `None`: the caller's own pane, found from the
/// daemon ([`fill_place`]).
pub(super) fn app_placement(identity: &Value, caller: &Caller, kind: Kind) -> Option<Placement> {
    if !caller.is_chat() && !app_places_terminals(identity) {
        return None;
    }
    placement_of(identity, kind)
}

/// The caller's own workspace, screen, pane, tab and terminal from the app's
/// `caller` (`system.identify`), keyed by scope; `None` when the app does not
/// place the caller.
pub(super) fn caller_path(identity: &Value) -> Option<Map<String, Value>> {
    let caller = identity.get("caller").and_then(Value::as_object)?;
    if caller.get("found").and_then(Value::as_bool) == Some(false)
        || caller.get("workspace").and_then(Value::as_str).is_none()
    {
        return None;
    }
    let mut path = Map::new();
    for (scope, field) in [
        ("workspace", "workspace"),
        ("screen", "screen"),
        ("pane", "pane"),
        ("tab", "tab"),
        ("terminal", "terminal_id"),
    ] {
        if let Some(id) = caller.get(field).filter(|id| id.is_string()) {
            path.insert(scope.into(), id.clone());
        }
    }
    Some(path)
}

/// The scopes the caller's own place fills in a creation that names none.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Scopes {
    /// Outermost first.
    pub fill: &'static [&'static str],
    /// The creation takes its place only as a whole (a pane with its
    /// parents): a caller place that lacks a scope fills nothing.
    pub whole: bool,
}

/// The typed creations that may name no place, which then act in the
/// caller's own: a tab in its pane, a pane on its screen, a screen or a web
/// link in its workspace. `None` for every other operation.
pub(super) fn creation_scopes(operation: ResourceOperation) -> Option<Scopes> {
    const PANE: &[&str] = &["workspace", "screen", "pane"];
    match operation {
        ResourceOperation::TabCreateTerminal | ResourceOperation::TabCreateBrowser => {
            Some(Scopes { fill: PANE, whole: false })
        }
        // The daemon takes a workspace and a screen only with their pane.
        ResourceOperation::BrowserProfileOpen => Some(Scopes { fill: PANE, whole: true }),
        ResourceOperation::PaneCreate => {
            Some(Scopes { fill: &["workspace", "screen"], whole: false })
        }
        ResourceOperation::ScreenCreate | ResourceOperation::WorkspaceOpenUrl => {
            Some(Scopes { fill: &["workspace"], whole: false })
        }
        _ => None,
    }
}

/// Puts the caller's own place (`path`, ids keyed by scope) into the
/// creation `params`, which names none: each scope from the workspace down
/// while `path` has it. Returns whether `params` changed.
pub(super) fn fill_place(
    params: &mut Map<String, Value>,
    scopes: Scopes,
    path: &Map<String, Value>,
) -> bool {
    let own: Vec<(&str, &Value)> = scopes
        .fill
        .iter()
        .map_while(|scope| path.get(*scope).filter(|id| id.is_string()).map(|id| (*scope, id)))
        .collect();
    if own.is_empty() || (scopes.whole && own.len() < scopes.fill.len()) {
        return false;
    }
    for (scope, id) in own {
        params.insert(scope.into(), id.clone());
    }
    true
}

/// The id of the workspace whose key is `key` (`CMUX_WORKSPACE_ID`, the
/// UUID form of the workspace's `extra.key`, any case, dashed or not) among
/// the `workspace.list` rows `workspaces`.
pub(super) fn workspace_of_key(workspaces: &Value, key: &str) -> Option<String> {
    let plain = |value: &str| -> String {
        value.chars().filter(|ch| *ch != '-').flat_map(char::to_lowercase).collect()
    };
    let wanted = plain(key);
    if wanted.is_empty() {
        return None;
    }
    let rows = workspaces.get("items").unwrap_or(workspaces).as_array()?;
    rows.iter()
        .find(|row| {
            row.pointer("/extra/key")
                .and_then(Value::as_str)
                .is_some_and(|own| plain(own) == wanted)
        })
        .and_then(|row| row.get("id").and_then(Value::as_str))
        .map(str::to_owned)
}

/// The `pane.split` params that open the terminal a `tab.create_terminal`
/// asked for as a new column right of `chat_pane`: its command, directory
/// and size carry over; `name` does not (a split has none), so the caller
/// renames the new tab after.
pub(super) fn split_params(
    create: &Map<String, Value>,
    workspace: &str,
    chat_pane: &str,
) -> Map<String, Value> {
    let mut split = split_below_params(create, workspace, chat_pane);
    split.insert("direction".into(), json!("right"));
    // A column that shares the window with the chat, never one wider than it.
    split.insert("fit".into(), json!(true));
    split
}

/// [`split_params`] for [`Placement::SplitBelow`]: a new pane below `pane`, in
/// its column (no new column, so no viewport width).
pub(super) fn split_below_params(
    create: &Map<String, Value>,
    workspace: &str,
    pane: &str,
) -> Map<String, Value> {
    let mut split = Map::new();
    for key in ["machine", "session", "argv", "shell", "cwd", "cols", "rows", "correlation_key"] {
        if let Some(value) = create.get(key) {
            split.insert(key.into(), value.clone());
        }
    }
    split.insert("workspace".into(), json!(workspace));
    split.insert("pane".into(), json!(pane));
    split.insert("direction".into(), json!("down"));
    split
}

/// The `tab.rename` params that give the split's new tab the name its
/// creation asked for, when it asked for one.
pub(super) fn rename_params(
    create: &Map<String, Value>,
    workspace: &str,
    created: &Value,
) -> Option<Map<String, Value>> {
    let name = create.get("name")?;
    let tab = created.get("tab_id")?;
    let mut rename = Map::new();
    for key in ["machine", "session"] {
        if let Some(value) = create.get(key) {
            rename.insert(key.into(), value.clone());
        }
    }
    rename.insert("workspace".into(), json!(workspace));
    rename.insert("tab".into(), tab.clone());
    rename.insert("name".into(), name.clone());
    Some(rename)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn identity(beside: Value) -> Value {
        json!({
            "caller": {"agent_session": "s", "workspace": "ws_a", "pane": "pane_chat", "screen": "screen_a"},
            "beside": beside,
        })
    }

    #[test]
    fn an_existing_column_right_of_the_chat_takes_the_tab() {
        let placed =
            placement(&identity(json!({"pane": "pane_right", "placement": "existing_column"})));
        assert_eq!(
            placed,
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_right".into() })
        );
    }

    #[test]
    fn no_column_right_of_the_chat_makes_one() {
        let placed = placement(&identity(json!({"pane": null, "placement": "new_column"})));
        assert_eq!(
            placed,
            Some(Placement::NewColumn { workspace: "ws_a".into(), chat_pane: "pane_chat".into() })
        );
    }

    #[test]
    fn a_terminal_goes_to_the_column_pane_that_already_holds_one() {
        let beside = json!({"pane": "pane_web", "placement": "existing_column", "panes": [
            {"id": "pane_web", "kinds": ["browser"]}, {"id": "pane_term", "kinds": ["terminal"]},
        ]});
        assert_eq!(
            placement(&identity(beside)),
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_term".into() })
        );
        let one = json!({"pane": "pane_term", "placement": "existing_column", "panes": [
            {"id": "pane_term", "kinds": ["terminal", "browser"]},
        ]});
        assert_eq!(
            placement(&identity(one)),
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_term".into() })
        );
    }

    #[test]
    fn a_terminal_beside_a_lone_browser_splits_below_it() {
        let beside = json!({"pane": "pane_web", "placement": "existing_column", "panes": [
            {"id": "pane_web", "kinds": ["browser"]},
        ]});
        assert_eq!(
            placement(&identity(beside)),
            Some(Placement::SplitBelow { workspace: "ws_a".into(), pane: "pane_web".into() })
        );
    }

    #[test]
    fn a_full_column_without_a_terminal_takes_its_lowest_pane() {
        let beside = json!({"pane": "pane_a", "placement": "existing_column", "panes": [
            {"id": "pane_a", "kinds": ["browser"]}, {"id": "pane_b", "kinds": []},
        ]});
        assert_eq!(
            placement(&identity(beside)),
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_b".into() })
        );
    }

    #[test]
    fn a_split_below_stays_in_the_column() {
        let create =
            json!({"shell": "make dev", "cwd": "/w"}).as_object().cloned().unwrap_or_default();
        let split = split_below_params(&create, "ws_a", "pane_web");
        assert_eq!(split["pane"], "pane_web");
        assert_eq!(split["direction"], "down");
        assert_eq!(split["shell"], "make dev");
        assert!(split.get("viewport_width").is_none());
    }

    #[test]
    fn a_caller_the_app_does_not_find_has_no_placement() {
        let unfound = json!({"caller": {"agent_session": "s", "found": false}, "beside": null});
        assert_eq!(placement(&unfound), None);
        assert_eq!(placement(&json!({"caller": null})), None);
    }

    #[test]
    fn a_split_keeps_the_command_and_a_rename_carries_the_name() {
        let create = json!({"session": "current", "shell": "make dev", "cwd": "/w", "name": "dev",
                            "cols": 80, "rows": 24})
        .as_object()
        .cloned()
        .unwrap_or_default();
        let split = split_params(&create, "ws_a", "pane_chat");
        assert_eq!(split["shell"], "make dev");
        assert_eq!(split["cwd"], "/w");
        assert_eq!(split["pane"], "pane_chat");
        assert_eq!(split["direction"], "right");
        assert_eq!(split["fit"], true);
        assert!(split.get("viewport_width").is_none());
        assert!(split.get("name").is_none());
        let rename = rename_params(&create, "ws_a", &json!({"tab_id": "tab_new"}));
        assert_eq!(rename.as_ref().map(|r| r["tab"].clone()), Some(json!("tab_new")));
        assert_eq!(rename.as_ref().map(|r| r["name"].clone()), Some(json!("dev")));
        assert!(rename_params(&Map::new(), "ws_a", &json!({"tab_id": "tab_new"})).is_none());
    }
}
