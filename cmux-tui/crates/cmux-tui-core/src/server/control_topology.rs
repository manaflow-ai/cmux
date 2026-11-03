//! The session topology in the app control socket's `snapshot.get` shape
//! (`control-topology-v1`, plans/cmux-next/control-snapshot-topology.md).
//!
//! The Mac app answers `snapshot.get`, `cmux tree` and `tabs.search` off its
//! main thread from a second copy of the whole session that it maps from its
//! daemon mirror on the main thread after every model change
//! (`ControlTopologyMapper`, `ControlSnapshotPublisher`). The workspaces,
//! screens, panes and tabs in that copy are this daemon's: `control-topology`
//! maps them here, from the same tree `list-workspaces` sends, with the rules
//! the app's mapper applies, so the app no longer has to.
//!
//! What only the app knows (the tab a window shows in a pane, the app's own
//! page tabs, the titles its pages give store page tabs, the browser tabs a
//! pane mirrors) is the app's view state: the app publishes it with
//! `set-control-view` as its own per-connection record
//! (OWNERSHIP-PRINCIPLES.md, "Single writer per entity"). Only that
//! connection writes it, `control-topology` joins the asking connection's
//! record, and the record ends with the connection.
//!
//! Not mapped here (app facts the app still adds to its reply): windows,
//! focus, sessions, the daemon connection state, remote sessions'
//! workspaces, and the app's pending intents (stand-ins of a create in
//! flight, a tab whose close is in flight): this answer is the daemon's
//! confirmed state.
//!
//! A remote device's lane and a page connection get neither command: the
//! answer lists every workspace (incognito ones too) and every tab title.

use std::collections::BTreeMap;
use std::collections::HashMap;
use std::sync::Arc;

use serde::Deserialize;
use serde_json::Map;
use serde_json::Value;
use serde_json::json;

use crate::Mux;
use crate::panic_free::RecoverPoison;

/// The largest `set-control-view` record, in JSON bytes.
pub(crate) const MAX_VIEW_BYTES: usize = 1 << 20;
/// The most panes and page titles one record may name.
pub(crate) const MAX_VIEW_ENTRIES: usize = 20_000;
/// The longest id, page id or title in a record, in bytes.
pub(crate) const MAX_VIEW_STRING_BYTES: usize = 4096;

/// One connection's app-only view facts (`set-control-view {view}`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ControlView {
    /// By pane id (`pane_…`, or `pane:<handle>` before it has one): what the
    /// app shows for that pane. A pane not named has no app facts.
    #[serde(default)]
    pub(crate) panes: BTreeMap<String, PaneView>,
    /// By tab id: the title the app's page gives a store page tab
    /// (`page-tabs-v1`; a Files tab names its file). Other tabs ignore it.
    #[serde(default)]
    pub(crate) page_titles: BTreeMap<String, String>,
}

/// The app facts of one pane.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PaneView {
    /// The tab the window shows in the pane.
    #[serde(default)]
    pub(crate) selected_tab: Option<String>,
    /// The app's own page tabs in the pane's strip (the App Store, Settings),
    /// which this daemon does not hold.
    #[serde(default)]
    pub(crate) page_tabs: Vec<PageTabView>,
    /// Browser tabs of other panes this pane's strip also lists.
    #[serde(default)]
    pub(crate) mirrored_tabs: Vec<String>,
}

/// One app-only page tab.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct PageTabView {
    pub(crate) id: String,
    pub(crate) page: String,
    pub(crate) title: String,
    #[serde(default)]
    pub(crate) selected: bool,
}

