//! Where a creation goes when it names no place: the caller's own workspace,
//! never the one the person has focused (Lawrence 2026-11-12: agents opened
//! tabs, browsers, diff viewers and terminals in the focused workspace or in
//! Home). One rule, shared by the CLI and the MCP server, for every caller:
//!
//! - An agent chat (`CMUX_AGENT_SESSION`) or a Chief turn
//!   (`CMUX_CALLER_HOME_CHAT=1`): beside its chat. The app's `beside` answer
//!   (`system.identify`) names the column right of the chat; a tab goes
//!   there, and with no pane there a new one is made directly right of the
//!   chat: a split of its pane, or for a docked chat (which cannot split) a
//!   strip column that shares the window.
//!   Within that column a tab goes to the pane that already holds one of its
//!   kind; a lone pane of another kind (a browser for a terminal) gets a
//!   split below it, the column's lower pane; two or more panes, the lowest.
//!   Never a third column (Leo 2026-10-31: "imo in this case, just open it
//!   on the existing. you only need the rightmost botom auto split when
//!   there's a terminal that gets opened when there's already a browser, and
//!   vice versa"), the app's RightColumnPlacement rule.
//! - A browser created with no place (`cmux browser open URL`, `cmux tab
//!   create browser`, `cmux browser profile open`) by anyone, an agent or a
//!   person's terminal, is a tab in the column right of the caller when there
//!   is one (the pane holding a browser, else the lowest), never a split
//!   below it and never over an agent's terminal (Lawrence 2026-11-15).
//!   A plain terminal's browser opens right of it too: in the pane on its
//!   right, else a new pane beside it, where a Cmd-click there opens a link.
//! - A cmux terminal (`CMUX_TUI_TERMINAL_ID`), for a new terminal: an app that places terminal
//!   callers ([`app_places_terminals`]) answers the same `beside` for it (the
//!   column right of a terminal that runs an agent, the terminal's own pane
//!   for a plain one). With an older app, or none, the terminal's own pane,
//!   found from the daemon.
//! - An agent chat no tab shows: the workspace its session runs in
//!   (`CMUX_WORKSPACE_ID`). The app that owns the daemon resolves that key
//!   (the caller names it, app.rs `caller_from`); in a session no app owns,
//!   the CLI reads it from the daemon. An agent the owning app cannot place
//!   at all is refused (`caller_unavailable`): its tabs never go to the
//!   focused workspace or Home (Lawrence 2026-11-18).
//! - No caller, a terminal that cannot be found, or a request to another
//!   session or machine: the daemon's default.
//!
//! A retry never makes a second surface. The placement is decided again on
//! every try, and the layout the first try changed can give another answer
//! (a new column the first time, a tab in that column the second). So the
//! one creation of a request is named by its key in the daemon (the
//! creation's `correlation_key`: [`correlation_key`]), each transport looks
//! that creation up before it decides again ([`earlier_creation`]), and the
//! daemon refuses a second creation of another shape under the same key.
//! A split right that the daemon refuses for its agent chat dock becomes a
//! column in the same command ([`column_after_refusal`]); the refused split
//! keeps the key, so the column has the second of [`creation_keys`], and a
//! retry looks both up.
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
    /// No pane right of a docked chat (Home's, an agent chat's dock), which
    /// cannot split: a new strip column right of it that shares the window.
    /// Also for an app that does not say whether the caller is docked
    /// (`caller.docked`), as before.
    NewColumn { workspace: String, chat_pane: String },
    /// No pane right of a caller that is not docked: a new pane split off
    /// the right of the caller's own pane, directly beside it, as the app
    /// makes one. A strip column goes after the caller's whole column: with
    /// another pane split off the caller's right (another agent's home), the
    /// column landed past that pane, the right-of relation never found it,
    /// and every creation made one more column.
    SplitRight { workspace: String, pane: String },
    /// A browser from a plain terminal, whose right side the app does not
    /// report (`own_pane`): the panes right of `pane`, by the same-kind
    /// rule, else a new pane right of it. The transport reads those panes
    /// from the daemon ([`right_of`]). The daemon knows no more: the
    /// person's link placement setting is the app's alone. `docked` is the
    /// app's `caller.docked`: a shell can run in the pane Split Down makes
    /// below a docked agent chat, and a dock takes no split to the right.
    RightOf { workspace: String, pane: String, docked: Option<bool> },
}

/// Whether a creation names no place, so it goes to the caller's own.
pub(super) fn names_no_place(params: &Map<String, Value>) -> bool {
    PARENTS.iter().all(|key| params.get(*key).is_none())
}

/// The kind of tab a creation makes, for the same-kind rule ([`same_kind`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Kind {
    Terminal,
    Browser,
}

impl Kind {
    /// The word the app's `beside.panes[].kinds` and a tab's `content_kind`
    /// use for it.
    fn word(self) -> &'static str {
        match self {
            Self::Terminal => "terminal",
            Self::Browser => "browser",
        }
    }
}

/// The placement `identity` (the app's `system.identify` answer) gives, or
/// `None` when the app does not place the caller.
pub(super) fn placement(identity: &Value) -> Option<Placement> {
    same_kind_placement(identity, Kind::Terminal)
}

/// [`placement`] for a new tab of `kind`: in the panes right of the caller
/// (`beside.panes`, top to bottom, with the kinds each holds), the same-kind
/// rule ([`same_kind`]); with none there, a new pane right of the caller
/// ([`new_pane_right`]).
fn same_kind_placement(identity: &Value, kind: Kind) -> Option<Placement> {
    let caller = identity.get("caller")?;
    if caller.get("found").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let workspace = caller.get("workspace").and_then(Value::as_str)?.to_owned();
    let beside = identity.get("beside");
    if let Some(pane) = beside.and_then(|beside| beside.get("pane")).and_then(Value::as_str) {
        // `panes`: the whole column, top to bottom, with the kinds each holds (an app
        // that does not list it keeps the first pane, as before).
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
        return Some(same_kind(workspace, pane, &column));
    }
    let pane = caller.get("pane").and_then(Value::as_str)?.to_owned();
    Some(new_pane_right(docked(caller), workspace, pane))
}

/// The app's `caller.docked`: whether the caller's pane is in a left or
/// right dock. `None` for an app that does not say.
fn docked(caller: &Value) -> Option<bool> {
    caller.get("docked").and_then(Value::as_bool)
}

/// The new pane right of a caller whose pane is `pane`, for every caller
/// kind: a plain split of that pane when the app says the caller is not
/// docked (`docked`: `Some(false)`), else a strip column that shares the
/// window (a dock cannot split; an older app does not say). The daemon has
/// its own dock rule, which can refuse the plain split of a caller the app
/// calls not docked: the send step then makes the column
/// ([`column_after_refusal`]).
fn new_pane_right(docked: Option<bool>, workspace: String, pane: String) -> Placement {
    if docked == Some(false) {
        Placement::SplitRight { workspace, pane }
    } else {
        Placement::NewColumn { workspace, chat_pane: pane }
    }
}

/// The same-kind rule for a new tab in the panes right of the caller
/// (`column`: each pane's id, top to bottom, and whether it already holds a
/// tab of the new tab's kind; `pane`: the first of them, for a caller that
/// lists none): a tab in the lowest pane that holds the kind; else a split
/// below a lone pane of another kind; else a tab in the lowest pane. Never a
/// third column (the app's RightColumnPlacement).
pub(super) fn same_kind(workspace: String, pane: &str, column: &[(&str, bool)]) -> Placement {
    match column {
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
    }
}

/// For an app from before `caller_placement` (the CLI names no pane for an
/// app that places every caller itself, beside/cli.rs): where a browser tab
/// created with no place goes (`cmux browser open URL`,
/// `cmux tab create browser`), from the app's identity answer: a tab in the
/// existing column right of the caller, in the pane there that already holds
/// a browser, else the column's lowest pane, never a split below it and never
/// the caller's own pane (Lawrence 2026-11-15: an agent's `cmux browser open`
/// of its page put the tab over the terminal it ran in, "i expected it to just
/// open in the right side"). `None` with no column on the right: the creation
/// keeps the daemon's default (a split would make a terminal pane first).
pub(super) fn browser_placement(identity: &Value) -> Option<Placement> {
    let caller = identity.get("caller")?;
    if caller.get("found").and_then(Value::as_bool) == Some(false) {
        return None;
    }
    let workspace = caller.get("workspace").and_then(Value::as_str)?.to_owned();
    let beside = identity.get("beside")?;
    // `own_pane` names the caller's own pane, not a column right of it: a
    // browser never opens over the terminal that asked for it.
    if own_pane(identity).is_some() {
        return None;
    }
    let pane = beside.get("pane").and_then(Value::as_str)?;
    let column: Vec<(&str, bool)> = beside
        .get("panes")
        .and_then(Value::as_array)
        .map(|panes| {
            panes
                .iter()
                .filter_map(|entry| {
                    let id = entry.get("id").and_then(Value::as_str)?;
                    let browser = entry
                        .get("kinds")
                        .and_then(Value::as_array)
                        .is_some_and(|kinds| kinds.iter().any(|kind| kind == "browser"));
                    Some((id, browser))
                })
                .collect()
        })
        .unwrap_or_default();
    let chosen = column
        .iter()
        .rev()
        .find(|(_, browser)| *browser)
        .or(column.last())
        .map_or(pane, |(id, _)| *id);
    Some(Placement::Pane { workspace, pane: chosen.to_owned() })
}