impl ControlView {
    /// Parse and bound a `set-control-view` record.
    pub(crate) fn parse(value: Value) -> anyhow::Result<Self> {
        let bytes = serde_json::to_vec(&value)?.len();
        anyhow::ensure!(
            bytes <= MAX_VIEW_BYTES,
            "bad request: view is {bytes} bytes; the most is {MAX_VIEW_BYTES}"
        );
        let view: Self = serde_json::from_value(value)
            .map_err(|error| anyhow::anyhow!("bad request: view: {error}"))?;
        anyhow::ensure!(
            view.panes.len() <= MAX_VIEW_ENTRIES && view.page_titles.len() <= MAX_VIEW_ENTRIES,
            "bad request: view names more than {MAX_VIEW_ENTRIES} panes or titles"
        );
        let strings = view
            .panes
            .iter()
            .flat_map(|(id, pane)| {
                std::iter::once(id.as_str())
                    .chain(pane.selected_tab.as_deref())
                    .chain(pane.mirrored_tabs.iter().map(String::as_str))
                    .chain(
                        pane.page_tabs.iter().flat_map(|tab| {
                            [tab.id.as_str(), tab.page.as_str(), tab.title.as_str()]
                        }),
                    )
            })
            .chain(view.page_titles.iter().flat_map(|(id, title)| [id.as_str(), title.as_str()]));
        for text in strings {
            anyhow::ensure!(
                text.len() <= MAX_VIEW_STRING_BYTES,
                "bad request: a view string is longer than {MAX_VIEW_STRING_BYTES} bytes"
            );
        }
        Ok(view)
    }
}

/// What the daemon knows beside the tree: personal groups, agent status by
/// surface, and tabs that show unread by their state record.
#[derive(Debug, Default)]
pub(crate) struct DaemonFacts {
    /// `list-workspaces`' tree (`workspaces_json`).
    pub(crate) tree: Value,
    /// The home session's personal groups (`list-personal` `groups`), in
    /// order; `None` when the session serves none.
    pub(crate) personal_groups: Option<Vec<Value>>,
    /// Agent status by surface: its state and its agent name.
    pub(crate) agents: HashMap<u64, (String, Option<String>)>,
    /// Tab ids whose state record shows them unread: marked unread by hand
    /// (`tab-mark-unread-v1`) or holding an agent's attention mark
    /// (`tab-attention-v1`).
    pub(crate) marked_tabs: std::collections::HashSet<String>,
}

/// `set-control-view {view}`: replace this connection's view record.
pub(super) fn set_view(mux: &Arc<Mux>, client: u64, view: Value) -> anyhow::Result<Value> {
    refuse_foreign(mux, client, "set-control-view")?;
    let view = ControlView::parse(view)?;
    let mut state = mux.control_clients.state.lock().recover_poison();
    let record =
        state.clients.get_mut(&client).ok_or_else(|| anyhow::anyhow!("unknown client {client}"))?;
    record.control_view = Some(view);
    Ok(json!({}))
}

/// `control-topology`: the session topology joined with this connection's
/// view record.
pub(super) fn topology(mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
    refuse_foreign(mux, client, "control-topology")?;
    // Each lock alone, in turn: the clients lock is released before the
    // state, presentation and registry locks are taken.
    let view = {
        let state = mux.control_clients.state.lock().recover_poison();
        state.clients.get(&client).and_then(|record| record.control_view.clone())
    }
    .unwrap_or_default();
    let facts = daemon_facts(mux)?;
    let mut reply = topology_json(&facts, &view);
    let (registry_id, generation) = mux.registry_identity();
    if let Value::Object(object) = &mut reply {
        object.insert("registry_id".into(), json!(registry_id));
        object.insert("generation".into(), json!(generation));
    }
    Ok(reply)
}

fn refuse_foreign(mux: &Mux, client: u64, command: &str) -> anyhow::Result<()> {
    anyhow::ensure!(
        !super::incognito_remote::is_remote_device(mux, client)
            && !super::origin_gate::is_page(mux, client),
        "forbidden: {command} is for the app's own connection"
    );
    Ok(())
}

fn daemon_facts(mux: &Mux) -> anyhow::Result<DaemonFacts> {
    let notifications = mux.tree_decorations();
    let tree = mux.with_state(|state| super::workspaces_json(state, &notifications));
    let personal = serde_json::to_value(mux.personal_snapshot()?.groups)?;
    let personal_groups = personal.as_array().cloned();
    let agents = mux
        .list_agents(None, None)
        .into_iter()
        .map(|record| (record.surface, (record.state.as_str().to_string(), record.agent)))
        .collect();
    let marked_tabs = mux.workspace_registry.lock().recover_poison().read_state(marked_tab_ids)?;
    Ok(DaemonFacts { tree, personal_groups, agents, marked_tabs })
}