/// The caller's own pane when the app answers `own_pane`: the caller is a
/// terminal no agent runs in (a person's shell, a script), and `beside.pane`
/// is that terminal's pane. A new terminal opens there as a tab.
fn own_pane(identity: &Value) -> Option<&str> {
    let beside = identity.get("beside")?;
    (beside.get("placement").and_then(Value::as_str) == Some("own_pane"))
        .then(|| beside.get("pane").and_then(Value::as_str))
        .flatten()
}

/// [`Placement::RightOf`] the caller's own pane, for an `own_pane` answer.
fn right_of_own_pane(identity: &Value) -> Option<Placement> {
    let pane = own_pane(identity)?.to_owned();
    let caller = identity.get("caller")?;
    let workspace = caller.get("workspace").and_then(Value::as_str)?.to_owned();
    Some(Placement::RightOf { workspace, pane, docked: docked(caller) })
}

/// The placement `identity` gives a new tab of `kind` whose pane this CLI
/// makes itself when there is none (a terminal, a profile browser tab): the
/// same-kind rule in the panes right of the caller, else a new pane there. A
/// browser from a plain terminal (`own_pane`) goes right of the terminal
/// too ([`Placement::RightOf`]); a terminal from a plain terminal is a tab
/// in its own pane.
pub(super) fn placement_of(identity: &Value, kind: Kind) -> Option<Placement> {
    match kind {
        Kind::Terminal => placement(identity),
        Kind::Browser => {
            right_of_own_pane(identity).or_else(|| same_kind_placement(identity, Kind::Browser))
        }
    }
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
/// no place. A new terminal: a chat is always placed by the app; a terminal
/// caller only by an app that places terminals (an older app answers
/// `new_column` for a person's shell too). A browser goes right of any
/// caller the app finds, whatever the app's version. `None`: the caller's
/// own pane, found from the daemon ([`fill_place`]).
pub(super) fn app_placement(identity: &Value, caller: &Caller, kind: Kind) -> Option<Placement> {
    match kind {
        Kind::Terminal => (caller.is_chat() || app_places_terminals(identity))
            .then(|| placement(identity))
            .flatten(),
        Kind::Browser => placement_of(identity, Kind::Browser),
    }
}

/// The `pane.neighbor.get` params that ask the session of `create` for the
/// pane on the `direction` side of `pane`.
fn neighbor_params(create: &Map<String, Value>, pane: &str, direction: &str) -> Map<String, Value> {
    let mut lookup = session_route(create);
    lookup.insert("pane".into(), json!(pane));
    lookup.insert("direction".into(), json!(direction));
    lookup
}

/// [`neighbor_params`] for the pane right of `pane`.
pub(super) fn right_neighbor_params(create: &Map<String, Value>, pane: &str) -> Map<String, Value> {
    neighbor_params(create, pane, "right")
}

/// The machine and session selectors of `create`.
fn session_route(create: &Map<String, Value>) -> Map<String, Value> {
    ["machine", "session"]
        .into_iter()
        .filter_map(|key| create.get(key).map(|value| (key.to_owned(), value.clone())))
        .collect()
}

/// How many panes above and below the right neighbor [`right_of`] reads.
const COLUMN_WALK: usize = 6;

/// [`Placement::RightOf`] made concrete with reads of the daemon (`read`:
/// one read of the session of `create`, `None` when it fails): the panes
/// right of the caller's `pane` are its right neighbor and the panes above
/// and below that one whose own left neighbor is the caller's pane. A pane
/// below both (a full-width pane under the caller and its neighbor) or one
/// diagonal to the caller (the lower pane of the next column, beside the
/// pane under the caller) is not right of the caller and is never counted.
/// One of them is an agent's home ([`holds_agent`]): a new pane right of the
/// caller, as the app does. Else the same-kind rule for a browser
/// ([`same_kind`]). Nothing on the right: a new pane there. The new pane is
/// the one every caller kind gets ([`new_pane_right`], with the caller's
/// `docked`): the terminal can be in a dock (the pane Split Down makes below
/// a docked agent chat), which takes no split to the right.
pub(super) fn right_of(
    create: &Map<String, Value>,
    workspace: String,
    pane: String,
    docked: Option<bool>,
    read: &mut dyn FnMut(ResourceOperation, Map<String, Value>) -> Option<Value>,
) -> Placement {
    let mut neighbor = |of: &str, direction: &str| {
        read(ResourceOperation::PaneNeighborGet, neighbor_params(create, of, direction))
            .and_then(|answer| neighbor_pane(&answer))
    };
    let Some(right) = neighbor(&pane, "right") else {
        return new_pane_right(docked, workspace, pane);
    };
    let mut column = vec![right.clone()];
    for direction in ["up", "down"] {
        let mut at = right.clone();
        for _ in 0..COLUMN_WALK {
            let Some(next) =
                neighbor(&at, direction).filter(|next| *next != pane && !column.contains(next))
            else {
                break;
            };
            // Right of the caller: it touches the caller's right edge.
            if neighbor(&next, "left").as_deref() != Some(pane.as_str()) {
                break;
            }
            if direction == "up" {
                column.insert(0, next.clone());
            } else {
                column.push(next.clone());
            }
            at = next;
        }
    }
    let agents = read(ResourceOperation::AgentList, session_route(create)).unwrap_or(Value::Null);
    let mut holds_browser = Vec::with_capacity(column.len());
    for id in &column {
        let mut tabs = session_route(create);
        tabs.insert("pane".into(), json!(id));
        let tabs = read(ResourceOperation::TabList, tabs).unwrap_or(Value::Null);
        if holds_agent(&tabs, &agents) {
            return new_pane_right(docked, workspace, pane);
        }
        let browser = rows(&tabs).iter().any(|tab| {
            tab.get("content_kind").and_then(Value::as_str) == Some(Kind::Browser.word())
        });
        holds_browser.push(browser);
    }
    let kinds: Vec<(&str, bool)> = column.iter().map(String::as_str).zip(holds_browser).collect();
    same_kind(workspace, &right, &kinds)
}

/// The rows of a list answer (`[…]`, `{items}`, `{agents}` or `{value}`).
fn rows(answer: &Value) -> &[Value] {
    ["items", "agents", "value"]
        .iter()
        .find_map(|key| answer.get(*key).and_then(Value::as_array))
        .or(answer.as_array())
        .map_or(&[], Vec::as_slice)
}

/// Whether a pane is an agent's home, by the app's rule
/// (ControlCallerPlacement `isAnotherAgent`): one of its `tabs` (a
/// `tab.list` of the pane) is an agent's chat, or shows a terminal an agent
/// of `agents` (`agent.list`) runs in and has not ended. A caller's tab never
/// opens in another agent's pane. The caller here is a plain shell, which has
/// no session of its own, so every agent's chat is another agent's.
fn holds_agent(tabs: &Value, agents: &Value) -> bool {
    let live: Vec<&str> = rows(agents)
        .iter()
        .filter(|agent| agent.get("state").and_then(Value::as_str) != Some("done"))
        .filter_map(|agent| agent.get("terminal_id").and_then(Value::as_str))
        .collect();
    rows(tabs).iter().any(|tab| {
        is_agent_chat(tab)
            || tab
                .get("content_id")
                .and_then(Value::as_str)
                .is_some_and(|terminal| live.contains(&terminal))
    })
}

/// Whether a tab row is an agent's chat: a conversation tab
/// (`content_kind: conversation`) whose record names an agent session
/// (`extra.conversation.agent_session.session`, the store's
/// `agent-session-tabs-v1` record). A chat tab that has no session yet (a
/// New Tab page before its agent starts) is no agent's, as in the app.
fn is_agent_chat(tab: &Value) -> bool {
    tab.get("content_kind").and_then(Value::as_str) == Some("conversation")
        && tab
            .pointer("/extra/conversation/agent_session/session")
            .and_then(Value::as_str)
            .is_some_and(|session| !session.is_empty())
}

/// The id of the pane a `pane.neighbor.get` answer names, if any.
pub(super) fn neighbor_pane(answer: &Value) -> Option<String> {
    answer
        .get("value")
        .unwrap_or(answer)
        .pointer("/pane/id")
        .and_then(Value::as_str)
        .map(str::to_owned)
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

impl Caller {
    /// [`creation_scopes`] for this caller. A Chief turn's own place is the
    /// Home workspace, which the app draws as a page: a pane, a screen or a
    /// link made there may never be seen. Only its tabs go beside the Home
    /// chat (the app's `beside` answer is a column the window shows); its
    /// pane, screen and link keep the daemon's default.
    pub(super) fn creation_scopes(&self, operation: ResourceOperation) -> Option<Scopes> {
        let tab = matches!(
            operation,
            ResourceOperation::TabCreateTerminal
                | ResourceOperation::TabCreateBrowser
                | ResourceOperation::BrowserProfileOpen
        );
        if self.home_chat && !tab {
            return None;
        }
        creation_scopes(operation)
    }
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
/// asked for as a new column right of `chat_pane` ([`Placement::NewColumn`]):
/// its command, directory and size carry over; `name` does not (a split has
/// none), so the caller renames the new tab after.
pub(super) fn split_params(
    create: &Map<String, Value>,
    workspace: &str,
    chat_pane: &str,
) -> Map<String, Value> {
    let mut split = split_right_params(create, workspace, chat_pane);
    // A column that shares the window with the chat, never one wider than it.
    split.insert("fit".into(), json!(true));
    split
}

/// [`split_params`] for [`Placement::SplitRight`]: a new pane split off the
/// right of `pane`, directly beside it (no strip column, so no `fit`).
pub(super) fn split_right_params(
    create: &Map<String, Value>,
    workspace: &str,
    pane: &str,
) -> Map<String, Value> {
    let mut split = split_below_params(create, workspace, pane);
    split.insert("direction".into(), json!("right"));
    split
}

/// The daemon's reason code for a new pane it refuses in an agent chat dock
/// (`operation.failed`, `details.extra.reason_code`).
const DOCK_REFUSAL: &str = cmux_tui_core::AGENT_CHAT_COLUMN_CODE;

/// The key step of the column that [`column_after_refusal`] makes
/// (`<key>-beside-fit`), apart from the refused split's own (`<key>-beside`).
pub(super) const COLUMN_STEP: &str = "beside-fit";

/// The correlation keys under which a try of the request that `key` names
/// can have created its pane or tab: `key` itself, and the key of the column
/// made after the daemon refused the split ([`column_after_refusal`]). A
/// retry asks for both, in this order, before it places anything.
pub(super) fn creation_keys(key: &str) -> [String; 2] {
    [key.to_owned(), format!("{key}-{COLUMN_STEP}")]
}

/// The column to make when the daemon refused `split`, a plain split right
/// of the caller's pane ([`split_right_params`]), because that pane is in
/// an agent chat dock: the same split as a strip column that shares the
/// window ([`split_params`]). The app's `docked` and the daemon's dock rule
/// can disagree, so every caller kind gets this. `None` for any other split
/// and any other refusal, which is reported as it is. A refused split
/// applied nothing, so the column is the one creation of the request. The
/// daemon keeps the refused split's correlation key bound to that split, so
/// the column has a key of its own ([`creation_keys`]).
pub(super) fn column_after_refusal(
    split: &Map<String, Value>,
    error: &Value,
) -> Option<Map<String, Value>> {
    let plain_right = split.get("direction").and_then(Value::as_str) == Some("right")
        && !split.contains_key("fit");
    if !plain_right || !refused_by_dock(error) {
        return None;
    }
    let mut column = split.clone();
    column.insert("fit".into(), json!(true));
    if let Some(key) = split.get("correlation_key").and_then(Value::as_str) {
        let [_, column_key] = creation_keys(key);
        column.insert("correlation_key".into(), json!(column_key));
    }
    Some(column)
}

/// Whether `error` (a resource error) is the daemon's refusal of a new pane
/// in an agent chat dock, by its reason code.
pub(super) fn refused_by_dock(error: &Value) -> bool {
    error.get("code").and_then(Value::as_str) == Some("operation.failed")
        && error.pointer("/details/extra/reason_code").and_then(Value::as_str) == Some(DOCK_REFUSAL)
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

/// The key that names one creation across its tries: the `correlation_key`
/// the request carries, else its idempotency key (the daemon's own default).
/// `None`: the request has no identity a retry could repeat.
pub(super) fn correlation_key<'a>(
    create: &'a Map<String, Value>,
    idempotency_key: Option<&'a str>,
) -> Option<&'a str> {
    create.get("correlation_key").and_then(Value::as_str).or(idempotency_key)
}

/// `split` named as the one creation of the request `key` names, so the
/// daemon refuses any other creation under that key.
pub(super) fn correlated(mut split: Map<String, Value>, key: Option<&str>) -> Map<String, Value> {
    if let Some(key) = key {
        split.entry("correlation_key").or_insert_with(|| json!(key));
    }
    split
}

/// The `session.creation.resolve` params that ask the session of `create`
/// what the creation `key` names made.
pub(super) fn creation_lookup_params(create: &Map<String, Value>, key: &str) -> Map<String, Value> {
    let mut lookup = Map::new();
    for route in ["machine", "session"] {
        if let Some(value) = create.get(route) {
            lookup.insert(route.into(), value.clone());
        }
    }
    lookup.insert("correlation_key".into(), json!(key));
    lookup
}

/// What an earlier try of the same request created.
#[derive(Debug, PartialEq)]
pub(super) struct Earlier {
    /// The daemon operation that made it (`pane.split`, `tab.create_terminal`).
    pub operation: String,
    /// The created path (`workspace_id`, `pane_id`, `tab_id`, `terminal_id`).
    pub path: Value,
    /// The answer of that creation, as a replay of it.
    pub result: Value,
}

/// The creation an earlier try made, from the daemon's
/// `session.creation.resolve` answer; `None` when the key made nothing yet.
pub(super) fn earlier_creation(resolution: &Value) -> Option<Earlier> {
    if resolution.get("state").and_then(Value::as_str) != Some("created") {
        return None;
    }
    let path = resolution.get("created_path").filter(|path| path.is_object())?.clone();
    let operation = resolution.get("operation").and_then(Value::as_str)?.to_owned();
    let mut result = Map::new();
    result.insert("value".into(), path.clone());
    for field in ["generation", "revision"] {
        if let Some(value) = resolution.get(field) {
            result.insert(field.into(), value.clone());
        }
    }
    result.insert("replayed".into(), json!(true));
    Some(Earlier { operation, path, result: Value::Object(result) })
}

/// The error for a request whose key an earlier request of another kind
/// used for its creation (`existing`: that creation's operation), in the
/// shape of the daemon's own refusal.
pub(super) fn creation_conflict(existing: &str) -> Value {
    json!({
        "code": "creation.conflict",
        "message": format!(
            "this key already names another creation ({existing}); use a new idempotency key"
        ),
        "details": {"existing_operation": existing},
        "retryable": false,
    })
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
    fn a_browser_with_no_place_is_a_tab_in_the_column_right_of_the_caller() {
        let lone = json!({"pane": "pane_web", "placement": "existing_column", "panes": [
            {"id": "pane_web", "kinds": ["browser"]},
        ]});
        assert_eq!(
            browser_placement(&identity(lone)),
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_web".into() })
        );
        let terminal = json!({"pane": "pane_term", "placement": "existing_column", "panes": [
            {"id": "pane_term", "kinds": ["terminal"]},
        ]});
        assert_eq!(
            browser_placement(&identity(terminal)),
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_term".into() }),
            "a browser beside a lone terminal pane is a tab there, never a split below it"
        );
        let column = json!({"pane": "pane_web", "placement": "existing_column", "panes": [
            {"id": "pane_web", "kinds": ["browser"]}, {"id": "pane_md", "kinds": []},
        ]});
        assert_eq!(
            browser_placement(&identity(column)),
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_web".into() })
        );
        let mixed = json!({"pane": "pane_a", "placement": "existing_column", "panes": [
            {"id": "pane_a", "kinds": ["terminal"]}, {"id": "pane_b", "kinds": []},
        ]});
        assert_eq!(
            browser_placement(&identity(mixed)),
            Some(Placement::Pane { workspace: "ws_a".into(), pane: "pane_b".into() })
        );
        assert_eq!(
            browser_placement(&identity(json!({"pane": null, "placement": "new_column"}))),
            None
        );
        assert_eq!(browser_placement(&json!({"caller": {"found": false}, "beside": null})), None);
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