/// Tab ids whose state record shows them unread.
fn marked_tab_ids(
    connection: &rusqlite::Connection,
) -> anyhow::Result<std::collections::HashSet<String>> {
    let mut statement = connection.prepare(
        "SELECT tab_id, marked_unread, attention_json FROM tab_state
         WHERE coalesce(marked_unread, 0) != 0 OR attention_json IS NOT NULL",
    )?;
    let rows = statement.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, Option<i64>>(1)?,
            row.get::<_, Option<String>>(2)?,
        ))
    })?;
    let mut marked = std::collections::HashSet::new();
    for row in rows {
        let (tab, marked_unread, attention) = row?;
        let attention = attention
            .and_then(|stored| serde_json::from_str::<Value>(&stored).ok())
            .is_some_and(|value| valid_attention(&value));
        if marked_unread.is_some_and(|value| value != 0) || attention {
            marked.insert(tab);
        }
    }
    Ok(marked)
}

/// An attention mark the app shows: a non-empty `reason` and a whole
/// `at_ms` (the app's `TabAttention(_:)`).
pub(crate) fn valid_attention(value: &Value) -> bool {
    let reason =
        value.get("reason").and_then(Value::as_str).is_some_and(|reason| !reason.is_empty());
    let at = value.get("at_ms").is_some_and(|at| {
        at.as_u64().is_some()
            || at.as_f64().is_some_and(|at| at >= 0.0 && at.fract() == 0.0 && at <= u64::MAX as f64)
    });
    reason && at
}

/// The topology of `facts` with `view`'s app facts: `workspace_groups`,
/// `workspaces` (in `snapshot.get`'s `topology` shape) and `tab_count` (the
/// daemon's tabs; app page tabs are not counted).
pub(crate) fn topology_json(facts: &DaemonFacts, view: &ControlView) -> Value {
    let groups =
        facts.personal_groups.clone().unwrap_or_else(|| array(&facts.tree, "groups").to_vec());
    let workspace_groups = groups.iter().map(group_json).collect::<Vec<_>>();
    let mut tab_count = 0usize;
    let workspaces = array(&facts.tree, "workspaces")
        .iter()
        .map(|workspace| workspace_json(workspace, facts, view, &mut tab_count))
        .collect::<Vec<_>>();
    json!({
        "workspace_groups": workspace_groups,
        "workspaces": workspaces,
        "tab_count": tab_count,
    })
}

fn array<'a>(value: &'a Value, key: &str) -> &'a [Value] {
    value.get(key).and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default()
}

fn text<'a>(value: &'a Value, key: &str) -> Option<&'a str> {
    value.get(key).and_then(Value::as_str)
}

fn optional(value: Option<&str>) -> Value {
    value.map_or(Value::Null, |text| json!(text))
}

fn handle(value: &Value) -> String {
    value.get("id").and_then(Value::as_u64).map(|id| id.to_string()).unwrap_or_default()
}

fn group_json(group: &Value) -> Value {
    json!({
        "id": text(group, "id").unwrap_or_default(),
        "name": text(group, "name").unwrap_or_default(),
        "color": optional(text(group, "color")),
        "collapsed": group.get("collapsed").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// A workspace's key: its durable key, else `handle:<id>`.
fn workspace_key(workspace: &Value) -> String {
    text(workspace, "key").map_or_else(|| format!("handle:{}", handle(workspace)), str::to_string)
}

fn workspace_json(
    workspace: &Value,
    facts: &DaemonFacts,
    view: &ControlView,
    tab_count: &mut usize,
) -> Value {
    let key = workspace_key(workspace);
    let title = text(workspace, "title");
    let name = match title {
        Some(title) if !title.is_empty() => title,
        _ => text(workspace, "name").unwrap_or_default(),
    };
    let screens = array(workspace, "screens");
    // Unread tabs of the mapped tree; the rollup only for a workspace whose
    // tree has no screens (the app's `WorkspaceModel.unreadCount`).
    let unread = if screens.is_empty() {
        workspace.get("unread_count").and_then(Value::as_u64).unwrap_or(0)
    } else {
        screens
            .iter()
            .flat_map(|screen| array(screen, "panes"))
            .flat_map(|pane| array(pane, "tabs"))
            .filter(|tab| notification_unread(tab))
            .count() as u64
    };
    json!({
        "id": text(workspace, "resource_id").map_or_else(|| key.clone(), str::to_string),
        "key": key,
        "handle": handle(workspace),
        "name": name,
        "title": optional(title),
        "color": optional(text(workspace, "color")),
        "icon": optional(text(workspace, "icon")),
        "group": optional(text(workspace, "group")),
        "unread": unread,
        "machine": Value::Null,
        "screens": screens.iter().map(|screen| screen_json(screen, facts, view, tab_count)).collect::<Vec<_>>(),
        "session": Value::Null,
    })
}

fn notification_unread(tab: &Value) -> bool {
    tab.get("notification")
        .and_then(|notification| notification.get("unread"))
        .and_then(Value::as_bool)
        .unwrap_or(false)
}

fn pane_id(pane: &Value) -> String {
    text(pane, "resource_id").map_or_else(|| format!("pane:{}", handle(pane)), str::to_string)
}

fn screen_json(
    screen: &Value,
    facts: &DaemonFacts,
    view: &ControlView,
    tab_count: &mut usize,
) -> Value {
    let panes = array(screen, "panes");
    let zoomed = screen.get("zoomed_pane").and_then(Value::as_u64).and_then(|zoomed| {
        panes
            .iter()
            .find(|pane| pane.get("id").and_then(Value::as_u64) == Some(zoomed))
            .map(pane_id)
    });
    let placed = placed_columns(screen);
    json!({
        "id": text(screen, "resource_id")
            .map_or_else(|| format!("screen:{}", handle(screen)), str::to_string),
        "handle": handle(screen),
        "name": optional(text(screen, "name")),
        "zoomed_pane": zoomed.map_or(Value::Null, Value::String),
        "panes": panes.iter().map(|pane| pane_json(pane, &placed, facts, view, tab_count)).collect::<Vec<_>>(),
    })
}

/// A screen's columns as the window draws them, left to right: left docks,
/// the scrolling strip, right docks; top and bottom bands are no column.
/// Each is its panes (by handle) and its dock edge. Empty for a screen stored
/// as one split tree.
fn placed_columns(screen: &Value) -> Vec<(Vec<u64>, Option<String>)> {
    let mut ranked = array(screen, "columns")
        .iter()
        .filter_map(|column| {
            let edge = column.get("dock").and_then(|dock| text(dock, "edge"));
            let rank = match edge {
                None => 1,
                Some("left") => 0,
                Some("top" | "bottom") => return None,
                // The app reads an edge it does not know as `right`.
                Some(_) => 2,
            };
            let edge = edge.map(|edge| match edge {
                "left" | "right" | "top" | "bottom" => edge.to_string(),
                _ => "right".to_string(),
            });
            let mut panes = Vec::new();
            layout_panes(column.get("layout").unwrap_or(&Value::Null), &mut panes);
            Some((rank, panes, edge))
        })
        .collect::<Vec<_>>();
    // Stable: columns of one rank keep their order.
    ranked.sort_by_key(|(rank, _, _)| *rank);
    ranked.into_iter().map(|(_, panes, edge)| (panes, edge)).collect()
}

/// A layout node's panes, depth first (`LayoutNode.paneIDs`).
fn layout_panes(node: &Value, panes: &mut Vec<u64>) {
    match text(node, "type") {
        Some("leaf") => panes.extend(node.get("pane").and_then(Value::as_u64)),
        Some("split") => {
            layout_panes(node.get("a").unwrap_or(&Value::Null), panes);
            layout_panes(node.get("b").unwrap_or(&Value::Null), panes);
        }
        Some("stack") => panes.extend(array(node, "panes").iter().filter_map(Value::as_u64)),
        _ => {}
    }
}

fn pane_json(
    pane: &Value,
    placed: &[(Vec<u64>, Option<String>)],
    facts: &DaemonFacts,
    view: &ControlView,
    tab_count: &mut usize,
) -> Value {
    let id = pane_id(pane);
    let facts_view = view.panes.get(&id);
    let tabs = array(pane, "tabs");
    *tab_count += tabs.len();
    let handle_number = pane.get("id").and_then(Value::as_u64);
    let (column, dock) = if placed.is_empty() {
        (json!(0), Value::Null)
    } else {
        match placed
            .iter()
            .position(|(panes, _)| handle_number.is_some_and(|pane| panes.contains(&pane)))
        {
            Some(index) => (
                json!(index),
                placed
                    .get(index)
                    .and_then(|(_, dock)| dock.clone())
                    .map_or(Value::Null, Value::String),
            ),
            None => (Value::Null, Value::Null),
        }
    };
    let mut tab_values = tabs.iter().map(|tab| tab_json(tab, facts, view)).collect::<Vec<_>>();
    if let Some(pane_view) = facts_view {
        tab_values.extend(pane_view.page_tabs.iter().map(|page| {
            json!({"id": page.id, "kind": "page", "page": page.page, "title": page.title, "selected": page.selected})
        }));
    }
    let tab_id_of = |surface: u64| {
        tabs.iter()
            .find(|tab| tab.get("surface").and_then(Value::as_u64) == Some(surface))
            .map_or_else(|| surface.to_string(), tab_id)
    };
    let tab_groups = array(pane, "tab_groups")
        .iter()
        .map(|group| {
            json!({
                "id": text(group, "id").unwrap_or_default(),
                "name": text(group, "name").unwrap_or_default(),
                "color": optional(text(group, "color")),
                "collapsed": group.get("collapsed").and_then(Value::as_bool).unwrap_or(false),
                "members": array(group, "surfaces").iter().filter_map(Value::as_u64).map(&tab_id_of).collect::<Vec<_>>(),
            })
        })
        .collect::<Vec<_>>();
    let mut value = Map::new();
    value.insert("id".into(), json!(id));
    value.insert("handle".into(), json!(handle(pane)));
    value.insert("name".into(), optional(text(pane, "name")));
    value.insert(
        "selected_tab".into(),
        optional(facts_view.and_then(|pane| pane.selected_tab.as_deref())),
    );
    value.insert("tabs".into(), Value::Array(tab_values));
    value.insert("tab_groups".into(), Value::Array(tab_groups));
    value.insert("column".into(), column);
    value.insert("dock".into(), dock);
    // Only a pane that mirrors a tab says so (older readers see the same object).
    if let Some(mirrored) =
        facts_view.map(|pane| &pane.mirrored_tabs).filter(|tabs| !tabs.is_empty())
    {
        value.insert("mirrored_tabs".into(), json!(mirrored));
    }
    Value::Object(value)
}

/// A tab's id: its public id, else `terminal:<terminal id>`, else
/// `surface:<surface>` (`TabModel.identity`).
fn tab_id(tab: &Value) -> String {
    if let Some(id) = text(tab, "tab_resource_id") {
        return id.to_string();
    }
    if let Some(terminal) = text(tab, "terminal_id") {
        return format!("terminal:{terminal}");
    }
    format!("surface:{}", tab.get("surface").and_then(Value::as_u64).unwrap_or_default())
}

fn tab_json(tab: &Value, facts: &DaemonFacts, view: &ControlView) -> Value {
    let id = tab_id(tab);
    let raw_kind = text(tab, "kind").unwrap_or("pty");
    let kind = match raw_kind {
        "pty" => "terminal",
        other => other,
    };
    let conversation = (raw_kind == "conversation").then(|| tab.get("conversation")).flatten();
    let agent_session = conversation
        .and_then(|conversation| conversation.get("agent_session"))
        .filter(|session| !session.is_null());
    // A conversation names an agent session or a page, never both (`ConversationTabRef`).
    let page = conversation
        .filter(|_| agent_session.is_none())
        .and_then(|conversation| text(conversation, "page"));
    let raw_title = text(tab, "title").unwrap_or_default();
    let title_text = match raw_kind {
        "pty" | "remote-terminal" => terminal_title_text(raw_title),
        _ => raw_title.to_string(),
    };
    let name = text(tab, "name");
    let mut title = match name {
        Some(name) if !name.is_empty() => name.to_string(),
        _ => title_text,
    };
    if page.is_some()
        && let Some(page_title) = view.page_titles.get(&id)
    {
        title.clone_from(page_title);
    }
    let terminal_id = text(tab, "terminal_id");
    let size = tab.get("size");
    let surface = tab.get("surface").and_then(Value::as_u64).unwrap_or_default();
    let agent = facts.agents.get(&surface);
    let unread = notification_unread(tab) || facts.marked_tabs.contains(&id);
    let shown_kind = if page.is_some() { "page" } else { kind };
    json!({
        "id": id,
        "surface": surface.to_string(),
        "kind": shown_kind,
        "page": optional(page),
        "title": title,
        "name": optional(name),
        "terminal": optional(text(tab, "terminal_resource_id").or(terminal_id)),
        "terminal_key": optional(terminal_id),
        "columns": size.and_then(|size| size.get("cols")).and_then(Value::as_u64).map_or(Value::Null, |cols| json!(cols)),
        "rows": size.and_then(|size| size.get("rows")).and_then(Value::as_u64).map_or(Value::Null, |rows| json!(rows)),
        "cwd": optional(text(tab, "cwd")),
        "url": optional(text(tab, "url")),
        "git_branch": optional(text(tab, "git_branch")),
        "pinned": tab.get("pinned").and_then(Value::as_bool).unwrap_or(false),
        "dead": tab.get("dead").and_then(Value::as_bool).unwrap_or(false),
        "unread": unread,
        "tab_group": optional(text(tab, "group")),
        "agent_state": optional(agent.map(|(state, _)| state.as_str())),
        "agent": optional(agent.and_then(|(_, agent)| agent.as_deref())),
        "agent_session": optional(agent_session.and_then(|session| text(session, "session"))),
    })
}

/// A terminal's title as a tab shows it: without the status glyphs a program
/// puts in front (`TerminalTitle(raw:)`, plans/cmux-next/osc-titles.md). A
/// title of glyphs only keeps them, so the tab is not blank.
pub(crate) fn terminal_title_text(raw: &str) -> String {
    let mut rest = raw;
    while let Some(first) = rest.chars().next().filter(|first| is_status_glyph(*first)) {
        rest = rest.strip_prefix(first).unwrap_or_default();
        // A variation selector (`✔︎`) belongs to the glyph before it.
        while let Some(next) = rest.chars().next().filter(|next| is_variation_selector(*next)) {
            rest = rest.strip_prefix(next).unwrap_or_default();
        }
        rest = rest.trim_start_matches(char::is_whitespace);
    }
    let words = rest.trim_matches(is_space);
    if words.is_empty() { raw.trim_matches(is_space).to_string() } else { words.to_string() }
}

/// Foundation's `CharacterSet.whitespaces`: tab and the space separators.
fn is_space(character: char) -> bool {
    matches!(
        character,
        '\t' | ' ' | '\u{00A0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200A}' | '\u{202F}' | '\u{205F}' | '\u{3000}'
    )
}

fn is_variation_selector(character: char) -> bool {
    matches!(
        character,
        '\u{180B}'..='\u{180D}' | '\u{180F}' | '\u{FE00}'..='\u{FE0F}' | '\u{E0100}'..='\u{E01EF}'
    )
}

/// A leading status glyph: a spinner frame, a resting marker, a check mark
/// or a cross.
fn is_status_glyph(character: char) -> bool {
    matches!(
        u32::from(character),
        0x2801..=0x28FF
            | 0x25D0..=0x25D3
            | 0x25F4..=0x25F7
            | 0x2596..=0x259F
            | 0x2733
            | 0x2736
            | 0x273B
            | 0x273D
            | 0x2722
            | 0x00B7
            | 0x25CF
            | 0x25CB
            | 0x25C9
            | 0x23FA
            | 0x2713
            | 0x2714
            | 0x2705
            | 0x2717
            | 0x2718
            | 0x274C
    )
}
